package Plugins::ListenLater::Played;

# Watches playback and moves a saved album to "Played" once most of it has been
# listened to. Subscribes to playlist newsong/stop/clear and, per player, counts
# the distinct tracks seen for whichever saved album is currently playing.
#
#   library albums   → real track count is known; threshold = played_threshold %.
#   streaming albums → the same, once the release has been resolved and its playable
#                      track count stored; until then there is no reliable total and it
#                      falls back to streaming_min_tracks distinct tracks (best-effort).
#
# This is the same code path for plays started inside the plugin or outside it;
# the `watch_outside` pref is the master toggle for auto-marking.

use strict;
use warnings;

use POSIX qw(floor);

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
            # First track of a release we have no MEASURED length for: ask the service now.
            # This is the moment it matters and the moment we're best placed to ask — there's
            # a live client, and the answer decides whether this play can ever count. Fired
            # only here, in the branch that STARTS tracking, so a 10-track album asks once
            # rather than once per newsong. Async and best-effort: if it never answers, the
            # flat floor still applies, exactly as before.
            _learnTrackCount($client, $rec, $url) unless defined $total;
        }
        _maybeMark($cid);
    }
    else {
        # now playing something not in our Listen Later list
        _finalize($cid) if $cur;
    }

    return;
}

# Measure how long a release actually is, at the moment it starts playing, and remember it.
#
# This is what replaced guessing from the release type. A streaming row arrives with no
# measured length (the count only comes from the service, and the add path must not wait on
# one), so the first play is where we ask: resolve the tracklist, count the real tracks
# (Sources::isPlayableTrack) and store it. Every later play of that release — and the
# threshold for THIS one, if the answer arrives while it's still playing — then works from a
# fact instead of a label.
#
# In flight per record, so a stubborn service can't be asked twice over — but held as a
# TIMESTAMP, not a flag. A request the service ACCEPTS AND NEVER ANSWERS fires neither the
# callback below nor the eval's die branch, so a boolean guard would stick for the life of
# the server and this release could never be measured again: track_count stays NULL,
# _totalTracks returns undef, and it sits on the flat streaming_min_tracks floor forever —
# which anything shorter than the floor can never reach. That is the very bug the measure
# exists to fix, arriving back through the measure's own failure route. (_verifyRelease
# guards the identical case with VERIFY_TIMEOUT_SECS; this path had nothing.)
#
# Deliberately NOT a timer. Nothing has to HAPPEN when the guard expires — it is only ever
# read here — so evaluating it lazily at the single read site avoids arming, killing and
# pairing a timer, and with it the whole class of ordering bug that 0.1.83's re-arm chain
# and 0.1.90's $done flag both had to fix. It also covers a failure no $cb-based guard can
# see: a die inside the SERVICE's own async handler (Qobuz's _pagingGet dereferences the
# decoded body before our callback exists), where nothing of ours runs at all.
#
# Longer than the services' own HTTP timeout — Qobuz's SimpleAsyncHTTP uses 15s — so a slow
# but still-live request is never duplicated. A success deletes the entry outright, and once
# a count is stored _onChange stops asking at all (it fires only when $total is undef), so
# this window governs the failure case and nothing else.
use constant COUNT_STALE_SECS => 60;

my %counting;
sub _learnTrackCount {
    my ($client, $rec, $url) = @_;
    my $id = $rec->{id} or return;
    return if ($rec->{source} || '') eq 'library';   # counted live, never stored
    if (my $prev = $counting{$id}) {
        return if $prev > time() - COUNT_STALE_SECS;
        # Never silent: the lost request logged nothing at the time (nothing ran), so this
        # is the first and only chance to say it happened.
        $log->warn("LL: rec $id — the last release-length request never answered; re-asking");
    }
    $counting{$id} = time();

    my $cid = $client->id;
    eval {
        Plugins::ListenLater::Sources::resolveTrackCount($client, $rec, sub {
            my ($n) = @_;
            delete $counting{$id};
            unless ($n) {
                $log->warn("LL: rec $id — couldn't measure the release length; "
                    . "falling back to the streaming floor");
                return;
            }
            Plugins::ListenLater::DB::updateTrackCount($id, $n);
            $log->warn("LL: rec $id is $n track(s) — measured on first play");

            # Apply it to the play already in progress, if that's still what's on.
            my $t = $tracking{$cid};
            return unless $t && $t->{rec_id} == $id;

            # A release that turns out to be a SINGLE track must not now be marked by the
            # counter: it is already "1 of 1 seen", so it would be marked the instant it
            # started, which is the skip-past-it bug 0.1.83 exists to prevent. It has the
            # same shape as a saved individual track, so hand it to the same played-through
            # check — but only while it IS still the playing track.
            if ($n == 1) {
                delete $tracking{$cid};
                my $song = eval { $client->playingSong } or return;
                my $tr   = eval { $song->track }         or return;
                return unless ($tr->url // '') eq $url;
                _armDeferredMark($client, $song, $rec, $url);
                return;
            }

            $t->{total} = $n;
            _maybeMark($cid);
        });
        1;
    } or do { delete $counting{$id}; $log->warn("LL: rec $id — track-count measure failed: $@"); };
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

    # Last resort: match the label the SERVICE printed on the row this record was added
    # from (ref.svc_title — 0.1.92). Both lookups above key on the stored album TITLE, and
    # a sibling's '&al=' handshake deliberately replaces that with MusicBrainz's release
    # name — which for a release MB distinguishes OUTSIDE the title is the bare, shared one
    # ("American Football", where the service says "American Football (LP2)"), so the
    # playing track can never match it. The service label was kept at add time precisely
    # for this. Same artist guard as above, so a same-labelled release by a different
    # artist still can't be marked; and being LAST, it can only ever rescue a miss — it
    # cannot change which record an already-matching play resolves to.
    for my $c (Plugins::ListenLater::DB::findBySourceRefTitle($source, $album)) {
        next unless defined $c->{artist} && length $c->{artist};
        return $c if Plugins::ListenLater::Sources::_artistMatch(
            $na, Plugins::ListenLater::Sources::_norm($c->{artist}));
    }
    return undef;
}

# How many tracks the release actually has, or undef when that isn't known. The difference
# decides everything downstream: a known total is thresholded at played_threshold% of it,
# an unknown one falls back to the flat streaming_min_tracks floor in _maybeMark — which is
# wrong in both directions for a short release, so it is worth some effort to have a total.
sub _totalTracks {
    my ($rec) = @_;

    # A library release is counted live, not from any stored column: the library is the
    # authority on itself, and a rescan can change it.
    if (($rec->{source} || '') eq 'library') {
        my $id = $rec->{ref}{album_id} or return undef;
        return eval {
            Slim::Schema->search('Track', { 'album.id' => $id }, { join => 'album' })->count;
        };
    }

    # A streaming release that has been resolved — at add time, or on its first drill/play
    # from the list (Browse::_albumTracks) — carries its real playable track count, so the
    # same percentage threshold as a library album applies instead of the floor below. This
    # is the only thing that rescues a release SHORTER than that floor: a 1-track album (a
    # shape MusicBrainz hands us quite correctly — an album that happens to hold one track)
    # otherwise sits at 1 of a required 4 forever, never marked however often it's played.
    my $n = $rec->{track_count};
    return $n + 0 if defined $n && $n =~ /^\d+$/ && $n > 0;

    # And that is ALL. The release TYPE deliberately does not answer this question.
    #
    # 'single' used to return 1 here, on the reasoning that the classification means exactly
    # one track. It doesn't. The type comes from MusicBrainz (via the sibling's '&rt='
    # handshake) or a service's catalogue, and it is a BIBLIOGRAPHIC LABEL, not a count: MB
    # calls a lead track plus B-sides a Single, and calls a 1-track release an EP. Neither
    # plugin can change what MB says — LBF passes on what it is given. So every threshold
    # derived from the label was a guess dressed as a fact, and each way it could be wrong
    # cost a real bug: a "single" of 3 tracks marked Played after one, and an "EP" of 1 track
    # (adieu - Wanna me, reported 2026-07-30) that could never be marked because the EP floor
    # asked for 2 tracks it does not have.
    #
    # A length is now only ever MEASURED — the library, or a resolved tracklist counted by
    # Sources::isPlayableTrack — and if it isn't known yet, Played says so and asks for it
    # (_onChange fires resolveTrackCount on first play). The type survives as the row's
    # label, which is the one thing it is honest about.
    return undef;
}

# How many DISTINCT tracks of a release of $total tracks must be heard before it counts as
# Played. Split out of _maybeMark so it can be tested DIRECTLY: this arithmetic is the thing
# that has regressed most often in this plugin, and _maybeMark needs %tracking and writes to
# the DB, so a test could only ever restate the formula alongside it — and a restated formula
# goes on passing quite happily while the real one is wrong.
#
# Rounded DOWN, deliberately (2026-07-30, when the threshold moved 60% -> 90%). ceil() was
# fine at 60% but is punishing at 90%: 0.9*N exceeds N-1 for every N below 10, so ceil lands
# back on N and "90%" becomes arithmetically identical to "100%" for any release under ten
# tracks. An 8-track album with one track skipped — or one unplayable in this region — could
# then never be marked, however often it was heard. Rounding down always leaves a track of
# slack.
#
# But never down to 1 for a MULTI-track release: "1 of 2 seen" is already true on the very
# first newsong, so a 2-track release would be marked the instant it started — the
# skip-past-it bug 0.1.83 exists to prevent, arriving by a new route (at 90%,
# floor(0.9*2) = 1). A genuinely 1-track release never reaches here; it is routed to
# _armDeferredMark's played-through check instead.
sub tracksNeeded {
    my ($total) = @_;
    my $need = floor(($prefs->get('played_threshold') / 100) * $total);
    $need = 2 if $need < 2 && $total > 1;
    $need = 1 if $need < 1;
    return $need;
}

sub _maybeMark {
    my ($cid) = @_;
    my $t = $tracking{$cid} or return;

    my $seen = scalar keys %{ $t->{seen} };
    my $met;

    if (defined $t->{total} && $t->{total} > 0) {
        $met = $seen >= tracksNeeded($t->{total});
    }
    else {
        # No total: a streaming release whose length we could not measure, even after asking
        # for it on first play. The flat floor is an admitted guess at "enough of it", and a
        # release with fewer tracks than the floor can never reach it — which is why
        # _onChange works to avoid landing here at all.
        #
        # The floor is NOT adjusted by release type any more. It used to drop to 2 for an
        # 'ep', which reads as helpful and was the direct cause of a 1-track release that MB
        # labels an EP never being marked: capping at 2 still asks for a track that does not
        # exist. Guessing a smaller wrong number is not better than guessing a bigger one —
        # the answer is to measure, which _onChange now does.
        my $need = $prefs->get('streaming_min_tracks') || 4;
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
