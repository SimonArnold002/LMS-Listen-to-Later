#!/usr/bin/env perl
# Regression tests for DB.pm against a REAL SQLite database in a temp dir: schema
# migration of an old file, dedupe-key behaviour, and the column writers.
#
# Each block names the release whose decision it protects, so a failure says which
# documented behaviour just broke rather than only which line did. The dedupe rules in
# particular are easy to break from a distance — they are the difference between an
# accidental double-tap being harmless and a saved album being silently refused.
use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
require "$FindBin::Bin/t_stubs.pl";

my $dir = tempdir(CLEANUP => 1);
Slim::Utils::Prefs::set_test_pref('cachedir', $dir);

ll_require('DB');

my ($pass, $fail) = (0, 0);
sub is {
    my ($desc, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && "$got" eq "$want");
    $ok ? $pass++ : $fail++;
    printf "%s %-56s got=%-10s want=%s\n", ($ok ? 'ok  ' : 'FAIL'), $desc,
        (defined $got ? "'$got'" : '(undef)'), (defined $want ? "'$want'" : '(undef)');
}
sub section { printf "\n== %s\n", $_[0] }

my $rec = sub {
    my (%o) = @_;
    return {
        source      => $o{source} // 'qobuz',
        kind        => $o{kind},
        artist      => $o{artist} // 'Chanel Beads',
        album_title => $o{album}  // 'Your Day Will Come',
        track_title => $o{track},
        year        => $o{year},
        rel_type    => $o{rel},
        track_count => $o{count},
        ref_kind    => 'search',
        ref         => {},
    };
};

# ---------------------------------------------------------------------------
section('0.1.43 — same title, different year: both saveable');
# The dedupe key carries the year precisely so two identically-titled releases from
# different years don't block each other. Break this and the second one vanishes with
# no error.
my ($id2024) = Plugins::ListenLater::DB::add($rec->(year => 2024));
my ($id2026, $already2026) = Plugins::ListenLater::DB::add($rec->(year => 2026));
is('2024 edition saved',                   ($id2024 ? 'yes' : 'no'), 'yes');
is('2026 edition saved as its own row',    ($id2026 && $id2026 != $id2024 ? 'yes' : 'no'), 'yes');
is('...and is NOT reported as duplicate',  ($already2026 // 0), 0);
my (undef, $againAlready) = Plugins::ListenLater::DB::add($rec->(year => 2026));
is('re-adding the same one IS a no-op',    $againAlready, 1);

# ---------------------------------------------------------------------------
section('0.1.33 — a duplicate is found across sources, not just within one');
my (undef, $xAlready, $xSource) = Plugins::ListenLater::DB::add($rec->(source => 'tidal', year => 2026));
is('same album from another service dedupes', $xAlready, 1);
is('...and reports where it was first saved', $xSource, 'qobuz');

# ---------------------------------------------------------------------------
section('0.1.74+ — a track and its parent album never collide');
# A track key gains a 4th '|t:<title>' segment. Without it, saving a track called X
# from album X would collide with the album itself.
my ($tId) = Plugins::ListenLater::DB::add($rec->(kind => 'track', album => 'Your Day Will Come',
                            track => 'Your Day Will Come', year => 2026));
is('track saved alongside its album',      ($tId && $tId != $id2026 ? 'yes' : 'no'), 'yes');
is('album key has 3 segments',   scalar(split /\|/, Plugins::ListenLater::DB::dedupeKey('A','B',2026)), 3);
is('track key has 4 segments',   scalar(split /\|/, Plugins::ListenLater::DB::dedupeKey('A','B',2026,'T')), 4);

# ---------------------------------------------------------------------------
section('0.1.81 — the same track from two surfaces is one row');
# A queue/Now-Playing add carries the parent album name; a streaming browse add sends
# none. The year-and-album-agnostic lookup is what reconciles them.
my ($qId) = Plugins::ListenLater::DB::add($rec->(kind => 'track', artist => 'Runner', album => 'Real Album',
                            track => 'Shared Song', year => 2026));
my $found = Plugins::ListenLater::DB::findTrackByArtistTitle('qobuz', 'Runner', 'Shared Song');
is('found with the album segment wild',    ($found && $found->{id} == $qId ? 'yes' : 'no'), 'yes');
is('a different track is not matched',     (Plugins::ListenLater::DB::findTrackByArtistTitle('qobuz','Runner','Other') ? 'yes':'no'), 'no');
is('another artist is not matched',        (Plugins::ListenLater::DB::findTrackByArtistTitle('qobuz','Someone','Shared Song') ? 'yes':'no'), 'no');

# ---------------------------------------------------------------------------
section('0.1.43 — Played looks up year-agnostically');
# A playing streaming track can't be trusted to report the year, so Played matches on
# the artist|album prefix. It must still find a row saved WITH a year.
my $byAA = Plugins::ListenLater::DB::findByArtistAlbum('qobuz', 'Chanel Beads', 'Your Day Will Come');
is('artist+album finds a year-bearing row', ($byAA ? 'yes' : 'no'), 'yes');
is('...preferring the lower id',            ($byAA ? $byAA->{id} : '-'), $id2024);

# ---------------------------------------------------------------------------
section('0.1.88 — track_count is stored, and only when it is real');
my ($cId) = Plugins::ListenLater::DB::add($rec->(artist => 'Counted', album => 'Nine', year => 2026, count => 9));
is('a real count persists',                 Plugins::ListenLater::DB::get($cId)->{track_count}, 9);
my ($zId) = Plugins::ListenLater::DB::add($rec->(artist => 'Counted', album => 'Zero', year => 2026, count => 0));
is('a count of 0 is stored as unknown',     Plugins::ListenLater::DB::get($zId)->{track_count}, undef);
my ($nId) = Plugins::ListenLater::DB::add($rec->(artist => 'Counted', album => 'None', year => 2026));
is('no count stays unknown',                Plugins::ListenLater::DB::get($nId)->{track_count}, undef);
Plugins::ListenLater::DB::updateTrackCount($nId, 4);
is('updateTrackCount fills it',             Plugins::ListenLater::DB::get($nId)->{track_count}, 4);
Plugins::ListenLater::DB::updateTrackCount($nId, 6);
is('...and OVERWRITES (it is a re-measure)', Plugins::ListenLater::DB::get($nId)->{track_count}, 6);
Plugins::ListenLater::DB::updateTrackCount($nId, 0);
is('...but junk cannot wipe it',            Plugins::ListenLater::DB::get($nId)->{track_count}, 6);

# ---------------------------------------------------------------------------
section('0.1.88 — rel_type is filled once, and only forced deliberately');
my ($rId) = Plugins::ListenLater::DB::add($rec->(artist => 'Typed', album => 'Claimed', year => 2026, rel => 'single'));
Plugins::ListenLater::DB::updateRelType($rId, 'album');
is('an existing type is NOT overwritten',   Plugins::ListenLater::DB::get($rId)->{rel_type}, 'single');
Plugins::ListenLater::DB::updateRelType($rId, 'ep', 1);
is('...unless forced (the single fix)',     Plugins::ListenLater::DB::get($rId)->{rel_type}, 'ep');
my ($uId) = Plugins::ListenLater::DB::add($rec->(artist => 'Typed', album => 'Unknown', year => 2026));
Plugins::ListenLater::DB::updateRelType($uId, 'ep');
is('an unset type is filled unforced',      Plugins::ListenLater::DB::get($uId)->{rel_type}, 'ep');
Plugins::ListenLater::DB::updateRelType($uId, 'nonsense', 1);
is('an invalid type is rejected',           Plugins::ListenLater::DB::get($uId)->{rel_type}, 'ep');

# ---------------------------------------------------------------------------
section('updateYear — fill a MISSING year and re-key the row');
# A streaming browse row usually carries no year, and the year is part of the dedupe key, so
# a yearless row keys as 'artist|album|' — the SAME album added later from a source that does
# supply the year keys differently and lands as a second row nothing can dedupe. Backfilled
# from the service's own album object once we've fetched it for other reasons.
{
    my ($id) = Plugins::ListenLater::DB::add($rec->(artist=>'Kelela', album=>'new avatar'), 'later');
    my $before = Plugins::ListenLater::DB::get($id);
    is('starts with no year',            $before->{year}, undef);
    is('...and a yearless key',          $before->{dedupe_key}, 'kelela|new avatar|');

    Plugins::ListenLater::DB::updateYear($id, 2026);
    my $after = Plugins::ListenLater::DB::get($id);
    is('the year is filled in',          $after->{year}, 2026);
    is('...and the key is recomputed',   $after->{dedupe_key}, 'kelela|new avatar|2026');

    # So the same album arriving WITH a year now dedupes against it instead of doubling up.
    my (undef, $already) = Plugins::ListenLater::DB::add(
        $rec->(artist=>'Kelela', album=>'new avatar', year=>2026), 'later');
    is('a later add with the year dedupes', ($already ? 'deduped' : 'DOUBLED'), 'deduped');

    # A year we already hold came from the add, closer to the user's own view of the release,
    # and a service date can differ (reissue vs original) — so it is never overwritten.
    my ($id2) = Plugins::ListenLater::DB::add(
        $rec->(artist=>'Band', album=>'Reissued', year=>1971), 'later');
    Plugins::ListenLater::DB::updateYear($id2, 2026);
    is('an existing year is NOT overwritten',
       Plugins::ListenLater::DB::get($id2)->{year}, 1971);

    # Junk must not reach the column or the key.
    my ($id3) = Plugins::ListenLater::DB::add($rec->(artist=>'X', album=>'Y'), 'later');
    Plugins::ListenLater::DB::updateYear($id3, $_) for ('', 'abc', '20', '12345', 0, '1899');
    is('junk years are refused',         Plugins::ListenLater::DB::get($id3)->{year}, undef);
    is('...leaving the key alone',       Plugins::ListenLater::DB::get($id3)->{dedupe_key}, 'x|y|');
}

# ---------------------------------------------------------------------------
section('migration — an old database file upgrades without losing rows');
# Rebuilt from scratch each run: a pre-0.1.74 schema (no kind/track_title/rel_type/
# track_count, user_version 0) with a row in it, exactly what an upgrading user has.
require DBI;
my $legacy = "$dir/legacy.db";
my $h = DBI->connect("dbi:SQLite:dbname=$legacy", '', '', { RaiseError => 1, PrintError => 0 });
$h->do(q{CREATE TABLE albums (
    id INTEGER PRIMARY KEY AUTOINCREMENT, status TEXT NOT NULL DEFAULT 'later',
    source TEXT NOT NULL, artist TEXT, album_title TEXT, year INTEGER, artwork TEXT,
    ref_kind TEXT, ref_json TEXT, dedupe_key TEXT NOT NULL, added_at INTEGER,
    played_at INTEGER, play_count INTEGER NOT NULL DEFAULT 0, UNIQUE(source, dedupe_key))});
# One row with a pre-0.1.43 TWO-segment key, to exercise that migration too.
$h->do("INSERT INTO albums (status,source,artist,album_title,year,dedupe_key,added_at)
        VALUES ('later','qobuz','Temples','Sun Structures',2014,'temples|sun structures',0)");
Plugins::ListenLater::DB::_migrate($h);

my %col = map { $_->{name} => 1 }
          @{ $h->selectall_arrayref('PRAGMA table_info(albums)', { Slice => {} }) };
is('kind column added',        ($col{kind}        ? 'yes':'no'), 'yes');
is('track_title column added', ($col{track_title} ? 'yes':'no'), 'yes');
is('rel_type column added',    ($col{rel_type}    ? 'yes':'no'), 'yes');
is('track_count column added', ($col{track_count} ? 'yes':'no'), 'yes');
is('user_version stamped',     ($h->selectrow_array('PRAGMA user_version'))[0], 4);

# user_version 4: every streaming count stored before it was produced by counting the
# resolved item list with a deny-list filter, which let a service's non-track rows through —
# Qobuz sends 5-6 with every album, so a 1-track release was recorded as 6 and an 11-track
# album as 17. A wrong count can never heal itself (Played only measures a length it does NOT
# have), so they are cleared and re-measured on the next play. Library rows never stored one.
{
    my $g = DBI->connect("dbi:SQLite:dbname=$dir/poisoned.db", '', '', { RaiseError => 1, PrintError => 0 });
    $g->do(q{CREATE TABLE albums (
        id INTEGER PRIMARY KEY AUTOINCREMENT, status TEXT NOT NULL DEFAULT 'later',
        source TEXT NOT NULL, artist TEXT, album_title TEXT, year INTEGER, artwork TEXT,
        ref_kind TEXT, ref_json TEXT, dedupe_key TEXT NOT NULL, added_at INTEGER,
        played_at INTEGER, play_count INTEGER NOT NULL DEFAULT 0,
        kind TEXT NOT NULL DEFAULT 'album', track_title TEXT, rel_type TEXT,
        track_count INTEGER, UNIQUE(source, dedupe_key))});
    $g->do('PRAGMA user_version = 3');
    $g->do("INSERT INTO albums (source,artist,album_title,dedupe_key,track_count,rel_type)
            VALUES ('qobuz','adieu','Wanna me','adieu|wanna me|2026',6,'ep')");
    $g->do("INSERT INTO albums (source,artist,album_title,dedupe_key,track_count)
            VALUES ('bandcamp','Cola','Cost Of Living','cola|cost of living|2026',17)");
    $g->do("INSERT INTO albums (source,artist,album_title,dedupe_key,track_count)
            VALUES ('library','Local','Album','local|album|2020',9)");
    Plugins::ListenLater::DB::_migrate($g);
    my $rows = $g->selectall_hashref('SELECT * FROM albums', 'source');
    is('the inflated qobuz count is cleared',    $rows->{qobuz}{track_count}, undef);
    is('...and bandcamp too',                    $rows->{bandcamp}{track_count}, undef);
    is('...but a library count is untouched',    $rows->{library}{track_count}, 9);
    is('the label is NOT touched (display only)',$rows->{qobuz}{rel_type}, 'ep');
    is('...and stamped so it runs once',         ($g->selectrow_array('PRAGMA user_version'))[0], 4);
}

my $kept = $h->selectrow_hashref('SELECT * FROM albums WHERE id = 1');
is('the existing row survives',            $kept->{album_title}, 'Sun Structures');
is('its kind defaults to album',           $kept->{kind}, 'album');
is('its count is unknown, not 0',          $kept->{track_count}, undef);
is('0.1.43 — its key gained the year',     $kept->{dedupe_key}, 'temples|sun structures|2014');
is('re-running the migration is safe',
   (eval { Plugins::ListenLater::DB::_migrate($h); 1 } ? 'ok' : "died: $@"), 'ok');
is('...and does not re-append the year',   $h->selectrow_hashref('SELECT * FROM albums WHERE id = 1')->{dedupe_key},
                                           'temples|sun structures|2014');
$h->disconnect;

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
