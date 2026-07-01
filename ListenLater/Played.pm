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

use Plugins::ListenLater::DB;
use Plugins::ListenLater::Sources;

my $log   = logger('plugin.listenlater');
my $prefs = preferences('plugin.listenlater');

# per-player: { rec_id => N, seen => { url => 1 }, total => T|undef }
my %tracking;

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
    return;
}

sub _onChange {
    my $request = shift;

    return unless $prefs->get('watch_outside');

    my $client = $request->client || return;
    my $cid    = $client->id;

    # stop / clear → finalise (threshold re-checked; only marks if reached)
    if ($request->isCommand([['playlist'], ['stop', 'clear']])) {
        _finalize($cid);
        return;
    }

    my $song  = $client->playingSong   or return _finalize($cid);
    my $track = $song->track           or return _finalize($cid);
    my $url   = $track->url;

    my $rec = _matchRecord($client, $track, $url);

    my $cur = $tracking{$cid};

    if ($rec && ($rec->{status} || '') eq 'later') {
        if ($cur && $cur->{rec_id} == $rec->{id}) {
            $cur->{seen}{$url} = 1;
        }
        else {
            _finalize($cid) if $cur;
            $tracking{$cid} = {
                rec_id => $rec->{id},
                seen   => { $url => 1 },
                total  => _totalTracks($rec),
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
    return undef unless length $album;   # streaming best-effort

    # Match on artist+album regardless of year: the dedupe key now carries the release
    # year (so same-title different-year albums save separately), but a playing streaming
    # track can't be relied on to report the matching year, so Played uses the year-agnostic
    # lookup.
    return Plugins::ListenLater::DB::findByArtistAlbum($source, $artist, $album);
}

sub _totalTracks {
    my ($rec) = @_;
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
        $met = $seen >= ($prefs->get('streaming_min_tracks') || 4);
    }

    if ($met) {
        Plugins::ListenLater::DB::markPlayed($t->{rec_id});
        $log->info("marked album rec $t->{rec_id} as Played ($seen tracks)");
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
