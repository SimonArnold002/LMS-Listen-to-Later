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
    source      TEXT    NOT NULL,                    -- 'library' | 'qobuz' | 'bandcamp' | ...
    artist      TEXT,
    album_title TEXT,
    year        INTEGER,
    artwork     TEXT,
    ref_kind    TEXT,                                -- 'album_id' | 'url' | 'passthrough'
    ref_json    TEXT,                                -- JSON: { album_id, url, passthrough, _svc }
    dedupe_key  TEXT    NOT NULL,                     -- normalised source|artist|album
    added_at    INTEGER,
    played_at   INTEGER,
    play_count  INTEGER NOT NULL DEFAULT 0,
    UNIQUE(source, dedupe_key)
);
SQL

    $h->do('CREATE INDEX IF NOT EXISTS idx_albums_status ON albums(status)');
    # Rebrand: the "To Buy" list status was 'tobuy' before it became "Wish List".
    $h->do("UPDATE albums SET status = 'wishlist' WHERE status = 'tobuy'");
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

sub dedupeKey {
    my ($artist, $album) = @_;
    return _norm($artist) . '|' . _norm($album);
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
    my $key    = dedupeKey($rec->{artist}, $rec->{album_title});

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
            (status, source, artist, album_title, year, artwork, ref_kind, ref_json, dedupe_key, added_at, play_count)
         VALUES (?,?,?,?,?,?,?,?,?,?,0)',
        undef,
        $status, $source, $rec->{artist}, $rec->{album_title}, $rec->{year},
        $rec->{artwork}, $rec->{ref_kind}, $ref_json, $key, time(),
    );

    return (dbh()->last_insert_id('', '', 'albums', ''), 0, undef);
}

sub get {
    my ($id) = @_;
    my $row = dbh()->selectrow_hashref('SELECT * FROM albums WHERE id = ?', undef, $id);
    return _rowToHash($row);
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

sub findByKey {
    my ($source, $key) = @_;
    my $row = dbh()->selectrow_hashref(
        'SELECT * FROM albums WHERE source = ? AND dedupe_key = ?', undef, $source, $key);
    return _rowToHash($row);
}

# Like findByKey but across EVERY source — the same album from a different service
# shares the same dedupe_key, so this is how add() spots a cross-service duplicate.
# Returns the earliest-added match (lowest id) when more than one exists.
sub findAnyByKey {
    my ($key) = @_;
    my $row = dbh()->selectrow_hashref(
        'SELECT * FROM albums WHERE dedupe_key = ? ORDER BY id LIMIT 1', undef, $key);
    return _rowToHash($row);
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

sub count {
    my ($status) = @_;
    my ($n) = dbh()->selectrow_array('SELECT COUNT(*) FROM albums WHERE status = ?', undef, $status);
    return $n || 0;
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
# Wish List list ('wishlist') are never purged; re-playing an album resets played_at,
# restarting its clock. Returns the number removed.
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
