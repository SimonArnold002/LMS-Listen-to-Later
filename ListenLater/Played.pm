package Plugins::ListenLater::Played;

# Watches playback and moves a saved album to "Played" once most of it has been
# listened to. Subscribes to playlist newsong/stop/clear and, per player, counts
# the distinct tracks seen for whichever saved album is currently playing.
#
#   library albums  → real track count is known; threshold = played_threshold %.
#   streaming albums → no reliable total; fall back to streaming_min_tracks
#                      distinct tracks (best-effort, per the plan).
#
# This is the same code path for plays started inside the plugin or outside it;
# the `watch_outside` pref is the master toggle for auto-marking.

use strict;
use warnings;

use POSIX qw(ceil);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::ListenLater::DB;
use Plugins::ListenLater::Sources;

my $log   = logger('plugin.listenlater');
my $prefs = preferences('plugin.listenlater');

# per-player: { rec_id => N, seen => { url => 1 }, total => T|undef }
my %tracking;

# per-player pending "played through" mark: { rec_id, url, target, client, title }.
# Used for anything whose Played status rests on ONE track (a saved track, a Single, a
# 1-track library release) — there's no track COUNT to threshold, so it's marked on a
# timer once that track has actually been played. See _armDeferredMark.
my %trackPending;

# How much of a single track must actually play before it counts as Played.
use constant TRACK_MARK_FRACTION => 0.90;

# Fallback listen time (seconds) when the song reports no duration (some streams), where
# the fraction above can't be computed.
use constant TRACK_MARK_FALLBACK_SECS => 60;

sub init {
    my ($class) = @_;
    Slim::Control::Request::subscribe(
        \&_onChange,
        [['playlist'], ['newsong', 'stop', 'clear']],
    );
    $log->info('Listen Later play-detector subscribed');
    return;
}

sub shutdown {
    Slim::Control::Request::unsubscribe(\&_onChange);
    _cancelTrackMark($_) for keys %trackPending;
    return;
}

sub _onChange {
    my $request = shift;

    return unless $prefs->get('watch_outside');

    my $client = $request->client || return;
    my $cid    = $client->id;

    # stop / clear → finalise (threshold re-checked; only marks if reached)
    if ($request->isCommand([['playlist'], ['stop', 'clear']])) {
        _cancelTrackMark($cid);
        _finalize($cid);
        return;
    }

    # A new song supersedes any pending track mark: the old one either already fired or
    # didn't earn it.
    _cancelTrackMark($cid);

    my $song  = $client->playingSong   or return _finalize($cid);
    my $track = $song->track           or return _finalize($cid);
    my $url   = $track->url;

    # Independent TRACK-Played marking, separate from album-threshold tracking — no shared
    # state, so a track and its album never affect each other's Played status. The saved
    # track is LOOKED UP now (newsong, when the metadata is freshest) but only MARKED after
    # it has actually been listened to (_armDeferredMark) — a track has no track count to
    # threshold against, so without the timer merely skipping past a saved track would mark
    # it Played, and purgePlayed would then delete it played_retention_days later.
    # Best-effort; guarded.
    eval { _markPlayedTrack($client, $song, $track, $url); 1 }
        or $log->warn("LL: track-played check failed: $@");

    my $rec = _matchRecord($client, $track, $url);

    my $cur = $tracking{$cid};

    if ($rec && ($rec->{status} || '') eq 'later') {
        my $total = _totalTracks($rec);

        # A release that is COMPLETE after one track — a Single, or a 1-track library
        # release — must not be marked the instant that track starts. Counting says "1 of 1
        # seen" on the very first newsong, so skipping past it would mark it Played and
        # purgePlayed would delete it later. It has the same shape as a saved individual
        # track, so it takes the same played-through check instead of the counter.
        if (defined $total && $total == 1) {
            _finalize($cid) if $cur;
            delete $tracking{$cid};
            _armDeferredMark($client, $song, $rec, $url);
            return;
        }

        if ($cur && $cur->{rec_id} == $rec->{id}) {
            $cur->{seen}{$url} = 1;
        }
        else {
            _finalize($cid) if $cur;
            $tracking{$cid} = {
                rec_id   => $rec->{id},
                seen     => { $url => 1 },
                total    => $total,
                rel_type => $rec->{rel_type},
            };
        }
        _maybeMark($cid);
    }
    else {
        # now playing something not in our Listen Later list
        _finalize($cid) if $cur;
    }

    return;
}

# Find the saved individual TRACK (kind='track', status='later') this playing track is, and
# arm its Played mark. Matches first on the EXACT play url (a saved track stores its
# canonical url, which is what plays whether started from our list OR straight from the
# service/library — Qobuz/Tidal/Deezer/library all use stable per-track urls), then falls
# back to a metadata match (source+artist+album+title) for the rare url drift. Independent
# of album %tracking.
sub _markPlayedTrack {
    my ($client, $song, $track, $url) = @_;

    my $remote = $track->can('remote') ? $track->remote
        : ($url && $url !~ /^file:/i && $url =~ m|^\w+://|) ? 1 : 0;
    my $source = $remote ? Plugins::ListenLater::Sources::sourceFromUrl($url) : 'library';

    # Exact-url match first.
    my $rec = Plugins::ListenLater::DB::findTrackByUrl($source, $url);

    # Metadata fallback (streaming urls can differ between a stored favurl and the played
    # stream for some services): recover title/artist/album the same way _matchRecord does.
    if (!$rec) {
        my $title  = eval { $track->title }      // '';
        my $artist = eval { $track->artistName } // '';
        my $album;
        if (!$remote) {
            my $alb = $track->can('album') ? $track->album : undef;
            $album  = eval { $alb ? $alb->title : undef } // '';
            $artist = eval { $alb && $alb->contributor ? $alb->contributor->name : undef } // $artist;
        }
        else {
            $album = eval { $track->albumname } // '';
            if (!length $album || !length $artist || !length $title) {
                my $meta = Plugins::ListenLater::Sources::playingMeta($client, $url);
                $title  = $meta->{title}  if !length $title  && defined $meta->{title}  && length $meta->{title};
                $artist = $meta->{artist} if !length $artist && defined $meta->{artist} && length $meta->{artist};
                $album  = $meta->{album}  if !length $album  && defined $meta->{album}  && length $meta->{album};
            }
        }
        return unless length $title;
        $rec = Plugins::ListenLater::DB::findSavedTrack($source, $artist, $album, $title);
    }

    return unless $rec && ($rec->{status} || '') eq 'later';
    _armDeferredMark($client, $song, $rec, $url);
    return;
}

# Arm the deferred "played through" mark for a record whose Played status rests on ONE
# track — a saved individual track, a Single, or a 1-track library release. It fires at
# TRACK_MARK_FRACTION of the song's duration, or TRACK_MARK_FALLBACK_SECS when the song
# reports no duration (some streams).
#
# Why a fraction and not the actual end: the last seconds are usually fade/silence, and
# with crossfade or gapless the NEXT song's `newsong` — which cancels this mark — arrives
# BEFORE the current track's audio truly ends. 90% is "played through" in every practical
# sense and always lands before that hand-off.
sub _armDeferredMark {
    my ($client, $song, $rec, $url) = @_;

    my $dur    = eval { $song->duration } || 0;
    my $target = ($dur > 0) ? $dur * TRACK_MARK_FRACTION : 0;
    my $wait   = $target > 0 ? $target : TRACK_MARK_FALLBACK_SECS;
    $wait = 5 if $wait < 5;

    my $info = {
        rec_id => $rec->{id},
        url    => $url,
        target => $target,
        client => $client,
        title  => $rec->{track_title} || $rec->{album_title} || '?',
    };
    $trackPending{ $client->id } = $info;
    Slim::Utils::Timers::setTimer($client, time() + $wait, \&_deferredMarkTick, $info);

    $log->warn(sprintf("LL: rec %s ('%s') will be marked Played after %.0fs of playback%s",
        $rec->{id}, $info->{title}, $wait,
        $target ? sprintf(' (%d%% of %.0fs)', TRACK_MARK_FRACTION * 100, $dur) : ' (no duration reported)'));
    return;
}

# Timer body. A named sub (not a closure) so setTimer/killTimers can pair on the coderef,
# and so a re-arm can't build a self-referencing closure chain.
sub _deferredMarkTick {
    my ($client, $info) = @_;
    my $cid = $client->id;
    delete $trackPending{$cid};

    # Re-check the master toggle: it can be switched off while the timer runs, and an
    # auto-mark after that would be exactly what the user just disabled.
    return unless $prefs->get('watch_outside');

    my $nowUrl = eval { $client->playingSong->track->url };
    return unless defined $nowUrl && $nowUrl eq $info->{url};

    # Trust PLAYBACK progress, not the wall clock. A pause (or a seek backwards) means the
    # track hasn't actually been played through even though the timer has come round — so
    # re-arm for the shortfall instead of marking it.
    my $played = eval { $client->songElapsedSeconds } || 0;
    if ($info->{target} > 0 && $played + 1 < $info->{target}) {
        my $again = $info->{target} - $played;
        $again = 5 if $again < 5;
        $trackPending{$cid} = $info;
        Slim::Utils::Timers::setTimer($client, time() + $again, \&_deferredMarkTick, $info);
        $log->info("rec $info->{rec_id} only ${played}s in — re-checking in ${again}s");
        return;
    }

    # Re-read: the row may have been moved or removed while the timer ran.
    my $cur = Plugins::ListenLater::DB::get($info->{rec_id});
    return unless $cur && ($cur->{status} || '') eq 'later';
    Plugins::ListenLater::DB::markPlayed($info->{rec_id});
    $log->warn("LL: marked rec $info->{rec_id} ('$info->{title}') as Played — played through");
    return;
}

# Drop a player's pending mark (new song, stop, clear, shutdown). Keeps the client object
# it was armed with so the kill matches the (object, coderef) pair setTimer was given.
sub _cancelTrackMark {
    my ($cid) = @_;
    my $p = delete $trackPending{$cid} or return;
    eval { Slim::Utils::Timers::killTimers($p->{client}, \&_deferredMarkTick) };
    return;
}

# Map the playing track to a stored 'later'/'played' record (or undef).
sub _matchRecord {
    my ($client, $track, $url) = @_;

    my $remote = $track->can('remote') ? $track->remote
        : ($url && $url !~ /^file:/i && $url =~ m|^\w+://|) ? 1 : 0;

    if (!$remote) {
        my $album = $track->can('album') ? $track->album : undef;
        return undef unless $album && $album->can('id');
        return Plugins::ListenLater::DB::findBySourceAlbumId('library', $album->id);
    }

    my $source = Plugins::ListenLater::Sources::sourceFromUrl($url);
    my $artist = eval { $track->artistName } // '';
    my $album  = eval { $track->albumname }  // '';
    # Streaming services (Qobuz/Tidal/Deezer) don't store album/artist on the LMS Track
    # row — it lives in the protocol handler's metadata (the same source the status query
    # and Now Playing use). Without it $album stays '' and the play never matches, so the
    # album never auto-moves to Played. Fill the blanks from the handler.
    if (!length $album || !length $artist) {
        my $meta = Plugins::ListenLater::Sources::playingMeta($client, $url);
        $album  = $meta->{album}  if !length $album  && defined $meta->{album}  && length $meta->{album};
        $artist = $meta->{artist} if !length $artist && defined $meta->{artist} && length $meta->{artist};
    }
    return undef unless length $album;   # streaming best-effort

    # Match on artist+album regardless of year: the dedupe key now carries the release
    # year (so same-title different-year albums save separately), but a playing streaming
    # track can't be relied on to report the matching year, so Played uses the year-agnostic
    # lookup.
    my $rec = Plugins::ListenLater::DB::findByArtistAlbum($source, $artist, $album);
    return $rec if $rec;

    # The exact artist|album key lookup can miss when the playing track's metadata artist
    # differs from the stored album artist — a track credited "X feat. Y" vs the album's "X",
    # or an album-artist vs a track-artist. Fall back to an album-title match within the
    # source, disambiguated by the SAME token-subset artist compare replay uses — so a
    # same-titled album by a genuinely different artist is NOT wrongly marked Played. Both
    # sides must carry an artist: with no playing artist there's nothing to disambiguate a
    # title-only match, and an artist-LESS stored row can't be confirmed the same album as a
    # named playing track (the artist-less/artist-less case already matched exactly above).
    return undef unless length $artist;
    my $na = Plugins::ListenLater::Sources::_norm($artist);
    for my $c (Plugins::ListenLater::DB::findByAlbum($source, $album)) {
        next unless defined $c->{artist} && length $c->{artist};
        return $c if Plugins::ListenLater::Sources::_artistMatch(
            $na, Plugins::ListenLater::Sources::_norm($c->{artist}));
    }
    return undef;
}

sub _totalTracks {
    my ($rec) = @_;

    # A SINGLE has exactly one track — that IS what the classification means (Qobuz's
    # authoritative release_type, or a resolved count of 1; see Sources::relTypeFor). This
    # is a known total for a STREAMING release, which otherwise has none, and without it a
    # single can never be marked Played: 0.1.79 stores a streaming single in ALBUM form, so
    # it goes down this album path and lands on the streaming_min_tracks fallback below —
    # a floor of 4 distinct tracks that a 1-track release can never reach.
    return 1 if ($rec->{rel_type} || '') eq 'single';

    return undef unless ($rec->{source} || '') eq 'library';
    my $id = $rec->{ref}{album_id} or return undef;
    return eval {
        Slim::Schema->search('Track', { 'album.id' => $id }, { join => 'album' })->count;
    };
}

sub _maybeMark {
    my ($cid) = @_;
    my $t = $tracking{$cid} or return;

    my $seen = scalar keys %{ $t->{seen} };
    my $met;

    if (defined $t->{total} && $t->{total} > 0) {
        my $need = ceil(($prefs->get('played_threshold') / 100) * $t->{total});
        $need = 1 if $need < 1;
        $met = $seen >= $need;
    }
    else {
        my $need = $prefs->get('streaming_min_tracks') || 4;
        # An EP is 2-6 tracks (Sources::relTypeFor), so the default 4-track floor can be
        # more than the release HAS — cap it so a short EP can still complete. (A single
        # never reaches here: _totalTracks gives it a real total of 1.)
        $need = 2 if ($t->{rel_type} || '') eq 'ep' && $need > 2;
        $met = $seen >= $need;
    }

    if ($met) {
        Plugins::ListenLater::DB::markPlayed($t->{rec_id});
        # WARN, not INFO: INFO is invisible in log.txt unless the category is raised, which
        # is exactly what made "Played isn't working" undiagnosable from a log dump.
        $log->warn("LL: marked album rec $t->{rec_id} as Played ($seen tracks, rel="
            . ($t->{rel_type} || '-') . ", total=" . ($t->{total} // '-') . ")");
        delete $tracking{$cid};
    }
    return;
}

sub _finalize {
    my ($cid) = @_;
    return unless $tracking{$cid};
    _maybeMark($cid);
    delete $tracking{$cid};
    return;
}

1;
