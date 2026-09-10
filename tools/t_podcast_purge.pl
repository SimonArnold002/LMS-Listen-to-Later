#!/usr/bin/env perl
# THE 0.1.136 PODCAST PURGE — does it delete exactly the rows it should, and nothing else?
#
# Built-in Podcasts-app support was REMOVED, not rebuilt, so its rows are deleted rather than
# migrated. That makes this the one rung in the ladder that destroys user data, and the
# blast radius is the whole point of the suite: `source` alone identifies a built-in row and
# a Deezer episode, but NOT a Spotify one — 'spotify' is also every Spotify music track, and
# only the play url separates them.
#
# THE PRE-0.1.126 TRAP, which is why this cannot be one SQL predicate. spotifyEpisodeUri,
# episodeKey and the `episode` flag all landed in ONE commit (49b8902). Before it a Spotify
# episode was not recognised and stored as an ordinary track: a '|t:' key with no '|e:' tail,
# indistinguishable from music by key alone. A `dedupe_key LIKE '%|e:spotify:%'` purge misses
# every one of them; a `ref_json LIKE '%spotify://episode:%'` purge misses the bare
# 'spotify:episode:<id>' spelling that normaliseFavurl only started rewriting at 0.1.113.
# So the test is the URL, through Sources::spotifyEpisodeUri, which knows both spellings.
#
# ANTI-TEST — measured, not asserted. Revert a rule in ListenLater/DB.pm and re-run:
#   - purge on `source` alone (drop the url test)      -> 4 red: the ordinary Spotify track
#     AND the correctly-keyed episode are both destroyed — the data-loss case
#   - keep only rows whose key already carries '|e:'   -> 4 red: the mis-keyed pre-0.1.126
#     row survives, unplayable, and is missing from the report
#   - stamp user_version regardless of the result      -> 2 red: a half-purged db is never
#     retried. NB this one needs the LADDER under test — see the note in the last section
#   - drop the unfinished-ladder guard                  -> 2 red: rung 6 stamps over a rung 5
#     that failed, carrying the schema past a migration that never ran
use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
require "$FindBin::Bin/t_stubs.pl";

my $dir = tempdir(CLEANUP => 1);
Slim::Utils::Prefs::set_test_pref_ns('server', 'cachedir', $dir);
ll_require('DB', 'Sources');

my ($pass, $fail) = (0, 0);
sub is {
    my ($desc, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && "$got" eq "$want");
    $ok ? $pass++ : $fail++;
    printf "%s %-58s got=%-24s want=%s\n", ($ok ? 'ok  ' : 'FAIL'), $desc,
        (defined $got ? "'$got'" : '(undef)'), (defined $want ? "'$want'" : '(undef)');
}
sub ok { my ($d, $c) = @_; is($d, ($c ? 1 : 0), 1) }
sub section { printf "\n== %s\n", $_[0] }

my $DB = 'Plugins::ListenLater::DB';
my $h  = $DB->can('dbh')->();

# Seed BELOW the purge rung, by hand, so the rows are exactly the shapes an older build
# wrote — DB::add would key them the way THIS build keys, which is not what we are testing.
$h->do('PRAGMA user_version = 5');
$h->do('DELETE FROM albums');
my $n = 0;
sub seed {
    my (%r) = @_;
    $n++;
    $h->do('INSERT INTO albums (status, kind, source, artist, album_title, track_title,
                                dedupe_key, ref_kind, ref_json, added_at)
            VALUES (?,?,?,?,?,?,?,?,?,?)', undef,
        ($r{status} // 'later'), ($r{kind} // 'track'), $r{source}, $r{artist},
        $r{album}, $r{track}, $r{key}, 'url', $r{ref}, 1750000000 + $n);
    return $n;
}

seed(source=>'podcast', album=>'Darko.Audio', track=>'Ep 129', key=>'|darko audio|2025|t:ep 129',
     ref=>'{"url":"podcast://https://cdn.ex/e129.mp3"}');
seed(source=>'deezerpodcast', album=>'Serial', track=>'Ep 1', key=>'|ep 1||e:deezerpodcast:deezerpodcast://927648401',
     ref=>'{"url":"deezerpodcast://927648401"}');
# 0.1.124-0.1.125 wrote Deezer episodes BEFORE episodeKey existed (0.1.126), so they carry a
# '|t:' key. Mis-keyed, never shipped, cleared — while the correctly-keyed one above stays.
seed(source=>'deezerpodcast', artist=>'Serial', album=>'Serial', track=>'Old Deezer Ep',
     key=>'serial|serial||t:old deezer ep', ref=>'{"url":"deezerpodcast://111"}');
# pre-0.1.126: stored as an ordinary track, '|t:' key, and the BARE uri spelling
seed(source=>'spotify', artist=>'Some Show', album=>'Some Show', track=>'Mis-keyed Ep',
     key=>'some show|some show||t:mis keyed ep', ref=>'{"url":"spotify:episode:abc123"}');
# correctly-keyed streaming episode — SUPPORTED, must survive
seed(source=>'spotify', album=>'Good Show', track=>'Kept Ep',
     key=>'|kept ep||e:spotify:spotify://episode:zzz999', ref=>'{"url":"spotify://episode:zzz999"}');
# the collateral-damage controls
seed(source=>'spotify', artist=>'Real Band', album=>'Real Album', track=>'Real Song',
     key=>'real band|real album||t:real song', ref=>'{"url":"spotify://track:t1"}');
seed(source=>'qobuz', kind=>'album', artist=>'A', album=>'An Album', key=>'a|an album|2024', ref=>'{}');
seed(source=>'tidal', kind=>'playlist', album=>'A Playlist', key=>'|a playlist||p:tidal:99', ref=>'{}');

section('the purge removes the removed path, and only it');
ok('the purge ran', $DB->can('_purgeRemovedPodcasts')->($h));
my %left = map { $_->[0] => 1 }
    @{ $h->selectall_arrayref('SELECT track_title FROM albums WHERE track_title IS NOT NULL') };
is('the built-in Podcasts-app row is gone',        ($left{'Ep 129'}       ? 'kept' : 'gone'), 'gone');
is('a correctly-keyed DEEZER episode SURVIVES — that path is supported too',
                                                   ($left{'Ep 1'}         ? 'kept' : 'gone'), 'kept');
is('...but a pre-0.1.126 mis-keyed Deezer row is cleared',
                                                   ($left{'Old Deezer Ep'} ? 'kept' : 'gone'), 'gone');
is('the pre-0.1.126 MIS-KEYED Spotify episode is gone — only the url identified it',
                                                   ($left{'Mis-keyed Ep'} ? 'kept' : 'gone'), 'gone');
is('...but a correctly-keyed Spotify episode SURVIVES (that path is supported)',
                                                   ($left{'Kept Ep'}      ? 'kept' : 'gone'), 'kept');

section('nothing else is touched — this is the rung that destroys data');
is('an ordinary Spotify TRACK survives',           ($left{'Real Song'}    ? 'kept' : 'gone'), 'kept');
is('the album row survives',
   scalar @{ $h->selectall_arrayref("SELECT id FROM albums WHERE kind='album'") }, 1);
is('the playlist row survives',
   scalar @{ $h->selectall_arrayref("SELECT id FROM albums WHERE kind='playlist'") }, 1);
is('so exactly three rows went, and five remain',
   scalar @{ $h->selectall_arrayref('SELECT id FROM albums') }, 5);

section('the report names what was removed, and is written BEFORE the delete');
my $report = "$dir/listenlater-removed-podcasts.txt";
ok('the report exists', -e $report);
my $txt = do { open my $fh, '<:encoding(UTF-8)', $report or die $!; local $/; <$fh> };
is('it lists the built-in episode',   (($txt =~ /Ep 129/)       ? 'y' : 'n'), 'y');
is('...the mis-keyed Deezer one',     (($txt =~ /Old Deezer Ep/) ? 'y' : 'n'), 'y');
is('...and the mis-keyed Spotify one', (($txt =~ /Mis-keyed Ep/) ? 'y' : 'n'), 'y');
is('...with its play url so it can be found again',
   (($txt =~ m{podcast://https://cdn\.ex/e129\.mp3}) ? 'y' : 'n'), 'y');
is('it does NOT name a row that survived',
   (($txt =~ /Kept Ep|Real Song|Ep 1\b/) ? 'named' : 'absent'), 'absent');

section('a failed delete leaves the version where it was, so it is retried');
# Driven through _migrate, NOT by calling the purge directly: the rule under test is the
# LADDER's — stamp user_version only on success — and a test that sets the version itself
# proves nothing about it. (Measured: with the purge called directly, breaking the stamp
# rule left this section entirely green.)
$h->do('PRAGMA user_version = 5');
seed(source=>'podcast', album=>'S', track=>'Doomed', key=>'|s||t:doomed', ref=>'{"url":"podcast://x"}');
{
    # DBD::SQLite will not fail a DELETE on demand, so the failure is injected at the handle.
    my $real = \&DBI::db::do;
    no warnings 'redefine';
    local *DBI::db::do = sub {
        my ($self, $sql, @rest) = @_;
        die "injected delete failure\n" if $sql =~ /^DELETE FROM albums WHERE id/;
        return $real->($self, $sql, @rest);
    };
    $DB->can('_migrate')->($h);
}
my ($ver) = $h->selectrow_array('PRAGMA user_version');
is('the ladder does NOT stamp version 6 when the purge failed', $ver, 5);
is('...so the row is still there to retry',
   scalar @{ $h->selectall_arrayref("SELECT id FROM albums WHERE track_title='Doomed'") }, 1);

# ...and the mirror: a clean run DOES stamp, or the purge would run on every single start.
$DB->can('_migrate')->($h);
my ($ver2) = $h->selectrow_array('PRAGMA user_version');
is('a successful pass completes the ladder through version 8', $ver2, 8);
is('...and the doomed row is gone this time',
   scalar @{ $h->selectall_arrayref("SELECT id FROM albums WHERE track_title='Doomed'") }, 0);

section('a PARTIAL delete failure rolls the whole purge back and keeps the report complete');
$h->do('PRAGMA user_version = 5');
$h->do('DELETE FROM albums');
seed(source=>'podcast', album=>'Retry Show', track=>'Episode A',
     key=>'|retry show||t:episode a', ref=>'{"url":"podcast://a"}');
seed(source=>'podcast', album=>'Retry Show', track=>'Episode B',
     key=>'|retry show||t:episode b', ref=>'{"url":"podcast://b"}');
{
    my $real = \&DBI::db::do;
    my $seen = 0;
    no warnings 'redefine';
    local *DBI::db::do = sub {
        my ($self, $sql, @rest) = @_;
        die "injected second-delete failure\n"
            if $sql =~ /^DELETE FROM albums WHERE id/ && ++$seen == 2;
        return $real->($self, $sql, @rest);
    };
    $DB->can('_migrate')->($h);
}
is('the partial failure leaves the version at 5',
   ($h->selectrow_array('PRAGMA user_version'))[0], 5);
is('the first DELETE was rolled back too',
   scalar @{ $h->selectall_arrayref("SELECT id FROM albums WHERE album_title='Retry Show'") }, 2);
my $partialReport = do { open my $fh, '<:encoding(UTF-8)', $report or die $!; local $/; <$fh> };
is('the failed pass report contains episode A', (($partialReport =~ /Episode A/) ? 'y' : 'n'), 'y');
is('...and episode B',                         (($partialReport =~ /Episode B/) ? 'y' : 'n'), 'y');

$DB->can('_migrate')->($h);
is('the retry commits and completes the ladder through version 8',
   ($h->selectrow_array('PRAGMA user_version'))[0], 8);
is('the retry removes both rows',
   scalar @{ $h->selectall_arrayref("SELECT id FROM albums WHERE album_title='Retry Show'") }, 0);
my $retryReport = do { open my $fh, '<:encoding(UTF-8)', $report or die $!; local $/; <$fh> };
is('the retry report still contains episode A', (($retryReport =~ /Episode A/) ? 'y' : 'n'), 'y');
is('...and episode B',                          (($retryReport =~ /Episode B/) ? 'y' : 'n'), 'y');

section('the NO-PODCASTS case — the only path most upgrades will take');
# Simon's own library has no podcast rows at all, and a user who never used the built-in
# path has none either, so this is the path that actually runs on most upgrades. It must be
# a clean no-op: stamp the version so it never runs again, and write NO report file — an
# empty "here is what we deleted" file next to the DB is worse than none, because it reads
# as data loss that did not happen.
$h->do('PRAGMA user_version = 5');
$h->do('DELETE FROM albums');
unlink $report;
seed(source=>'qobuz', kind=>'album', artist=>'B', album=>'Only Music', key=>'b|only music|2024', ref=>'{}');
$DB->can('_migrate')->($h);
is('an empty purge still completes the ladder, so it runs once',
   ($h->selectrow_array('PRAGMA user_version'))[0], 8);
is('...writes NO report file',            (-e $report ? 'written' : 'absent'), 'absent');
is('...and leaves the library alone',
   scalar @{ $h->selectall_arrayref('SELECT id FROM albums') }, 1);

section('rung 6 must not stamp over an EARLIER rung that failed');
# Found while building this suite: _migrate reads user_version ONCE at entry, so a rung 5
# that withheld its stamp (the refold's documented retry rule) still left `$schemaVer < 6`
# true — and rung 6 then stamped 6, carrying the ladder past a migration that never ran and
# losing its retry for good. The purge now re-reads the live version and waits.
$h->do('PRAGMA user_version = 4');
$h->do('DELETE FROM albums');
seed(source=>'podcast', album=>'S', track=>'Survivor', key=>'|s||t:survivor',
     ref=>'{"url":"podcast://y"}');
{
    no warnings 'redefine';
    local *Plugins::ListenLater::DB::_migrateRefold = sub { 0 };   # rung 5 fails
    $DB->can('_migrate')->($h);
}
is('the version is left at 4 for rung 5 to retry',
   ($h->selectrow_array('PRAGMA user_version'))[0], 4);
is('...and the purge has NOT run ahead of it',
   scalar @{ $h->selectall_arrayref("SELECT id FROM albums WHERE track_title='Survivor'") }, 1);

section('with Sources unreachable the purge removes NOTHING — it cannot answer the question');
# DB.pm cannot `use` Sources: the package name matches the INSTALLED layout, so a top-level
# use compiles only where a Plugins/ parent exists and dies in a checkout (measured — it takes
# every suite with it). The sub is reached through ->can instead, and the fallback is the part
# under test. Only the url separates a Spotify EPISODE from a Spotify music track, so with the
# carrier gone the question is unanswerable and the whole rung must stand down: skipping just
# that row would KEEP a mis-keyed episode this rung exists to clear, and carrying on would
# delete music. The built-in row is the assertion that matters — it is already in @doomed when
# the guard trips, so if the abort were per-row rather than whole-rung it would be deleted.
# ANTI-TEST: make the guard `next` instead of `return 0` and 4 go red — the built-in row is
# deleted, the ladder stamps through to 7, a report claims the removal, and the mirror pass
# then finds the Spotify row still there with the rung already retired.
$h->do('DELETE FROM albums');
$h->do('PRAGMA user_version = 5');
unlink $report;
seed(source=>'podcast', album=>'Gone Show', track=>'Built-in Ep',
     key=>'|gone show||t:built-in ep', ref=>'{"url":"podcast://z"}');
seed(source=>'spotify', album=>'Show', track=>'Mis-keyed Spotify Ep',
     key=>'|show||t:mis-keyed spotify ep', ref=>'{"url":"spotify://episode:zz"}');
Slim::Utils::Log::clear();
{
    no warnings 'redefine';
    local *Plugins::ListenLater::Sources::spotifyEpisodeUri;   # the glob, not the value
    ok('...the carrier really is unreachable inside this block',
       (Plugins::ListenLater::Sources->can('spotifyEpisodeUri') ? 0 : 1));
    $DB->can('_migrate')->($h);
}
is('the built-in row is NOT deleted, though it was already doomed',
   scalar @{ $h->selectall_arrayref("SELECT id FROM albums WHERE track_title='Built-in Ep'") }, 1);
is('...nor is the mis-keyed Spotify episode',
   scalar @{ $h->selectall_arrayref("SELECT id FROM albums WHERE track_title LIKE 'Mis-keyed Spotify%'") }, 1);
is('the version is left for the retry', ($h->selectrow_array('PRAGMA user_version'))[0], 5);
is('...and no report claims anything was removed', (-e $report ? 'written' : 'absent'), 'absent');
ok('the reason is logged rather than swallowed',
   ((grep { /cannot identify Spotify episodes/ } Slim::Utils::Log::lines()) ? 1 : 0));

# The mirror, so the guard cannot be satisfied by a purge that never runs: with the carrier
# back, the same two rows go on the very next pass.
$DB->can('_migrate')->($h);
is('with Sources reachable again both rows are removed',
   scalar @{ $h->selectall_arrayref('SELECT id FROM albums') }, 0);
is('...and the ladder completes', ($h->selectrow_array('PRAGMA user_version'))[0], 8);

section('a failing rung REPORTS the version the ladder reached, not the one it entered at');
# The warn is the only trace a withheld stamp leaves, and both failing rungs named $schemaVer
# — read ONCE at the top of _migrate and never reassigned — so an upgrade that ADVANCED through
# earlier rungs before failing named a version the database had already left. Entering at 2 is
# what tells the two apart: rungs 3 and 4 stamp before the refold is reached, so the entry
# value (2) and the live one (4, then 5) differ. ANTI-TEST: put $schemaVer back in either warn
# and that rung's assertion reads 'version 2' (2 red). Rung 7 always had this right and is the
# shape the other two now follow.
sub last_warn {
    my ($re) = @_;
    my @hit = grep { $_ =~ $re } Slim::Utils::Log::lines();
    return @hit ? $hit[-1] : '';
}

$h->do('DELETE FROM albums');
$h->do('PRAGMA user_version = 2');
Slim::Utils::Log::clear();
{
    no warnings 'redefine';
    local *Plugins::ListenLater::DB::_migrateRefold = sub { 0 };   # rung 5 fails at 4
    $DB->can('_migrate')->($h);
}
ok('the refold warn names the version the ladder stamped, not the entry value',
   (last_warn(qr/dedupe-key refold did not complete/) =~ /schema left at version 4 /) ? 1 : 0);
is('...and that is the version actually left on the database',
   ($h->selectrow_array('PRAGMA user_version'))[0], 4);

$h->do('PRAGMA user_version = 2');
Slim::Utils::Log::clear();
{
    no warnings 'redefine';
    local *Plugins::ListenLater::DB::_purgeRemovedPodcasts = sub { 0 };   # rung 6 fails at 5
    $DB->can('_migrate')->($h);
}
ok('the purge warn names the version the ladder stamped, not the entry value',
   (last_warn(qr/podcast purge did not complete/) =~ /schema left at version 5 /) ? 1 : 0);
is('...and that is the version actually left on the database',
   ($h->selectrow_array('PRAGMA user_version'))[0], 5);

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
