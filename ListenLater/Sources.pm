package Plugins::ListenLater::Sources;

# Per-source adapters. Three jobs:
#   1. capture*   — turn an info-menu context (a track or a library album) into a
#                   storable record: display metadata + a best-effort replayable ref.
#   2. buildPlayableItems — turn a stored record back into playable album node(s)
#                   for the list. Prefers a native album id; otherwise searches the
#                   originating service by "artist album" (the same resilient match
#                   the sibling ListenBrainz plugin uses), so we never hard-depend
#                   on having captured the service album id.
#   3. playingAlbumRef — map a currently-playing track to (source, album_id) so the
#                   play-detector can attribute outside plays.
#
# Streaming adapters are guarded with ->can(...) so the plugin works with any
# subset of Qobuz / Bandcamp installed. Adding a service = one more entry.

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

my $log = logger('plugin.listenlater');

# url scheme -> our source tag
my %SCHEME = (
    qobuz    => 'qobuz',
    bandcamp => 'bandcamp',
    tidal    => 'tidal',
);

# ---------------------------------------------------------------------------
# Source detection
# ---------------------------------------------------------------------------
sub sourceFromUrl {
    my ($url) = @_;
    return 'library' unless $url && $url =~ m|^(\w+)://|;
    my $scheme = lc $1;
    return $SCHEME{$scheme} || $scheme;   # unknown streaming scheme kept as-is
}

# Best-effort service detection from an artwork/cover URL. Streaming browse rows
# (e.g. Qobuz New Releases albums) carry a cover but no favorites_url; the LMS
# image proxy embeds the original host (…/imageproxy/https%3A%2F%2Fstatic.qobuz.com%2F…),
# so the service can be inferred from it.
sub sourceFromImage {
    my ($img) = @_;
    return '' unless $img;
    return 'qobuz'    if $img =~ /qobuz\.com/i;
    return 'tidal'    if $img =~ /tidal/i;
    return 'bandcamp' if $img =~ /bcbits\.com|bandcamp/i;
    return 'spotify'  if $img =~ /spotify|scdn\.co/i;
    return '';
}

# ---------------------------------------------------------------------------
# Capture from a TrackInfo context (works for local AND remote tracks)
#   args mirror a TrackInfo provider: ($client, $url, $track, $remoteMeta)
# ---------------------------------------------------------------------------
sub captureFromTrack {
    my ($client, $url, $track, $remoteMeta) = @_;

    $remoteMeta = {} unless ref $remoteMeta eq 'HASH';   # undef for local tracks

    # Trust the track object's own flag; only fall back to the URL when there's
    # no object. file:// is local, so don't let "://" alone mark it remote.
    my $remote =
        ($track && $track->can('remote')) ? $track->remote
      : ($url && $url !~ /^file:/i && $url =~ m|^\w+://|) ? 1 : 0;

    my $source = $remote ? sourceFromUrl($url) : 'library';

    if (!$remote) {
        my $album = $track && $track->can('album') ? $track->album : undef;
        return _libraryAlbumRec($album);
    }

    # Remote: pull display metadata from remoteMeta (or the track object).
    my $artist = $remoteMeta->{artist}
        || ($track && $track->can('artistName') ? $track->artistName : undef);
    my $album  = $remoteMeta->{album}
        || ($track && $track->can('albumname') ? $track->albumname : undef);
    my $year   = $remoteMeta->{year};
    my $art    = $remoteMeta->{cover} || $remoteMeta->{image} || $remoteMeta->{icon};

    return undef unless $album;   # nothing to save without an album name

    # Best-effort native album id (lets us replay directly instead of searching).
    my $albumId = $remoteMeta->{albumId} || $remoteMeta->{album_id};

    return {
        source      => $source,
        artist      => $artist,
        album_title => $album,
        year        => ($year && $year =~ /(\d{4})/) ? $1 : undef,
        artwork     => $art,
        ref_kind    => $albumId ? 'passthrough' : 'search',
        ref         => {
            _svc        => $source,
            album_id    => $albumId,
            passthrough => $albumId ? { album_id => $albumId } : undef,
        },
    };
}

# ---------------------------------------------------------------------------
# Capture from an AlbumInfo context (library albums)
#   ($client, $url, $album, $remoteMeta) per AlbumInfo provider signature
# ---------------------------------------------------------------------------
sub captureFromAlbum {
    my ($client, $url, $album, $remoteMeta) = @_;

    # Be tolerant of how the album arrives: an Album object, or a bare id, or an
    # id tucked in $remoteMeta — load the object if we only got an id.
    if (!(ref $album && $album->can('title'))) {
        my $id = (ref $album ? undef : $album)
            || ($remoteMeta && (ref $remoteMeta eq 'HASH')
                ? ($remoteMeta->{album_id} || $remoteMeta->{albumId}) : undef);
        if (defined $id && $id =~ /^\d+$/) {
            $album = eval { Slim::Schema->find('Album', $id) };
            $log->info("captureFromAlbum: loaded Album by id $id") if $album;
        }
    }

    return _libraryAlbumRec($album);
}

sub _libraryAlbumRec {
    my ($album) = @_;
    return undef unless $album && $album->can('id');

    my $artist = eval { $album->contributor ? $album->contributor->name : undef };
    $artist  ||= eval { $album->contributors ? ($album->contributors)[0]->name : undef };

    return {
        source      => 'library',
        artist      => $artist,
        album_title => $album->title,
        year        => $album->year || undef,
        artwork     => ($album->artwork ? 'music/' . $album->artwork . '/cover' : undef),
        ref_kind    => 'album_id',
        ref         => { album_id => $album->id },
    };
}

# ---------------------------------------------------------------------------
# Build playable album node(s) for a stored record
#   ($client, $rec, $callback) — $callback->( \@items )
# ---------------------------------------------------------------------------
sub buildPlayableItems {
    my ($client, $rec, $cb) = @_;

    my $source = $rec->{source} || 'library';

    if ($source eq 'library') {
        return $cb->(_libraryPlayable($rec));
    }

    # Streaming: if we captured a native album id, rebuild directly; else search.
    my $ref = $rec->{ref} || {};
    my $albumId = $ref->{album_id} || ($ref->{passthrough} && $ref->{passthrough}{album_id});

    if ($albumId && _serviceCan($source)) {
        my $item = _streamingAlbumNode($client, $source, $albumId, $rec);
        return $cb->([$item]) if $item;
    }

    return _searchService($client, $source, $rec, $cb);
}

# Resolve a stored record to a flat list of playable track items (type => audio),
# so an album row can be played/drilled directly. $cb->( \@trackItems ).
sub resolveTracks {
    my ($client, $rec, $cb) = @_;

    my $source = $rec->{source} || 'library';

    if ($source eq 'library') {
        return $cb->(_libraryTrackItems($rec->{ref}{album_id}));
    }

    # Streaming: get the album node, then invoke the service's own coderef to turn
    # it into tracks.
    buildPlayableItems($client, $rec, sub {
        my $items = shift || [];
        my ($node) = grep { ($_->{type} || '') eq 'playlist' && ref $_->{url} eq 'CODE' } @$items;

        unless ($node) {
            return $cb->([{ name => cstring($client, 'PLUGIN_LL_NO_MATCH'), type => 'text' }]);
        }

        my $pt = (ref $node->{passthrough} eq 'ARRAY') ? $node->{passthrough}[0] : {};
        eval {
            $node->{url}->($client, sub {
                my $res = shift;
                # Services differ in what their album coderef returns: Qobuz/Tidal
                # pass a hashref { items => [...] }; Bandcamp passes a bare arrayref
                # of tracks. Accept either (anything else → empty).
                my $items = ref $res eq 'HASH'  ? ($res->{items} || [])
                          : ref $res eq 'ARRAY' ? $res
                          : [];
                $cb->($items);
            }, {}, $pt);
            1;
        } or $cb->([{ name => cstring($client, 'PLUGIN_LL_NO_MATCH'), type => 'text' }]);
    });
}

# The album's tracks (disc/track order) as a flat list of playable audio items.
# Single source of truth — both the direct resolve path and the OPML node coderef
# (_libraryAlbumTracks) go through here.
sub _libraryTrackItems {
    my ($albumId) = @_;
    return [] unless $albumId;

    my @items;
    my $rs = Slim::Schema->search('Track', { 'album.id' => $albumId },
        { join => 'album', order_by => 'me.disc, me.tracknum' });
    while (my $t = $rs->next) {
        push @items, { name => $t->title, type => 'audio', url => $t->url };
    }
    return \@items;
}

sub _libraryPlayable {
    my ($rec) = @_;
    my $albumId = $rec->{ref}{album_id};
    return [{
        name        => $rec->{album_title},
        type        => 'playlist',
        playlist    => \&_libraryAlbumTracks,
        url         => \&_libraryAlbumTracks,
        image       => $rec->{artwork},
        passthrough => [ { album_id => $albumId } ],
    }];
}

# OPML node coderef for a library album row (drilled or played directly): the same
# track list as _libraryTrackItems, wrapped in the { items => … } shape the feed wants.
sub _libraryAlbumTracks {
    my ($client, $cb, $args, $pt) = @_;
    $cb->({ items => _libraryTrackItems($pt->{album_id}) });
}

# Rebuild a native streaming album node from a captured album id, reattaching the
# service's own play coderef (same round-trip the sibling plugin uses for caching).
sub _streamingAlbumNode {
    my ($client, $source, $albumId, $rec) = @_;

    my %item = (
        name        => $rec->{album_title},
        type        => 'playlist',
        image       => $rec->{artwork},
        passthrough => [ { album_id => $albumId } ],
    );

    if ($source eq 'qobuz' && Plugins::Qobuz::Plugin->can('QobuzGetTracks')) {
        $item{url} = \&Plugins::Qobuz::Plugin::QobuzGetTracks;
        $item{passthrough} = [ { album_id => $albumId } ];
    }
    elsif ($source eq 'bandcamp' && Plugins::Bandcamp::Plugin->can('get_album')) {
        $item{url} = \&Plugins::Bandcamp::Plugin::get_album;
        $item{passthrough} = [ { album_id => $albumId } ];
    }
    elsif ($source eq 'tidal' && Plugins::TIDAL::Plugin->can('getAlbum')) {
        # Tidal's getAlbum reads $params->{id} (NOT album_id) and returns {items=>...}.
        $item{url} = \&Plugins::TIDAL::Plugin::getAlbum;
        $item{passthrough} = [ { id => $albumId } ];
    }
    else {
        return undef;
    }

    return \%item;
}

# ---------------------------------------------------------------------------
# Search fallback: ask the originating service for "artist album", keep the
# title+artist match, return its native (playable) album node.
# ---------------------------------------------------------------------------
sub _searchService {
    my ($client, $source, $rec, $cb) = @_;

    my $artist = $rec->{artist} // '';
    my $album  = $rec->{album_title} // '';
    my $query  = _norm("$artist $album");

    if ($source eq 'qobuz' && Plugins::Qobuz::Plugin->can('getAPIHandler')
                          && Plugins::Qobuz::Plugin->can('_albumItem')) {
        my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);
        return $cb->(_noMatch($client)) unless $api;
        $api->search(sub {
            my $res = shift;
            my @out;
            for my $a (@{ ($res && $res->{albums} && $res->{albums}{items}) || [] }) {
                my $candArtist = ref $a->{artist} eq 'HASH' ? $a->{artist}{name} : '';
                next unless _albumMatches(_norm($artist), _norm($album), $candArtist, $a->{title});
                push @out, Plugins::Qobuz::Plugin::_albumItem($client, $a);
            }
            $cb->(@out ? \@out : _noMatch($client));
        }, lc($query), 'albums');
        return;
    }

    if ($source eq 'bandcamp') {
        eval { require Plugins::Bandcamp::Search; 1 } or return $cb->(_noMatch($client));
        Plugins::Bandcamp::Search::search($client, sub {
            my $res = shift;
            my @out;
            for my $it (@{ ($res && $res->{items}) || [] }) {
                next unless ref $it eq 'HASH';
                my $pt = ref $it->{passthrough} eq 'ARRAY' ? $it->{passthrough}[0] : undef;
                next unless $pt && $pt->{album_id};
                next unless _albumMatches(_norm($artist), _norm($album), $pt->{artist}, $pt->{title});
                push @out, $it;
            }
            $cb->(@out ? \@out : _noMatch($client));
        }, { search => $query });
        return;
    }

    # Tidal: search albums (callback gets a bare arrayref of album hashes), keep
    # title+artist matches, render via the plugin's own _renderAlbum (url => getAlbum).
    if ($source eq 'tidal' && Plugins::TIDAL::Plugin->can('getAPIHandler')
                           && Plugins::TIDAL::Plugin->can('_renderAlbum')) {
        my $api = Plugins::TIDAL::Plugin::getAPIHandler($client);
        return $cb->(_noMatch($client)) unless $api;
        $api->search(sub {
            my $albums = shift;
            my @out;
            for my $a (@{ $albums || [] }) {
                next unless ref $a eq 'HASH';
                my $ar = $a->{artist} || ($a->{artists} && $a->{artists}[0]) || {};
                my $candArtist = ref $ar eq 'HASH' ? $ar->{name} : '';
                next unless _albumMatches(_norm($artist), _norm($album), $candArtist, $a->{title});
                push @out, Plugins::TIDAL::Plugin::_renderAlbum($a);
            }
            $cb->(@out ? \@out : _noMatch($client));
        }, { type => 'albums', search => $query, limit => 20 });
        return;
    }

    return $cb->(_noMatch($client));
}

sub _noMatch {
    my ($client) = @_;
    return [ { name => cstring($client, 'PLUGIN_LL_NO_MATCH'), type => 'text' } ];
}

# ---------------------------------------------------------------------------
# Bandcamp purchase link. We store only artist+album for Bandcamp items, so the
# album page URL has to be resolved on demand: resolve the album's items (search
# → get_album) and scan them for the bandcamp.com page link the plugin emits
# ("Download album from the following address: http://artist.bandcamp.com/album/…").
# $cb->( $url | undef ).
# ---------------------------------------------------------------------------
sub bandcampBuyUrl {
    my ($client, $rec, $cb) = @_;
    return $cb->(undef) unless ($rec->{source} || '') eq 'bandcamp';
    resolveTracks($client, $rec, sub {
        my $items = shift || [];
        $cb->(_findBandcampUrl($items));
    });
}

sub _findBandcampUrl {
    my ($items) = @_;
    return undef unless ref $items eq 'ARRAY';

    # The track play URLs are bandcamp://… (not http), and artwork lives on
    # bcbits.com — both excluded by requiring an http(s) bandcamp.com link. Prefer
    # an album/track page, then any *.bandcamp.com page.
    for my $rx (qr{bandcamp\.com/(?:album|track)/}i, qr{\.bandcamp\.com/}i, qr{//bandcamp\.com/}i) {
        for my $it (@$items) {
            next unless ref $it eq 'HASH';
            for my $f (qw(weblink url link name title)) {
                my $v = $it->{$f};
                next if !defined $v || ref $v;
                return $v if $v =~ m{^https?://\S+} && $v =~ $rx;
            }
        }
    }
    return undef;
}

# ---------------------------------------------------------------------------
# Small matching helpers (ported from the sibling plugin's tuned logic)
# ---------------------------------------------------------------------------
sub _serviceCan {
    my ($source) = @_;
    return 1 if $source eq 'qobuz'    && Plugins::Qobuz::Plugin->can('QobuzGetTracks');
    return 1 if $source eq 'bandcamp' && Plugins::Bandcamp::Plugin->can('get_album');
    return 1 if $source eq 'tidal'    && Plugins::TIDAL::Plugin->can('getAlbum');
    return 0;
}

# Normalise for fuzzy MATCHING. NB: intentionally differs from DB::_norm — this one
# also STRIPS "(…)"/"[…]" (deluxe/remaster/edition qualifiers) so a saved title
# matches the service's variant. Don't unify it with DB::_norm, whose dedupe key
# must keep those qualifiers distinct.
sub _norm {
    my $s = lc($_[0] // '');
    $s =~ s/\([^)]*\)//g;
    $s =~ s/\[[^\]]*\]//g;
    $s =~ s/[^a-z0-9]+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# Candidate title must BE or START WITH our album, and artists must match.
sub _albumMatches {
    my ($artistNorm, $albumNorm, $candArtist, $candTitle) = @_;
    return 0 if length $albumNorm < 2;

    my $ct = _norm($candTitle);
    return 0 unless $ct eq $albumNorm || $ct =~ /^\Q$albumNorm\E\s/;

    return 1 unless length $artistNorm;
    return _artistMatch($artistNorm, _norm($candArtist));
}

# Token-subset: every word of the shorter credit appears in the longer.
sub _artistMatch {
    my ($a, $b) = @_;
    return 1 unless length $a && length $b;
    my ($short, $long) = length($a) <= length($b) ? ($a, $b) : ($b, $a);
    my %has = map { $_ => 1 } split /\s+/, $long;
    for my $w (split /\s+/, $short) {
        return 0 unless $has{$w};
    }
    return 1;
}

1;
