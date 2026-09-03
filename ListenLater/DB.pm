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
    dedupe_key  TEXT    NOT NULL,                     -- normalised artist|album|year (+ '|t:<track>' for a track, '|p:<svc>:<id>' for a playlist)
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
    # LAST in the ladder on purpose: it reads every row and recomputes its key, so it
    # must run AFTER the migrations that change what a key is built from (0.1.43's year
    # segment, 0.1.71's artist-prefix cleanup), or it would faithfully rekey rows that
    # those passes are about to rewrite again.
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
            $log->warn('Listen Later: dedupe-key refold did not complete (see the warnings '
                . "above) — schema left at version $schemaVer so it is retried at the next "
                . 'start');
        }
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
# One-off REKEY for the 0.1.112 fleet matcher sync. `DB::_norm` gained Latin folding
# and apostrophe elision, and it builds `dedupe_key` — a UNIQUE column on every row —
# so every stored key computed under the old fold is now wrong. A key nothing
# recomputes the same way is invisible: add() would stop deduping against it and
# Played's lookups would stop finding it. This is the migration the fold change owes.
#
# THE NEW FOLD MERGES KEYS THAT WERE DISTINCT, which is the point ("Jane's Addiction"
# and "Janes Addiction" are one album) and also the whole difficulty — UNIQUE(source,
# dedupe_key) has to be satisfied while collapsing them. Rows are therefore GROUPED by
# their new (source, key) and each group settled as a unit, rather than updated one at
# a time and catching the constraint error: a per-row loop also collides transiently
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
#   • MIXED STATUS (one 'later', one 'played', one in the Wish List) -> LEFT ALONE, on
#     their OLD keys, with a WARN naming the ids. Collapsing would have to silently
#     pick a list for the user: marking a Wish List item played, or resurrecting
#     something they had finished with. An old key on a genuinely ambiguous pair costs
#     one un-deduped row — visible, harmless, and reversible by hand — where guessing
#     costs a list entry that vanishes without explanation. NOTHING IS EVER DELETED
#     without a same-status twin to merge into.
#
# Idempotent: a second run recomputes the same keys, finds them already stored, and
# changes nothing. Gated once on PRAGMA user_version regardless.
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
        my $new;
        if (($r->{kind} || '') eq 'playlist' && $r->{dedupe_key} =~ /(\|p:.*)$/s) {
            $new = '' . '|' . _norm($r->{album_title}) . '|' . '' . $1;
        }
        elsif (($r->{kind} || '') eq 'track' && length($r->{track_title} // '')) {
            $new = dedupeKey($r->{artist}, $r->{album_title}, $r->{year}, $r->{track_title});
        }
        else {
            $new = dedupeKey($r->{artist}, $r->{album_title}, $r->{year});
        }
        $r->{_new} = $new;
        push @{ $group{ ($r->{source} // '') . "\0" . $new } }, $r;
    }

    my ($rekeyed, $merged, $skipped, $failed) = (0, 0, 0, 0);
    for my $g (values %group) {
        # Untouched by the fold: nothing to do, and no group to settle.
        next if @$g == 1 && $g->[0]{dedupe_key} eq $g->[0]{_new};

        if (@$g > 1) {
            my %status = map { ($_->{status} // '') => 1 } @$g;
            if (keys %status > 1) {
                $skipped += @$g;
                $log->warn("Listen Later: refold would merge rows with different statuses ("
                    . join(', ', map { "id $_->{id} [" . ($_->{status} // '?') . "]" } @$g)
                    . ") — left on their old keys, merge by hand if you want them as one");
                next;
            }
        }

        # Earliest save wins; added_at can be NULL on a very old row, so sort those last
        # rather than letting undef order arbitrarily.
        my @sorted = sort { ($a->{added_at} // 9**15) <=> ($b->{added_at} // 9**15)
                         || $a->{id} <=> $b->{id} } @$g;
        my $keep = shift @sorted;

        for my $lose (@sorted) {
            $keep->{play_count} = ($lose->{play_count} // 0) > ($keep->{play_count} // 0)
                                ? $lose->{play_count} : $keep->{play_count};
            $keep->{played_at}  = $lose->{played_at}
                if !defined $keep->{played_at}
                || (defined $lose->{played_at} && $lose->{played_at} > $keep->{played_at});
            for my $f (qw(track_count rel_type artwork year)) {
                $keep->{$f} = $lose->{$f} if !defined $keep->{$f} && defined $lose->{$f};
            }
            # A ref is what makes a row REPLAYABLE, so a row that has one beats a row
            # that does not — taken as a pair, since ref_kind describes ref_json.
            if (!length($keep->{ref_kind} // '') && length($lose->{ref_kind} // '')) {
                @{$keep}{qw(ref_kind ref_json)} = @{$lose}{qw(ref_kind ref_json)};
            }
        }

        # ONE TRANSACTION PER GROUP — the merge is all-or-nothing.
        #
        # The deletes MUST land before the survivor's UPDATE, or the new key collides with a
        # row that is about to be removed. The handle is AutoCommit, so without a transaction
        # that ordering is a trap: a failed UPDATE leaves the losers already COMMITTED AWAY
        # and the survivor still on its stale key — a saved album and its play history gone,
        # silently, with nothing left to retry from. The rekey CAN fail: a MIXED-STATUS group
        # (skipped just above, left on its OLD keys) can hold the very key this survivor is
        # moving to, and UNIQUE(source, dedupe_key) then refuses the UPDATE. No SERVICE-
        # supplied pair of titles reaches that state (Review Ledger A2 works through why, and
        # it has been raised twice) — so this transaction is a guard, not a hot path. Keep it
        # anyway: it costs one begin_work per changed group, and the alternative is silent,
        # permanent data loss on a path with no retry.
        #
        # Rolled back, the group is exactly as it was — on the old keys, which is what
        # $skipped already means for the mixed-status case and what the ladder's unstamped
        # version (see _migrate) gets to retry.
        #
        # begin_work is guarded: it dies on a handle already inside a transaction, and one
        # group is not worth taking the whole ladder down for. Failing that, do the same work
        # unwrapped — no worse than what this replaces — and say so in the warn, because then
        # the failure really can be partial.
        my $txn = eval { $h->begin_work; 1 } ? 1 : 0;

        my $err;
        for my $lose (@sorted) {
            next if eval { $h->do('DELETE FROM albums WHERE id = ?', undef, $lose->{id}); 1 };
            $err = "could not delete id $lose->{id}: $@";
            last;
        }
        if (!defined $err) {
            eval {
                $h->do('UPDATE albums SET dedupe_key = ?, played_at = ?, play_count = ?,
                                          track_count = ?, rel_type = ?, artwork = ?, year = ?,
                                          ref_kind = ?, ref_json = ?
                         WHERE id = ?',
                    undef, $keep->{_new}, $keep->{played_at}, $keep->{play_count} // 0,
                    $keep->{track_count}, $keep->{rel_type}, $keep->{artwork}, $keep->{year},
                    $keep->{ref_kind}, $keep->{ref_json}, $keep->{id});
                1;
            } or $err = "could not rekey id $keep->{id}: $@";
        }

        # A commit that fails leaves nothing applied, so it is the same outcome as any other
        # failure in the group and is reported as one.
        if (!defined $err && $txn) {
            eval { $h->commit; 1 } or $err = "could not commit the merge of id $keep->{id}: $@";
        }

        if (defined $err) {
            if ($txn && !eval { $h->rollback; 1 }) {
                # begin_work turned AutoCommit OFF, and ONLY a completed commit or rollback
                # turns it back on. A rollback that RAISED leaves it off on a handle this sub
                # does not own and does not close, and the damage runs far past the migration:
                # every later begin_work dies "Already in a transaction" so the remaining groups
                # run unwrapped, and every plugin write for the REST OF THE SERVER RUN joins a
                # transaction nothing ever commits — DBI discards it at handle destruction, so
                # saves and play counts vanish silently at shutdown with nothing in the log.
                # Restore it by hand, and ABANDON: the transactional state is the very thing we
                # just failed to settle, so there is nothing safe for the rest of the loop to run
                # against. $failed withholds the version stamp, so the whole pass is retried at
                # the next start — which is what the untouched groups need anyway.
                $log->error("Listen Later: refold rollback failed: $@");
                # Undo the group by hand FIRST, and by raw SQL since it is ->rollback that just
                # failed. Order is not cosmetic: assigning AutoCommit = 1 while a transaction is
                # still open COMMITS it, which would turn "the rollback failed" into "the
                # half-applied group is now permanent" — the losers deleted for good and the
                # survivor left on its stale key, precisely the loss the transaction exists to
                # prevent. If this fails too there is nothing left to try: SQLite has almost
                # certainly rolled back on its own already (it does that on a full disk or an I/O
                # error, which is also the likeliest reason ->rollback raised), and that is the
                # outcome we wanted anyway.
                eval { $h->do('ROLLBACK'); 1 }
                    or $log->error("Listen Later: refold could not roll back by hand either "
                        . "(SQLite has most likely done it already): $@");
                eval { $h->{AutoCommit} = 1; 1 }
                    or $log->error("Listen Later: refold could not restore AutoCommit: $@");
                $skipped += @$g;
                $failed++;
                $log->warn("Listen Later: refold $err — and the rollback failed too, so the "
                    . 'migration is abandoned here rather than run on a handle whose '
                    . 'transaction state is unknown; the whole pass is retried at the next start');
                last;
            }
            $skipped += @$g;
            $failed++;
            $log->warn("Listen Later: refold $err — "
                . ($txn ? 'the whole group is left on its old key(s), untouched'
                        : 'NO transaction was available, so this group may be half-applied')
                . '; it is retried at the next start');
            next;
        }

        $merged  += scalar @sorted;
        $rekeyed++;
    }

    $log->info("Listen Later: dedupe-key refold — $rekeyed row(s) rekeyed, "
             . "$merged duplicate(s) merged, $skipped left on the old key")
        if $rekeyed || $merged || $skipped;

    # A group that FAILED withholds the version stamp, so the next start tries it again —
    # the likeliest causes (the db locked by another process, a full disk) are transient, and
    # a rolled-back group is in exactly the state a retry wants. A MIXED-STATUS skip does not:
    # that is a deliberate policy decision, not an error, and re-running could never change it
    # — it would just re-log the same warn at every boot for ever.
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
sub _norm {
    my $s = foldLatin($_[0]);
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
    my $key    = ($kind eq 'track')
        ? dedupeKey($rec->{artist}, $rec->{album_title}, $rec->{year}, $rec->{track_title})
      : ($kind eq 'playlist')
        ? playlistKey($source, ($rec->{ref} || {})->{playlist_id}, $rec->{album_title})
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
