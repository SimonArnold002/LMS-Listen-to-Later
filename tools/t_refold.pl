#!/usr/bin/env perl
# FLEET MATCHER SYNC IN LL (0.1.112) — the fold, and the migration it owes.
#
# WHAT LL TOOK, AND WHY ITS SHAPE MADE THIS DIFFERENT FROM THE OTHER REPOS.
#
# DSC/PFR/LBF took three Discography-origin rules. LL took TWO of them — apostrophe
# elision and the ~90-entry %FOLD — and skipped the compound-word collapse, which only
# reaches the replay gate where _bestMatches already re-ranks. What makes LL different
# is not which rules it took but WHERE its normalisers are read:
#
#   DB::_norm            builds `dedupe_key`, a UNIQUE column ON EVERY STORED ROW.
#   Sources::_norm       the fuzzy match gate            — live, nothing persisted.
#   Sources::_normStrict the replay ranker               — live, nothing persisted.
#
# In the other three repos `_norm` feeds caches, so a fold change is a cache bump. Here
# it rewrites STORED IDENTITY, which is why this file exists and why most of it is about
# the migration rather than the fold.
#
# THE FOLD LIVES IN DB.pm, not with the matcher in Sources.pm, and section 5 pins that
# rather than leaving it to a comment. Sources reaches it through ->can (two leaf
# modules, no compile-time cycle) and falls back to plain lc if it ever missed. A
# fallback on the LIVE path is a worse match, discarded at the end of the request; the
# same fallback on the DEDUPE KEY path would write a wrong key into a UNIQUE column,
# permanently, and the row would be invisible to every later lookup. The authority
# belongs with the irreversible consumer.
#
# ANTI-TEST: LL_DB= / LL_SOURCES= are not used here (the modules are loaded for real);
# revert a rule in the source and re-run.
#   - drop the apostrophe elision from DB::foldLatin  -> 15 red
#   - drop the %FOLD/NFD pass from DB::foldLatin      ->  7 red
#   - make Sources::_fold return lc (simulating a     ->  5 red  (the live path degrades;
#     ->can miss)                                                 the stored keys do NOT —
#                                                                 §4's migration assertions
#                                                                 stay GREEN, which is the
#                                                                 asymmetry §5 exists for)
#   - skip _migrateRefold in the ladder               ->  8 red
#   - let the migration merge MIXED-status rows       ->  3 red
use strict;
use warnings;
use utf8;
use FindBin;
use File::Temp qw(tempdir);
binmode(STDOUT, ':encoding(UTF-8)');
require "$FindBin::Bin/t_stubs.pl";

my $dir = tempdir(CLEANUP => 1);
Slim::Utils::Prefs::set_test_pref_ns('server', 'cachedir', $dir);
ll_require('DB');
ll_require('Sources');

my ($pass, $fail) = (0, 0);
sub is {
    my ($desc, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && "$got" eq "$want");
    $ok ? $pass++ : $fail++;
    printf "%s %-58s got=%-28s want=%s\n", ($ok ? 'ok  ' : 'FAIL'), $desc,
        (defined $got ? "'$got'" : '(undef)'), (defined $want ? "'$want'" : '(undef)');
}
sub ok {
    my ($desc, $cond) = @_;
    my $b = $cond ? 1 : 0;
    $b ? $pass++ : $fail++;
    printf "%s %s\n", ($b ? 'ok  ' : 'FAIL'), $desc;
}
sub section { printf "\n== %s\n", $_[0] }

# FIXTURES ARE UPGRADED, and it is a real trap rather than ceremony. Perl sets the UTF8
# flag on a literal only once it carries a codepoint ABOVE U+00FF, and the fold runs only
# inside `if ($HAVE_NFD && utf8::is_utf8($s))` — so "\x{f0}ark" would silently SKIP the
# fold and fail against perfectly good code, while "\x{283}ine" passes. Live input is
# decoded from service JSON or read back from SQLite, so upgrading reproduces production.
sub u { my $s = shift; utf8::upgrade($s); return $s }
sub dbn  { Plugins::ListenLater::DB::_norm(u($_[0])) }
sub srcn { Plugins::ListenLater::Sources::_norm(u($_[0])) }
sub strn { Plugins::ListenLater::Sources::_normStrict(u($_[0])) }

# ---------------------------------------------------------------------------
section('1. APOSTROPHES ELIDE — the Played failure this rule exists to fix');
# `Sources::_artistMatch` is an exact-token SUBSET test. Spacing the mark split
# "Jane's" into 'jane'+'s', so the token 'janes' from the other spelling matched
# nothing and a saved album never auto-moved to Played. Silent: it played fine.
is('DB key: straight apostrophe',      dbn("Jane's Addiction"),        'janes addiction');
is('DB key: no apostrophe agrees',     dbn('Janes Addiction'),         'janes addiction');
is('DB key: curly U+2019 agrees',      dbn("Jane\x{2019}s Addiction"), 'janes addiction');
is('match gate agrees',                srcn("Jane's Addiction"),       'janes addiction');
is('replay ranker agrees',             strn("Jane's Addiction"),       'janes addiction');
is("O'Connor",                         dbn("Sin\x{e9}ad O'Connor"),    'sinead oconnor');
is("The B-52's",                       dbn("The B-52's"),              'the b 52s');

ok('the two spellings now share ONE artist-match verdict',
   Plugins::ListenLater::Sources::_artistMatch(srcn("Jane's Addiction"),
                                               srcn('Janes Addiction')));

section("1b. …and the \"'n'\" guard, which joins two WORDS rather than sitting inside one");
is("Rock'n'Roll",                      dbn("Rock'n'Roll"),             'rock n roll');
is("Rock 'n' Roll agrees",             dbn("Rock 'n' Roll"),           'rock n roll');
is('Rock N Roll agrees',               dbn('Rock N Roll'),             'rock n roll');
ok('eliding blindly would have keyed rocknroll',  dbn("Rock'n'Roll") ne 'rocknroll');

# ---------------------------------------------------------------------------
section('2. %FOLD — LL had NO folding, and its punctuation pass made that worse');
# `[^a-z0-9]+ -> ' '` turned every non-ASCII letter into a SPACE, so an accented name
# was not merely unfolded, it was SHATTERED into single-letter tokens: "Sigur Rós"
# keyed 'sigur r s'. The token-subset test could never reconcile that with 'sigur ros'.
is('diacritic stripped, not spaced',   dbn("Sigur R\x{f3}s"),          'sigur ros');
is('plain spelling agrees',            dbn('Sigur Ros'),               'sigur ros');
is("atomic letter \x{f8} -> o",        dbn("Bj\x{f8}rk"),              'bjork');
is("ligature \x{e6} -> ae",            dbn("\x{e6}ther"),              'aether');
is("IPA \x{283} -> sh",                dbn("\x{283}ine"),              'shine');
is("dotless \x{131} -> i",             dbn("Alt\x{131}n G\x{fc}n"),    'altin gun');
is('the match gate folds identically', srcn("Sigur R\x{f3}s"),         'sigur ros');

# ---------------------------------------------------------------------------
section('3. WHAT MUST NOT MOVE — the three normalisers still differ where they should');
# The fold is shared; the punctuation passes are not, and that is the point. Unifying
# them would break either the dedupe key (which must keep "(Deluxe)" distinct) or the
# match gate (which must ignore it).
is('DB key KEEPS a qualifier',         dbn('Album (Deluxe)'),          'album deluxe');
is('...so it is a distinct save',      (dbn('Album (Deluxe)') ne dbn('Album') ? 'yes':'no'), 'yes');
is('match gate STRIPS it',             srcn('Album (Deluxe)'),         'album');
is('...so it matches the plain title', (srcn('Album (Deluxe)') eq srcn('Album') ? 'yes':'no'), 'yes');
is('ranker keeps a DISTINGUISHER',     strn('American Football (LP4)'), 'american football lp4');
is('...but drops a quality qualifier', strn('American Football (Hi-Res 24bit)'), 'american football');

section('3b. THE LENIENT GATES ARE UNTOUCHED — LL keeps its pinned variant');
# Empty-artist saved-item replay (LL 0.1.66): a streaming Now-Playing add can carry no
# artist metadata at all, and that row must still re-find itself.
ok('empty artist still accepts (replay path)',
   Plugins::ListenLater::Sources::_albumMatches('', srcn('Open Soul'), 'Anyone', 'Open Soul'));
ok('empty side still matches in _artistMatch',
   Plugins::ListenLater::Sources::_artistMatch('', 'anyone'));
ok('a genuinely different artist is still rejected',
   !Plugins::ListenLater::Sources::_albumMatches(srcn('Tomorrows People'), srcn('Open Soul'),
                                                 'Some Other Band', 'Open Soul'));

# ---------------------------------------------------------------------------
section('4. THE MIGRATION — a stored key is not a cache');
# Every dedupe_key written before the fold is stale, and a stale key is INVISIBLE: add()
# stops deduping against it and Played's lookups stop finding it.
my $mig = sub {
    my ($seed) = @_;
    my $f = "$dir/refold-" . int(rand(1e9)) . '.db';
    my $h = DBI->connect("dbi:SQLite:dbname=$f", '', '', { RaiseError => 1, AutoCommit => 1 });
    # An OLD database: schema at the previous ladder height, keys in the old fold.
    Plugins::ListenLater::DB::_migrate($h);
    $h->do('PRAGMA user_version = 4');
    $h->do('DELETE FROM albums');
    $seed->($h);
    Plugins::ListenLater::DB::_migrate($h);
    return $h;
};
my $ins = sub {
    my ($h, %o) = @_;
    $h->do("INSERT INTO albums (status,kind,source,artist,album_title,track_title,year,
                                dedupe_key,added_at,played_at,play_count,track_count,
                                rel_type,artwork,ref_kind,ref_json)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", undef,
        $o{status} // 'later', $o{kind} // 'album', $o{source} // 'qobuz',
        $o{artist}, $o{album}, $o{track}, $o{year}, $o{key}, $o{added} // 100,
        $o{played_at}, $o{play_count} // 0, $o{count}, $o{rel}, $o{art},
        $o{ref_kind}, $o{ref_json});
};

{
    my $h = $mig->(sub {
        $ins->($_[0], artist => "Jane's Addiction", album => 'Ritual de lo Habitual',
               year => 1990, key => "jane s addiction|ritual de lo habitual|1990");
    });
    my $r = $h->selectall_arrayref('SELECT dedupe_key FROM albums', { Slice => {} });
    is('a stale key is rewritten',  $r->[0]{dedupe_key}, 'janes addiction|ritual de lo habitual|1990');
    is('...and the ladder is stamped', ($h->selectrow_array('PRAGMA user_version'))[0], 5);
}

section('4b. …and it COLLAPSES the duplicates the new fold merges');
{
    # The same album saved twice under two spellings. Same status, so this is
    # unambiguous: one album, two rows, and the fold has just proved it.
    my $h = $mig->(sub {
        $ins->($_[0], artist => "Jane's Addiction", album => 'Ritual', year => 1990,
               key => 'jane s addiction|ritual|1990', added => 100, play_count => 3,
               played_at => 555, ref_kind => '', ref_json => '');
        $ins->($_[0], artist => 'Janes Addiction', album => 'Ritual', year => 1990,
               key => 'janes addiction|ritual|1990', added => 200, play_count => 1,
               count => 11, rel => 'album', ref_kind => 'album_id', ref_json => '{"album_id":"z9"}');
    });
    my $r = $h->selectall_arrayref('SELECT * FROM albums', { Slice => {} });
    is('two rows become one',                   scalar(@$r), 1);
    is('the EARLIEST save survives',            $r->[0]{added_at}, 100);
    is('...carrying the higher play count',     $r->[0]{play_count}, 3);
    is('...and the play timestamp',             $r->[0]{played_at}, 555);
    # The survivor was the row WITHOUT a ref. Losing the other one would have made the
    # album unreplayable, so what the loser knew is carried across rather than dropped.
    is('...and the loser\'s ref (replayable)',  $r->[0]{ref_kind}, 'album_id');
    is('...and its resolved track count',       $r->[0]{track_count}, 11);
    is('...and its release type',               $r->[0]{rel_type}, 'album');
    is('under the folded key',                  $r->[0]{dedupe_key}, 'janes addiction|ritual|1990');
}

section('4c. MIXED STATUS IS LEFT ALONE — never guess which list the user wanted');
{
    # One finished with, one still to hear. Collapsing would have to silently resurrect
    # something marked played or mark something the user still has queued. An old key
    # costs one un-deduped row; guessing costs a list entry that vanishes unexplained.
    my $h = $mig->(sub {
        $ins->($_[0], status => 'later',  artist => "Jane's Addiction", album => 'Ritual',
               year => 1990, key => 'jane s addiction|ritual|1990', added => 100);
        $ins->($_[0], status => 'played', artist => 'Janes Addiction', album => 'Ritual',
               year => 1990, key => 'janes addiction|ritual|1990', added => 200);
    });
    my $r = $h->selectall_arrayref('SELECT * FROM albums ORDER BY added_at', { Slice => {} });
    is('BOTH rows survive',                     scalar(@$r), 2);
    is('the later row keeps its OLD key',       $r->[0]{dedupe_key}, 'jane s addiction|ritual|1990');
    is('...and its status',                     $r->[0]{status}, 'later');
    is('the played row is untouched too',       $r->[1]{status}, 'played');
}

section('4d. TRACK and PLAYLIST keys keep their identity segments');
{
    my $h = $mig->(sub {
        $ins->($_[0], kind => 'track', artist => "Jane's Addiction", album => 'Ritual',
               year => 1990, track => "Been Caught Stealin'",
               key => "jane s addiction|ritual|1990|t:been caught stealin");
        # A playlist's identity is the SERVICE'S id, which lives only in the key's tail —
        # it cannot be rebuilt from any column, so the tail must survive verbatim.
        $ins->($_[0], kind => 'playlist', album => "Tomorrow's Hits",
               key => "|tomorrow s hits||p:qobuz:69183531");
    });
    my $r = $h->selectall_hashref('SELECT * FROM albums', 'kind');
    is('track: artist folded, |t: kept',  $r->{track}{dedupe_key},
       'janes addiction|ritual|1990|t:been caught stealin');
    is('playlist: title folded',          $r->{playlist}{dedupe_key},
       '|tomorrows hits||p:qobuz:69183531');
    ok('playlist: the service id is untouched',
       $r->{playlist}{dedupe_key} =~ /\|p:qobuz:69183531$/);
}

section('4e. IDEMPOTENT — a second pass changes nothing');
{
    my $h = $mig->(sub {
        $ins->($_[0], artist => "Jane's Addiction", album => 'Ritual', year => 1990,
               key => 'jane s addiction|ritual|1990');
    });
    my ($before) = $h->selectrow_array('SELECT dedupe_key FROM albums');
    $h->do('PRAGMA user_version = 4');            # force it to run again
    Plugins::ListenLater::DB::_migrate($h);
    my $r = $h->selectall_arrayref('SELECT dedupe_key FROM albums', { Slice => {} });
    is('still one row',            scalar(@$r), 1);
    is('and the same key',         $r->[0]{dedupe_key}, $before);
}

# ---------------------------------------------------------------------------
section('5. THE FOLD LIVES IN DB.pm, AND THAT IS LOAD-BEARING');
# Sources reaches it through ->can and falls back to lc; DB calls it directly. So a
# missing fold degrades the LIVE match (discarded at end of request) and can never
# reach the stored key. Pinned as source, because the failure it prevents is a
# permanent wrong key rather than anything observable from a passing call.
my $dbsrc  = do { open my $fh, '<:encoding(UTF-8)', "$FindBin::Bin/../ListenLater/DB.pm" or die $!; local $/; <$fh> };
my $srcsrc = do { open my $fh, '<:encoding(UTF-8)', "$FindBin::Bin/../ListenLater/Sources.pm" or die $!; local $/; <$fh> };
ok('DB.pm owns %FOLD',                    scalar($dbsrc  =~ /my %FOLD = \(/));
ok('Sources.pm does NOT keep a second copy', !scalar($srcsrc =~ /my %FOLD = \(/));
ok('DB::_norm calls the fold DIRECTLY (no ->can, no fallback)',
   scalar($dbsrc =~ /sub _norm \{\s*my \$s = foldLatin\(/));
ok('Sources reaches it via ->can',        scalar($srcsrc =~ /DB->can\('foldLatin'\)/));
ok('all three normalisers fold',
   scalar($dbsrc =~ /sub _norm \{\s*my \$s = foldLatin/)
   && scalar($srcsrc =~ /sub _norm \{\s*my \$s = _fold\(/)
   && scalar($srcsrc =~ /sub _normStrict \{\s*my \$s = _fold\(/));

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
