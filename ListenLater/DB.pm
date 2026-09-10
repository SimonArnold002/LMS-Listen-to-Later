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

# A live artist/year backfill can merge a row while another callback, timer, or already-rendered
# menu still carries its old id. Keep that process-local lineage: AUTOINCREMENT ids are never
# reused in this database, and a server restart removes every in-flight carrier along with this
# map. `get()` deliberately remains an exact existence check; callers opt into following a
# logical row with getCanonical()/canonicalId(), while service-derived writes additionally check
# that the survivor still belongs to the service which produced their answer.
my %identityCanonical;

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
    kind        TEXT    NOT NULL DEFAULT 'album',    -- 'album' | 'track' | 'playlist'
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
    dedupe_key  TEXT    NOT NULL,                     -- normalised artist|album|year (+ '|t:<track>' for a track, '|p:<svc>:<id>' for a playlist, '|e:<svc>:<url>' for a streaming podcast episode, '|u:<svc>:<url>' for a NAMELESS track that collided with another — see trackUrlKey)
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
    # 0.1.112: the fleet matcher sync gave DB::_norm Latin folding and apostrophe
    # elision, and DB::_norm builds `dedupe_key`. Every key stored under the old fold
    # is therefore stale — and a stale key is INVISIBLE, not merely untidy: add() would
    # no longer dedupe against it and Played's lookups would no longer find it. Rewrite
    # them, collapsing the duplicates the new fold merges. See _migrateRefold for the
    # collision policy (same-status groups merge into the earliest save; mixed-status
    # ones are left alone rather than guessing which list the user wanted).
    #
    # LAST among migrations that RECOMPUTE a key from row metadata, on purpose: it reads
    # every row and must run AFTER the migrations that change what a key is built from
    # (0.1.43's year segment, 0.1.71's artist-prefix cleanup), or it would faithfully rekey
    # rows those passes are about to rewrite again. Rung 7 comes later but only reconciles
    # exact keys already stored; it does not define another key shape.
    #
    # Stamped ONLY on a completed pass. _migrateRefold reports false when its one SELECT
    # fails, and when a group's merge had to be rolled back; stamping regardless would retire
    # the migration for good — those keys left on the OLD fold, which is precisely the
    # invisible-row state it exists to prevent, with no path back. Leaving the version where
    # it is costs one extra SELECT at the next start and gets the rewrite done then instead.
    # A mixed-status group is NOT a failure — it is left alone on purpose (see
    # _migrateRefold), so it must not hold the ladder back for ever.
    if ($schemaVer < 5) {
        if (_migrateRefold($h)) {
            $h->do('PRAGMA user_version = 5');
        }
        else {
            # Report the version the ladder actually STAMPED, not the one it was ENTERED at.
            # Rungs 1-4 stamp user_version without reassigning $schemaVer, so a 2 -> 5 upgrade
            # failing here used to say "left at version 2" with the database at 4. One extra
            # read, on the failure path only. Rung 6 ($ladderVer) and rung 7 ($identityVer)
            # already had a live read to hand; this rung is the one that did not.
            my ($atVer) = $h->selectrow_array('PRAGMA user_version');
            $atVer = 0 unless defined $atVer;
            $log->warn('Listen Later: dedupe-key refold did not complete (see the warnings '
                . "above) — schema left at version $atVer so it is retried at the next "
                . 'start');
        }
    }

    # 0.1.136 — the built-in Podcasts-app path was REMOVED, so its rows are purged rather
    # than migrated. A re-key would have been the higher-risk change (this file's most
    # expensive bugs all live on the UNIQUE dedupe_key rung) for rows the user has agreed to
    # re-add by hand, and the removal means nothing can replay a 'podcast://' url any more:
    # Sources::_serviceCan no longer has an arm for it, so a surviving row would sit in the
    # list unplayable. The report is written BEFORE the DELETE and the whole purge is one
    # transaction, so a failed pass cannot lose either a row or its recovery record.
    # Re-read the version rather than trusting the one taken at entry: rung 5 withholds its
    # stamp on failure so it retries next start, and stamping 6 over it would carry the
    # ladder PAST a rung that never ran — losing that retry for good. A rung must never
    # advance the version on behalf of an earlier one that failed.
    my ($ladderVer) = $h->selectrow_array('PRAGMA user_version');
    $ladderVer = 0 unless defined $ladderVer;
    if ($ladderVer < 5) {
        $log->warn("Listen Later: an earlier migration is still pending (schema $ladderVer) "
            . '— the podcast purge waits for it rather than stamping over it');
    }
    elsif ($schemaVer < 6) {
        if (_purgeRemovedPodcasts($h)) {
            $h->do('PRAGMA user_version = 6');
        }
        else {
            $log->warn('Listen Later: podcast purge did not complete — schema left at '
                . "version $ladderVer so it is retried at the next start");
        }
    }

    # 0.1.137 — repair databases that already ran the original rung-5 refold. That version
    # grouped by (source,key), weaker than add()'s cross-source findAnyByKey rule, so two old
    # spellings from different services could both be rewritten to the same logical key and
    # survive. Editing rung 5 is necessary for upgrades from released builds, but not enough
    # for a dev install that has already stamped 5/6; this new rung reconciles the keys as they
    # now stand. It waits for the destructive purge exactly as rung 6 waits for the refold.
    my ($identityVer) = $h->selectrow_array('PRAGMA user_version');
    $identityVer = 0 unless defined $identityVer;
    if ($identityVer < 6) {
        $log->warn("Listen Later: an earlier migration is still pending (schema $identityVer) "
            . '— cross-source identity repair waits rather than stamping over it');
    }
    elsif ($identityVer < 7) {
        if (_migrateCrossSourceIdentity($h)) {
            $h->do('PRAGMA user_version = 7');
        }
        else {
            $log->warn('Listen Later: cross-source identity repair did not complete — schema '
                . "left at version $identityVer so it is retried at the next start");
        }
    }

    # 0.1.143 — re-run the refold under the fold that no longer DELETES a non-Latin name.
    # See _norm: until this version 米津玄師 / Кино / !!! all normalised to '', so their rows
    # carry a key that identifies nothing and unrelated releases sit on a shared '||'.
    #
    # A NEW RUNG RATHER THAN AN EDIT TO RUNG 5, for the reason rung 7 already records: a dev
    # install has stamped 5 and would never revisit it, and a released install needs rung 5 to
    # keep doing its own job on the way past. Both reach the new fold here.
    #
    # _migrateRefold needs NO EDIT — it recomputes every key through _keyForRow (so the new
    # fold applies by construction), skips a row whose key is unchanged, preserves the
    # '|p:'/'|e:'/'|u:' identity tails, and withholds its answer on operational failure so the
    # stamp below is retried. What makes this rung cheap is a property of the FOLD, not of the
    # migration: the new one only stops deleting characters, so it can only SPLIT a group,
    # never merge two. Every UNIQUE collision _migrateRefold guards against is unreachable
    # here, and a Latin-only library is rekeyed zero rows.
    #
    # It waits on rung 7 exactly as rung 7 waits on 6 — a rung must never advance the version
    # on behalf of an earlier one that failed, or that rung's retry is lost for good.
    #
    # STAMPS 9, NOT 8 (0.1.144), and this is a version-number edit rather than a tenth rung
    # on purpose. 0.1.143 shipped this same rung stamping 8, with a fold whose two
    # substitutions ran in the wrong order — see _norm, where the order is now spelled out.
    # Under it '01_-_Intro' keyed '01   intro' instead of '01 intro', so a dev install that
    # already stamped 8 holds keys nothing will ever look up again. A rung 9 that called
    # _migrateRefold a second time would run the identical pass twice on every other
    # database; moving THIS rung's stamp lets a database at 8 re-enter and a database below
    # 8 arrive here exactly as before, with one pass either way.
    #
    # ONE THING THIS CANNOT REPAIR. A database that was at 5 or 6 when 0.1.143 ran had its
    # colliding rows DELETED by rung 7 before this rung could split them (measured: three
    # unrelated non-Latin albums in, one out). The guard in _migrateCrossSourceIdentity
    # stops that happening again, but the deleted saves are gone and only the user can
    # re-add them. That is why the guard is a precondition on the DELETE and not merely a
    # reordering of the ladder.
    my ($foldVer) = $h->selectrow_array('PRAGMA user_version');
    $foldVer = 0 unless defined $foldVer;
    if ($foldVer < 7) {
        $log->warn("Listen Later: an earlier migration is still pending (schema $foldVer) "
            . '— the non-Latin refold waits rather than stamping over it');
    }
    elsif ($foldVer < 9) {
        if (_migrateRefold($h)) {
            $h->do('PRAGMA user_version = 9');
        }
        else {
            $log->warn('Listen Later: the non-Latin refold did not complete (see the warnings '
                . "above) — schema left at version $foldVer so it is retried at the next start");
        }
    }
    return;
}

# Which rows go, and why `source` alone cannot answer it for Spotify.
#
#   source 'podcast'        — the removed built-in path. ALL of them.
#   source 'deezerpodcast'  — its own scheme, so the tag is enough.
#   source 'spotify'        — the tag is shared with every Spotify MUSIC TRACK, so only the
#                             play url separates them. Before 0.1.126 (commit 49b8902, which
#                             added spotifyEpisodeUri, episodeKey AND the `episode` flag in
#                             one go) an episode was not recognised at all and stored as an
#                             ordinary track — a `|t:` key with no `|e:` tail. Those rows are
#                             indistinguishable from music by key alone.
#
# So the url is the test, through Sources::spotifyEpisodeUri — the one carrier for that
# question, which already accepts both the bare 'spotify:episode:<id>' and the '//' spelling
# normaliseFavurl has produced since 0.1.113. A CORRECTLY-keyed streaming episode is KEPT:
# that path is still supported.
sub _purgeRemovedPodcasts {
    my ($h) = @_;

    my $rows = eval {
        $h->selectall_arrayref(
            "SELECT id, status, source, artist, album_title, track_title, dedupe_key,
                    ref_json, added_at
               FROM albums WHERE source IN ('podcast', 'deezerpodcast', 'spotify')",
            { Slice => {} })
    };
    unless ($rows) {
        $log->error("Listen Later: podcast purge could not read the table: $@");
        return 0;
    }

    my @doomed;
    for my $r (@$rows) {
        # The REMOVED path: every one of them, whatever its key.
        if ($r->{source} eq 'podcast') {
            push @doomed, $r;
            next;
        }
        # Everything below is a STREAMING episode, which is a SUPPORTED path — Deezer's as
        # much as Spotify's. A correctly-keyed one is KEPT. Only a MIS-KEYED one goes, and
        # the '|e:' tail is what says which: episodeKey (and the `episode` flag that drives
        # it) arrived in 0.1.126, so a Deezer row written by 0.1.124-0.1.125 or a Spotify
        # row written before recognition existed carries a '|t:' key instead. Those cannot
        # dedupe or mark played against the url the way the supported path does, and they
        # have never shipped, so they are cleared rather than carried.
        next if ($r->{dedupe_key} // '') =~ /\|e:/;
        # Deezer's own scheme says "episode" on its own; Spotify's source tag is shared with
        # every music track, so only the play url can answer it — via the one carrier that
        # knows both the bare and '//' spellings.
        if ($r->{source} eq 'deezerpodcast') {
            push @doomed, $r;
            next;
        }
        my $ref = eval { $JSON->decode($r->{ref_json} // '{}') } || {};
        # Sources is a SIBLING LEAF and DB.pm does not `use` it — it cannot. The package
        # name matches the INSTALLED layout, so a top-level `use` compiles only where a
        # Plugins/ parent exists: it dies in a checkout, taking every test suite with it
        # (measured). In the plugin, Plugin.pm compiles both modules before anything can
        # reach dbh(), so the sub is always there; the guard is for the day that stops
        # being true. It is NOT the ->can-with-a-fallback the %FOLD header forbids, and the
        # difference is what the fallback DOES: there is no second way to ask whether a
        # Spotify row is an episode, so an unanswerable question ABORTS THE WHOLE RUNG
        # rather than deciding the row. Nothing is deleted, no report is written, the stamp
        # is withheld and the next start tries again. Skipping the row instead would KEEP a
        # mis-keyed episode this rung exists to clear; carrying on regardless would delete
        # music. Both of those are the irreversible half. Waiting is not.
        my $episodeUri = Plugins::ListenLater::Sources->can('spotifyEpisodeUri');
        unless ($episodeUri) {
            $log->error('Listen Later: podcast purge cannot identify Spotify episodes '
                . '(Sources is not loaded) — nothing has been removed and the purge is '
                . 'retried at the next start');
            return 0;
        }
        next unless $episodeUri->($ref->{url});
        push @doomed, $r;
    }
    return 1 unless @doomed;

    _writePurgeReport(\@doomed);

    # ALL OR NOTHING. The report is the user's recovery record and is rewritten when this
    # rung retries. Committing each DELETE separately let a late failure remove the first
    # episodes, leave the version at 5, then rewrite the report on the retry with only the
    # rows still present — erasing the only record of what the first pass had deleted.
    # Keeping every DELETE in one transaction means a retry sees (and reports) the same full
    # set. Unlike the refold's historical fallback, a destructive purge never runs unwrapped.
    unless (eval { $h->begin_work; 1 }) {
        $log->error("Listen Later: podcast purge could not begin its transaction: $@");
        return 0;
    }

    my ($gone, $err) = (0, undef);
    for my $r (@doomed) {
        my $rv = eval { $h->do('DELETE FROM albums WHERE id = ?', undef, $r->{id}) };
        if ($@ || !defined $rv || $rv eq '0E0') {
            $err = "could not delete id $r->{id}: " . ($@ || 'row was no longer present');
            last;
        }
        $gone++;
    }
    if (!defined $err) {
        eval { $h->commit; 1 } or $err = "could not commit: $@";
    }
    if (defined $err) {
        _rollbackTransaction($h, 'podcast purge');
        $log->error("Listen Later: podcast purge $err — no deletions were committed");
        return 0;
    }
    $log->warn("Listen Later: removed $gone podcast row(s) — see " . _reportPath());
    return 1;
}

# A failed DBI rollback can leave AutoCommit off on this process-wide handle, causing every
# later plugin write to join a transaction nothing commits. Try the normal rollback first;
# if it raises, issue SQLite's raw ROLLBACK before restoring AutoCommit. Callers still treat
# that path as a failure and abandon their current operation — this only makes the handle safe
# for the rest of the server run.
sub _rollbackTransaction {
    my ($h, $what) = @_;
    return 1 if eval { $h->rollback; 1 };

    my $err = $@;
    $log->error("Listen Later: $what rollback failed: $err");
    eval { $h->do('ROLLBACK'); 1 }
        or $log->error("Listen Later: $what could not roll back by hand either "
            . "(SQLite has most likely done it already): $@");
    eval { $h->{AutoCommit} = 1; 1 }
        or $log->error("Listen Later: $what could not restore AutoCommit: $@");
    return 0;
}

sub _reportPath {
    my $dir = preferences('server')->get('cachedir') || '/tmp';
    return "$dir/listenlater-removed-podcasts.txt";
}

# Beside the DB, in the same cachedir DB::_path uses, so a support question is answerable
# from one place. Best-effort: a report we cannot write must not stop the purge, but it is
# logged loudly, because the whole point is that the user can re-add these by hand.
sub _writePurgeReport {
    my ($rows) = @_;
    my $path = _reportPath();
    my $ok = eval {
        open my $fh, '>:encoding(UTF-8)', $path or die "$path: $!\n";
        print $fh "Listen Later — podcast rows removed by the 0.1.136 upgrade\n";
        print $fh "Built-in Podcasts-app support was removed; these rows could no longer be\n"
                . "played, so they were deleted. Re-add anything you still want by hand.\n\n";
        for my $r (sort { ($a->{added_at} || 0) <=> ($b->{added_at} || 0) } @$rows) {
            my @when = localtime($r->{added_at} || 0);
            printf $fh "[%s] %s — %s%s\n    url: %s\n    added: %04d-%02d-%02d\n\n",
                ($r->{status}   // 'later'),
                ($r->{album_title} // '(no show)'),
                ($r->{track_title} // '(no title)'),
                ($r->{source} eq 'podcast' ? '' : "  [$r->{source}]"),
                ((eval { $JSON->decode($r->{ref_json} // '{}')->{url} }) // '(none)'),
                $when[5] + 1900, $when[4] + 1, $when[3];
        }
        close $fh;
        1;
    };
    $log->error("Listen Later: could not write the podcast removal report: $@") unless $ok;
    return $ok ? 1 : 0;
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
# One-off REKEY for the 0.1.112 fleet matcher sync. `DB::_norm` gained Latin folding
# and apostrophe elision, and it builds `dedupe_key` — a UNIQUE column on every row —
# so every stored key computed under the old fold is now wrong. A key nothing
# recomputes the same way is invisible: add() would stop deduping against it and
# Played's lookups would stop finding it. This is the migration the fold change owes.
#
# THE NEW FOLD MERGES KEYS THAT WERE DISTINCT, which is the point ("Jane's Addiction"
# and "Janes Addiction" are one album) and also the whole difficulty — UNIQUE(source,
# dedupe_key) has to be satisfied while collapsing them. Runtime add() defines sameness
# ACROSS services through findAnyByKey, so rows are grouped by their new logical key — not
# by the weaker SQL (source,key) constraint — and each group is settled as a unit. Playlist
# and episode keys already carry their source in their '|p:'/'|e:' identity tail, so they
# remain service-scoped without a second grouping rule. Each group is settled as a unit
# rather than updating rows one at a time and catching the constraint error: a per-row loop
# also collides transiently
# against rows it has not reached yet, so the error tells you nothing about whether a
# real duplicate exists.
#
# COLLISION POLICY, and the asymmetry is deliberate:
#
#   • SAME STATUS across the group -> genuinely the same album saved twice under two
#     spellings. Collapse into the EARLIEST-SAVED row (that is the save the user
#     remembers making) and carry the play history and any resolved metadata across,
#     so nothing learned about the release is lost. The others are deleted.
#
#   • MIXED STATUS (one 'later', one 'played', one in the Wish List) -> NEVER MERGED,
#     with a WARN naming the ids. Collapsing would have to silently pick a list for the
#     user: marking a Wish List item played, or resurrecting something they had finished
#     with. NOTHING IS EVER DELETED without a same-status twin to merge into.
#
#     THAT BAR IS ON MERGING, NOT ON REKEYING, and the difference is the whole point of
#     grouping cross-source. UNIQUE(source, dedupe_key) is per SERVICE, so a Qobuz 'later'
#     row and a Tidal 'played' row can BOTH hold the new key. Rekey each service's rows
#     independently and refuse only the merge: the ambiguous pair stays two visible rows
#     (what the policy wants) but each is on the CURRENT fold, so add() still dedupes
#     against it and Played can still find it. Skipping the rekey too would strand both on
#     a stale key that no later pass revisits — the rung stamps regardless — which is the
#     invisible row this whole migration exists to prevent.
#
#     Only rows whose OWN service holds both statuses stay on their old keys: they cannot
#     both take the one new key, and choosing between them is exactly the guess we refuse.
#
# Idempotent: a second run recomputes the same keys, finds them already stored, and
# changes nothing. Gated once on PRAGMA user_version regardless.

# Merge one same-status logical-key group transactionally. This is shared by the one-off
# refold and the live key-changing backfills below, so cross-source identity cannot be
# repaired at upgrade and then recreated later by updateArtist/updateYear.
#
# `source` and the ref pair are ONE replay bundle. Album ids and passthrough shapes are
# interpreted by the adapter selected from source; for tracks, Played also derives source
# from the play url before findTrackByUrl. Copying a Tidal ref into a Qobuz survivor while
# leaving source unchanged therefore makes a row that cannot replay or auto-mark. The
# earliest row keeps its own bundle when it has one. If it has none, the first replayable
# loser's source/ref bundle moves together.
sub _mergeKeyRows {
    my ($h, $rows, $newKey) = @_;
    return { ok => 0, error => 'no rows to merge' }
        unless $rows && @$rows && defined $newKey;

    my @sorted = sort { ($a->{added_at} // 9**15) <=> ($b->{added_at} // 9**15)
                     || $a->{id} <=> $b->{id} } @$rows;
    my $keep = shift @sorted;

    for my $lose (@sorted) {
        $keep->{play_count} = ($lose->{play_count} // 0) > ($keep->{play_count} // 0)
                            ? $lose->{play_count} : $keep->{play_count};
        $keep->{played_at} = $lose->{played_at}
            if !defined $keep->{played_at}
            || (defined $lose->{played_at} && $lose->{played_at} > $keep->{played_at});
        for my $f (qw(artist album_title track_title artwork year)) {
            $keep->{$f} = $lose->{$f} if !defined $keep->{$f} && defined $lose->{$f};
        }
        if (!length($keep->{ref_kind} // '') && length($lose->{ref_kind} // '')) {
            @{$keep}{qw(track_count rel_type)} = (undef, undef)
                if ($keep->{source} // '') ne ($lose->{source} // '');
            @{$keep}{qw(source ref_kind ref_json)} = @{$lose}{qw(source ref_kind ref_json)};
        }
        # A streaming count is the number of tracks THIS service actually made playable in
        # this account/region, and rel_type can likewise be a service's own catalogue claim.
        # Carry either only from the replay source the survivor now uses (including the loser
        # whose whole source/ref bundle was just adopted). A different service gets to resolve
        # and classify itself later.
        if (($keep->{source} // '') eq ($lose->{source} // '')) {
            for my $f (qw(track_count rel_type)) {
                $keep->{$f} = $lose->{$f} if !defined $keep->{$f} && defined $lose->{$f};
            }
        }
    }

    unless (eval { $h->begin_work; 1 }) {
        return { ok => 0, fatal => 1, error => "could not begin transaction: $@" };
    }

    my $err;
    for my $lose (@sorted) {
        my $rv = eval { $h->do('DELETE FROM albums WHERE id = ?', undef, $lose->{id}) };
        if ($@ || !defined $rv || $rv eq '0E0') {
            $err = "could not delete id $lose->{id}: " . ($@ || 'row was no longer present');
            last;
        }
    }
    if (!defined $err) {
        my $rv = eval {
            $h->do('UPDATE albums SET source = ?, artist = ?, album_title = ?, track_title = ?,
                                      dedupe_key = ?, played_at = ?, play_count = ?,
                                      track_count = ?, rel_type = ?, artwork = ?, year = ?,
                                      ref_kind = ?, ref_json = ?
                     WHERE id = ?',
                undef, $keep->{source}, $keep->{artist}, $keep->{album_title},
                $keep->{track_title}, $newKey, $keep->{played_at}, $keep->{play_count} // 0,
                $keep->{track_count}, $keep->{rel_type}, $keep->{artwork}, $keep->{year},
                $keep->{ref_kind}, $keep->{ref_json}, $keep->{id});
        };
        $err = "could not rekey id $keep->{id}: " . ($@ || 'row was no longer present')
            if $@ || !defined $rv || $rv eq '0E0';
    }
    if (!defined $err) {
        eval { $h->commit; 1 } or $err = "could not commit the merge of id $keep->{id}: $@";
    }
    if (defined $err) {
        my $rolled = _rollbackTransaction($h, "dedupe-key merge of id $keep->{id}");
        return { ok => 0, fatal => ($rolled ? 0 : 1), error => $err };
    }

    return { ok => 1, id => $keep->{id}, merged => scalar @sorted };
}

# Rung 7: settle exact logical-key duplicates already left across services by the original
# rung-5 grouping, or created when an older live artist/year backfill converged on another
# source. Do NOT recompute keys here — rung 5 owns the fold. This pass repairs databases that
# already stamped that rung, so the key currently stored is the fact to reconcile.
sub _migrateCrossSourceIdentity {
    my ($h) = @_;
    my $rows = eval { $h->selectall_arrayref('SELECT * FROM albums', { Slice => {} }) }
        or return;
    return 1 unless @$rows;

    my %group;
    push @{ $group{ $_->{dedupe_key} // '' } }, $_ for @$rows;

    # ONE COUNTER PER REASON, AND THE SUMMARY NAMES THE REASON IT COUNTS. $skipped used to
    # carry both of these and the summary called all of them 'mixed-status', so a database
    # whose only skip was a fold split told the user to merge by hand rows that no two
    # statuses were ever involved in — and that the refold rung fixes moments later. If a
    # third reason to leave a row alone ever appears here, give it a third counter rather
    # than borrowing one of these; a counter here is not 'rows untouched', it is one cause.
    # (Named $foldSplit, not $split: the guard below uses a lexical %split hash. Perl keeps
    # the two apart by sigil, a reader does not.)
    my ($merged, $skipped, $foldSplit, $failed) = (0, 0, 0, 0);
  GROUP:
    for my $g (grep { @$_ > 1 } values %group) {
        # PARTITION BY STATUS — never skip the whole group on one dissenter. The documented
        # rule is that same-list duplicates collapse while conflicting lists stay separate,
        # and a wholesale skip breaks the first half: in a group of later:qobuz, later:tidal
        # and played:spotify, the two 'later' rows are an ordinary duplicate the user sees
        # twice, and the rung stamps either way so nothing ever revisits them.
        #
        # Unlike the refold this pass NEVER RECOMPUTES A KEY — every row here already stores
        # the identical key — so a subset merge only deletes rows and rewrites the survivor to
        # the key it already holds. UNIQUE(source, dedupe_key) additionally means the rows in
        # one group are all on DIFFERENT services, so no collision is reachable here at all.
        my %byStatus;
        push @{ $byStatus{ $_->{status} // '' } }, $_ for @$g;
        if (keys %byStatus > 1) {
            $log->warn('Listen Later: cross-source identity repair found different statuses ('
                . join(', ', map { "id $_->{id} [" . ($_->{status} // '?') . ']' } @$g)
                . ') — each list is settled on its own, merge by hand if you want them as one');
        }

        for my $u (values %byStatus) {
            # Alone in its list: nothing to merge it with, and its conflicting neighbours are
            # exactly what policy leaves standing.
            if (@$u < 2) {
                $skipped += @$u if keys %byStatus > 1;
                next;
            }

            # A SHARED STORED KEY IS NOT PROOF OF A SHARED IDENTITY, and this rung deletes
            # rows, so it has to check. Every row here holds the same key under WHATEVER
            # fold was current when it was written; if the fold has moved on since, that
            # key can be a collision the current fold does not make. The 0.1.143 refold is
            # exactly that case: until it, _norm ERASED a non-Latin name, so 中島みゆき/歌姫,
            # サカナクション/新宝島 and Кино/Группа крови all stored '||' on three different
            # services — different albums, one key. Merging them deletes two real saves,
            # which is the loss 0.1.143 exists to prevent, and the refold rung cannot undo it
            # because the rows are gone (MEASURED on a database at user_version 6).
            #
            # Ask the CURRENT fold instead. If it splits the unit, these were never one
            # album: leave every row alone and let the refold rung give each its own key.
            # This is not the "recompute keys here" the header forbids — nothing is
            # written, the rung still only ever stores a key a row already holds. It is a
            # precondition on the DELETE, and it belongs here rather than in the ladder
            # because it holds however the rungs are ordered and on every later retry.
            my %split = map { ( _keyForRow($_) => 1 ) } @$u;
            if (keys %split > 1) {
                $foldSplit += @$u;
                $log->warn('Listen Later: cross-source identity repair will not merge rows '
                    . 'the current fold tells apart ('
                    . join(', ', map { "id $_->{id} [" . ($_->{artist} // '?') . ' / '
                        . ($_->{album_title} // '?') . ']' } @$u)
                    . ") — they share the stored key '" . ($u->[0]{dedupe_key} // '')
                    . "' only because an older fold erased their names; the refold rung "
                    . 'gives each its own');
                next;
            }

            my $settled = _mergeKeyRows($h, $u, $u->[0]{dedupe_key});
            unless ($settled->{ok}) {
                $failed++;
                $log->warn("Listen Later: cross-source identity repair $settled->{error} — "
                    . 'the group is untouched and will be retried at the next start');
                last GROUP if $settled->{fatal};
                next;
            }
            $merged += $settled->{merged};
        }
    }

    # Every row counted below has already been warned about individually, with its ids and
    # its cause, so the summary states only what this rung DID — no clause claims what a
    # later rung will do with a row, because a failed group here withholds the stamp and the
    # refold rung then waits instead of running.
    $log->info('Listen Later: cross-source identity repair — '
        . join(', ', "$merged duplicate(s) merged",
            ($skipped ? "$skipped mixed-status row(s) left unchanged" : ()),
            ($foldSplit ? "$foldSplit row(s) left unmerged, the current fold tells them apart"
                        : ())))
        if $merged || $skipped || $foldSplit;
    return $failed ? 0 : 1;
}

sub _migrateRefold {
    my ($h) = @_;

    my $rows = eval {
        $h->selectall_arrayref(
            "SELECT id, source, kind, status, artist, album_title, track_title, year,
                    dedupe_key, added_at, played_at, play_count, track_count, rel_type,
                    artwork, ref_kind, ref_json
               FROM albums",
            { Slice => {} });
    } or return;
    # An empty table IS a completed pass — nothing to rewrite, so the version stamps and this
    # never runs again. Only the failed SELECT above returns false.
    return 1 unless $rows && @$rows;

    # A PLAYLIST key is not rebuildable from artist/album/year — its identity is the
    # service's own id, which lives in the '|p:<source>:<id>' tail rather than in any
    # column here. Re-normalise the TITLE segment and carry that tail across verbatim,
    # so the one part that identifies the row cannot be disturbed by a fold change.
    my %group;
    for my $r (@$rows) {
        # Same carrier as every other writer (_keyForRow). It prefers a stored '|p:'/'|e:' id
        # tail over a rebuild, which is exactly what this migration needs: re-normalise the
        # TITLE segment under the new fold, never touch the segment that identifies the row.
        $r->{_new} = _keyForRow($r);
        push @{ $group{ $r->{_new} } }, $r;
    }

    my ($rekeyed, $merged, $skipped, $failed) = (0, 0, 0, 0);
  GROUP:
    for my $g (values %group) {
        # Untouched by the fold: nothing to do, and no group to settle.
        next if @$g == 1 && $g->[0]{dedupe_key} eq $g->[0]{_new};

        # One unit per thing that may be settled as a whole. Same status throughout: the
        # group is one unit and merges. Mixed: split by SERVICE, because the merge is what
        # the policy above forbids and the constraint that would stop a rekey is per source.
        my @units = ($g);
        my %status = map { ($_->{status} // '') => 1 } @$g;
        if (keys %status > 1) {
            my %bySource;
            push @{ $bySource{ $_->{source} // '' } }, $_ for @$g;
            my @stuck;
            @units = ();
            for my $u (values %bySource) {
                my %s = map { ($_->{status} // '') => 1 } @$u;
                keys %s > 1 ? push(@stuck, @$u) : push(@units, $u);
            }
            $log->warn('Listen Later: refold will not merge rows with different statuses ('
                . join(', ', map { "id $_->{id} [" . ($_->{status} // '?') . ']' } @$g)
                . ') — each service\'s rows are rekeyed on their own, merge by hand if you '
                . 'want them as one') if @units;
            if (@stuck) {
                $skipped += @stuck;
                $log->warn('Listen Later: refold cannot rekey different statuses on one '
                    . 'service ('
                    . join(', ', map { "id $_->{id} [" . ($_->{status} // '?') . ']' } @stuck)
                    . ') — left on their old keys, merge by hand if you want them as one');
            }
        }

        for my $u (@units) {
            # A single row the fold did not move: the group only existed for its twin.
            next if @$u == 1 && $u->[0]{dedupe_key} eq $u->[0]{_new};

            my $settled = _mergeKeyRows($h, $u, $g->[0]{_new});
            unless ($settled->{ok}) {
                $skipped += @$u;
                $failed++;
                $log->warn("Listen Later: refold $settled->{error} — the whole group is left "
                    . 'on its old key(s), untouched; it is retried at the next start');
                last GROUP if $settled->{fatal};
                next;
            }

            $merged  += $settled->{merged};
            $rekeyed++;
        }
    }

    $log->info("Listen Later: dedupe-key refold — $rekeyed row(s) rekeyed, "
             . "$merged duplicate(s) merged, $skipped left on the old key")
        if $rekeyed || $merged || $skipped;

    # A group that FAILED withholds the version stamp, so the next start tries it again —
    # the likeliest causes (the db locked by another process, a full disk) are transient, and
    # a rolled-back group is in exactly the state a retry wants. A MIXED-STATUS skip does not:
    # that is a deliberate policy decision, not an error, and re-running could never change it
    # — it would just re-log the same warn at every boot for ever. Which is exactly why the
    # skip is now as NARROW as the policy needs: only rows whose own service holds both
    # statuses keep an old key, and those are the only ones a retry could never help.
    #
    # DO NOT "TIDY" A UNIQUE COLLISION INTO $skipped. It reads like the same policy case — the
    # squatter is a mixed-status row left alone on purpose — and it is not, because the loop
    # above runs `values %group`, i.e. HASH order, randomised per process. A collision against
    # a row that a LATER group would have vacated is TRANSIENT and the retry is what heals it
    # (measured at ~40% of runs on a seeded pair). Counting it as a skip would stamp the ladder
    # and strand those rows on the OLD fold for ever — invisible to add() and to Played, the
    # exact state this migration exists to prevent. Raised and withdrawn twice; Review Ledger
    # A2 has the worked case.
    return $failed ? 0 : 1;
}

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
        # kind => 'album' is asserted, not assumed, and it is the whole reason this SELECT
        # stays four columns wide. This rung runs at `user_version < 1`; `kind`/`track_title`
        # are added at `< 2`, BELOW it — so on the only DBs that reach here (pre-0.1.72) those
        # columns do not exist, no track or playlist row can exist either, and selecting them
        # would make the SELECT die `no such column: kind`, which the `or return` above
        # swallows: the cleanup would silently stop running on exactly the databases needing
        # it. Saying 'album' out loud is what stops that being re-"fixed". See Review Ledger A2.
        my $key = _keyForRow({ %$r, album_title => $clean, kind => 'album' });
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
# ---------------------------------------------------------------------------
# LATIN FOLDING — SHARED BY ALL THREE NORMALISERS, AND IT LIVES HERE ON PURPOSE.
#
# LL has three normalisers in two LEAF modules (neither Sources nor DB requires
# the other): DB::_norm builds the durable dedupe key, Sources::_norm is the fuzzy
# match gate, Sources::_normStrict is the replay ranker. All three must fold the
# same way or they disagree about what a name is.
#
# It sits in DB.pm rather than in Sources.pm with the rest of the matcher, and the
# reason is asymmetric damage. Sources reaches this through `->can` at runtime (no
# compile-time cycle between two leaf modules — the same pattern LBF's
# API::_foldKey uses to reach Browse::_norm), and a `->can` that ever missed would
# take a fallback path. In the LIVE matching path a fallback is merely a worse
# match, thrown away at the end of the request. In the DEDUPE KEY path it would
# write a DIFFERENT KEY into a UNIQUE column, permanently, and the row would then
# be invisible to every later lookup. So the authority lives with the irreversible
# consumer, and DB::_norm calls it DIRECTLY — never through ->can, never with a
# fallback.
#
# THAT RULE IS ABOUT THIS FOLD, not about the direction of the arrow. DB.pm reaches Sources
# once more, in _purgeRemovedPodcasts, and that one IS a ->can — because its fallback is to
# abort the rung and delete nothing, not to answer the question worse. See the comment there.
#
# (Fleet matcher sync, LL 0.1.112: the ~90-entry table is DSC/PFR/LBF's, verbatim.
# LL previously had NO folding at all, and its `[^a-z0-9]` pass turned every
# non-ASCII letter into a SPACE — so "Sigur Rós" keyed as 'sigur r s', shattered
# into single-letter tokens, and `_artistMatch`'s token-subset test could never
# reconcile it with the plain "Sigur Ros" spelling.)
# ---------------------------------------------------------------------------
my $HAVE_NFD = eval { require Unicode::Normalize; 1 } ? 1 : 0;
my %FOLD = (
    # ligatures and digraphs
    "\x{e6}"  => 'ae', "\x{153}" => 'oe', "\x{df}"  => 'ss', "\x{fe}" => 'th',
    "\x{133}" => 'ij', "\x{1c6}" => 'dz', "\x{1f3}" => 'dz', "\x{1c9}" => 'lj',
    "\x{1cc}" => 'nj', "\x{223}" => 'ou', "\x{195}" => 'hv', "\x{1a3}" => 'oi',
    # stroked / barred letters
    "\x{f8}"  => 'o', "\x{111}" => 'd', "\x{142}" => 'l', "\x{127}" => 'h',
    "\x{167}" => 't', "\x{180}" => 'b', "\x{19a}" => 'l', "\x{1e5}" => 'g',
    "\x{23c}" => 'c', "\x{23f}" => 's', "\x{240}" => 'z', "\x{247}" => 'e',
    "\x{249}" => 'j', "\x{24b}" => 'q', "\x{24d}" => 'r', "\x{24f}" => 'y',
    "\x{1b6}" => 'z', "\x{2c65}" => 'a', "\x{2c66}" => 't', "\x{289}" => 'u',
    "\x{268}" => 'i', "\x{275}" => 'o',
    # hooked letters
    "\x{253}" => 'b', "\x{188}" => 'c', "\x{256}" => 'd', "\x{257}" => 'd',
    "\x{192}" => 'f', "\x{260}" => 'g', "\x{199}" => 'k', "\x{1ad}" => 't',
    "\x{1a5}" => 'p', "\x{272}" => 'n', "\x{19e}" => 'n', "\x{288}" => 't',
    "\x{28b}" => 'v', "\x{1b4}" => 'y', "\x{271}" => 'm',
    # dotless, long-s, turned and archaic forms
    "\x{131}" => 'i', "\x{17f}" => 's', "\x{140}" => 'l', "\x{138}" => 'k',
    "\x{149}" => 'n', "\x{14b}" => 'n', "\x{1dd}" => 'e', "\x{259}" => 'e',
    "\x{254}" => 'o', "\x{25b}" => 'e', "\x{25c}" => 'e', "\x{292}" => 'z',
    "\x{250}" => 'a', "\x{26f}" => 'm', "\x{28a}" => 'u', "\x{26a}" => 'i',
    "\x{283}" => 'sh', "\x{263}" => 'g', "\x{28c}" => 'v', "\x{280}" => 'r',
    "\x{21d}" => 'g', "\x{1bf}" => 'w', "\x{1a8}" => 's', "\x{225}" => 'z',
    "\x{221}" => 'd', "\x{234}" => 'l', "\x{235}" => 'n', "\x{236}" => 't',
    "\x{237}" => 'j', "\x{f0}"  => 'd',
);

# Lowercase, decode, strip combining marks, fold the atomic letters NFD cannot
# split, and elide apostrophes. Everything up to (not including) the punctuation
# pass, which is where the three normalisers legitimately differ.
sub foldLatin {
    my $s = $_[0] // '';

    # Input arrives as OCTETS from a raw-CLI request (Plugin.pm's handlers take artist /
    # album straight off `$request->getParam`) and as characters everywhere else — SQLite
    # included, since the handle sets `sqlite_unicode`. Fold only what is valid UTF-8, and
    # only adopt the decode if it succeeds — a latin-1 byte string is left exactly as it was.
    if (!utf8::is_utf8($s) && $s =~ /[^\x00-\x7f]/) {
        my $d = $s;
        $s = $d if utf8::decode($d);
    }

    # LOWERCASE **AFTER** THE DECODE, not before. `lc` on a byte string is ASCII-only, so an
    # uppercase accented letter survives the fold as bytes, decodes to an uppercase codepoint,
    # and `_norm`'s `[^a-z0-9]` then DELETES it rather than folding it: 'SIGUR RÓS' keyed
    # 'sigur r s' on the octet path against 'sigur ros' on the character path — the same album
    # under two keys in a UNIQUE column, which is the invisible row _migrateRefold exists to
    # prevent. Lowercasing here costs nothing on the character path (identical result) and
    # must stay above the %FOLD pass, whose keys are all lowercase.
    $s = lc($s);
    if ($HAVE_NFD && utf8::is_utf8($s)) {
        $s = Unicode::Normalize::NFC(
             Unicode::Normalize::NFD($s) =~ s/[\x{0300}-\x{036F}]+//gr );
        $s =~ s/([^\x00-\x7f])/exists $FOLD{$1} ? $FOLD{$1} : $1/ge;
    }

    # APOSTROPHES ELIDE — they do NOT become a space. Every other mark the callers'
    # punctuation passes handle SEPARATES words; an apostrophe sits INSIDE one.
    # Spacing it keyed "Jane's Addiction" as 'jane s addiction' against 'janes
    # addiction', and `Sources::_artistMatch` is an exact-token SUBSET test — so the
    # token 'janes' matched nothing and Played never marked the record.
    #
    # GUARD — "'n'" contracting "and" joins two WORDS rather than sitting inside
    # one. All three spellings of "Rock'n'Roll" agree today; eliding blindly would
    # key the first 'rocknroll' and break a set that works. Space that form first.
    my $apos = qr/['\x{2019}\x{2018}\x{02bc}\x{00b4}\x{2032}`]/;
    $s =~ s/(?<=\w)${apos}n${apos}(?=\w)/ n /g;
    $s =~ s/$apos//g;

    return $s;
}

# Normalise for the dedupe KEY. NB: intentionally differs from Sources::_norm —
# this one KEEPS parenthesised/bracketed text (only collapses non-alphanumerics),
# so "Album (Deluxe)" and "Album" dedupe as distinct saves. Do NOT unify the two:
# Sources::_norm strips "(…)"/"[…]" for fuzzy match tolerance, which is the opposite
# of what a stable dedupe key needs.
#
# CHANGING THIS SUB CHANGES A STORED KEY. It is not a cache — dedupe_key sits in a
# UNIQUE column on every row, so any edit needs a migration that rewrites existing
# rows AND resolves the collisions the new fold creates. See _migrateRefold.
#
# 0.1.143 — KEEP LETTERS AND DIGITS OF EVERY SCRIPT. Until this version the pass was
# `s/[^a-z0-9]+/ /g`, which does not fold a non-Latin name, it DELETES it: 米津玄師,
# 中島みゆき, 아이유, Кино, †††, !!! and +/- every one normalised to ''. The whole key is
# built from these segments, so a name that folds to nothing produces a key that identifies
# nothing — and that key sits in a UNIQUE column. Two measured consequences:
#   * ALBUMS WERE SILENTLY LOST (shipped, 0.1.93). Artist and title both erased plus no year
#     — or a shared one — collapses unrelated releases onto '||': 中島みゆき/歌姫,
#     サカナクション/新宝島 and Кино/Группа крови all key '||', so the second and third adds
#     are refused "already saved". There is no url fallback on the album path to recover them.
#   * TRACKS DUPLICATED ACROSS SERVICES (0.1.141, never released). `_keyIsNamelessTrack`
#     tests the key's SHAPE, so a track whose artist merely folded away read as nameless and
#     took the '|u:' branch — minting a second row where 0.1.140 answered "already saved".
# The gate was not wrong about keys; the key was wrong about names. Fixing the fold is what
# lets that gate stay strict, and it fixes both paths at once — the album one has no other fix.
#
# THE NEW FOLD IS A PURE SPLIT: it only stops DELETING characters, so two names that folded
# equal either stay equal or come apart, and nothing that folded apart can come together.
# `_migrateRefold`'s collision-resolution path — the expensive half, and where this file's
# worst bugs live — is therefore unreachable for this change. Every Latin key is byte-identical
# ('sigur ros', 'janes addiction', 'album deluxe', '834 194', '100 free', 'under score'), so a
# Latin-only library is rekeyed ZERO rows by the refold rung. That is the property that made this
# migration affordable; do not lose it by "tidying" the fallback below into something lossy.
sub _norm {
    my $s = foldLatin($_[0]);

    # \w on a decoded string is Unicode-aware, so CJK, Hangul and Cyrillic survive while
    # punctuation still separates words exactly as it did. Underscore is stripped BECAUSE
    # \w includes it and it is a LIKE metacharacter — findSavedTrack and
    # findTrackByArtistTitle build LIKE patterns straight out of this sub and pass no ESCAPE.
    #
    # ORDER IS LOAD-BEARING, and it is not obvious from either line on its own. The
    # underscore MUST go first. Run the other way round (0.1.143) the '_' is still a \w
    # character while the non-word pass runs, so it does not join the separator run round
    # it — each one then becomes its OWN space and a mixed run leaves several:
    #   '01_-_Intro'  ->  s/[^\w]+/ /  '01_ _Intro'  ->  s/_+/ /  '01   intro'
    # against '01 intro' from the pre-0.1.143 fold. The bug hides from the obvious test
    # case: an underscore BETWEEN word characters ('under_score', 'M_A_N_D_Y') is its own
    # whole run and folds identically either way, so only an underscore ADJACENT to other
    # punctuation or a space can show it. Measured consequences, both real:
    #   * it breaks the "pure split" property this fold is sold on — 'Artist_-_Album' and
    #     '01_-_Intro' are ordinary ripped-file shapes, so a LATIN-ONLY library is rekeyed
    #     after all and the migration stops being free.
    #   * Sources::_punctPass carries the same two lines, so a saved
    #     'Boards_of_Canada_-_Roygbiv' stopped matching the service's
    #     'Boards of Canada - Roygbiv' — _albumMatches/_bestMatches compare with `eq`.
    my $w = $s;
    $w =~ s/_+/ /g;
    $w =~ s/[^\w]+/ /g;
    $w =~ s/^\s+|\s+$//g;
    return $w if length $w;

    # Nothing survived, so the name is ALL punctuation — a real and not-rare shape for a band
    # ('!!!', '†††', '+/-', '?'). Keep it rather than answering '', or every such act shares
    # one key again and a self-titled album by one of them collides with the next.
    # Three characters must not reach a key and are dropped here: '|' is the key's own
    # SEGMENT DELIMITER (an artist named '|' would otherwise forge a tail like '|p:' or
    # '|t:' and be read as another row's identity), and '%'/'_' are the LIKE metacharacters
    # above. A name made only of those still folds to '', exactly as it did before.
    my $p = $s;
    $p =~ s/[\s%_|]+//g;
    return $p;
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

# The dedupe key for a saved streaming PLAYLIST. A playlist has no artist and no release
# year, and its TITLE is not an identity (two services both offer a "Dance Pop"), so the key
# is built round the one thing that IS one: the service's own playlist id.
#
#   '' | <normalised title> | '' | 'p:<source>:<id>'      e.g. |hi res masters 2016||p:qobuz:69183531
#
# Three load-bearing properties, none of them incidental:
#   • the SOURCE sits inside the id segment. findAnyByKey (which add() dedupes with) is
#     deliberately cross-source, so without it Qobuz playlist 123 and Deezer playlist 123
#     would collapse into one row — for playlists the id is only unique WITHIN a service.
#   • it carries >= 2 pipes, so the 0.1.43 year migration (WHERE dedupe_key NOT LIKE
#     '%|%|%') leaves it alone.
#   • the artist segment is EMPTY, so a curator line can be stored and displayed without
#     ever touching dedupe — the title+id pair is the whole identity.
sub playlistKey {
    my ($source, $id, $title) = @_;
    return '' . '|' . _norm($title) . '|' . '' . '|p:' . lc($source // '') . ':' . ($id // '');
}

# The dedupe key for a saved STREAMING podcast episode. Same problem as the playlist above and
# the same answer: its TITLE is not an identity. "Trailer", "Episode 1", "Introduction" and
# "Chapter I" are titles dozens of shows share.
#
# THE REASON THIS IS RIGHT IS THE COLD CACHE, not "the services never say what the show is" —
# that was the stated justification until 0.1.132 and it is FALSE, checked against both
# vendors' own source. Deezer's PodcastProtocolHandler::getMetadataFor sets
# `$meta->{album} = $meta->{podcast}{title}` on a cache hit, and browsing a show warms that
# cache for every one of its episodes; Spotty's API::Cache normalises an episode to
# `album->{name} = show->{name}` AND `artists = [{ name => show->{publisher} }]`, which its
# getMetadataFor maps straight to album/artist. So a warm handler DOES supply a show, and on
# Spotify a publisher too.
#
# What it cannot do is supply them RELIABLY. _fillFromPlayingMeta is gated on a positive
# `duration`, so on a COLD cache — the first add after a restart, or an episode reached from a
# surface that never warmed it — nothing fills, the row keeps a bare browse-row title, and the
# key collapses to '|||t:trailer'. DB::add then swallows the second episode and leaves one row
# pointing at the FIRST episode's url: the user gets a confirmation and a row that plays the
# wrong thing. A key that is only an identity when a third party's cache happens to be warm is
# not an identity, which is what the url fixes.
#
#   '' | <normalised episode title> | '' | 'e:<source>:<play url>'
#
# The PLAY URL is the id, and deliberately so: it is already this row's identity everywhere
# else (Played::_markPlayedTrack matches DB::findTrackByUrl on it first), so keying on it
# makes the dedupe agree with the match instead of inventing a second notion of sameness. It
# also needs no per-service id parsing — the thing this whole area was cleaned up to avoid.
#
# AND THE TITLE IS NOT EVEN STABLE, which was measured after the fix and is the stronger
# argument: the same episode stores a DIFFERENT title depending on whether the service's
# metadata cache happened to be warm — the browse row's date-stripped line1 when cold, the
# handler's own name when warm (verified live 2026-09-04: the same add sent "Trailer" and
# stored "Mission Killer: …" once Spotty had the episode cached). A title-keyed row is
# therefore not merely ambiguous between episodes, it is unstable for ONE episode. A url is
# the same on both paths.
# The source is inside the id segment for the same reason playlistKey puts it there:
# findAnyByKey is cross-source.
#
# BUILT-IN Podcasts-app episodes deliberately do NOT use this. They store the show in
# album_title (read from the RSS feed), so their key carries a discriminator against OTHER
# SHOWS — but NOT against a sibling episode of the same show, and "cannot collide" was the
# wording here until 0.1.132. Measured: same show + same normalised title + same YEAR still
# collides and the second add is swallowed, and so does a feed that publishes no pubDate (the
# year segment goes empty). Population across five real feeds: 3 of 2,968 in The Daily, 0 in
# the other four. Left as-is DELIBERATELY — url-keying these would owe a migration, since they
# ship from 0.1.87 and `main` is 0.1.93, and a permanent rung on a UNIQUE column is not worth
# 0.1% (this file's most expensive bugs all live in that rung). Re-raise only with a real row; and unlike the streaming sources they exist in released builds (0.1.87,
# where `main` is 0.1.93), so re-keying them would owe a migration for no defect. The rule is
# therefore "an episode with no show stored keys on its url", which is exactly the set that
# lost its discriminator.
sub episodeKey {
    my ($source, $url, $title) = @_;
    return '' . '|' . _norm($title) . '|' . '' . '|e:' . lc($source // '') . ':' . ($url // '');
}

# The dedupe key for a track whose NAME says nothing about which recording it is: no artist
# and no album, so the plain key is '|||t:<title>' and the title is doing all the work. Two
# different songs that happen to share a title then collapse into one row — the second add is
# reported "already saved" and is silently lost. This keys such a row on the one thing that IS
# an identity, the play url, exactly as episodeKey does and for the same stated reason.
#
#   '' | <normalised title> | '' | 'u:<source>:<url>'
#
# WRITTEN ONLY ON A REAL COLLISION (see add()). A row already in the database keeps the key it
# has, so this shape appears only where the alternative was losing a row — which is why it owes
# NO migration rung, unlike the re-keying of every track row that this problem seemed to need.
# It carries >= 2 pipes, so the 0.1.43 year migration (dedupe_key NOT LIKE '%|%|%') skips it,
# and the source sits inside the tail, so the cross-source findAnyByKey cannot fold two
# services' rows together on a shared url.
sub trackUrlKey {
    my ($source, $url, $title) = @_;
    return '' . '|' . _norm($title) . '|' . '' . '|u:' . lc($source // '') . ':' . ($url // '');
}

# Is this key one that carries NO name identity at all? Exactly the '|||t:<title>' shape:
# empty artist, empty album, empty year. Deliberately strict — a key with any of the three
# filled in is a real name and its collisions are real duplicates, which is what the
# cross-source dedupe exists to catch.
sub _keyIsNamelessTrack { return (($_[0] // '') =~ m{^\|\|\|t:}) ? 1 : 0 }

# THE ONE PLACE A CURRENT-FORMAT ROW'S KEY IS DECIDED. Every current writer goes through here
# — add(), updateArtist(), updateYear(), _migrateArtistPrefix() and _migrateRefold() — because
# "what key does this row
# have" was answered in five places and they had already drifted: updateArtist() and
# updateYear() rebuilt with dedupeKey($artist,$album,$year) and NO track segment, so calling
# either on a kind='track' row silently re-keyed it as an ALBUM ('|album x||t:song y' becomes
# 'some artist|album x|'). The row then vanished from findTrackByArtistTitle and findSavedTrack
# and could collide with a real album row, with the eval swallowing the UNIQUE violation. That
# was unreachable when found — both callers sit behind _finishAlbumAdd, which only ever makes
# album rows — but the guard lived entirely in the CALLER, so the first future caller on a track
# row would have inherited it silently. Three separate bugs in this repo have now come from one
# concept answered in more than one place; this closes it for keys.
#
# THE STORED TAIL WINS when there is one. A playlist's and an episode's identity is an id, not a
# name, and it lives in the key's own '|p:…' / '|e:…' tail. Preferring that tail over a rebuild
# is what lets _migrateRefold share this sub: a fold change may legitimately alter how the TITLE
# segment normalises, but it must never disturb the id — and a rebuild would silently do so if
# ref_json ever drifted from the key. Build from `ref` only when there is no tail to keep, which
# is the add path.
sub _keyForRow {
    my ($rec) = @_;
    my $source = $rec->{source} // '';
    my $kind   = ($rec->{kind} && $rec->{kind} =~ /^(?:track|playlist)$/) ? $rec->{kind} : 'album';
    my $stored = $rec->{dedupe_key} // '';

    # `ref` decoded, whichever form the caller holds: add() and get() carry the hash, the
    # migrations select raw ref_json.
    my $ref = (ref $rec->{ref} eq 'HASH') ? $rec->{ref}
            : (defined $rec->{ref_json} ? (eval { $JSON->decode($rec->{ref_json}) } || {}) : {});

    if ($kind eq 'playlist') {
        return '' . '|' . _norm($rec->{album_title}) . '|' . '' . $1 if $stored =~ /(\|p:.*)$/s;
        return playlistKey($source, $ref->{playlist_id}, $rec->{album_title});
    }

    if ($kind eq 'track') {
        # '|u:' joins '|e:' here: both say this row's identity is its play url, not its
        # name, so a rebuild must never quietly replace one with a name key. That is the
        # same rule the header states for '|p:' and '|e:', and it is what lets a later
        # artist backfill run over such a row without re-keying it into its twin.
        return '' . '|' . _norm($rec->{track_title}) . '|' . '' . $1 if $stored =~ /(\|[eu]:.*)$/s;
        # No tail yet: the ADD path says whether this is a streaming episode (Plugin::
        # _insertTrackRow sets it — DB has no business knowing what a podcast is, exactly as it
        # does not know what a playlist is).
        my $epUrl = $rec->{episode} ? $ref->{url} : undef;
        return episodeKey($source, $epUrl, $rec->{track_title})
            if defined $epUrl && length $epUrl;
        return dedupeKey($rec->{artist}, $rec->{album_title}, $rec->{year}, $rec->{track_title});
    }

    return dedupeKey($rec->{artist}, $rec->{album_title}, $rec->{year});
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
    # A three-way whitelist, not a binary: anything unrecognised still falls back to 'album',
    # which is what every legacy row and every caller that passes no kind at all relies on.
    my $kind   = ($rec->{kind} && $rec->{kind} =~ /^(?:track|playlist)$/) ? $rec->{kind} : 'album';
    # One carrier — see _keyForRow. `episode` on the rec is how Plugin::_insertTrackRow tells
    # it this is a streaming podcast episode.
    my $key    = _keyForRow({ %$rec, kind => $kind, source => $source });

    # Block duplicates across EVERY source, not just the same one: the same album
    # saved from a different streaming service (or the library) is still the same
    # album, so an accidental "Add" is a no-op — we never create a second row and
    # never move it between sections (use the explicit "Move to …" for that).
    # Return the existing row's source so the caller can name it in the toast.
    my $existing = findAnyByKey($key);

    # A NAMELESS track key cannot prove a duplicate. '|||t:<title>' says only "some track
    # called this", so two genuinely different songs sharing a title arrive here looking
    # identical and the second one is reported "already saved" and lost. The url check in
    # Plugin::_insertTrackRow cannot help: it runs BEFORE this and answers the opposite
    # question (same url = same recording), so a DIFFERENT url passes it and lands here.
    #
    # Re-ask with the play url as the identity, which is what a track row IS at every other
    # end — Played matches findTrackByUrl before any name, and episodeKey settled the same
    # question for episodes. Only on a genuine collision, and only for this key shape:
    #   * the row already stored is never touched, so no stored key changes and NOTHING owes a
    #     migration rung. That is the whole reason this is done here rather than in _keyForRow.
    #   * a key with an artist, album or year in it keeps the plain shape, so cross-source
    #     dedupe of real names is untouched.
    #   * both rows must carry a url and they must differ. No url means nothing better to key
    #     on, and the old behaviour (treat it as a duplicate) is the safer of two guesses.
    if ($existing && $kind eq 'track' && _keyIsNamelessTrack($key)) {
        my $mine  = (ref $rec->{ref} eq 'HASH') ? ($rec->{ref}{url} // '') : '';
        my $their = $existing->{ref}{url} // '';
        if (length $mine && length $their && $mine ne $their) {
            $key = trackUrlKey($source, $mine, $rec->{track_title});
            # The url-keyed row may itself already exist — a re-add of the SECOND track, which
            # computes the nameless key again and lands here again. Answering "already saved"
            # from this lookup is what stops that becoming a third row.
            $existing = findAnyByKey($key);
        }
    }

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

sub canonicalId {
    my ($id) = @_;
    return unless $id;
    my %seen;
    while ($identityCanonical{$id} && !$seen{$id}++) {
        $id = $identityCanonical{$id};
    }
    return $id;
}

sub getCanonical {
    my ($id) = @_;
    $id = canonicalId($id) or return;
    return get($id);
}

# The service's own album id for a row, wherever the ref happens to carry it. A playlist ref
# must never hold one (Plugin::_savePlaylistRecord), which is what keeps findBySourceAlbumId
# — the one finder with no kind filter — off playlist rows.
sub refAlbumId {
    my ($rec) = @_;
    my $ref = (ref $rec eq 'HASH') ? $rec->{ref} : undef;
    return '' unless ref $ref eq 'HASH';
    my $aid = $ref->{album_id};
    $aid = $ref->{passthrough}{album_id}
        if !defined $aid && ref $ref->{passthrough} eq 'HASH';
    return (defined $aid && length $aid) ? "$aid" : '';
}

# The part of a ref that says WHICH release on the service a row replays: the album id above,
# else the album/play url a url-keyed source (Bandcamp, saved tracks) replays from. Only the
# async-write guards use the url arm — findBySourceAlbumId stays on refAlbumId, because
# widening a REVERSE LOOKUP to match urls would let it answer for rows it never has.
#
# Deliberately NOT the whole ref_json. setRefValue stores RESOLVED DECORATION (album_url,
# buy_url) onto the very rows these guards protect, so a whole-blob compare would reject a
# row's own follow-up write — the guard would then look like it worked while quietly dropping
# every Bandcamp url cache. Only the identifying field is compared.
sub refIdentity {
    my ($rec) = @_;
    my $aid = refAlbumId($rec);
    return $aid if length $aid;
    my $ref = (ref $rec eq 'HASH') ? $rec->{ref} : undef;
    return '' unless ref $ref eq 'HASH';
    for my $u ($ref->{album_url}, $ref->{url}) {
        return "$u" if defined $u && length $u;
    }
    return '';
}

# Resolve a stale id only while its survivor still replays the SAME RELEASE ON THE SAME
# SERVICE as the request that produced an asynchronous answer. Counts, release types and
# resolved URLs describe one service's catalogue/account/region for one release, and must not
# cross to a different replay bundle.
#
# THE SERVICE ALONE IS NOT THE BUNDLE. Two rows for the same release on ONE service exist
# whenever their keys differ — a Qobuz row saved with a year and another saved without — and a
# year backfill then merges the later into the earlier. The survivor keeps its OWN ref
# (_mergeKeyRows only adopts a loser's bundle when the keeper has none), so a callback for the
# deleted catalogue id passes a source-only check and writes the wrong catalogue's track
# count, release type and purchase url onto a DIFFERENT release. Compare the ref identity too.
#
# An EMPTY identity on either side is no evidence and stays permissive: a library row, a
# 'search' ref, and a Bandcamp row still resolving its first album_url all carry none, and
# refusing on absence would drop writes that are correct today.
sub _sameSourceCanonicalId {
    my ($id, $expectedSource, $expectedRefId) = @_;
    return $id unless defined $expectedSource && length $expectedSource;
    my $rec = getCanonical($id) or return;
    return unless ($rec->{source} // '') eq $expectedSource;
    if (defined $expectedRefId && length $expectedRefId) {
        my $have = refIdentity($rec);
        return if length $have && $have ne $expectedRefId;
    }
    return $rec->{id};
}

# Apply one of the two live metadata backfills that changes a dedupe key. DB::add checks
# findAnyByKey before inserting, but a row can still CONVERGE on another service's key later:
# one source arrives without an artist/year, a second source supplies it and is stored under a
# different key, then this backfill fills the missing value. UNIQUE(source,dedupe_key) cannot
# see that collision. Settle it with the same cross-source, same-status policy as the refold.
# Returns the canonical id because the row being updated may be the later duplicate and be
# merged into the earlier save.
sub _updateIdentityField {
    my ($id, $field, $value) = @_;
    return unless $id && defined $field && ($field eq 'artist' || $field eq 'year');

    $id = canonicalId($id) or return;

    my $rec = get($id) or return;
    my %next = (%$rec, $field => $value);
    my $key = _keyForRow(\%next);
    my $h = dbh();

    my $others = eval {
        $h->selectall_arrayref(
            'SELECT * FROM albums WHERE dedupe_key = ? AND id != ? ORDER BY id',
            { Slice => {} }, $key, $id)
    };
    unless ($others) {
        $log->warn("ListenLater: update $field for id $id could not check cross-source identity: $@");
        return $id;
    }

    my $write = sub {
        my $rv = eval {
            $h->do("UPDATE albums SET $field = ?, dedupe_key = ? WHERE id = ?",
                undef, $value, $key, $id)
        };
        if ($@ || !defined $rv || $rv eq '0E0') {
            $log->warn("ListenLater: update $field for id $id failed: "
                . ($@ || 'row was no longer present'));
        }
        return $id;
    };

    return $write->() unless @$others;

    my @group = (\%next, @$others);
    my %status = map { ($_->{status} // '') => 1 } @group;
    if (keys %status > 1) {
        # Refuse the MERGE, not the WRITE — the same asymmetry the refold's collision policy
        # spells out. dedupe_key is UNIQUE per SERVICE, so unless one of those differently-
        # statused rows sits on THIS row's own source, the resolved value and its recomputed
        # key still land and the ambiguous pair simply stays two rows. Dropping the value
        # instead is not a neutral 'leave it alone': a streaming row that never takes its
        # backfilled artist keys as 'artist-less' for ever, so Played's artist|album lookup
        # can never match it and it can never auto-move — the exact invisibility this carrier
        # exists to close. Only a same-source holder of the new key blocks the write, because
        # then the two rows really cannot both have it.
        my $blocked = grep { ($_->{source} // '') eq ($rec->{source} // '') } @$others;
        $log->warn("ListenLater: update $field for id $id will not merge rows with different "
            . 'statuses (' . join(', ', map { "id $_->{id} [" . ($_->{status} // '?') . ']' } @group)
            . ') — ' . ($blocked ? 'left unchanged' : 'settled within each list')
            . ', merge by hand if you want them as one');
        return $id if $blocked;

        # THE CONFLICT IS PER LIST, NOT PER GROUP. A dissenting row on another list bars the
        # merge WITH IT — it does not make this row's own-list twin stop being a duplicate.
        # Narrow the group to the rows sharing this row's status and settle those; the other
        # lists keep their rows and their keys untouched. Without this the pair stays visible
        # for good, because rung 7 has already stamped and nothing revisits a live backfill.
        my @sameList = grep { ($_->{status} // '') eq ($rec->{status} // '') } @$others;
        return $write->() unless @sameList;
        @group = (\%next, @sameList);
    }

    my $settled = _mergeKeyRows($h, \@group, $key);
    unless ($settled->{ok}) {
        $log->warn("ListenLater: update $field for id $id could not reconcile its duplicate: "
            . $settled->{error});
        return $id;
    }
    # Publish the lineage only after _mergeKeyRows has committed. Every pending carrier of a
    # deleted member can now reach the survivor; failed/rolled-back merges publish nothing.
    for my $member (@group) {
        next unless $member->{id} && $member->{id} != $settled->{id};
        $identityCanonical{$member->{id}} = $settled->{id};
    }
    $log->warn("ListenLater: update $field for id $id merged " . $settled->{merged}
        . " cross-source duplicate(s) into id $settled->{id}");
    return $settled->{id};
}

# Backfill the artist on an existing row (and recompute its dedupe_key, which now includes
# the artist — so Played's artist|album lookup and future dedupe both work). Used when a
# service supplies no artist at add time (Tidal) and it's fetched from the album afterwards.
# Won't clobber an existing artist. Returns the surviving id; a backfill can reveal that this
# row and a row saved from another service are the same logical release.
sub updateArtist {
    my ($id, $artist) = @_;
    return unless $id && defined $artist && length $artist;
    $id = canonicalId($id) or return;
    my $rec = get($id) or return;
    return $id if defined $rec->{artist} && length $rec->{artist}; # don't overwrite a real artist
    return _updateIdentityField($id, 'artist', $artist);
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
    $id = canonicalId($id) or return;
    my $rec = get($id) or return;
    return $id if $rec->{year};                                  # don't overwrite a real year
    return _updateIdentityField($id, 'year', $year);
}

# Persist a resolved value into the row's ref_json (e.g. a Bandcamp purchase URL
# discovered on first open), so later lookups are instant. Merges into existing ref.
sub setRefValue {
    my ($id, $key, $value, $expectedSource, $expectedRefId) = @_;
    return unless $id && defined $key;
    $id = _sameSourceCanonicalId($id, $expectedSource, $expectedRefId) or return;
    my $rec = get($id) or return;
    my $ref = (ref $rec->{ref} eq 'HASH') ? $rec->{ref} : {};
    $ref->{$key} = $value;
    dbh()->do('UPDATE albums SET ref_json = ? WHERE id = ?', undef, $JSON->encode($ref), $id);
    return $id;
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
    my ($id, $count, $expectedSource, $expectedRefId) = @_;
    my $n = _sane($count) or return;
    return unless $id;
    $id = _sameSourceCanonicalId($id, $expectedSource, $expectedRefId) or return;
    eval { dbh()->do('UPDATE albums SET track_count = ? WHERE id = ?', undef, $n, $id); 1 }
        or $log->warn("Listen Later: updateTrackCount($id) failed: $@");
    return $id;
}

sub updateRelType {
    my ($id, $relType, $force, $expectedSource, $expectedRefId) = @_;
    return unless $id && defined $relType && $relType =~ /^(?:album|ep|single)$/;
    $id = _sameSourceCanonicalId($id, $expectedSource, $expectedRefId) or return;
    my $sql = "UPDATE albums SET rel_type = ? WHERE id = ?"
        . ($force ? '' : ' AND rel_type IS NULL');
    eval { dbh()->do($sql, undef, $relType, $id); 1 }
        or $log->warn("Listen Later: updateRelType($id) failed: $@");
    return $id;
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
        # Same extractor the async-write guards compare on (_sameSourceCanonicalId), so a
        # reverse lookup and a guard can never disagree about which release a row replays.
        my $aid = refAlbumId($h);
        return $h if length $aid && $aid eq "$albumId";
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
    $id = canonicalId($id) or return;
    dbh()->do('DELETE FROM albums WHERE id = ?', undef, $id);
    return;
}

sub setStatus {
    my ($id, $status) = @_;
    $id = canonicalId($id) or return;
    my $played_at = $status eq 'played' ? time() : undef;
    dbh()->do('UPDATE albums SET status = ?, played_at = COALESCE(?, played_at) WHERE id = ?',
        undef, $status, $played_at, $id);
    return;
}

sub markPlayed {
    my ($id) = @_;
    $id = canonicalId($id) or return;
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
