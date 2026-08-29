package Plugins::ListenLater::Sources;

# Per-source adapters. Two jobs:
#   1. capture*   — turn an info-menu context (a track or a library album) into a
#                   storable record: display metadata + a best-effort replayable ref.
#   2. buildPlayableItems / resolveTracks — turn a stored record back into playable
#                   album node(s) / a flat track list for the list. Prefers a native
#                   album id; otherwise searches the originating service by
#                   "artist album" (the same resilient match the sibling ListenBrainz
#                   plugin uses), so we never hard-depend on having captured the id.
# (Play attribution for the Played detector lives in Played::_matchRecord, which keys
# off source + album id / artist+album — not a helper here.)
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
    deezer   => 'deezer',
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

# Does this favurl point at a single TRACK (vs an album)? The reliable album-vs-track
# discriminator for streaming adds: Material collapses a streaming album's track rows onto
# the 'online-album' custom-action category (verified live — a Qobuz album-drill track fires
# online-album, not online-track), so the category can't be trusted; the play url can.
# Order: a container ref ('album:' etc.) is a decisive NO; a media-file extension (Qobuz
# .flac, Deezer .flc, Tidal .flac/.m4a, …) or a '/track/' path (Bandcamp/SoundCloud) is a
# decisive YES; anything else falls through to a logged fail-open YES (see below).
sub favurlIsTrack {
    my ($u) = @_;
    return 0 unless defined $u && length $u;
    return 0 unless $u =~ m{^\w+://};      # must be a scheme url to say anything
    # A CONTAINER ref is decisive → not a track. 'album:' is the one the services actually
    # emit; the others cost nothing and stop a playlist/artist/mix row being replayed as a
    # single audio url.
    return 0 if $u =~ m{(?:[:/])(?:album|playlist|artist|mix):};
    # Explicit track shapes: a media-file extension (Qobuz .flac, Deezer .flc, Tidal
    # .flac/.m4a, …) or a '/track/' path (Bandcamp/SoundCloud).
    return 1 if $u =~ m{\.(?:flac|flc|mp3|m4a|mp4|aac|ogg|oga|opus|wav|alac|aiff?)(?:[?#].*)?$}i;
    return 1 if $u =~ m{/track/};
    # Otherwise: for every service we support, an ALBUM favurl is either EMPTY or carries
    # 'album:' — so a remaining non-empty scheme url with neither is a track (e.g. an
    # extension-less tidal://<id>). This is a fail-OPEN default and nothing enforces the
    # invariant: if a supported service ever starts emitting an album favurl in a shape we
    # don't recognise, its albums would be stored as kind='track' rows pointing a
    # type => 'audio' item at a non-audio url — i.e. rows that can't play. Log it so that
    # shows up in log.txt as a named suspect instead of silently. (An UNsupported service
    # breaking the invariant still costs nothing — it's rejected by _isReplayableSource.)
    $log->warn("LL: favurlIsTrack — assuming TRACK for an unrecognised favurl shape: $u");
    return 1;
}

# Metadata for a currently-playing REMOTE track, from its protocol handler's
# getMetadataFor — the same source LMS's status query / Material's Now Playing use.
# Streaming services (Qobuz/Tidal/Deezer) DON'T store album/artist/cover on the LMS
# Track row (->albumname/->artistName/->cover come back empty), so both the Now Playing
# "Add" (Plugin::_nowPlayingFallback) and the Played auto-detector (Played::_matchRecord) have
# to ask the handler instead. Returns the metadata hash (keys incl. album/artist/cover)
# or {} — always a hashref, so callers can index safely. Best-effort; guarded.
sub playingMeta {
    my ($client, $url) = @_;
    return {} unless defined $url && length $url;
    my $handler = eval { Slim::Player::ProtocolHandlers->handlerForURL($url) } or return {};
    return {} unless $handler->can('getMetadataFor');
    my $meta = eval { $handler->getMetadataFor($client, $url) };
    return ref $meta eq 'HASH' ? $meta : {};
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
    return 'deezer'   if $img =~ /dzcdn\.net|deezer/i;
    return 'spotify'  if $img =~ /spotify|scdn\.co/i;
    return '';
}

# Every source tag `sourceFromUrl`/`sourceFromImage` can produce. NOT the list of services we
# can REPLAY (that's `_serviceCan`) — deezer/spotify belong here precisely so an add naming
# them still reaches the reject gate under their own name, exactly as before.
my %KNOWN_SOURCE = map { $_ => 1 } qw(qobuz tidal bandcamp deezer spotify);

# Is this string actually the name of a service we recognise?
#
# The caller's problem is that Material's `$SERVICE` is NOT a service tag — it's the browse
# COMMAND of whatever menu the row came from (`data.params[1][0]`), and on a Material HOME SHELF
# that command is the home-extra id. The stock Qobuz plugin registers its shelves as
# `QobuzExtrasqobuz` ("Qobuz"), `QobuzExtrasnew-releases-full`, … — so entering Qobuz from the
# home screen instead of Apps sends svc='QobuzExtrasqobuz' for the very same rows.
#
# So a SHAPE test (`^[a-z0-9]+$`, which only ever meant to reject Material's unpopulated literal
# "$SERVICE" and hyphenated non-services) is not enough: an all-alphanumeric shelf id passes it,
# becomes `$source`, and short-circuits the cover-URL sniff that would have got the answer right.
# That is why the hyphenated shelves worked and `QobuzExtrasqobuz` did not.
#
# Deliberately an EXACT match, never a substring: 'QobuzExtrasqobuz' contains 'qobuz', and so
# would a hypothetical 'tidalqobuz' — matching loosely would just trade this bug for a subtler one.
sub knownSource {
    my ($s) = @_;
    return 0 unless defined $s && length $s;
    return $KNOWN_SOURCE{ lc $s } ? 1 : 0;
}

# Our OWN browse surfaces, by the command Material passes as $SERVICE: the plugin's list
# view (the dispatch verb, 'listenlater') and its Material home shelf (the home-extra tag,
# 'LLHome'), plus both pre-rebrand spellings — a stale actions.json outlives the rename.
#
# Kept here, next to knownSource, because the two answer the same question about the same
# untrusted string and the caller must ask BOTH: knownSource says "this doesn't name a
# service", which since 0.1.96 means "fall through to the cover sniff" — and on one of our
# own rows that sniff succeeds, because our cards carry the ORIGINAL streaming cover. Only
# an explicit name can tell those two cases apart.
my %OWN_SURFACE = map { lc($_) => 1 } qw(listenlater LLHome listentolater LtLHome);

sub ownSurface {
    my ($s) = @_;
    return 0 unless defined $s && length $s;
    return $OWN_SURFACE{ lc $s } ? 1 : 0;
}

# Recover the Qobuz album id from its cover URL. Qobuz browse rows carry NO
# favorites_url / album id, but they DO carry a cover whose filename IS the album id:
#   …/static.qobuz.com/images/covers/<xx>/<yy>/<ALBUMID>_<size>.jpg
# (the <xx>/<yy> path is even derived from the id's last chars). The url usually arrives
# via the LMS image proxy, url-encoded, so unescape first. Recovering the id lets us
# replay the EXACT album Qobuz was showing — by id, no artist/title search (which can miss
# a specific same-titled edition, e.g. "American Football (LP2)"). Returns the id or undef.
sub qobuzAlbumIdFromImage {
    my ($img) = @_;
    return undef unless defined $img && length $img;
    require URI::Escape;
    my $u = URI::Escape::uri_unescape($img);
    return $1 if $u =~ m{static\.qobuz\.com/images/covers/[^/]+/[^/]+/([A-Za-z0-9]+)_\d+\.[a-z0-9]+}i;
    return undef;
}

# Is this browse row a streaming-service PLAYLIST, and which one? Returns
# ($source, $playlist_id) or the empty list. The ONE detector — every caller asks here.
#
# Two shapes, in order, because only two exist:
#   1. a container favurl — Tidal and Deezer both emit one from a single shared playlist
#      renderer, so it covers curated AND personal lists on both services:
#         tidal://playlist:<uuid>   deezer://playlist:<id>
#      (the id charset allows '-' for a Tidal uuid; '.' and '_' cost nothing.)
#   2. Qobuz's cover URL — Qobuz's _playlistItem emits NO favorites_url at all, but an
#      editorial playlist's cover filename IS the playlist id:
#         static.qobuz.com/images/playlists/<ID>_<hash>_rectangle.jpg
#      Verified live: 69183531 = "Hi-Res Masters: 2016 / Qobuz UK". Deliberately mirrors
#      qobuzAlbumIdFromImage above, whose path (/images/covers/) is DISJOINT from this one
#      — the two can never both fire, which is what keeps an album row an album row.
#
# NOT supported, deliberately: a Qobuz PERSONAL playlist with no artwork of its own, whose
# cover falls back to a constituent track's album art (…/images/covers/…). It carries no
# recoverable id and is indistinguishable from an album row, so it keeps today's behaviour
# rather than being detectable enough to refuse. The real fix is upstream (a one-line
# qobuz://playlist:<id> favurl in Qobuz::Plugin::_playlistItem).
sub playlistFromRow {
    my ($favurl, $image) = @_;

    # Scheme and container ref matched SEPARATELY, deliberately: a single anchored
    # expression cannot do it. '^(\w+)://' consumes both slashes, leaving nothing for a
    # following '[:/]' to match against 'playlist:' — which is the shape Tidal and Deezer
    # actually send ('tidal://playlist:<uuid>'), i.e. the common case would be the one that
    # failed. The container half is therefore unanchored, exactly like the 'album:' match in
    # Plugin::_addCtxCommand.
    if (defined $favurl && $favurl =~ m{^(\w+)://}) {
        my $scheme = lc $1;
        return ($SCHEME{$scheme} || $scheme, $1)
            if $favurl =~ m{(?:^|[:/])playlist:([A-Za-z0-9._-]+)};
    }

    if (defined $image && length $image) {
        require URI::Escape;
        my $u = URI::Escape::uri_unescape($image);
        return ('qobuz', $1)
            if $u =~ m{static\.qobuz\.com/images/playlists/(\d+)_}i;
    }

    return ();
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
# Can this record's tracklist be fetched DIRECTLY — one album call — or would it cost a
# SEARCH of the service? The difference is what separates a cheap background job from an
# expensive one, so anything deciding whether to do optional work in the background must ask
# THIS, not "is there an album id".
#
# Bandcamp is the exception that makes it worth a named sub: its get_album scrapes the album
# PAGE url, so an album_id alone buys nothing there — a record with an id but no album_url
# still resolves via a full Bandcamp search. Plugin::_verifyRelease used to gate on the id
# alone and so spent exactly the search its own comment said it was avoiding. Every other
# service replays straight from the captured id.
sub hasDirectAlbumRef {
    my ($rec) = @_;
    my $source = $rec->{source} || 'library';
    my $ref    = $rec->{ref} || {};
    # A PLAYLIST has no album ref by construction (never write an album_id onto one — see
    # DB::add) and no search fallback to be spared, so the answer is a flat no. Stated
    # rather than inherited from "it has no album_id".
    return 0 if ($rec->{kind} || '') eq 'playlist';
    return 1 if $source eq 'library';
    return ($ref->{album_url} ? 1 : 0) if $source eq 'bandcamp';
    my $albumId = $ref->{album_id} || ($ref->{passthrough} && $ref->{passthrough}{album_id});
    return $albumId ? 1 : 0;
}

sub buildPlayableItems {
    my ($client, $rec, $cb) = @_;

    my $source = $rec->{source} || 'library';

    # A saved TRACK is a single, self-contained play URL — no album node, no matcher,
    # no search. The stored url plays directly (a library file://, or a streaming
    # qobuz://…/tidal://…/deezer://…/bandcamp track url).
    if (($rec->{kind} || '') eq 'track') {
        return $cb->(_trackPlayableItems($rec));
    }

    # A saved PLAYLIST replays through the service's own playlist call, by id. There is
    # deliberately NO search fallback: a playlist cannot be found by an artist+album search,
    # and falling through to _searchService is exactly how the junk "album named 'Dance Pop'"
    # rows arose before playlists were a kind of their own.
    if (($rec->{kind} || '') eq 'playlist') {
        my $ref  = $rec->{ref} || {};
        my $item = _streamingPlaylistNode($client, $source, $ref->{playlist_id}, $rec);
        return $cb->([$item]) if $item;
        return $cb->(_noMatch($client));
    }

    if ($source eq 'library') {
        return $cb->(_libraryPlayable($rec));
    }

    # Streaming: if we captured a native album id, rebuild directly; else search.
    my $ref = $rec->{ref} || {};
    my $albumId = $ref->{album_id} || ($ref->{passthrough} && $ref->{passthrough}{album_id});

    # Bandcamp's get_album scrapes the album PAGE url, NOT the album_id, so it needs
    # album_url for a direct replay. Normally that url arrives in the favurl's ?b= blob
    # (LBF 0.9.53+ packs <art>|<url>) and is stored on the record at add time, so this
    # path runs directly. The album_id-search resolve below is only a SAFETY NET for the
    # rare record with no stored url: it searches Bandcamp once, matches our exact
    # album_id, and caches the resolved url (_cacheBandcampUrl) so later replays are
    # direct. Qobuz/Tidal replay fine straight from the captured id.
    # (Historical note: an earlier belief that "Material drops a long favurl" was wrong —
    # it was a shadowed-install artifact; the full ?b= favurl survives intact.)
    my $directOk = hasDirectAlbumRef($rec);

    if ($directOk && _serviceCan($source)) {
        my $item = _streamingAlbumNode($client, $source, $albumId, $rec);
        return $cb->([$item]) if $item;
    }

    # Bandcamp, first time (no cached url): resolve via search (album_id-exact) and cache
    # the page url so subsequent plays skip the search.
    if ($source eq 'bandcamp' && !$ref->{album_url}) {
        return _searchService($client, $source, $rec, sub {
            my $items = shift;
            _cacheBandcampUrl($rec, $items);
            $cb->($items);
        });
    }

    return _searchService($client, $source, $rec, $cb);
}

# Persist the Bandcamp album PAGE url resolved by a first-time search, so future replays
# (and Buy-on-Bandcamp) use it directly instead of searching again. Pulls the url out of
# the matched playable node's passthrough.
sub _cacheBandcampUrl {
    my ($rec, $items) = @_;
    return unless $rec->{id} && ref $items eq 'ARRAY';
    my ($node) = grep {
        ref $_ eq 'HASH' && ($_->{type} || '') eq 'playlist' && ref $_->{passthrough} eq 'ARRAY'
    } @$items;
    my $pt  = $node ? $node->{passthrough}[0] : undef;
    my $url = $pt && ($pt->{album_url} || $pt->{url});
    return unless $url && !ref $url && $url =~ m{^https?://}i;
    eval {
        Plugins::ListenLater::DB::setRefValue($rec->{id}, 'album_url', $url);
        $rec->{ref}{album_url} = $url;   # reflect it on the in-hand record too
    };
}

# Resolve a stored record to a flat list of playable track items (type => audio),
# so an album row can be played/drilled directly. $cb->( \@trackItems ).
sub resolveTracks {
    my ($client, $rec, $cb) = @_;

    my $source = $rec->{source} || 'library';

    # Track saves resolve to the one stored audio item (no service round-trip).
    if (($rec->{kind} || '') eq 'track') {
        return $cb->(_trackPlayableItems($rec));
    }

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

# One playable audio item for a saved TRACK, from its stored play URL. The URL is the
# canonical service/library url captured at add time (qobuz://…flac, file://…, etc.), so
# replay is a direct handoff to the protocol handler — the same shape as a library album's
# track items. Returns a "no match" text row if the url is somehow missing (older/corrupt
# record) so the view is never blank.
sub _trackPlayableItems {
    my ($rec) = @_;
    my $ref = (ref $rec->{ref} eq 'HASH') ? $rec->{ref} : {};
    my $url = $ref->{url};
    return [{ name => cstring(undef, 'PLUGIN_LL_NO_MATCH'), type => 'text' }]
        unless defined $url && length $url;
    return [{
        name  => $rec->{track_title} // $rec->{album_title} // '',
        type  => 'audio',
        url   => $url,
        image => $rec->{artwork},
    }];
}

# Classify a release as 'album' | 'ep' | 'single'. Prefers an explicit type the SOURCE
# supplied (e.g. the ListenBrainz Fresh Releases favurl '&rt=' handshake, which carries
# the true MusicBrainz release-group type) — since the LMS streaming plugins' track
# coderefs don't expose a release type, that handshake is the only *authoritative* signal.
# Falls back to a track-count heuristic (1 = single, 2-6 = ep, else album), which is what
# library and direct-streaming adds use. Returns undef when neither signal is available
# (label then defaults to "Album" until a resolve fills in the count).
#
# ONE exception to "the source wins": a claimed 'single' is overruled by a real track
# count greater than one — see singleIsWrong().
sub relTypeFor {
    my (%a) = @_;
    my $svc = _normRelType($a{service});
    my $n   = $a{count};
    my $have = defined $n && $n =~ /^\d+$/ && $n > 0;
    return $svc if $svc && !($have && singleIsWrong($svc, $n));
    return undef unless $have;
    return $n == 1 ? 'single' : $n <= 6 ? 'ep' : 'album';
}

# Is a claimed 'single' contradicted by the release's real track count? To LL 'single'
# is not a genre label, it is the statement "this release has exactly ONE track":
# Played::_totalTracks returns 1 for it and Played then marks the whole release heard as
# soon as that one track has played through. So a release the SOURCE calls a single but
# which actually carries several tracks gets marked Played after its first track.
#
# Sources really do call such releases singles. MusicBrainz gives a release group whose
# primary type is Single that label however many B-sides, remixes or radio edits the
# release carries, and that type is what ListenBrainz Fresh Releases hands over in its
# '&rt=' handshake; Qobuz's own release_type behaves the same way. Neither is lying — a
# 4-track CD single IS a single as the industry means it — but it is not what LL's
# 'single' means, so we defer to the count, which is the thing Played actually cares
# about (it then reads as an EP, or an Album beyond 6 tracks — calling a 9-track release
# an EP would just re-run the same early-Played bug against the EP's 2-track floor).
sub singleIsWrong {
    my ($relType, $count) = @_;
    return 0 unless ($relType // '') eq 'single';
    return (defined $count && $count =~ /^\d+$/ && $count > 1) ? 1 : 0;
}

# Map a free-text release-type token (from a service / MB handshake) to our vocabulary.
sub _normRelType {
    my $t = lc($_[0] // '');
    return undef unless length $t;
    return 'single' if $t =~ /single/;
    return 'ep'     if $t =~ /\bep\b/ || $t eq 'ep';
    return 'album'  if $t =~ /album|^lp$|compilation|mixtape/;
    return undef;
}

# ---------------------------------------------------------------------------
# Is this resolved OPML item a playable TRACK?
#
# A port of LMS's own hasAudio (Slim::Control::XMLBrowser) — the definition the server
# itself uses to set the `isaudio` flag on a browse row. Counting by the same rule the
# server displays by means "we counted it" and "you can play it" are the same question, and
# the answer is checkable against any live feed over jsonrpc.js.
#
# It MUST be an allow-list. The old test was a deny-list — anything that is not type 'text'
# and has no weblink — so any row a service invents that we did not anticipate fails it
# OPEN and is counted as a track. Qobuz returns FIVE OR SIX such rows on every album
# ('Artist: X', "Add Release … to Qobuz favourites", 'Credits', 'Description', 'Music
# Label: …', 'Copyright'), and verified live against four releases, none of them carries a
# `type` at all — so every one was counted. A 1-track release stored 6; an 11-track album
# stored 17. Played thresholds on that number: the 1-track release needed 4 of its 1 track
# and could NEVER be marked, and the album needed all 11 instead of 7.
#
# Note 'playlist' counts as playable, not just 'audio' — that is what hasAudio does, and
# guessing 'audio' alone would silently undercount any service that nests a playable item.
sub isPlayableTrack {
    my ($i) = @_;
    return 0 unless ref $i eq 'HASH';
    return 1 if $i->{play};
    return 1 if ((($i->{type} // '') =~ /^(?:audio|playlist)$/)
                 && ($i->{playlist} || $i->{url} || scalar @{ $i->{outline} || [] }));
    return 1 if ref $i->{enclosure} eq 'HASH' && (($i->{enclosure}{type} // '') =~ /audio/);
    return 0;
}

# How many REAL tracks a resolved item list holds. This is the only number allowed to become
# Played's total — see Played::_totalTracks.
sub countPlayableTracks {
    my ($items) = @_;
    return 0 unless ref $items eq 'ARRAY';
    return scalar grep { isPlayableTrack($_) } @$items;
}

# Work out what a STREAMING release IS, async →
#     $cb->($relType|undef, $trackCount|undef, $countIsProvisional, $year|'')
#
# The FOURTH value is a release year read off the service's album object, for a row that
# arrived without one (Qobuz only — it is the one service whose ID call returns an album
# object rather than a tracklist). Empty when unknown. Callers fill a MISSING year with it
# and never overwrite one they already hold — see DB::updateYear.
#
# Two answers, both needed. The TYPE is the row's label; the COUNT is what Played
# thresholds against — without it a streaming release falls back to the blunt
# streaming_min_tracks floor, which a release shorter than the floor can never reach (see
# Played::_totalTracks).
#
# THE THIRD VALUE says where the count came from, and callers must honour it. A count from
# a resolved TRACKLIST is real: the service has already applied its own regional/licensing
# filter, so what came back is what can actually be played here ($provisional = 0). A count
# from a catalogue album OBJECT (Qobuz's tracks_count) is a claim about the release, not
# about your account — it can only ever be >= what's playable — so it is PROVISIONAL and
# must NOT be stored as Played's total ($provisional = 1). Storing it was a real bug: a
# 12-track catalogue entry with 5 playable tracks needs ceil(60% of 12) = 8 distinct tracks
# and can never be marked, which is WORSE than the flat 4-track floor it replaced.
# Provisional counts are still passed back, because they are perfectly good for settling
# the TYPE (that's what the fetch is for) and because their presence distinguishes "the
# service answered" from "the service could not be reached" — which is what
# Plugin::_verifyRelease's retry keys on.
#
# $claimed is a type the source already told us (the '&rt=' handshake). It settles the
# type — MusicBrainz knows an EP from an album better than a track count does — EXCEPT
# for a 'single', which is confirmed against the count (singleIsWrong). With no claim,
# Qobuz's own release_type (getAPIHandler->getAlbum → $album->{release_type}) plays the
# same role, and with neither the count decides. Either way the tracklist is resolved, so
# the count comes back regardless of who won the type. Called BEFORE the row is inserted
# (Plugin::_classifyThenAdd) so it is never shown mislabelled. Guarded; always fires $cb.
sub classifyRelType {
    my ($client, $source, $albumId, $rec, $cb, $claimed) = @_;

    my $claim = _normRelType($claimed);

    # Qobuz answers BOTH questions from one album fetch — its album object carries
    # release_type and tracks_count — so when it gives us a count there is no reason to
    # fetch a tracklist as well. Every other service's album call IS the tracklist, so
    # they get nothing from a special case and go the resolve route below.
    #
    # Note what that count MEANS: it's the catalogue's track count, which can exceed what
    # is actually playable here (regional/licensing gaps drop tracks from the tracklist,
    # not from the album object). Played thresholds against what can be PLAYED, so this
    # count is handed back flagged PROVISIONAL and is never stored as the total — see the
    # header. It still settles the type, which is what this fetch is for. The real total
    # arrives on the first drill/play from the list, which resolves the actual tracklist
    # (Browse::_albumTracks → DB::updateTrackCount).
    #
    # ONE use of a provisional count can RAISE the Played bar, and it is not allowed:
    # DEMOTING a claimed 'single' (singleIsWrong). A 'single' means a real total of 1, so it
    # needs 1 track; demote it to 'ep' with no stored total and it needs 2 (the EP floor).
    # If the catalogue count is inflated — it says 3, the region serves 1 — that release can
    # never be marked at all, where 0.1.87 marked it. So in exactly that case the count is
    # not good enough to act on and we fall through to resolving the real TRACKLIST, which
    # answers both questions properly: the true playable count (stored, not provisional) and
    # a type settled from it. It costs one call, only for a claimed single the catalogue
    # contradicts — rare — while albums, EPs and confirmed singles keep the zero-call path.
    #
    # Every OTHER use of the count can only LOWER the bar or leave it alone, which is why
    # they need no such care: with no assertion, a count of 1 gives 'single' (needs 1, down
    # from the 4-track floor), 2-6 gives 'ep' (needs 2, down from 4) and 7+ gives 'album'
    # (needs 4, unchanged). Only the demotion goes the wrong way.
    #
    # Residual case, accepted: a release Qobuz explicitly asserts is an 'album' but which
    # holds 2-6 tracks stores no total, so it sits on the 4-track floor until the first play
    # from the list. Narrow, and it can only ever make a release WAIT to be marked, never
    # mark early or never mark at all.
    if ($source eq 'qobuz' && defined $albumId && length $albumId
            && Plugins::Qobuz::Plugin->can('getAPIHandler')) {
        my $api = eval { Plugins::Qobuz::Plugin::getAPIHandler($client) };
        if ($api && $api->can('getAlbum')) {
            my $ok = eval {
                $api->getAlbum(sub {
                    my $album = shift;
                    my $rt = $claim
                        || _normRelType(ref $album eq 'HASH' ? $album->{release_type} : undef);
                    my $n = albumTrackCount($album);
                    # …and the release YEAR, off the same object, for a row that arrived
                    # without one — a plain Qobuz browse row carries no year at all (only the
                    # siblings' '&y=' handshake and Now Playing's "Album (YYYY)" label do), and
                    # the year is part of the dedupe key, so a yearless row can be duplicated
                    # by a later add that has one. Free: this object is already in hand.
                    #
                    # Read with serviceYear (the whole hash), NOT a hand-picked few fields:
                    # the earlier three-field version missed an album object that states only
                    # the epoch `released_at`, which is exactly what Pitchfork Reviews was
                    # getting years from while this path returned nothing.
                    my $yr = serviceYear($album);
                    # Short-circuit ONLY when the catalogue count can't raise the bar, i.e.
                    # anything but demoting a claimed single (see above). 1 = provisional.
                    return $cb->(_settle($rt, $n), $n, 1, $yr) if $n && !singleIsWrong($rt, $n);
                    # No count on the object, or a count that would demote a claimed single
                    # and so has to be proved first → resolve the real tracklist. The year
                    # still came off the object, so carry it through rather than lose it.
                    _countThen($client, $rec, $rt, sub {
                        my ($t, $c, $p) = @_;
                        $cb->($t, $c, $p, $yr);
                    });
                }, $albumId);
                1;
            };
            return if $ok;
        }
    }
    return _countThen($client, $rec, $claim, $cb);
}

# The track count a service states on its own album object, without resolving anything.
# Field names verified per plugin (and shared with the sibling ListenBrainz plugin's
# _candReleaseType): Qobuz tracks_count, Deezer nb_tracks, TIDAL numberOfTracks.
#
# Only the Qobuz name is reachable from classifyRelType today, and the reason is the shape
# of the two resolution paths, not a preference for Qobuz: the ID-based call returns an
# album OBJECT on Qobuz but a TRACKLIST on Tidal/Deezer/Bandcamp, so there is no hash to
# read a count from.
#
# Their album data is NOT missing — verified 2026-07-25 by reading each plugin's source:
# Tidal's album objects carry `type` (ALBUM/EP/SINGLE) + numberOfTracks and Deezer's carry
# record_type + nb_tracks, but only on the raw albums/<id> / album/<id> endpoints, which
# the plugins do not surface (their getAlbum returns tracks). **Reaching into those private
# API internals was DECLINED (2026-07-25) — it breaks on plugin updates — so do not
# re-attempt it; single/EP detection from a service's own catalogue is Qobuz-only by
# decision, not by oversight.** Bandcamp has no type at all and no count before its page
# is fetched.
#
# What IS legitimately available is those services' SEARCH results: the raw album hashes in
# _searchService's Tidal/Deezer branches carry the counts, through the plugins' own public
# search. That path isn't used here only because searching is the expense we're avoiding —
# so these two names stay both verified and (via search) reachable without going private.
sub albumTrackCount {
    my ($album) = @_;
    return undef unless ref $album eq 'HASH';
    my $n = $album->{tracks_count} // $album->{nb_tracks} // $album->{numberOfTracks};
    return (defined $n && "$n" =~ /^\d+$/ && $n > 0) ? $n + 0 : undef;
}

# Decide the final type from what the source asserted and what the release actually holds.
# With no assertion the count classifies. With one, the assertion stands — it comes from
# MusicBrainz or the service's own catalogue, either of which reads an EP better than a
# count does — UNLESS it says 'single' and the count disagrees, where the count wins
# (singleIsWrong). An assertion also stands when there's no count at all: that leaves an
# unreachable service exactly where it was, rather than guessing from nothing.
sub _settle {
    my ($asserted, $count) = @_;
    my $counted = relTypeFor(count => $count);
    return $counted unless $asserted;
    return ($counted || $asserted) if singleIsWrong($asserted, $count);
    return $asserted;
}

# The general route: resolve the release's tracklist and settle from what came back.
sub _countThen {
    my ($client, $rec, $asserted, $cb) = @_;
    return resolveTrackCount($client, $rec, sub {
        my ($n) = @_;
        # 0 = a real count: resolveTrackCount counted the tracklist the service actually served,
        # which is already filtered to what's playable here.
        $cb->(_settle($asserted, $n), $n, 0);
    });
}

# Count the release's real tracks → $cb->($count|undef). PUBLIC: Played calls this too, to
# learn a release's length at the moment it starts playing (see Played::_onChange).
# undef means "couldn't find out", never "zero".
sub resolveTrackCount {
    my ($client, $rec, $cb) = @_;
    my $ok = eval {
        resolveTracks($client, $rec, sub {
            my $items = shift || [];
            $cb->(countPlayableTracks($items) || undef);
        });
        1;
    };
    $cb->(undef) unless $ok;
    return;
}

# Best-effort native album id for a STREAMING track url, read SYNCHRONOUSLY from the
# service's already-cached playing-track metadata (no network) — used to classify a
# track-add's release (single vs album). Qobuz caches 'albumId', Tidal 'album_id'; Deezer's
# getMetadataFor flattens the album to a title (dropping the id), so it yields undef there
# and the caller stores the individual track. Guarded — any failure just returns undef.
sub trackAlbumId {
    my ($client, $url) = @_;
    return undef unless defined $url && length $url;
    my $meta = eval {
        my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
        ($handler && $handler->can('getMetadataFor'))
            ? $handler->getMetadataFor($client, $url) : undef;
    };
    return undef unless ref $meta eq 'HASH';
    my $id = $meta->{albumId} || $meta->{album_id}
        || (ref $meta->{album} eq 'HASH' ? $meta->{album}{id} : undef);
    return (defined $id && length $id) ? $id : undef;
}

# The number of library tracks on an album id (for release-type classification at add
# time — cheap, the count is local). 0/undef on any error.
sub libraryTrackCount {
    my ($albumId) = @_;
    return 0 unless $albumId;
    return eval {
        Slim::Schema->search('Track', { 'album.id' => $albumId }, { join => 'album' })->count;
    } || 0;
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
        # get_album resolves the tracklist from the album PAGE url (album_url||url), NOT
        # the album_id — so the captured page url is the real replay key (id kept only
        # for reference). buildPlayableItems only reaches here for Bandcamp when
        # album_url is present.
        my $burl = $rec->{ref}{album_url};
        $item{url} = \&Plugins::Bandcamp::Plugin::get_album;
        $item{passthrough} = [ { album_id => $albumId, ($burl ? (album_url => $burl, url => $burl) : ()) } ];
    }
    elsif ($source eq 'tidal' && Plugins::TIDAL::Plugin->can('getAlbum')) {
        # Tidal's getAlbum reads $params->{id} (NOT album_id) and returns {items=>...}.
        $item{url} = \&Plugins::TIDAL::Plugin::getAlbum;
        $item{passthrough} = [ { id => $albumId } ];
    }
    elsif ($source eq 'deezer' && Plugins::Deezer::Plugin->can('getAlbum')) {
        # Deezer's getAlbum reads $params->{id} (like Tidal) → albumTracks → {items=>...}.
        $item{url} = \&Plugins::Deezer::Plugin::getAlbum;
        $item{passthrough} = [ { id => $albumId } ];
    }
    else {
        return undef;
    }

    return \%item;
}

# Rebuild a streaming PLAYLIST node from a captured playlist id — the playlist mirror of
# _streamingAlbumNode, and the same shape (type => 'playlist' + the service's own coderef),
# so resolveTracks/_albumTracks need no special case: they find the node and invoke it.
#
# The service's LIVE tracklist is what comes back, which is the point — a curated playlist
# changes under you, and we store only its identity, never its contents.
#
# `creatorId => ''` is passed rather than omitted: Tidal's and Deezer's getPlaylist both do
# `$api->userId eq $params->{creatorId}` to decide whether it's the user's own list, which
# warns on an undef under `use warnings`. Empty string answers "not yours" without noise.
sub _streamingPlaylistNode {
    my ($client, $source, $playlistId, $rec) = @_;
    return undef unless defined $playlistId && length $playlistId;

    my %item = (
        name  => $rec->{album_title},
        type  => 'playlist',
        image => $rec->{artwork},
    );

    if ($source eq 'qobuz' && Plugins::Qobuz::Plugin->can('QobuzPlaylistGetTracks')) {
        $item{url}         = \&Plugins::Qobuz::Plugin::QobuzPlaylistGetTracks;
        $item{passthrough} = [ { playlist_id => $playlistId } ];
    }
    elsif ($source eq 'tidal' && Plugins::TIDAL::Plugin->can('getPlaylist')) {
        # Tidal's getPlaylist reads $params->{uuid}.
        $item{url}         = \&Plugins::TIDAL::Plugin::getPlaylist;
        $item{passthrough} = [ { uuid => $playlistId, creatorId => '' } ];
    }
    elsif ($source eq 'deezer' && Plugins::Deezer::Plugin->can('getPlaylist')) {
        # Deezer's getPlaylist reads $params->{id}.
        $item{url}         = \&Plugins::Deezer::Plugin::getPlaylist;
        $item{passthrough} = [ { id => $playlistId, creatorId => '' } ];
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

    my $artist  = $rec->{artist} // '';
    my $album   = $rec->{album_title} // '';
    my $recYear = ($rec->{year} && $rec->{year} =~ /(\d{4})/) ? $1 : '';
    my $query   = _norm("$artist $album");   # Bandcamp combined query (its recall needs the album title)
    # Qobuz/Tidal: search the RAW artist only and filter by title locally. Folding
    # "artist album" into one normalised query made the service's own fuzzy search
    # rank/drop the target (the lesson the sibling ListenBrainz plugin learned); an
    # artist-only search returns the discography so the year/title tiering below can pick
    # the right same-named release. Octet-encode for the URI layer (a wide-char query warns).
    my $artistQuery = $artist;
    utf8::encode($artistQuery) if utf8::is_utf8($artistQuery);

    if ($source eq 'qobuz' && Plugins::Qobuz::Plugin->can('getAPIHandler')
                          && Plugins::Qobuz::Plugin->can('_albumItem')) {
        my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);
        return $cb->(_noMatch($client)) unless $api;
        $api->search(sub {
            my $res = shift;
            my @cand;
            for my $a (@{ ($res && $res->{albums} && $res->{albums}{items}) || [] }) {
                my $candArtist = ref $a->{artist} eq 'HASH' ? $a->{artist}{name} : '';
                next unless _albumMatches(_norm($artist), _norm($album), $candArtist, $a->{title});
                my $item = Plugins::Qobuz::Plugin::_albumItem($client, $a);
                # Raw date field first; fall back to the year the renderer already shows on
                # the item (e.g. "… (2026)") so we don't depend on the exact Qobuz key name.
                my $cy = _yearOf($a->{release_date_original} // $a->{release_date_stream}
                              // $a->{release_date_download} // $a->{year})
                      || _yearOf($item->{name}) || _yearOf($item->{line1}) || _yearOf($item->{line2});
                push @cand, [ $item, $a->{title}, $cy ];
            }
            $cb->(_bestMatches(\@cand, $album, $recYear) || _noMatch($client));
        }, lc($artistQuery), 'albums');
        return;
    }

    if ($source eq 'bandcamp') {
        eval { require Plugins::Bandcamp::Search; 1 } or return $cb->(_noMatch($client));
        # The album was originally matched in the sibling plugin and we kept its native
        # album_id — so prefer the search result whose album_id matches it EXACTLY (the
        # same album, no fuzziness), and only fall back to an artist+album title match.
        my $wantId = $rec->{ref}
            && ($rec->{ref}{album_id} || ($rec->{ref}{passthrough} && $rec->{ref}{passthrough}{album_id}));
        Plugins::Bandcamp::Search::search($client, sub {
            my $res = shift;
            my (@idHits, @titleHits);
            for my $it (@{ ($res && $res->{items}) || [] }) {
                next unless ref $it eq 'HASH';
                my $pt = ref $it->{passthrough} eq 'ARRAY' ? $it->{passthrough}[0] : undef;
                next unless $pt && $pt->{album_id};
                if (defined $wantId && length $wantId && $pt->{album_id} eq $wantId) {
                    push @idHits, $it;
                }
                elsif (_albumMatches(_norm($artist), _norm($album), $pt->{artist}, $pt->{title})) {
                    push @titleHits, $it;
                }
            }
            my @out = @idHits ? @idHits : @titleHits;
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
            my @cand;
            for my $a (@{ $albums || [] }) {
                next unless ref $a eq 'HASH';
                my $ar = $a->{artist} || ($a->{artists} && $a->{artists}[0]) || {};
                my $candArtist = ref $ar eq 'HASH' ? $ar->{name} : '';
                next unless _albumMatches(_norm($artist), _norm($album), $candArtist, $a->{title});
                my $item = Plugins::TIDAL::Plugin::_renderAlbum($a);
                my $cy = _yearOf($a->{releaseDate} // $a->{year})
                      || _yearOf($item->{name}) || _yearOf($item->{line1}) || _yearOf($item->{line2});
                push @cand, [ $item, $a->{title}, $cy ];
            }
            $cb->(_bestMatches(\@cand, $album, $recYear) || _noMatch($client));
        }, { type => 'albums', search => $artistQuery, limit => 20 });
        return;
    }

    # Deezer: mirror of the Tidal branch. getAPIHandler->search(cb,{search,type=>'album'})
    # calls back with a bare arrayref of raw album hashes; render via the plugin's own
    # _renderAlbum (type=>playlist, url=>\&getAlbum, passthrough=>[{id}]). Type SINGULAR.
    if ($source eq 'deezer' && Plugins::Deezer::Plugin->can('getAPIHandler')
                            && Plugins::Deezer::Plugin->can('_renderAlbum')) {
        my $api = Plugins::Deezer::Plugin::getAPIHandler($client);
        return $cb->(_noMatch($client)) unless $api;
        $api->search(sub {
            my $albums = shift;
            my @cand;
            for my $a (@{ $albums || [] }) {
                next unless ref $a eq 'HASH';
                my $ar = $a->{artist} || ($a->{artists} && $a->{artists}[0]) || {};
                my $candArtist = ref $ar eq 'HASH' ? $ar->{name} : '';
                next unless _albumMatches(_norm($artist), _norm($album), $candArtist, $a->{title});
                my $item = Plugins::Deezer::Plugin::_renderAlbum($a);
                my $cy = _yearOf($a->{release_date} // $a->{year})
                      || _yearOf($item->{name}) || _yearOf($item->{line1}) || _yearOf($item->{line2});
                push @cand, [ $item, $a->{title}, $cy ];
            }
            $cb->(_bestMatches(\@cand, $album, $recYear) || _noMatch($client));
        }, { search => $artistQuery, type => 'album', strict => 'off', limit => 20 });
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
    # Once the page url has been resolved (cached on the record by the first replay —
    # _cacheBandcampUrl), it IS the buy page: link straight to it, no scan needed.
    my $burl = $rec->{ref} && $rec->{ref}{album_url};
    return $cb->($burl) if defined $burl && $burl =~ m{^https?://}i;
    # Not cached yet: resolveTracks resolves+caches it; scan the items for the page link.
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
    return 1 if $source eq 'deezer'   && Plugins::Deezer::Plugin->can('getAlbum');
    # A podcast EPISODE needs no service adapter at all — it's a single self-contained
    # enclosure url, stored podcast://-wrapped, and replay is a straight handoff to the
    # Podcast plugin's own protocol handler (which also keeps its resume-position
    # tracking). So the only question is whether that handler exists on this server.
    return 1 if $source eq 'podcast'  && _hasPodcastHandler();
    return 0;
}

# The same "don't store what we can't replay" gate as _serviceCan, asked of the PLAYLIST
# call rather than the album one. Kept separate rather than folded into _serviceCan: a
# service can perfectly well expose one and not the other (Bandcamp has no playlists at
# all), and the album path must not start believing in a service because its playlist
# call exists, or vice versa.
sub _serviceCanPlaylist {
    my ($source) = @_;
    return 0 unless defined $source && length $source;
    return 1 if $source eq 'qobuz'  && Plugins::Qobuz::Plugin->can('QobuzPlaylistGetTracks');
    return 1 if $source eq 'tidal'  && Plugins::TIDAL::Plugin->can('getPlaylist');
    return 1 if $source eq 'deezer' && Plugins::Deezer::Plugin->can('getPlaylist');
    return 0;
}

# Is the built-in Podcast plugin's podcast:// protocol handler registered? Asked with a
# representative url because handlerForURL parses the scheme off one (the same call
# trackAlbumId already relies on).
sub _hasPodcastHandler {
    return eval {
        Slim::Player::ProtocolHandlers->handlerForURL('podcast://https://example.com/e.mp3')
    } ? 1 : 0;
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

    # SELF-TITLED releases ("The Beatles", "Weezer") match on the EXACT title only:
    # the lenient prefix rule below would let "The Beatles" swallow "The Beatles
    # 1962-1966" (Red), "…1967-1970" (Blue), "…Anthology 1". Fires ONLY when the
    # artist is present AND equals the album — LL's lenient empty-artist replay path
    # (the `return 1 unless length $artistNorm` below) is deliberately untouched.
    # (Ported from the Discography plugin 0.11.1 — fleet matcher sync.)
    if (length($artistNorm) && $albumNorm eq $artistNorm) {
        return 0 unless $ct eq $albumNorm;
        return _artistMatch($artistNorm, _norm($candArtist));
    }

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

# From the base-title-matched candidates, return the best-disambiguated subset as an
# arrayref of playable nodes (undef if empty). Each candidate is [ $item, $title, $year ].
# Tiers, best first: exact full title (keeps the "(LP4)" distinguisher) AND matching
# year; then matching year; then exact full title; then everything (today's behaviour).
# This is what stops a same-base-title release replaying the wrong album — "American
# Football (LP4)" resolving to the 1999 "American Football", or one of two same-titled
# "Your Day Will Come"s to the wrong year — which _norm (it strips ALL parens) can't tell
# apart. The distinguishing full title and the year are both already on the saved record.
sub _bestMatches {
    my ($cands, $album, $recYear) = @_;
    return undef unless $cands && @$cands;
    my $want = _normStrict($album);
    my (@t1, @t2, @t3, @t4);
    for my $c (@$cands) {
        my ($item, $title, $cy) = @$c;
        my $te = (length $want && _normStrict($title) eq $want) ? 1 : 0;
        my $ym = ($recYear && $cy && $cy eq $recYear) ? 1 : 0;
        if    ($te && $ym) { push @t1, $item }
        elsif ($ym)        { push @t2, $item }
        elsif ($te)        { push @t3, $item }
        else               { push @t4, $item }
    }
    my $best = @t1 ? \@t1 : @t2 ? \@t2 : @t3 ? \@t3 : \@t4;
    return @$best ? $best : undef;
}

# Extract a plausible release year (19xx/20xx) from a date string (best-effort; '' if
# none). The year-anchored, boundary-bounded pattern ignores an epoch timestamp like
# "released_at" (a long digit run has no 4-digit year at a word boundary), so only real
# "YYYY-MM-DD"-style dates yield a year.
sub _yearOf {
    my ($v) = @_;
    return '' unless defined $v && !ref $v;
    return $1 if $v =~ /\b((?:19|20)\d{2})\b/;
    return '';
}

# The release year a SERVICE states on its own album hash, whatever it happens to call the
# field. Ported from Pitchfork Reviews' _svcYear so the two read a service identically —
# PFR was getting years off native adds that this plugin was dropping, and the difference
# was entirely in the breadth of this lookup.
#
# Takes the HASH, not a string, and that is the point: the field name varies per service
# (Qobuz release_date_original / release_date, TIDAL releaseDate / streamStartDate, Deezer
# release_date) and asking for a fixed few means a service that spells it differently
# silently yields nothing.
#
# `released_at` is Qobuz's EPOCH variant and needs converting, not pattern-matching:
# _yearOf above deliberately refuses it (a long digit run has no 4-digit year at a word
# boundary, so 1767225600 can't become a nonsense "1767"), which is right for a string but
# means an album object carrying ONLY the epoch yielded no year at all. Convert it here,
# where we know what the number is.
#
# Returns '' when nothing usable is present — never undef, and never a guess.
sub serviceYear {
    my (@hashes) = @_;
    for my $h (@hashes) {
        next unless ref $h eq 'HASH';
        # Order is precedence, not taste: Qobuz's *_original is the ORIGINAL release date and
        # *_stream is when it reached streaming, so a reissue gets the year it was actually
        # made. release_date_stream is a Qobuz field PFR's list doesn't carry — keep it, this
        # plugin was already reading it.
        for my $k (qw(release_date_original release_date_stream release_date
                      releaseDate date streamStartDate)) {
            my $v = $h->{$k};
            return $1 if defined $v && !ref $v && $v =~ /^((?:19|20)\d{2})/;
        }
        my $e = $h->{released_at};                      # Qobuz epoch
        if (defined $e && !ref $e && $e =~ /^\d{9,}$/) {
            my $y = (localtime($e))[5] + 1900;
            return $y if $y >= 1900 && $y < 2100;
        }
        return $1 if defined $h->{year} && !ref $h->{year} && $h->{year} =~ /^((?:19|20)\d{2})/;
    }
    return '';
}

# The release year of a LIBRARY album, straight from the local database. Free, always
# available, and authoritative — the mirror of libraryTrackCount.
#
# Needed because Material's custom action has NO $YEAR variable (its map is
# $ALBUMNAME/$ARTISTNAME/$TITLE/$FAVURL/$IMAGE/$ALBUMID), so a library album added from a
# Material menu arrives with no year even though $ALBUMID is passed and LMS knows the
# answer. The year is part of the dedupe key, so a yearless row keys as 'artist|album|' and
# the same album added from anywhere that DOES supply a year lands as a second row dedupe
# can't see. '' on any error, matching serviceYear.
sub libraryAlbumYear {
    my ($albumId) = @_;
    return '' unless $albumId && $albumId =~ /^\d+$/;
    my $y = eval { Slim::Schema->find('Album', $albumId) };
    $y = eval { $y->year } if $y;
    return (defined $y && $y =~ /^((?:19|20)\d{2})$/) ? $1 : '';
}

# Like _norm but KEEPS distinguishing "(...)" content (e.g. "(LP4)") as words — only
# quality/format qualifiers are dropped — so replay can tell same-base-title releases
# apart. (_norm strips ALL parens: right for the fuzzy title GATE, but it collapses these.)
sub _normStrict {
    my $s = lc($_[0] // '');
    $s =~ s/\((?:hi-res[^)]*|explicit|mono|stereo|album|track|remaster(?:ed)?[^)]*|deluxe[^)]*)\)//g;
    $s =~ s/[^a-z0-9]+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

1;
