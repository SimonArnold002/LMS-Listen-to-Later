package Plugins::ListenLater::DB;

# Persistent storage for the Listen Later list.
#
# A plain SQLite file (DBI/DBD::SQLite ship with LMS — the library DB uses them)
# rather than prefs: the list is meant to grow, be sorted several ways, carry
# play history, and be queried by future features. Prefs give none of that.
#
# One row per saved album. Display metadata is denormalised into the row so the
# list renders without re-hitting any streaming service; ref_json carries just
# enough to rebuild a *playable* album node later (see Sources.pm).

use strict;
use warnings;

use DBI;
use JSON::XS ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log = logger('plugin.listenlater');

my $dbh;        # lazily-opened handle
my $JSON = JSON::XS->new->utf8->canonical;

# ---------------------------------------------------------------------------
# Connection / migration
# ---------------------------------------------------------------------------
sub _path {
    my $dir = preferences('server')->get('cachedir') || '/tmp';
    return "$dir/listenlater.db";
}

sub dbh {
    return $dbh if $dbh && $dbh->ping;

    my $path = _path();
    _migrateDbFile($path);   # rebrand: reuse the pre-rename listentolater.db if present
    $dbh = DBI->connect("dbi:SQLite:dbname=$path", '', '', {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
        sqlite_unicode => 1,
    });

    $dbh->do('PRAGMA journal_mode=WAL');
    _migrate($dbh);

    $log->info("Listen Later DB ready at $path");
    return $dbh;
}

# Rebrand migration: the DB was listentolater.db before this release. If the new
# file doesn't exist yet but the old one does, move it (with its WAL/SHM sidecars)
# so the user keeps their saved albums. Best-effort — failure just starts fresh.
sub _migrateDbFile {
    my ($newPath) = @_;
    return if -e $newPath;
    (my $oldPath = $newPath) =~ s/\blistenlater\.db$/listentolater.db/;
    return if $oldPath eq $newPath || !-e $oldPath;
    require File::Copy;
    for my $suf ('', '-wal', '-shm', '-journal') {
        next unless -e "$oldPath$suf";
        File::Copy::move("$oldPath$suf", "$newPath$suf")
            or $log->warn("Listen Later: could not move $oldPath$suf -> $newPath$suf: $!");
    }
    $log->info("Listen Later: migrated DB $oldPath -> $newPath");
    return;
}

sub _migrate {
    my ($h) = @_;

    $h->do(<<'SQL');
CREATE TABLE IF NOT EXISTS albums (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    status      TEXT    NOT NULL DEFAULT 'later',   -- 'later' | 'played' | 'wishlist'
    kind        TEXT    NOT NULL DEFAULT 'album',    -- 'album' | 'track'
    source      TEXT    NOT NULL,                    -- 'library' | 'qobuz' | 'bandcamp' | ...
    artist      TEXT,
    album_title TEXT,                                -- the (parent) album title; also set for a track
    track_title TEXT,                                -- set only when kind='track'
    rel_type    TEXT,                                -- release type for kind='album': 'album'|'ep'|'single' (NULL until known)
    track_count INTEGER,                             -- resolved playable track count (NULL until resolved) — Played's threshold
    year        INTEGER,
    artwork     TEXT,
    ref_kind    TEXT,                                -- 'album_id' | 'url' | 'passthrough'
    ref_json    TEXT,                                -- JSON: { album_id, url, passthrough, _svc }
    dedupe_key  TEXT    NOT NULL,                     -- normalised artist|album|year (+ '|t:<track>' for a track)
    added_at    INTEGER,
    played_at   INTEGER,
    play_count  INTEGER NOT NULL DEFAULT 0,
    UNIQUE(source, dedupe_key)
);
SQL

    $h->do('CREATE INDEX IF NOT EXISTS idx_albums_status ON albums(status)');
    # Rebrand: the "To Buy" list status was 'tobuy' before it became "Wish List".
    $h->do("UPDATE albums SET status = 'wishlist' WHERE status = 'tobuy'");
    # 0.1.43: the dedupe key gained a trailing "|<year>" so same-title different-year
    # albums can both be saved. Upgrade existing 1-pipe keys in place. Idempotent — a
    # migrated key has two pipes so it's skipped; the normalised parts never contain a
    # pipe, so a 1-pipe key is exactly the old format. Keeps existing rows dedup-stable
    # and keeps Played's artist|album-prefix lookup matching them.
    $h->do("UPDATE albums SET dedupe_key = dedupe_key || '|' || COALESCE(CAST(year AS TEXT), '')
            WHERE dedupe_key NOT LIKE '%|%|%'");
    # 0.1.71: streaming rows added from a sibling plugin that labels its rows "Artist - Album"
    # (Pitchfork Reviews) were stored with the artist prefixed into the album title, so the
    # list showed it doubled AND Played auto-detection never matched (the key's album segment
    # carried the artist, so the playing track's clean album name never lined up). Clean the
    # already-saved rows to match the fixed add path (which now reads the clean album from the
    # favurl '&al='). See _migrateArtistPrefix.
    #
    # Run it ONCE, gated on the SQLite PRAGMA user_version (0 = never run: a fresh db or an
    # upgrade from < 0.1.72). Unlike the self-limiting SQL migrations above, this one is a
    # full non-library SELECT + a per-row Perl loop, so re-running it on every start is pure
    # wasted work; worse, a row that can't be cleaned (a UNIQUE(source,dedupe_key) collision
    # with an already-clean twin) would re-log its skip WARN on every boot forever. The gate
    # makes both one-off. Idempotent regardless, so a re-run after a partial upgrade is safe.
    my ($schemaVer) = $h->selectrow_array('PRAGMA user_version') || 0;
    if ($schemaVer < 1) {
        _migrateArtistPrefix($h);
        $h->do('PRAGMA user_version = 1');
    }
    # 0.1.74: track saves. Existing DBs predate the kind/track_title/rel_type columns —
    # add them (a fresh install already has them from CREATE TABLE, so guard on absence).
    # kind defaults 'album', so every legacy row keeps behaving as an album; rel_type is
    # NULL until the release is first resolved (then classified — see Sources::relTypeFor).
    if ($schemaVer < 2) {
        _addColumn($h, 'kind',        "TEXT NOT NULL DEFAULT 'album'");
        _addColumn($h, 'track_title', 'TEXT');
        _addColumn($h, 'rel_type',    'TEXT');
        $h->do('PRAGMA user_version = 2');
    }
    # 0.1.88: the resolved playable track count, so a STREAMING release can be thresholded
    # on what it actually contains instead of the blunt streaming_min_tracks floor (see
    # Played::_totalTracks). NULL on every existing row and filled the first time each is
    # resolved — no backfill is possible here, the count only comes from the service.
    if ($schemaVer < 3) {
        _addColumn($h, 'track_count', 'INTEGER');
        $h->do('PRAGMA user_version = 3');
    }
    # 0.1.90: every streaming count stored before this version is WRONG and has to go.
    # They were produced by counting the resolved item list with a deny-list filter, which
    # let a service's non-track rows through — Qobuz sends 5-6 with every album ('Artist:
    # …', 'Credits', 'Music Label: …', 'Copyright', …), so a 1-track release was recorded as
    # 6 and an 11-track album as 17 (see Sources::isPlayableTrack). Played thresholds on this
    # number, so those rows want 60% of a total that overshoots what can be played: the
    # 1-track release needed 4 and could never be marked at all.
    #
    # A wrong count cannot heal on its own — Played only resolves a count it does NOT have
    # (Played::_onChange), so a present-but-wrong one is never revisited. Clearing them puts
    # every streaming row back to "length unknown", which the next play resolves correctly.
    # Library rows are untouched: their count is queried live and was never stored here.
    if ($schemaVer < 4) {
        my $n = eval { $h->do("UPDATE albums SET track_count = NULL WHERE source != 'library'") } || 0;
        $log->warn("Listen Later: cleared $n stale streaming track count(s) — they will be "
            . "re-measured on the next play") if $n && $n ne '0E0';
        $h->do('PRAGMA user_version = 4');
    }
    return;
}

# ALTER TABLE ... ADD COLUMN, but only if the column isn't already present (a fresh
# install created it in CREATE TABLE, and ALTER on an existing column errors). Idempotent.
sub _addColumn {
    my ($h, $name, $decl) = @_;
    my $info = eval { $h->selectall_arrayref('PRAGMA table_info(albums)', { Slice => {} }) } || [];
    return if grep { ($_->{name} // '') eq $name } @$info;
    eval { $h->do("ALTER TABLE albums ADD COLUMN $name $decl"); 1 }
        or $log->warn("Listen Later: add column $name failed: $@");
    return;
}

# One-off cleanup for rows whose album title begins with the artist name + " - " (a sibling
# plugin's "Artist - Album" row label stored verbatim as the album). Strip the redundant
# "<artist> - " prefix and recompute the dedupe_key so Played's artist|album lookup matches.
# Streaming rows only — a LOCAL album can legitimately be titled "Artist - Title", and library
# adds never came through the polluting path. Per-row guarded against a UNIQUE(source,
# dedupe_key) collision with an already-clean twin (that row is left as-is). Naturally
# idempotent: a cleaned title no longer begins with "<artist> - ". Gated to run once (see
# _migrate / PRAGMA user_version).
#
# The prefix must be the SPACE-PADDED "<artist> <dash> <album>" shape Material renders for a
# two-part row label — requiring whitespace on both sides of the dash keeps a hyphenated
# single-token title ("Jay-Z", "Sunn O)))-Monoliths") from being misread as a prefix. The
# dash may be any of the dash family (hyphen, figure/en/em/horizontal-bar, minus) since
# sibling labels differ. Residual (accepted, now bounded to one run): a streaming album whose
# REAL title genuinely is "<its own artist> - <rest>" with spaces is indistinguishable from
# the pollution by stored content alone and is still stripped — vanishingly rare, and library
# rows (where it's most plausible) are excluded outright.
sub _migrateArtistPrefix {
    my ($h) = @_;
    my $rows = eval {
        $h->selectall_arrayref(
            "SELECT id, artist, album_title, year FROM albums
              WHERE source != 'library' AND artist IS NOT NULL AND artist != ''
                AND album_title IS NOT NULL",
            { Slice => {} });
    } or return;
    for my $r (@$rows) {
        my $clean = $r->{album_title};
        next unless $clean =~ s/^\s*\Q$r->{artist}\E\s+[-\x{2012}\x{2013}\x{2014}\x{2015}\x{2212}]\s+//i
                 && length $clean;
        my $key = dedupeKey($r->{artist}, $clean, $r->{year});
        eval {
            $h->do('UPDATE albums SET album_title = ?, dedupe_key = ? WHERE id = ?',
                undef, $clean, $key, $r->{id});
            1;
        } or $log->warn("Listen Later: artist-prefix cleanup skipped id $r->{id}: $@");
    }
    return;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Normalise for the dedupe KEY. NB: intentionally differs from Sources::_norm —
# this one KEEPS parenthesised/bracketed text (only collapses non-alphanumerics),
# so "Album (Deluxe)" and "Album" dedupe as distinct saves. Do NOT unify the two:
# Sources::_norm strips "(…)"/"[…]" for fuzzy match tolerance, which is the opposite
# of what a stable dedupe key needs.
sub _norm {
    my $s = lc($_[0] // '');
    $s =~ s/[^a-z0-9]+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# The dedupe key is source-agnostic (source is its own column) and includes the release
# YEAR, so two same-artist/same-title albums from different years — e.g. Chanel Beads'
# 2024 and 2026 "Your Day Will Come", titled identically — are DISTINCT saves rather than
# one blocking the other. The album title still keeps its "(Deluxe)"/"(LP4)" qualifiers
# (see _norm), which already separated differently-titled editions; the year separates
# the identically-titled ones. Year is the 4-digit release year, or '' when unknown.
# For a TRACK save, a fourth arg (the track title) appends a '|t:<track>' segment, so a
# saved track is a distinct key from its parent album (3 segments vs 4) AND from other
# tracks on it — this is what lets a track and its album co-exist as independent rows
# (UNIQUE(source,dedupe_key)), and keeps Played's album-prefix lookups from matching tracks.
sub dedupeKey {
    my ($artist, $album, $year, $track) = @_;
    my $yr = (defined $year && $year =~ /(\d{4})/) ? $1 : '';
    my $key = _norm($artist) . '|' . _norm($album) . '|' . $yr;
    $key .= '|t:' . _norm($track) if defined $track && length $track;
    return $key;
}

sub _rowToHash {
    my ($row) = @_;
    return undef unless $row;
    my %h = %$row;
    $h{ref} = eval { $JSON->decode($h{ref_json} || '{}') } || {};
    return \%h;
}

# ---------------------------------------------------------------------------
# CRUD
# ---------------------------------------------------------------------------

# add($rec, $status) — $rec: { source, artist, album_title, year, artwork, ref_kind, ref }
# $status is the target list for a NEW album: 'later' (default) or 'wishlist'.
# Returns (id, $already) where $already is true if it was already present.
sub add {
    my ($rec, $status) = @_;
    $status = 'later' unless defined $status && $status =~ /^(?:later|wishlist)$/;

    my $source = $rec->{source} or return (undef, 0, undef);
    my $kind   = ($rec->{kind} && $rec->{kind} eq 'track') ? 'track' : 'album';
    my $key    = ($kind eq 'track')
        ? dedupeKey($rec->{artist}, $rec->{album_title}, $rec->{year}, $rec->{track_title})
        : dedupeKey($rec->{artist}, $rec->{album_title}, $rec->{year});

    # Block duplicates across EVERY source, not just the same one: the same album
    # saved from a different streaming service (or the library) is still the same
    # album, so an accidental "Add" is a no-op — we never create a second row and
    # never move it between sections (use the explicit "Move to …" for that).
    # Return the existing row's source so the caller can name it in the toast.
    my $existing = findAnyByKey($key);
    if ($existing) {
        return ($existing->{id}, 1, $existing->{source});
    }

    my $ref_json = $JSON->encode($rec->{ref} || {});

    dbh()->do(
        'INSERT INTO albums
            (status, kind, source, artist, album_title, track_title, rel_type, track_count, year, artwork, ref_kind, ref_json, dedupe_key, added_at, play_count)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,0)',
        undef,
        $status, $kind, $source, $rec->{artist}, $rec->{album_title}, $rec->{track_title},
        $rec->{rel_type}, _sane($rec->{track_count}), $rec->{year},
        $rec->{artwork}, $rec->{ref_kind}, $ref_json, $key, time(),
    );

    return (dbh()->last_insert_id('', '', 'albums', ''), 0, undef);
}

sub get {
    my ($id) = @_;
    my $row = dbh()->selectrow_hashref('SELECT * FROM albums WHERE id = ?', undef, $id);
    return _rowToHash($row);
}

# Backfill the artist on an existing row (and recompute its dedupe_key, which now includes
# the artist — so Played's artist|album lookup and future dedupe both work). Used when a
# service supplies no artist at add time (Tidal) and it's fetched from the album afterwards.
# Won't clobber an existing artist. Eval-guarded: recomputing the key could in principle hit
# the UNIQUE(source,dedupe_key) constraint (a twin already stored with the artist) — leave
# the row as-is if so.
sub updateArtist {
    my ($id, $artist) = @_;
    return unless $id && defined $artist && length $artist;
    my $rec = get($id) or return;
    return if defined $rec->{artist} && length $rec->{artist};   # don't overwrite a real artist
    my $key = dedupeKey($artist, $rec->{album_title}, $rec->{year});
    eval { dbh()->do('UPDATE albums SET artist = ?, dedupe_key = ? WHERE id = ?', undef, $artist, $key, $id); 1 }
        or $log->warn("ListenLater: updateArtist($id) failed: $@");
    return;
}

# Fill in a MISSING release year, and recompute the dedupe key with it — the exact shape of
# updateArtist above, and for the same reason. A streaming browse row often carries no year
# (only the sibling plugins' '&y=' handshake and Material's Now Playing "Album (YYYY)" label
# supply one), and the year is part of the key: a row saved without one keys as
# 'artist|album|', so the SAME album added later from a source that does supply the year keys
# differently and lands as a second row that dedupe can't see. Backfilled from the service's
# own album object (Sources::classifyRelType) once we've fetched it for other reasons.
#
# Never overwrites a year we already hold: that one came from the add, closer to the user's
# own view of the release, and a service's date can differ (reissue vs original).
sub updateYear {
    my ($id, $year) = @_;
    return unless $id && defined $year && $year =~ /^(?:19|20)\d{2}$/;
    my $rec = get($id) or return;
    return if $rec->{year};                                       # don't overwrite a real year
    my $key = dedupeKey($rec->{artist}, $rec->{album_title}, $year);
    eval { dbh()->do('UPDATE albums SET year = ?, dedupe_key = ? WHERE id = ?', undef, $year, $key, $id); 1 }
        or $log->warn("ListenLater: updateYear($id) failed: $@");
    return;
}

# Persist a resolved value into the row's ref_json (e.g. a Bandcamp purchase URL
# discovered on first open), so later lookups are instant. Merges into existing ref.
sub setRefValue {
    my ($id, $key, $value) = @_;
    return unless $id && defined $key;
    my $rec = get($id) or return;
    my $ref = (ref $rec->{ref} eq 'HASH') ? $rec->{ref} : {};
    $ref->{$key} = $value;
    dbh()->do('UPDATE albums SET ref_json = ? WHERE id = ?', undef, $JSON->encode($ref), $id);
    return;
}

# Find a saved album by artist+album REGARDLESS of year — the Played detector's lookup.
# The dedupe key now carries the year, but a playing streaming track can't be trusted to
# report the same year (or any), so Played matches on the artist|album prefix of the key
# instead. The normalised parts contain only [a-z0-9 ], so they carry no LIKE
# metacharacters (no ESCAPE needed). If two same-title different-year albums are both
# saved, the lower id wins — Played can't tell them apart from streaming track metadata
# alone (an accepted edge case; adding both is the point of the year in the key).
sub findByArtistAlbum {
    my ($source, $artist, $album) = @_;
    my $prefix = _norm($artist) . '|' . _norm($album) . '|';
    # kind='album' only: a track row's key shares this artist|album| prefix (it just adds
    # a '|t:<track>' segment), so without the guard the album detector would match tracks.
    my $row = dbh()->selectrow_hashref(
        "SELECT * FROM albums WHERE source = ? AND kind = 'album' AND dedupe_key LIKE ? ORDER BY id LIMIT 1",
        undef, $source, $prefix . '%');
    return _rowToHash($row);
}

# The saved 'later' TRACK (kind='track') matching a playing track, for independent
# track-Played marking (Played.pm). Year-agnostic like findByArtistAlbum — a playing
# streaming track can't be trusted to report the year — anchored to the '|t:<track>'
# segment so it can only match a track row with this exact (normalised) title.
sub findSavedTrack {
    my ($source, $artist, $album, $track) = @_;
    return undef unless defined $track && length $track;
    my $prefix = _norm($artist) . '|' . _norm($album) . '|';
    my $suffix = '|t:' . _norm($track);
    my $row = dbh()->selectrow_hashref(
        "SELECT * FROM albums WHERE source = ? AND kind = 'track' AND dedupe_key LIKE ? ORDER BY id LIMIT 1",
        undef, $source, $prefix . '%' . $suffix);
    return _rowToHash($row);
}

# A saved TRACK (kind='track') by artist + title, regardless of the stored album or year —
# the cross-kind reconciler for singles (a single release and its lone track are the same
# recording). Anchored to the '|t:<title>' suffix so it matches only a track row with this
# exact (normalised) title; the album segment between the artist and the suffix is wild. The
# normalised parts are [a-z0-9 ] so they carry no LIKE metacharacters (no ESCAPE needed).
sub findTrackByArtistTitle {
    my ($source, $artist, $title) = @_;
    return undef unless defined $source && length $source
        && defined $title && length $title;
    my $pattern = _norm($artist) . '|%|t:' . _norm($title);
    my $row = dbh()->selectrow_hashref(
        "SELECT * FROM albums WHERE source = ? AND kind = 'track' AND dedupe_key LIKE ? ORDER BY id LIMIT 1",
        undef, $source, $pattern);
    return _rowToHash($row);
}

# Persist a release-type classification ('album'|'ep'|'single') once it's known — set at
# add time for library releases (track count is free) and lazily on first resolve for
# streaming ones (see Sources::relTypeFor). Won't overwrite an existing value unless
# $force is set, which only the mislabelled-single correction does (Browse::_albumTracks):
# there the stored type is a source's claim and the resolved tracklist has just disproved
# it, so it is the one case where a known value is worth replacing.
# A count is only worth storing if it's a positive whole number — a service that
# returns nothing resolvable must leave the column NULL ("unknown"), not 0, since Played
# reads any stored count as a real total. Returns undef for anything else.
sub _sane {
    my ($n) = @_;
    return (defined $n && $n =~ /^\d+$/ && $n > 0) ? $n + 0 : undef;
}

# Persist the resolved playable track count. Unlike rel_type this DOES overwrite: it's a
# fact about the release re-measured on every resolve, and the newest measurement is the
# one to keep (a service that fixes an incomplete tracklist should correct the row).
sub updateTrackCount {
    my ($id, $count) = @_;
    my $n = _sane($count) or return;
    return unless $id;
    eval { dbh()->do('UPDATE albums SET track_count = ? WHERE id = ?', undef, $n, $id); 1 }
        or $log->warn("Listen Later: updateTrackCount($id) failed: $@");
    return;
}

sub updateRelType {
    my ($id, $relType, $force) = @_;
    return unless $id && defined $relType && $relType =~ /^(?:album|ep|single)$/;
    my $sql = "UPDATE albums SET rel_type = ? WHERE id = ?"
        . ($force ? '' : ' AND rel_type IS NULL');
    eval { dbh()->do($sql, undef, $relType, $id); 1 }
        or $log->warn("Listen Later: updateRelType($id) failed: $@");
    return;
}

# All saved albums for a source whose NORMALISED album title matches, regardless of artist
# or year — Played's fallback lookup when the playing track's metadata artist doesn't equal
# the stored album artist ("feat." track credits / album-artist vs track-artist / an
# artist-less row a backfill never filled). The caller disambiguates by a fuzzy artist
# compare, so a same-titled album by a genuinely different artist isn't returned by mistake.
# The album part is normalised [a-z0-9 ] so it carries no LIKE metacharacters (no ESCAPE);
# the '|<album>|' anchors it to the middle key segment so it can't match an artist/year.
sub findByAlbum {
    my ($source, $album) = @_;
    my $alb = _norm($album);
    return () unless length $alb;
    my $rows = dbh()->selectall_arrayref(
        "SELECT * FROM albums WHERE source = ? AND kind = 'album' AND dedupe_key LIKE ? ORDER BY id",
        { Slice => {} }, $source, '%|' . $alb . '|%');
    return map { _rowToHash($_) } @$rows;
}

# Across EVERY source — the same album saved from a different service shares the same
# dedupe_key, so this is how add() spots a cross-service duplicate. Returns the
# earliest-added match (lowest id) when more than one exists.
sub findAnyByKey {
    my ($key) = @_;
    my $row = dbh()->selectrow_hashref(
        'SELECT * FROM albums WHERE dedupe_key = ? ORDER BY id LIMIT 1', undef, $key);
    return _rowToHash($row);
}

# The saved TRACK (kind='track') whose stored play url is exactly this url — the primary,
# most-reliable track-Played match (Played.pm), since a saved track stores its canonical
# url and that's what plays. Scans the (small) track rows for the source, like
# findBySourceAlbumId, because the url lives in ref_json (not a queryable column).
sub findTrackByUrl {
    my ($source, $url) = @_;
    return undef unless defined $url && length $url;
    my $rows = dbh()->selectall_arrayref(
        "SELECT * FROM albums WHERE kind = 'track' AND source = ?", { Slice => {} }, $source);
    for my $row (@$rows) {
        my $h = _rowToHash($row);
        return $h if ($h->{ref}{url} // '') eq $url;
    }
    return undef;
}

# Reverse lookup used by play-detection: which stored album owns this ref?
# $matchKind/$matchVal e.g. ('album_id', 1234) for library, or ('passthrough_album_id', 'abc') for streaming.
sub findBySourceAlbumId {
    my ($source, $albumId) = @_;
    return undef unless defined $albumId && length $albumId;

    my $rows = dbh()->selectall_arrayref(
        'SELECT * FROM albums WHERE source = ?', { Slice => {} }, $source);
    for my $row (@$rows) {
        my $h = _rowToHash($row);
        my $aid = $h->{ref}{album_id} // ($h->{ref}{passthrough} && $h->{ref}{passthrough}{album_id});
        return $h if defined $aid && "$aid" eq "$albumId";
    }
    return undef;
}

# Album rows whose stored SERVICE LABEL (ref.svc_title, written by _addCtxCommand when a
# sibling's '&al=' replaced the title — 0.1.92) matches this album name. The last resort for
# Played: a record saved under MusicBrainz's bare release name ("American Football") never
# matches the title the service reports while playing ("American Football (LP2)"), because
# _norm here deliberately KEEPS the qualifier. Scanned rather than queried — svc_title lives
# in ref_json, not a column — exactly like findBySourceAlbumId, and for the same reason: the
# table is a hand-curated list (tens of rows), so a scan on the MISS path is free. Returns a
# list; the caller still has to disambiguate by artist.
sub findBySourceRefTitle {
    my ($source, $album) = @_;
    my $want = _norm($album);
    return () unless length $want;

    my $rows = dbh()->selectall_arrayref(
        "SELECT * FROM albums WHERE source = ? AND kind = 'album'", { Slice => {} }, $source);
    my @out;
    for my $row (@$rows) {
        my $h = _rowToHash($row);
        my $t = $h->{ref}{svc_title};
        next unless defined $t && length $t;
        push @out, $h if _norm($t) eq $want;
    }
    return @out;
}

# list($status, $sort) — $sort: added|artist|album|year|played
sub list {
    my ($status, $sort) = @_;
    $sort ||= 'added';

    my %order = (
        added  => 'added_at DESC',
        artist => 'LOWER(artist), year',
        album  => 'LOWER(album_title)',
        year   => 'year DESC, LOWER(artist)',
        played => 'played_at DESC',
    );
    my $orderby = $order{$sort} || $order{added};

    my $rows = dbh()->selectall_arrayref(
        "SELECT * FROM albums WHERE status = ? ORDER BY $orderby",
        { Slice => {} }, $status);

    return [ map { _rowToHash($_) } @$rows ];
}

sub remove {
    my ($id) = @_;
    dbh()->do('DELETE FROM albums WHERE id = ?', undef, $id);
    return;
}

sub setStatus {
    my ($id, $status) = @_;
    my $played_at = $status eq 'played' ? time() : undef;
    dbh()->do('UPDATE albums SET status = ?, played_at = COALESCE(?, played_at) WHERE id = ?',
        undef, $status, $played_at, $id);
    return;
}

sub markPlayed {
    my ($id) = @_;
    dbh()->do(
        "UPDATE albums SET status = 'played', played_at = ?, play_count = play_count + 1 WHERE id = ?",
        undef, time(), $id);
    return;
}

# Delete Played albums whose played_at is older than $days days. Only status='played'
# rows are ever deleted, so albums moved back to Listen Later ('later') or to the
# Wish List list ('wishlist') are never purged. played_at is set the moment an album is
# marked Played and is NOT refreshed by replaying an already-Played album (Played
# detection only tracks 'later' rows — see Played.pm), so the retention clock runs from
# the first Played mark; move it back to 'later' and re-play it to restart the clock.
# Returns the number removed.
sub purgePlayed {
    my ($days) = @_;
    return 0 unless $days && $days =~ /^\d+$/ && $days > 0;
    my $cutoff = time() - $days * 86400;
    my $n = dbh()->do(
        "DELETE FROM albums WHERE status = 'played' AND played_at IS NOT NULL AND played_at < ?",
        undef, $cutoff);
    return ($n && $n ne '0E0') ? ($n + 0) : 0;
}

1;
