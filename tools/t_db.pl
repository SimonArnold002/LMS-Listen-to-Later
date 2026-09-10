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
Slim::Utils::Prefs::set_test_pref_ns('server', 'cachedir', $dir);

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
section('playlist rows are stored as a third kind, with a source-qualified key');
my ($pId) = Plugins::ListenLater::DB::add({
    source      => 'qobuz',
    kind        => 'playlist',
    artist      => '',
    album_title => 'Hi-Res Masters: 2016 / Qobuz UK',
    year        => 2026,
    artwork     => 'https://static.qobuz.com/images/playlists/69183531_x_rectangle.jpg',
    ref_kind    => 'playlist_id',
    ref         => { _svc => 'qobuz', playlist_id => '69183531' },
}, 'later');
is('playlist row saves as kind=playlist', Plugins::ListenLater::DB::get($pId)->{kind}, 'playlist');
is('playlist row keeps playlist_id ref', Plugins::ListenLater::DB::get($pId)->{ref}{playlist_id}, '69183531');
is('playlist key includes source + playlist id', Plugins::ListenLater::DB::get($pId)->{dedupe_key}, '|hi res masters 2016 qobuz uk||p:qobuz:69183531');
# list() is kind-agnostic — the playlist row is a first-class member of the list.
is('playlist row is visible in list()',
   (scalar grep { $_->{id} == $pId } @{ Plugins::ListenLater::DB::list('later','added') }), 1);

# ...but INVISIBLE to every release/track finder, which is what keeps Played and the
# cross-kind dedupe from ever touching it. findByAlbum matters most: its LIKE is
# '%|<album>|%', which the playlist key's own title segment would otherwise match — the
# kind='album' filter is the only thing stopping it.
is('...not returned by findByAlbum',
   (scalar Plugins::ListenLater::DB::findByAlbum('qobuz', 'Hi-Res Masters: 2016 / Qobuz UK')), 0);
is('...not returned by findByArtistAlbum',
   (Plugins::ListenLater::DB::findByArtistAlbum('qobuz', '', 'Hi-Res Masters: 2016 / Qobuz UK') ? 'yes' : 'no'), 'no');
is('...not returned by findBySourceRefTitle',
   (scalar Plugins::ListenLater::DB::findBySourceRefTitle('qobuz', 'Hi-Res Masters: 2016 / Qobuz UK')), 0);
is('...not returned by findSavedTrack',
   (Plugins::ListenLater::DB::findSavedTrack('qobuz', '', 'Hi-Res Masters: 2016 / Qobuz UK', '') ? 'yes' : 'no'), 'no');
is('...not returned by findTrackByArtistTitle',
   (Plugins::ListenLater::DB::findTrackByArtistTitle('qobuz', '', 'Hi-Res Masters: 2016 / Qobuz UK') ? 'yes' : 'no'), 'no');
# The one finder with NO kind filter: it keys on ref.album_id, which a playlist ref must
# never carry (see Plugin::_savePlaylistRecord).
is('...not returned by findBySourceAlbumId on its playlist id',
   (Plugins::ListenLater::DB::findBySourceAlbumId('qobuz', '69183531') ? 'yes' : 'no'), 'no');

# Same playlist id on two DIFFERENT services = two rows. findAnyByKey is cross-source, so
# this is the case the key's embedded source segment exists for.
my ($dId) = Plugins::ListenLater::DB::add({
    source => 'deezer', kind => 'playlist', artist => '',
    album_title => 'Hi-Res Masters: 2016 / Qobuz UK',
    ref_kind => 'playlist_id', ref => { _svc => 'deezer', playlist_id => '69183531' },
}, 'later');
is('the same playlist id on another service is a separate row',
   (($dId && $dId != $pId) ? 'separate' : 'collided'), 'separate');
is('...keyed under its own source',
   Plugins::ListenLater::DB::get($dId)->{dedupe_key}, '|hi res masters 2016 qobuz uk||p:deezer:69183531');

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
# The oldest SQL key carrier appends the year before the Perl migration ladder. A second
# service can therefore converge on the same completed key; the later refold/repair rungs
# must reconcile it just like every current-format writer.
$h->do("INSERT INTO albums (status,source,artist,album_title,year,dedupe_key,added_at)
        VALUES ('later','tidal','Temples','Sun Structures',2014,'temples|sun structures',10)");
Plugins::ListenLater::DB::_migrate($h);

my %col = map { $_->{name} => 1 }
          @{ $h->selectall_arrayref('PRAGMA table_info(albums)', { Slice => {} }) };
is('kind column added',        ($col{kind}        ? 'yes':'no'), 'yes');
is('track_title column added', ($col{track_title} ? 'yes':'no'), 'yes');
is('rel_type column added',    ($col{rel_type}    ? 'yes':'no'), 'yes');
is('track_count column added', ($col{track_count} ? 'yes':'no'), 'yes');
is('user_version stamped',     ($h->selectrow_array('PRAGMA user_version'))[0], 8);
is('the legacy year-append carrier is reconciled cross-source',
   scalar @{ $h->selectall_arrayref('SELECT id FROM albums') }, 1);

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
    is('...and stamped so it runs once',         ($g->selectrow_array('PRAGMA user_version'))[0], 8);
}

# _migrateArtistPrefix is the fifth key writer, but it runs before the columns required by
# _migrateRefold exist. The ladder order is its reconciliation carrier: clean first, then the
# final refold sees and merges a cross-source key the cleanup made equal.
{
    my $g = DBI->connect("dbi:SQLite:dbname=$dir/prefix-cross-source.db", '', '',
        { RaiseError => 1, PrintError => 0 });
    $g->do(q{CREATE TABLE albums (
        id INTEGER PRIMARY KEY AUTOINCREMENT, status TEXT NOT NULL DEFAULT 'later',
        source TEXT NOT NULL, artist TEXT, album_title TEXT, year INTEGER, artwork TEXT,
        ref_kind TEXT, ref_json TEXT, dedupe_key TEXT NOT NULL, added_at INTEGER,
        played_at INTEGER, play_count INTEGER NOT NULL DEFAULT 0, UNIQUE(source, dedupe_key))});
    $g->do("INSERT INTO albums (source,artist,album_title,year,dedupe_key,added_at)
            VALUES ('qobuz','Carrier Band','Carrier Band - Carrier Album',2024,
                    'carrier band|carrier band carrier album|2024',100)");
    $g->do("INSERT INTO albums (source,artist,album_title,year,dedupe_key,added_at)
            VALUES ('tidal','Carrier Band','Carrier Album',2024,
                    'carrier band|carrier album|2024',200)");
    Plugins::ListenLater::DB::_migrate($g);
    my $rows = $g->selectall_arrayref('SELECT * FROM albums', { Slice => {} });
    is('prefix cleanup and refold reconcile cross-source twins', scalar(@$rows), 1);
    is('...under the cleaned title', $rows->[0]{album_title}, 'Carrier Album');
    is('...and the current key', $rows->[0]{dedupe_key}, 'carrier band|carrier album|2024');
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

# ---------------------------------------------------------------------------
# ONE CARRIER FOR THE CURRENT KEY (_keyForRow). Five current-format writers used to answer
# "what key does this row have" — add(), updateArtist(), updateYear(), _migrateArtistPrefix()
# and _migrateRefold() —
# and two of them had drifted: updateArtist/updateYear rebuilt with dedupeKey($artist,$album,
# $year) and NO track segment, so calling either on a kind='track' row silently re-keyed it as
# an ALBUM. It could not fire when found (both callers sit behind _finishAlbumAdd, which only
# makes album rows) but the guard lived entirely in the caller, so any future caller inherited
# it. ANTI-TEST: point updateArtist/updateYear back at dedupeKey(...) with three args and the
# first four of these go red.
section('the dedupe key has one writer, and it respects kind');
{
    my $D = 'Plugins::ListenLater::DB';
    my $mk = sub { my ($id) = $D->can('add')->({ @_ }, 'later'); return $D->can('get')->($id); };

    # A TRACK row keeps its '|t:<title>' segment through both key-rewriting updaters.
    my $tr = $mk->(source=>'tidal', kind=>'track', artist=>undef, album_title=>'Album X',
                   track_title=>'Song Y', ref_kind=>'url', ref=>{url=>'tidal://9.flac'});
    $D->can('updateArtist')->($tr->{id}, 'Some Artist');
    is('updateArtist keeps a track row a TRACK key',
       $D->can('get')->($tr->{id})->{dedupe_key}, 'some artist|album x||t:song y');
    $D->can('updateYear')->($tr->{id}, 2024);
    is('...and so does updateYear',
       $D->can('get')->($tr->{id})->{dedupe_key}, 'some artist|album x|2024|t:song y');
    is('...so the row is still findable AS a track',
       ($D->can('findTrackByArtistTitle')->('tidal', 'Some Artist', 'Song Y') || {})->{id}, $tr->{id});

    # An EPISODE's id tail must survive a key rewrite — rebuilding it from `ref` would be a
    # second notion of the row's identity.
    my $ep = $mk->(source=>'spotify', kind=>'track', track_title=>'Trailer', ref_kind=>'url',
                   ref=>{url=>'spotify://episode:zz'}, episode=>1);
    $D->can('updateArtist')->($ep->{id}, 'Some Publisher');
    is('updateArtist leaves an episode id tail alone',
       $D->can('get')->($ep->{id})->{dedupe_key}, '|trailer||e:spotify:spotify://episode:zz');

    # ANTI-REGRESSION: the album path — the only one these two updaters could reach before —
    # must behave exactly as it always did.
    my $al = $mk->(source=>'tidal', kind=>'album', artist=>undef, album_title=>'Some Album',
                   year=>2020, ref=>{});
    $D->can('updateArtist')->($al->{id}, 'Real Artist');
    is('an ALBUM row is keyed exactly as before',
       $D->can('get')->($al->{id})->{dedupe_key}, 'real artist|some album|2020');
    my $pl = $mk->(source=>'tidal', kind=>'playlist', album_title=>'Dance Pop',
                   ref=>{playlist_id=>'p1'});
    is('...and a PLAYLIST key is untouched too', $pl->{dedupe_key}, '|dance pop||p:tidal:p1');
}

# ---------------------------------------------------------------------------
# add() is not the only way a row reaches a key: an artist/year can arrive later from an
# asynchronous service lookup. Those writers must enforce the same cross-source identity or
# the refold repairs the database once and a backfill recreates the duplicate afterwards.
section('live key backfills reconcile across sources too');
{
    my ($q) = Plugins::ListenLater::DB::add({
        source => 'qobuz', kind => 'album', artist => 'Kelela', album_title => 'Carrier Year',
        ref_kind => 'album_id', ref => { _svc => 'qobuz', album_id => 'qy' },
    }, 'later');
    my ($t, $already) = Plugins::ListenLater::DB::add({
        source => 'tidal', kind => 'album', artist => 'Kelela', album_title => 'Carrier Year',
        year => 2026, ref_kind => 'album_id',
        ref => { _svc => 'tidal', album_id => 'ty' },
    }, 'later');
    is('the differently-keyed Tidal row initially saves', $already, 0);
    my $canonical = Plugins::ListenLater::DB::updateYear($q, 2026);
    is('updateYear returns the earliest canonical id',     $canonical, $q);
    is('the converged cross-source rows become one',
       scalar @{ Plugins::ListenLater::DB::dbh()->selectall_arrayref(
           "SELECT id FROM albums WHERE album_title='Carrier Year'") }, 1);
    is('the canonical row keeps its source',               Plugins::ListenLater::DB::get($q)->{source}, 'qobuz');
    is('...and its matching replay ref',
       Plugins::ListenLater::DB::get($q)->{ref}{album_id}, 'qy');
    is('the later duplicate id is gone',
       (Plugins::ListenLater::DB::get($t) ? 'present' : 'gone'), 'gone');
}

{
    my ($t) = Plugins::ListenLater::DB::add({
        source => 'tidal', kind => 'album', artist => 'Carrier Artist',
        album_title => 'Backfill Carrier', year => 2025, ref_kind => 'album_id',
        ref => { _svc => 'tidal', album_id => 'ta' },
    }, 'later');
    my ($q) = Plugins::ListenLater::DB::add({
        source => 'qobuz', kind => 'album', artist => undef,
        album_title => 'Backfill Carrier', year => 2025, ref_kind => 'album_id',
        ref => { _svc => 'qobuz', album_id => 'qa' },
    }, 'later');
    my $canonical = Plugins::ListenLater::DB::updateArtist($q, 'Carrier Artist');
    is('updateArtist returns a different earlier winner',  $canonical, $t);
    is('the updating row is merged away',
       (Plugins::ListenLater::DB::get($q) ? 'present' : 'gone'), 'gone');
    is('the winner keeps its coherent source/ref bundle',
       join(':', Plugins::ListenLater::DB::get($t)->{source},
           Plugins::ListenLater::DB::get($t)->{ref}{album_id}), 'tidal:ta');
}

{
    my ($q) = Plugins::ListenLater::DB::add({
        source => 'qobuz', kind => 'album', artist => 'Status Band',
        album_title => 'Status Carrier', ref_kind => 'album_id', ref => { album_id => 'qs' },
    }, 'later');
    Plugins::ListenLater::DB::add({
        source => 'tidal', kind => 'album', artist => 'Status Band',
        album_title => 'Status Carrier', year => 2024, ref_kind => 'album_id',
        ref => { album_id => 'ts' },
    }, 'wishlist');
    Plugins::ListenLater::DB::updateYear($q, 2024);
    my $row = Plugins::ListenLater::DB::get($q);
    # The mixed status bars the MERGE. It does not bar the WRITE: the Wish List twin is on
    # another service and dedupe_key is UNIQUE per service, so both rows can hold the key.
    # Dropping the year instead would leave this row keyed 'artist|album|' for ever — a key
    # no later add() or Played lookup can converge on, which is worse than the un-merged pair
    # the policy is willing to accept.
    is('mixed-status backfill still records the year',    $row->{year}, 2024);
    is('...and rekeys with it',                           $row->{dedupe_key},
       'status band|status carrier|2024');
    is('...but never merges across the status',
       scalar @{ Plugins::ListenLater::DB::dbh()->selectall_arrayref(
           "SELECT id FROM albums WHERE album_title='Status Carrier'") }, 2);
    is('...leaving this row in its own list',             $row->{status}, 'later');
}

{
    # THE CONTROL: same mixed status, but the twin is on THIS row's OWN service, so the two
    # cannot both hold the recomputed key. Only here is the value dropped — and the pair in
    # the block above proves the refusal is about the constraint, not about the status.
    my ($q) = Plugins::ListenLater::DB::add({
        source => 'qobuz', kind => 'album', artist => 'Status Band',
        album_title => 'Same Source Carrier', ref_kind => 'album_id', ref => { album_id => 'q1' },
    }, 'later');
    Plugins::ListenLater::DB::add({
        source => 'qobuz', kind => 'album', artist => 'Status Band',
        album_title => 'Same Source Carrier', year => 2024, ref_kind => 'album_id',
        ref => { album_id => 'q2' },
    }, 'wishlist');
    Plugins::ListenLater::DB::updateYear($q, 2024);
    my $row = Plugins::ListenLater::DB::get($q);
    is('a same-source mixed-status twin does block the year', $row->{year}, undef);
    is('...and the row keeps its old key',                $row->{dedupe_key},
       'status band|same source carrier|');
    is('...with both rows still present',
       scalar @{ Plugins::ListenLater::DB::dbh()->selectall_arrayref(
           "SELECT id FROM albums WHERE album_title='Same Source Carrier'") }, 2);
}

# The artist lookup and release verification are parallel requests. If verification supplies
# the year first, updateYear can delete the id still captured by the artist callback. That id
# must remain a carrier for identity metadata, while service-specific answers and user actions
# follow their deliberately different rules.
{
    my ($t) = Plugins::ListenLater::DB::add({
        source => 'tidal', kind => 'album', artist => undef,
        album_title => 'Parallel Carrier', year => 2026, ref_kind => 'album_id',
        ref => { _svc => 'tidal', album_id => 'parallel-t' },
    }, 'later');
    my ($q) = Plugins::ListenLater::DB::add({
        source => 'qobuz', kind => 'album', artist => undef,
        album_title => 'Parallel Carrier', ref_kind => 'album_id',
        ref => { _svc => 'qobuz', album_id => 'parallel-q' },
    }, 'later');

    my $canonical = Plugins::ListenLater::DB::updateYear($q, 2026);
    is('the year-first callback merges away the id held by the artist callback',
       $canonical, $t);
    is('exact lookup still reports that old id as deleted',
       (Plugins::ListenLater::DB::get($q) ? 'present' : 'gone'), 'gone');
    is('a logical lookup follows the old id to its survivor',
       Plugins::ListenLater::DB::getCanonical($q)->{id}, $t);

    my $artistCanonical = Plugins::ListenLater::DB::updateArtist($q, 'Parallel Artist');
    is('the late artist callback returns the survivor', $artistCanonical, $t);
    is('...and its artist reaches that survivor',
       Plugins::ListenLater::DB::get($t)->{artist}, 'Parallel Artist');

    Plugins::ListenLater::DB::updateTrackCount($q, 17, 'qobuz');
    Plugins::ListenLater::DB::updateRelType($q, 'single', 1, 'qobuz');
    Plugins::ListenLater::DB::setRefValue(
        $q, 'buy_url', 'https://wrong.example/', 'qobuz');
    my $survivor = Plugins::ListenLater::DB::get($t);
    is('a stale Qobuz id cannot put its count on the Tidal survivor',
       $survivor->{track_count}, undef);
    is('...or its release type', $survivor->{rel_type}, undef);
    is('...or a resolved service URL', $survivor->{ref}{buy_url}, undef);

    Plugins::ListenLater::DB::setStatus($q, 'played');
    is('a logical status action on the old id reaches the survivor',
       Plugins::ListenLater::DB::get($t)->{status}, 'played');
    Plugins::ListenLater::DB::remove($q);
    is('a logical remove on the old id removes the survivor',
       (Plugins::ListenLater::DB::get($t) ? 'present' : 'gone'), 'gone');
}

# SAME SERVICE, SAME RELEASE — the merge a service-specific answer SHOULD follow. Two rows
# for one Qobuz album exist whenever their keys differ (one save carried the year, one did
# not), and both carry the same catalogue id. The year backfill merges them, and the answer in
# flight still describes the release the survivor replays, so it must land. This is the half
# the guard must not over-refuse.
{
    my $ref = { _svc => 'qobuz', album_id => 'same-1' };
    my ($first) = Plugins::ListenLater::DB::add({
        source => 'qobuz', kind => 'album', artist => 'Same Service',
        album_title => 'Carrier Writes', year => 2026, ref_kind => 'album_id', ref => $ref,
    }, 'later');
    my ($late) = Plugins::ListenLater::DB::add({
        source => 'qobuz', kind => 'album', artist => 'Same Service',
        album_title => 'Carrier Writes', ref_kind => 'album_id',
        ref => { %$ref },
    }, 'later');
    # What the caller froze when it dispatched the request, before the merge deleted its row.
    my $held = Plugins::ListenLater::DB::refIdentity(Plugins::ListenLater::DB::get($late));
    Plugins::ListenLater::DB::updateYear($late, 2026);
    is('a same-release count follows a merged id',
       Plugins::ListenLater::DB::updateTrackCount($late, 8, 'qobuz', $held), $first);
    is('...and lands on the survivor',
       Plugins::ListenLater::DB::get($first)->{track_count}, 8);
    is('a same-release type follows too',
       Plugins::ListenLater::DB::updateRelType($late, 'album', undef, 'qobuz', $held), $first);
    is('...as does a resolved URL',
       Plugins::ListenLater::DB::setRefValue(
           $late, 'album_url', 'https://right.example/', 'qobuz', $held), $first);
    is('the URL lands on the matching replay bundle',
       Plugins::ListenLater::DB::get($first)->{ref}{album_url},
       'https://right.example/');
}

# 0.1.139 — SAME SERVICE, DIFFERENT RELEASE. The service is NOT the replay bundle. Two Qobuz
# rows for what folds to one logical release can hold different catalogue ids (a region or
# edition entry), and _mergeKeyRows leaves the survivor on its OWN ref. A source-only guard
# then reads the deleted twin's callback as the survivor's own and writes another catalogue
# entry's playable count, release type and purchase url onto a different release.
{
    my ($keep) = Plugins::ListenLater::DB::add({
        source => 'qobuz', kind => 'album', artist => 'Two Catalogues',
        album_title => 'Split Release', year => 2026, ref_kind => 'album_id',
        ref => { _svc => 'qobuz', album_id => 'catalogue-A' },
    }, 'later');
    my ($gone) = Plugins::ListenLater::DB::add({
        source => 'qobuz', kind => 'album', artist => 'Two Catalogues',
        album_title => 'Split Release', ref_kind => 'album_id',
        ref => { _svc => 'qobuz', album_id => 'catalogue-B' },
    }, 'later');
    my $held = Plugins::ListenLater::DB::refIdentity(Plugins::ListenLater::DB::get($gone));
    is('the two catalogue entries are one logical release',
       Plugins::ListenLater::DB::updateYear($gone, 2026), $keep);
    is('...and the survivor keeps its own catalogue id',
       Plugins::ListenLater::DB::get($keep)->{ref}{album_id}, 'catalogue-A');

    is('catalogue B\'s count is refused',
       Plugins::ListenLater::DB::updateTrackCount($gone, 99, 'qobuz', $held), undef);
    is('catalogue B\'s release type is refused',
       Plugins::ListenLater::DB::updateRelType($gone, 'ep', 1, 'qobuz', $held), undef);
    is('catalogue B\'s purchase URL is refused',
       Plugins::ListenLater::DB::setRefValue(
           $gone, 'buy_url', 'https://b.example/', 'qobuz', $held), undef);
    my $survivor = Plugins::ListenLater::DB::get($keep);
    is('...so the survivor takes none of them',
       join('/', $survivor->{track_count} // '-', $survivor->{rel_type} // '-',
            $survivor->{ref}{buy_url} // '-'), '-/-/-');

    # THE CONTROL: without it this block would also pass against a guard that refuses every
    # write. The survivor's OWN answer, on the same service, must still land.
    my $own = Plugins::ListenLater::DB::refIdentity($survivor);
    is('the survivor\'s own count still lands',
       Plugins::ListenLater::DB::updateTrackCount($keep, 10, 'qobuz', $own), $keep);
    is('...and its own purchase URL still lands',
       Plugins::ListenLater::DB::setRefValue(
           $keep, 'buy_url', 'https://a.example/', 'qobuz', $own), $keep);
    is('...with both stored',
       join('/', Plugins::ListenLater::DB::get($keep)->{track_count},
            Plugins::ListenLater::DB::get($keep)->{ref}{buy_url}),
       '10/https://a.example/');
}

# 0.1.139 — A CONFLICTING LIST BARS THE MERGE WITH ITSELF, NOT WITH AN OWN-LIST TWIN.
# Three rows on one key: two 'later' saves on different services and one 'played'. Skipping
# the whole group leaves the two 'later' rows as a duplicate the user sees twice, and nothing
# revisits a live backfill — rung 7 has already stamped by the time this carrier runs.
{
    my $h = Plugins::ListenLater::DB::dbh();
    my $ins = sub {
        my ($status, $source, $year, $key, $added, $aid) = @_;
        $h->do("INSERT INTO albums (status,kind,source,artist,album_title,year,dedupe_key,
                                    added_at,play_count,ref_kind,ref_json)
                VALUES (?,'album',?,'Three Ways','One Album',?,?,?,0,'album_id',?)",
            undef, $status, $source, $year, $key, $added, qq({"album_id":"$aid"}));
        return $h->last_insert_id('', '', 'albums', '');
    };
    # add() dedupes cross-source, so this shape is reached by a migration or a converging
    # backfill, never by two taps. Seed it directly.
    my $q = $ins->('later',  'qobuz',   undef, 'three ways|one album|',     100, 'q1');
    my $t = $ins->('later',  'tidal',   2026,  'three ways|one album|2026', 200, 't1');
    my $s = $ins->('played', 'spotify', 2026,  'three ways|one album|2026', 300, 's1');

    my $canonical = Plugins::ListenLater::DB::updateYear($q, 2026);
    is('the own-list twin is merged despite the conflicting row', $canonical, $q);
    is('...leaving one row per list',
       scalar @{ $h->selectall_arrayref(
           "SELECT id FROM albums WHERE album_title='One Album'") }, 2);
    is('...the tidal duplicate is gone',
       (Plugins::ListenLater::DB::get($t) ? 'present' : 'gone'), 'gone');
    is('...the conflicting list is untouched',
       Plugins::ListenLater::DB::get($s)->{status}, 'played');
    is('...and the survivor took the recomputed key',
       Plugins::ListenLater::DB::get($q)->{dedupe_key}, 'three ways|one album|2026');
}

# ---------------------------------------------------------------------------
section('0.1.143 — the fold KEEPS a non-Latin name instead of deleting it');
# Until 0.1.143 the key pass was `s/[^a-z0-9]+/ /g`, which does not fold a non-Latin name,
# it ERASES it. Every name below normalised to '' and the whole key is built from these
# segments, so unrelated releases shared one key in a UNIQUE column.
#
# ANTI-TEST for this whole block: restore the old pass and every `is` here goes red except
# the Latin controls, which is the point of having both halves.
{
    my $norm = \&Plugins::ListenLater::DB::_norm;
    # This file has no `use utf8`, so a non-ASCII literal here is OCTETS — which is the
    # realistic input, since the raw-CLI add path hands _norm octets. But _norm DECODES, so
    # every expected value must be decoded too or the comparison is bytes against characters
    # and fails on a correct fold. That is exactly what it did when this block was written.
    my $chr = sub { my $x = $_[0]; utf8::decode($x); return $x };

    # THE SCRIPTS. Each was '' before; each must now be its own value.
    is('CJK survives the fold',      $norm->("\xe7\xb1\xb3\xe6\xb4\xa5\xe7\x8e\x84\xe5\xb8\xab"), $chr->("\xe7\xb1\xb3\xe6\xb4\xa5\xe7\x8e\x84\xe5\xb8\xab"));
    is('Hangul survives the fold',   $norm->("\xec\x95\x84\xec\x9d\xb4\xec\x9c\xa0"),             $chr->("\xec\x95\x84\xec\x9d\xb4\xec\x9c\xa0"));
    is('Cyrillic survives, lowercased',
       $norm->("\xd0\x9a\xd0\xb8\xd0\xbd\xd0\xbe"), $chr->("\xd0\xba\xd0\xb8\xd0\xbd\xd0\xbe"));
    is('Greek survives, lowercased', $norm->("\xce\xa9"), $chr->("\xcf\x89"));

    # THE LATIN CONTROLS. A pure split means every existing key is byte-identical, which is
    # what makes rung 8 rekey ZERO rows in a Latin-only library. If any of these move, the
    # migration stops being free and the claim in _norm's header is false.
    is('Latin folding is unchanged',        $norm->('Sigur R'."\xc3\xb3".'s'),   'sigur ros');
    is('apostrophe elision is unchanged',   $norm->("Jane\xe2\x80\x99s Addiction"), 'janes addiction');
    is("the 'n' guard is unchanged",        $norm->("Rock\xe2\x80\x99n\xe2\x80\x99Roll"), 'rock n roll');
    is('bracketed text is still KEPT',      $norm->('Album (Deluxe)'), 'album deluxe');
    is('digits and dots are unchanged',     $norm->('834.194'),        '834 194');
    is('a percent still separates words',   $norm->('100% Free'),      '100 free');
    # \w includes '_', so it is stripped explicitly — it is a LIKE metacharacter and the two
    # finders below build patterns straight out of this sub with no ESCAPE.
    is('an underscore still separates words', $norm->('under_score'),  'under score');

    # A NAME THAT IS ALL PUNCTUATION keeps its punctuation rather than answering ''. Real
    # bands ('!!!', '+/-') and a self-titled album by one of them collided with every other
    # such act before this.
    is('a punctuation-only name is kept',   $norm->('!!!'),   '!!!');
    is('...including a symbol name',        $norm->("\xe2\x80\xa0\xe2\x80\xa0\xe2\x80\xa0"), $chr->("\xe2\x80\xa0\xe2\x80\xa0\xe2\x80\xa0"));
    is('...and a mixed-punctuation one',    $norm->('+/-'),   '+/-');

    # THE THREE CHARACTERS THAT MUST NEVER REACH A KEY. '|' is the segment delimiter: an
    # artist named '|' would otherwise forge an identity tail and be read as another row.
    # '%' and '_' are the LIKE metacharacters. A name made only of these still folds to ''.
    is('a pipe name cannot forge a segment', $norm->('|'),    '');
    is('...nor a run of them',               $norm->('|||'),  '');
    is('a LIKE metacharacter name folds away', $norm->('%'),  '');
    is('...and so does the other one',       $norm->('_'),    '');

    # OCTETS AND CHARACTERS MUST AGREE, or the same album keys two ways depending on which
    # surface added it — the invisible-row state _migrateRefold exists to prevent. The raw-CLI
    # add path hands this sub octets; everything else hands it characters.
    my $octets = "\xe4\xb8\xad\xe5\xb3\xb6\xe3\x81\xbf\xe3\x82\x86\xe3\x81\x8d";
    my $chars  = $octets;
    utf8::decode($chars);
    is('a non-Latin name keys the same as octets and as characters',
       $norm->($octets), $norm->($chars));
    is('...and that key is not empty', (length $norm->($chars) ? 'filled' : 'EMPTY'), 'filled');
}

# ---------------------------------------------------------------------------
section('0.1.143 — an erased name no longer collapses unrelated rows');
# THE DEFECT THIS RELEASE EXISTS FOR, asked at DB::add because that is where the loss
# happened. Before 0.1.143 all three of these keyed '||' and the second and third adds were
# refused "already saved" with a success toast. There is no url fallback on the album path,
# so nothing recovered them.
{
    my $mk = sub {
        my ($src, $artist, $album, $year) = @_;
        return { source => $src, artist => $artist, album_title => $album, year => $year,
                 ref_kind => 'search', ref => { album_id => "$artist-$album" } };
    };
    my ($a1) = Plugins::ListenLater::DB::add($mk->('qobuz', "\xe4\xb8\xad\xe5\xb3\xb6\xe3\x81\xbf\xe3\x82\x86\xe3\x81\x8d", "\xe6\xad\x8c\xe5\xa7\xac"));
    my ($a2, $dup2) = Plugins::ListenLater::DB::add($mk->('qobuz', "\xe3\x82\xb5\xe3\x82\xab\xe3\x83\x8a\xe3\x82\xaf\xe3\x82\xb7\xe3\x83\xa7\xe3\x83\xb3", "\xe6\x96\xb0\xe5\xae\x9d\xe5\xb3\xb6"));
    my ($a3, $dup3) = Plugins::ListenLater::DB::add($mk->('tidal', "\xd0\x9a\xd0\xb8\xd0\xbd\xd0\xbe", "\xd0\x93\xd1\x80\xd1\x83\xd0\xbf\xd0\xbf\xd0\xb0 \xd0\xba\xd1\x80\xd0\xbe\xd0\xb2\xd0\xb8"));
    is('a second all-CJK album is not swallowed by the first', ($dup2 ? 'refused' : 'stored'), 'stored');
    is('...and it is its own row',            (($a2 && $a2 != $a1) ? 'own row' : 'the same row'), 'own row');
    is('a Cyrillic album on another service is not swallowed either',
       ($dup3 ? 'refused' : 'stored'), 'stored');
    is('...and it is its own row too',        (($a3 && $a3 != $a1) ? 'own row' : 'the same row'), 'own row');
    is('...so all three are present',
       scalar @{ Plugins::ListenLater::DB::dbh()->selectall_arrayref(
           "SELECT id FROM albums WHERE ref_kind='search' AND dedupe_key LIKE '%|%'
              AND id IN ($a1, $a2, $a3)") }, 3);

    # A self-titled album by a punctuation-only act is the same collision with a year on it.
    my ($p1) = Plugins::ListenLater::DB::add($mk->('qobuz', '!!!', '!!!', 2004));
    my ($p2, $pDup) = Plugins::ListenLater::DB::add($mk->('qobuz', "\xe2\x80\xa0\xe2\x80\xa0\xe2\x80\xa0", "\xe2\x80\xa0\xe2\x80\xa0\xe2\x80\xa0", 2004));
    is('two self-titled punctuation acts of the same year stay apart',
       ($pDup ? 'refused' : 'stored'), 'stored');
    is('...and hold different keys',
       ((Plugins::ListenLater::DB::get($p1)->{dedupe_key} ne
         Plugins::ListenLater::DB::get($p2)->{dedupe_key}) ? 'different' : 'THE SAME'), 'different');

    # THE CROSS-SOURCE CONTROL. Widening the fold must not cost the dedupe that already
    # worked: the same non-Latin album from a second service is still one row.
    my (undef, $same) = Plugins::ListenLater::DB::add($mk->('deezer', "\xe4\xb8\xad\xe5\xb3\xb6\xe3\x81\xbf\xe3\x82\x86\xe3\x81\x8d", "\xe6\xad\x8c\xe5\xa7\xac"));
    is('the SAME non-Latin album from another service still dedupes', $same, 1);
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
