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
#   - skip _migrateRefold in the ladder               -> 14 red
#   - let the migration merge MIXED-status rows       ->  4 red
#   - strand a whole MIXED-status group on its old    ->  1 red  (the bar is on the MERGE,
#     keys instead of rekeying it per service                     not on the rekey: a
#                                                                 cross-source pair still
#                                                                 takes the new key — §4c2)
#   - stamp user_version regardless of the refold's   ->  6 red
#     result
#   - drop the per-group transaction (delete, then    ->  4 red  (and the 3 rows §4h says
#     rekey, on the AutoCommit handle)                           survive are GONE)
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

section("3c. AN ERASED NAME IS NOT AN ABSENT ONE — the lenient gates aimed backwards");
# 0.1.143. The gates above are lenient BY DESIGN: an empty artist accepts, because a streaming
# Now-Playing add can genuinely carry none. Until 0.1.143 `_norm` did not fold a non-Latin
# name, it ERASED it — so a real artist arrived at those gates looking ABSENT, and absent means
# ACCEPT ANYTHING. Two wrong answers, both measured 2026-09-10 against the shipped build:
#
#   * Played marked the WRONG ALBUM. A play of 'Lemon' by 米津玄師 marked a stored 'Lemon' by
#     中島みゆき, because both credits normalised to '' and `_artistMatch` answers 1 when either
#     side is empty. Played::_albumFallback's own comment promises this cannot happen.
#   * Replay could resolve to ANOTHER ARTIST'S release of the same title, via the
#     `return 1 unless length $artistNorm` arm of _albumMatches.
#
# THE LENIENCY IS NOT THE BUG AND MUST SURVIVE — the last two assertions here are the ones that
# say so, and they are the reason the fix is in the fold rather than in the gates.
#
# ANTI-TEST: restore `s/[^a-z0-9]+/ /g` in Sources::_punctPass and the first five go red while
# the leniency pair stays green — which is exactly the asymmetry that made this hard to see.
{
    my $am = \&Plugins::ListenLater::Sources::_artistMatch;
    my $al = \&Plugins::ListenLater::Sources::_albumMatches;

    ok('two different CJK artists no longer match each other',
       !$am->(srcn(u("\x{7c73}\x{6d25}\x{7384}\x{5e2b}")), srcn(u("\x{4e2d}\x{5cf6}\x{307f}\x{3086}\x{304d}"))));
    ok('...while the SAME CJK artist still does',
       $am->(srcn(u("\x{7c73}\x{6d25}\x{7384}\x{5e2b}")), srcn(u("\x{7c73}\x{6d25}\x{7384}\x{5e2b}"))));
    ok('two different Cyrillic artists no longer match',
       !$am->(srcn(u("\x{41a}\x{438}\x{43d}\x{43e}")), srcn(u("\x{410}\x{43a}\x{432}\x{430}\x{440}\x{438}\x{443}\x{43c}"))));
    ok('two different punctuation-only acts no longer match',
       !$am->(srcn('!!!'), srcn(u("\x{2020}\x{2020}\x{2020}"))));

    # The replay gate, asked the same way round.
    ok('a CJK-credited album no longer matches another artist\'s same-titled release',
       !$al->(srcn(u("\x{7c73}\x{6d25}\x{7384}\x{5e2b}")), srcn('Lemon'), 'Some Other Band', 'Lemon'));
    ok('...while its own release still matches',
       $al->(srcn(u("\x{7c73}\x{6d25}\x{7384}\x{5e2b}")), srcn('Lemon'), u("\x{7c73}\x{6d25}\x{7384}\x{5e2b}"), 'Lemon'));

    # A non-Latin TITLE was rejected outright by the `length $albumNorm < 2` guard, since it
    # normalised to ''. Two characters of CJK are a title; they just were not two characters.
    ok('a CJK album title can be matched at all now',
       $al->(srcn(u("\x{4e2d}\x{5cf6}\x{307f}\x{3086}\x{304d}")), srcn(u("\x{6b4c}\x{59eb}")),
             u("\x{4e2d}\x{5cf6}\x{307f}\x{3086}\x{304d}"), u("\x{6b4c}\x{59eb}")));
    ok('...and it does NOT match a different CJK album',
       !$al->(srcn(u("\x{4e2d}\x{5cf6}\x{307f}\x{3086}\x{304d}")), srcn(u("\x{6b4c}\x{59eb}")),
              u("\x{4e2d}\x{5cf6}\x{307f}\x{3086}\x{304d}"), u("\x{65b0}\x{5b9d}\x{5cf6}")));

    # THE LENIENCY CONTROLS — LL 0.1.66's saved-item replay path. `_norm('')` is still '', so
    # a genuinely ABSENT artist behaves exactly as it did. If these two ever go red the fix has
    # been "tidied" into making the gates strict, which breaks Now-Playing replay.
    ok('a genuinely absent artist still accepts (0.1.66 replay path)',
       $al->('', srcn('Open Soul'), 'Anyone', 'Open Soul'));
    ok('...and _artistMatch still short-circuits on an empty side',
       $am->('', 'anyone'));
}

section('3d. STYLISED LETTERS — the fourth fleet rule LL never received (0.1.145)');
# A punctuation mark standing in for a LETTER. The rule landed 2026-07-21 as PFR 0.7.8 across
# the four full matcher copies; LL did not join the matcher sync until 0.1.112, and that port
# was scoped to the three Discography-origin rules — two taken, the compound-word collapse
# skipped with a stated reason. This one appears there neither as taken nor as skipped. MISSED,
# not decided. Without it `_artistMatch`'s token SUBSET test shares no token and the row
# silently never moves to Played — the same failure the apostrophe rule fixed in 0.1.112.
#
# ANTI-TEST, per rule and separately, or one assertion covers for another: drop the `$`/`@`
# lines -> 4 red; drop the `!` branch -> 3 red; drop the `&`/`+` line -> 3 red.
{
    my $am = \&Plugins::ListenLater::Sources::_artistMatch;

    is('a mark standing in for a letter folds to it', srcn('P!nk'),        'pink');
    is('...unconditionally for $',                    srcn('Ke$ha'),       'kesha');
    is('...including a trailing one',                 srcn('$uicideboy$'), 'suicideboys');
    is('...and @',                                    srcn('M@ss'),        'mass');
    is('currency marks fold too',                     srcn(u("M\x{a3}\x{a5}")), 'mly');
    ok('so a stylised name now MATCHES its plain spelling',
       $am->(srcn('P!nk'), srcn('Pink')));
    ok('...and so does the $ pair',    $am->(srcn('Ke$ha'), srcn('Kesha')));
    ok('...and the trailing-$ pair',   $am->(srcn('$uicideboy$'), srcn('Suicideboys')));

    # A DECORATIVE mark is punctuation, not a letter, and those already worked here — the
    # word-boundary test is what keeps them working rather than keying 'whami'.
    is('a trailing ! is still decoration',   srcn('Wham!'),               'wham');
    is('...and a mid-name one',              srcn('Panic! At The Disco'), 'panic at the disco');
    ok('Layo & Bushwacka! still matches its plain spelling',
       $am->(srcn('Layo & Bushwacka!'), srcn('Layo and Bushwacka')));

    # THE `else` BRANCH. A name made ENTIRELY of marks must fold to letters, not fall through.
    # Deleting the branch in a repo without LL's all-marks fallback sends it to '', and LL's
    # gates read empty as ABSENT — the 0.1.143 bug in a new costume. Pinned directly.
    is('an all-marks name folds to letters',  srcn('!!!'), 'iii');
    ok('...so two different all-marks acts still do not match',
       !$am->(srcn('!!!'), srcn(u("\x{2020}\x{2020}\x{2020}"))));
    is('...and one with no mapping keeps its marks rather than erasing',
       srcn(u("\x{2020}\x{2020}\x{2020}")), u("\x{2020}\x{2020}\x{2020}"));

    # AMPERSAND. It changes the token SET, which is why it needs both halves: the fold is
    # asserted, AND that the subset test absorbs it so no existing match is lost.
    is('& becomes a word',   srcn('Simon & Garfunkel'),      'simon and garfunkel');
    is('...and + does too',  srcn('Florence + The Machine'), 'florence and the machine');
    ok('an & credit still matches the bare juxtaposition',
       $am->(srcn('Simon & Garfunkel'), srcn('Simon Garfunkel')));
    ok('...and the spelled-out form',
       $am->(srcn('Simon & Garfunkel'), srcn('Simon and Garfunkel')));

    # BOTH DIRECTIONS, because the comment above this rule claimed for four versions that the
    # losing one did not exist, and only the winning half was ever asserted here. Real pairs,
    # measured 2026-09-11 across an 8,958-artist library: exactly one win, exactly one loss.
    # The LOSS is the load-bearing assertion — it is what stops the comment reverting to
    # "cannot cost a match". The WIN is why the rule is kept rather than reverted to a strip.
    ok('an & credit does NOT match a different connector for the same act',
       !$am->(srcn('Davie Allan & the Arrows'), srcn('The Arrows feat. Davie Allan')));
    ok('...while the rule still WINS the spelled-out shorter side',
       $am->(srcn('Carole King & Gerry Goffin'), srcn('Goffin And King')));

    # THE REGRESSION HALF. 0.1.144 fixed an order bug in this very sub that no fixture caught,
    # because none had an underscore ADJACENT to other punctuation — the ripped-file shape.
    # The new block goes ABOVE both substitutions, so it must not disturb that order.
    is('an underscore beside punctuation still collapses to ONE space',
       srcn('01_-_Intro'), '01 intro');
    is('...on the shape that actually broke',
       srcn('Boards_of_Canada_-_Roygbiv'), 'boards of canada roygbiv');
    is('...and a plain underscore is unchanged', srcn('under_score'), 'under score');

    # 0.1.143 MUST NOT BE UNDONE — the fixtures outside the range that motivated this rule.
    is('a CJK name still survives',      srcn(u("\x{7c73}\x{6d25}\x{7384}\x{5e2b}")), u("\x{7c73}\x{6d25}\x{7384}\x{5e2b}"));
    is('a Cyrillic name still survives', srcn(u("\x{41a}\x{438}\x{43d}\x{43e}")),     u("\x{43a}\x{438}\x{43d}\x{43e}"));
    ok('and two different CJK artists still do not match',
       !$am->(srcn(u("\x{7c73}\x{6d25}\x{7384}\x{5e2b}")), srcn(u("\x{4e2d}\x{5cf6}\x{307f}\x{3086}\x{304d}"))));

    # THE GATE AND THE RANKER SHARE _punctPass, which 0.1.112 requires: the gate normalises a
    # candidate and _bestMatches re-reads the SAME one, so a divergence lets a title clear the
    # gate and then fail its own exact-title tier.
    is('the ranker folds stylised letters identically', strn('P!nk'), srcn('P!nk'));
    is('...and the ampersand identically',              strn('Simon & Garfunkel'),
                                                        srcn('Simon & Garfunkel'));
    is('...while still keeping its OWN distinguisher',  strn('American Football (LP4)'),
       'american football lp4');
}

section('3e. A TITLE THAT NORMALISES TO NOTHING — the escape hatch LL never took');
# `length $albumNorm < 2` rejected Sigur Rós's "( )" and any one-character CJK title outright,
# so they could never match from any source. DSC/PFR/LBF have had `_punctNorm` since
# 2026-07-10; ported at 0.1.145. LL taking FROM the fleet, the reverse of the usual direction.
#
# ANTI-TEST: remove the branch and the first two go red while the leniency control stays GREEN.
{
    my $al = \&Plugins::ListenLater::Sources::_albumMatches;
    my $cjk = u("\x{7cf8}");

    ok('an all-paren title can be matched at all now',
       $al->(srcn('Sigur Ros'), srcn('( )'), 'Sigur Ros', '( )', '( )'));
    ok('...and a ONE-character CJK title',
       $al->(srcn(u("\x{4e2d}\x{5cf6}\x{307f}\x{3086}\x{304d}")), srcn($cjk),
             u("\x{4e2d}\x{5cf6}\x{307f}\x{3086}\x{304d}"), $cjk, $cjk));

    # EXACT equality only on that path — a prefix rule would let "x" swallow "xx".
    ok('...but it does NOT swallow a longer title',
       !$al->(srcn('Sigur Ros'), srcn('( )'), 'Sigur Ros', '( ) (live)', '( )'));
    ok('...nor match a different CJK title of the same length',
       !$al->(srcn(u("\x{4e2d}\x{5cf6}\x{307f}\x{3086}\x{304d}")), srcn($cjk),
              u("\x{4e2d}\x{5cf6}\x{307f}\x{3086}\x{304d}"), u("\x{6b4c}"), $cjk));

    # THE ARTIST GATE IS MANDATORY ON OUR SIDE ONLY. Assert BOTH sides, because asserting
    # the record side alone is what let the comment read as a promise about the candidate
    # side too — and four review rounds reported the gap as a bug.
    ok('...and rejects a different artist',
       !$al->(srcn('Sigur Ros'), srcn('( )'), 'Other Band', '( )', '( )'));
    ok('...and refuses an EMPTY artist, where the normal path would accept',
       !$al->('', srcn('( )'), 'Anyone', '( )', '( )'));

    # THE CANDIDATE SIDE IS DELIBERATELY NOT GATED — DECLINED FOUR TIMES (Simon, 2026-09-10).
    # `_artistMatch` answers 1 when either side is empty, so an artist-less CANDIDATE is
    # accepted on the title alone. Pinned as a test so the next round finds a DECISION here
    # rather than an apparent contradiction. Flipping to the fleet's strict variant turns
    # these two red; that is the intended tripwire, not a regression to fix.
    ok('an artist-less CANDIDATE is accepted here (0.1.66 leniency, pinned)',
       $al->(srcn('Sigur Ros'), srcn('( )'), '', '( )', '( )'));
    ok('...and so is an undef one, which is what the TIDAL/Deezer `|| {}` default yields',
       $al->(srcn('Sigur Ros'), srcn('( )'), undef, '( )', '( )'));

    # The branch is ORDINARY, correcting the ledger's "( )"-only example: these are four
    # Ed Sheeran albums and a Beyonce one. Only the artist-less candidate is the rarity.
    for my $t ('x', "\x{f7}", '=', '-', '4') {
        ok("a real one-character title enters the branch: '" . u($t) . "'",
           length(srcn(u($t))) < 2);
    }
    ok('THE CONTROL: the normal path still accepts an empty artist (0.1.66 replay)',
       $al->('', srcn('Open Soul'), 'Anyone', 'Open Soul', 'Open Soul'));

    # A raw title that is only whitespace has nothing to compare on either.
    ok('a title with nothing in it at all still matches nothing',
       !$al->(srcn('Sigur Ros'), srcn('  '), 'Sigur Ros', '  ', '  '));
}

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
    is('...and the ladder is stamped', ($h->selectrow_array('PRAGMA user_version'))[0], 9);
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

section('4c. MIXED STATUS IS NEVER MERGED — never guess which list the user wanted');
{
    # One finished with, one still to hear. Collapsing would have to silently resurrect
    # something marked played or mark something the user still has queued. Two rows costs
    # one un-deduped save; guessing costs a list entry that vanishes unexplained. Both rows
    # are on ONE service here, so neither can be rekeyed either — 4c2 has the cross-source
    # case, where the merge is still refused but both rows do take the folded key.
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

section('4c2. CROSS-SOURCE IDENTITY MATCHES add(), WITHOUT CROSSING REPLAY WIRES');
{
    # add() has treated one logical album as one row across every source since 0.1.33. The
    # migration must apply the same rule to spellings that only become equal under this fold.
    # The earliest Qobuz row already has a replay ref, so its complete source/ref bundle wins;
    # Tidal's regional track count must not be borrowed by the Qobuz survivor.
    my $h = $mig->(sub {
        $ins->($_[0], source => 'qobuz', artist => "Jane's Addiction", album => 'Ritual',
               year => 1990, key => 'jane s addiction|ritual|1990', added => 100,
               ref_kind => 'album_id', ref_json => '{"_svc":"qobuz","album_id":"q1"}');
        $ins->($_[0], source => 'tidal', artist => 'Janes Addiction', album => 'Ritual',
               year => 1990, key => 'janes addiction|ritual|1990', added => 200,
               count => 11, rel => 'single', ref_kind => 'album_id',
               ref_json => '{"_svc":"tidal","album_id":"t1"}');
    });
    my $r = $h->selectall_arrayref('SELECT * FROM albums', { Slice => {} });
    is('cross-source twins become one',                scalar(@$r), 1);
    is('the earliest source survives',                 $r->[0]{source}, 'qobuz');
    is('...with its own ref',
       JSON::XS->new->decode($r->[0]{ref_json})->{album_id}, 'q1');
    is('...without a different service\'s track count', $r->[0]{track_count}, undef);
    is('...or its catalogue release type',              $r->[0]{rel_type}, undef);
}

{
    # If the earliest row has no replay carrier, adopting a later row's ref is still the
    # right repair — but its source has to move with it, and then its measured count is safe.
    my $h = $mig->(sub {
        $ins->($_[0], source => 'qobuz', artist => "Jane's Addiction", album => 'Strays',
               year => 2003, key => 'jane s addiction|strays|2003', added => 100,
               count => 7, ref_kind => '', ref_json => '');
        $ins->($_[0], source => 'tidal', artist => 'Janes Addiction', album => 'Strays',
               year => 2003, key => 'janes addiction|strays|2003', added => 200,
               count => 13, rel => 'album', ref_kind => 'album_id',
               ref_json => '{"_svc":"tidal","album_id":"t2"}');
    });
    my $r = $h->selectall_arrayref('SELECT * FROM albums', { Slice => {} });
    is('the earliest row id still survives',            $r->[0]{added_at}, 100);
    is('the adopted ref brings its source atomically',  $r->[0]{source}, 'tidal');
    is('...and its id',
       JSON::XS->new->decode($r->[0]{ref_json})->{album_id}, 't2');
    is('...so its own measured count may follow',       $r->[0]{track_count}, 13);
    is('...and its own release type',                    $r->[0]{rel_type}, 'album');
}

{
    # MIXED STATUS BARS THE MERGE, NOT THE REKEY. These two are on different SERVICES, and
    # dedupe_key is UNIQUE per service — so both can hold the folded key. Leaving the Qobuz
    # row on its old spelling instead would strand it: rung 5 stamps whether it skipped or
    # not, so nothing revisits it, add() stops deduping against it and Played stops finding
    # it. Two visible rows is the policy; two INVISIBLE rows is the bug it caused.
    my $h = $mig->(sub {
        $ins->($_[0], source => 'qobuz', status => 'later', artist => "Jane's Addiction",
               album => 'Nothing', year => 2011, key => 'jane s addiction|nothing|2011');
        $ins->($_[0], source => 'tidal', status => 'played', artist => 'Janes Addiction',
               album => 'Nothing', year => 2011, key => 'janes addiction|nothing|2011');
    });
    my $r = $h->selectall_arrayref('SELECT * FROM albums ORDER BY id', { Slice => {} });
    is('cross-source mixed statuses both survive',      scalar(@$r), 2);
    is('...neither is merged into the other',           $r->[1]{status}, 'played');
    is('...and the stale spelling is rekeyed, not guessed away', $r->[0]{dedupe_key},
       'janes addiction|nothing|2011');
    is('...on the same key as its cross-source twin',   $r->[1]{dedupe_key},
       'janes addiction|nothing|2011');
    is('...with the un-merged row keeping its own list', $r->[0]{status}, 'later');
    is('...and the ladder still stamps',                ($h->selectrow_array('PRAGMA user_version'))[0], 9);
}

{
    # THE CONTROL for the rekey above, and the reason the split is by SOURCE rather than
    # simply dropping the mixed-status bar. One service cannot hold the same key twice, so
    # here there is no rekey to be had — picking which of the two takes it IS the guess the
    # policy refuses. Same seed as 4c, asserted from the other direction: 4c pins that the
    # rows survive, this pins that the fold really would have moved them if it could.
    my $h = $mig->(sub {
        $ins->($_[0], source => 'qobuz', status => 'later', artist => "Jane's Addiction",
               album => 'Something', year => 2011, key => 'jane s addiction|something|2011');
        $ins->($_[0], source => 'qobuz', status => 'played', artist => 'Janes Addiction',
               album => 'Something', year => 2011, key => 'janes addiction|something|2011');
    });
    my $r = $h->selectall_arrayref('SELECT * FROM albums ORDER BY id', { Slice => {} });
    is('same-source mixed statuses both survive',       scalar(@$r), 2);
    is('...and neither is rekeyed onto the other',      $r->[0]{dedupe_key},
       'jane s addiction|something|2011');
    # Control: the fold DID want to move it — a single row of that spelling is rekeyed.
    my $h2 = $mig->(sub {
        $ins->($_[0], source => 'qobuz', status => 'later', artist => "Jane's Addiction",
               album => 'Something', year => 2011, key => 'jane s addiction|something|2011');
    });
    is('...only because its own service already holds that key',
       ($h2->selectrow_array('SELECT dedupe_key FROM albums'))[0],
       'janes addiction|something|2011');
}

{
    # These identity tails already contain the service. Grouping by the complete logical key
    # must therefore leave same-named containers/media from different services independent.
    my $h = $mig->(sub {
        $ins->($_[0], source => 'qobuz', kind => 'playlist', album => "Today's Hits",
               key => '|today s hits||p:qobuz:77');
        $ins->($_[0], source => 'deezer', kind => 'playlist', album => "Today's Hits",
               key => '|today s hits||p:deezer:77');
        $ins->($_[0], source => 'spotify', kind => 'track', track => 'Trailer',
               key => '|trailer||e:spotify:spotify://episode:77');
        $ins->($_[0], source => 'deezerpodcast', kind => 'track', track => 'Trailer',
               key => '|trailer||e:deezerpodcast:deezerpodcast://77');
    });
    my $r = $h->selectall_arrayref('SELECT * FROM albums', { Slice => {} });
    is('playlist/episode source tails keep all four rows', scalar(@$r), 4);
}

{
    # '|u:' is the THIRD identity tail (2026-09-10) and it must behave like the other two: a
    # fold may change how the TITLE segment normalises, never the segment that says WHICH
    # recording this is. The row is a nameless track disambiguated by its play url; the
    # apostrophe in the title is what makes the fold act, so a rebuild instead of a
    # tail-preserve would be visible as a lost or altered tail rather than a no-op.
    my $h = $mig->(sub {
        $ins->($_[0], source => 'qobuz', kind => 'track', track => "Don't Look",
               key => "|don t look||u:qobuz:qobuz://999333.flac");
        $ins->($_[0], source => 'tidal', kind => 'track', track => "Don't Look",
               key => '|don t look||u:tidal:tidal://track:5');
    });
    my $rows = $h->selectall_arrayref('SELECT source, dedupe_key FROM albums ORDER BY source',
                                      { Slice => {} });
    is('a url tail keeps both services\' rows independent', scalar(@$rows), 2);
    is('...the qobuz tail survives the refold verbatim',
       $rows->[0]{dedupe_key}, '|dont look||u:qobuz:qobuz://999333.flac');
    is('...and the title segment IS refolded around it',
       (($rows->[0]{dedupe_key} =~ /^\|dont look\|/) ? 'refolded' : 'untouched'), 'refolded');
}

{
    # The same rule at the live carrier rather than the migration: a later artist backfill on
    # a url-keyed row must not rebuild it into a name key. Unreachable today (updateArtist's
    # callers sit behind _finishAlbumAdd, which only makes album rows), which is exactly why
    # it is asserted at _keyForRow instead of through a caller — the guard has to hold for the
    # first caller that ISN'T, which is how the 0.1.129 five-writer bug got in.
    my $keyed = Plugins::ListenLater::DB::_keyForRow({
        source => 'qobuz', kind => 'track', track_title => 'Untitled',
        artist => 'A Band Backfilled Later', album_title => 'An Album',
        dedupe_key => '|untitled||u:qobuz:qobuz://999333.flac',
        ref => { url => 'qobuz://999333.flac' },
    });
    is('a stored url tail wins over a rebuild, exactly as |e: and |p: do',
       $keyed, '|untitled||u:qobuz:qobuz://999333.flac');
}

section('4c3. RUNG 7 REPAIRS DATABASES THAT ALREADY STAMPED THE OLD REFOLD');
{
    # Editing rung 5 fixes released upgrades, but a development database may already have run
    # the old (source,key)-grouped implementation and stamped 5 or 6. Reproduce its surviving
    # state directly: the two services carry the exact same logical key.
    my $h = $mig->(sub { });
    $h->do('DELETE FROM albums');
    $h->do('PRAGMA user_version = 6');
    $ins->($h, source => 'qobuz', artist => 'Carrier Band', album => 'Carrier Album',
           year => 2024, key => 'carrier band|carrier album|2024', added => 100,
           ref_kind => 'album_id', ref_json => '{"_svc":"qobuz","album_id":"q7"}');
    $ins->($h, source => 'tidal', artist => 'Carrier Band', album => 'Carrier Album',
           year => 2024, key => 'carrier band|carrier album|2024', added => 200,
           count => 12, rel => 'album', ref_kind => 'album_id',
           ref_json => '{"_svc":"tidal","album_id":"t7"}');

    Plugins::ListenLater::DB::_migrate($h);
    my $r = $h->selectall_arrayref('SELECT * FROM albums', { Slice => {} });
    is('rung 7 collapses the exact cross-source twins', scalar(@$r), 1);
    is('...keeps the earliest replay source',          $r->[0]{source}, 'qobuz');
    is('...and that source\'s ref',
       JSON::XS->new->decode($r->[0]{ref_json})->{album_id}, 'q7');
    is('...without borrowing another service\'s count', $r->[0]{track_count}, undef);
    is('...and stamps the repair rung',
       ($h->selectrow_array('PRAGMA user_version'))[0], 9);

    # A different list choice remains a policy conflict even when the stored keys are already
    # identical. The repair completes (otherwise it would warn on every boot) but guesses none.
    $h->do('DELETE FROM albums');
    $h->do('PRAGMA user_version = 6');
    $ins->($h, source => 'qobuz', status => 'later', artist => 'Mixed Band', album => 'Same',
           key => 'mixed band|same|', added => 100);
    $ins->($h, source => 'tidal', status => 'played', artist => 'Mixed Band', album => 'Same',
           key => 'mixed band|same|', added => 200);
    Plugins::ListenLater::DB::_migrate($h);
    is('rung 7 leaves mixed-status twins visible',
       scalar(@{ $h->selectall_arrayref('SELECT id FROM albums') }), 2);
    is('...but still stamps the deliberate skip',
       ($h->selectrow_array('PRAGMA user_version'))[0], 9);

    # 0.1.139 — THE POLICY IS PER LIST, NOT PER GROUP. The pair above is the whole group, so
    # there is nothing to collapse and leaving both is right. Add a THIRD row and the two
    # halves come apart: two 'later' saves on different services are an ordinary duplicate the
    # user sees twice, and one 'played' row alongside them must not buy their survival.
    # Skipping wholesale strands them for good — the rung stamps either way.
    $h->do('DELETE FROM albums');
    $h->do('PRAGMA user_version = 6');
    $ins->($h, source => 'qobuz', status => 'later', artist => 'Three Ways',
           album => 'One Album', key => 'three ways|one album|', added => 100,
           ref_kind => 'album_id', ref_json => '{"album_id":"q1"}');
    $ins->($h, source => 'tidal', status => 'later', artist => 'Three Ways',
           album => 'One Album', key => 'three ways|one album|', added => 200,
           count => 12, ref_kind => 'album_id', ref_json => '{"album_id":"t1"}');
    $ins->($h, source => 'spotify', status => 'played', artist => 'Three Ways',
           album => 'One Album', key => 'three ways|one album|', added => 300,
           ref_kind => 'album_id', ref_json => '{"album_id":"s1"}');
    Plugins::ListenLater::DB::_migrate($h);
    my $mix = $h->selectall_arrayref(
        'SELECT status, source, track_count FROM albums ORDER BY added_at', { Slice => {} });
    is('a same-list subset still collapses inside a mixed group', scalar(@$mix), 2);
    is('...keeping the earliest save of that list',
       join(':', $mix->[0]{status}, $mix->[0]{source}), 'later:qobuz');
    is('...without borrowing the merged twin\'s regional count',
       $mix->[0]{track_count}, undef);
    is('...and the conflicting list is left exactly as it was',
       join(':', $mix->[1]{status}, $mix->[1]{source}), 'played:spotify');
    is('...with the rung stamped',
       ($h->selectrow_array('PRAGMA user_version'))[0], 9);

    # THE CONTROL for the count above: a rung-7 merge is not a merge that drops every column.
    # When the keeper carries NO replay bundle it adopts the loser's whole source/ref, and the
    # count then belongs to the service the survivor actually replays from, so it carries.
    #
    # Note what canNOT be seeded here: two rows on ONE service sharing one key. Every row in a
    # rung-7 group stores the SAME key, and UNIQUE(source, dedupe_key) makes that impossible —
    # which is exactly why splitting the group by status can never produce a collision. This
    # block asserted it before the constraint refused the insert.
    $h->do('DELETE FROM albums');
    $h->do('PRAGMA user_version = 6');
    $ins->($h, source => 'qobuz', status => 'later', artist => 'One Way',
           album => 'One Album', key => 'one way|one album|', added => 100);
    $ins->($h, source => 'tidal', status => 'later', artist => 'One Way',
           album => 'One Album', key => 'one way|one album|', added => 200,
           count => 12, ref_kind => 'album_id', ref_json => '{"album_id":"t1"}');
    Plugins::ListenLater::DB::_migrate($h);
    my $adopt = $h->selectall_arrayref(
        'SELECT source, track_count FROM albums', { Slice => {} });
    is('a keeper with no bundle adopts the loser\'s service', $adopt->[0]{source}, 'tidal');
    is('...and the count carries with it',                    $adopt->[0]{track_count}, 12);

    # A read failure is operational, not policy: keep 6 so the repair has a path to retry.
    $h->do('PRAGMA user_version = 6');
    {
        no warnings 'redefine';
        my $orig = \&DBI::db::selectall_arrayref;
        local *DBI::db::selectall_arrayref = sub {
            die "simulated rung-7 read failure\n" if ($_[1] // '') eq 'SELECT * FROM albums';
            goto &$orig;
        };
        Plugins::ListenLater::DB::_migrate($h);
    }
    is('a failed repair withholds rung 7',
       ($h->selectrow_array('PRAGMA user_version'))[0], 6);
    Plugins::ListenLater::DB::_migrate($h);
    is('the next start retries rung 7 and the ladder completes',
       ($h->selectrow_array('PRAGMA user_version'))[0], 9);
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

section('4h. A MERGE THAT CANNOT LAND TAKES NOTHING WITH IT');
{
    # The deletes have to precede the survivor's UPDATE (the new key would otherwise collide
    # with a row about to go), so on an AutoCommit handle a failed UPDATE used to leave the
    # losers committed away and the survivor on its stale key: a saved album and its play
    # history gone, silently. The collision needs no injected FAILURE — the UPDATE really does
    # hit UNIQUE(source, dedupe_key) — but the STATE is PLANTED: the squatter below is seeded
    # with a dedupe_key no fold could ever produce for its own artist/album. That is deliberate,
    # and it is what makes the test deterministic. Do not read it as evidence that stored data
    # reaches this state; it does not (Review Ledger A2, raised and withdrawn twice). What 4h
    # pins is the TRANSACTION — that a merge which cannot land takes nothing with it.
    my $h = $mig->(sub {
        my ($d) = @_;
        # The mixed-status pair: left alone, and one of them is squatting on the key the
        # pair below is about to claim.
        $ins->($d, status => 'later',  artist => 'Sigur Rós', album => 'Takk', year => 2005,
               key => 'janes addiction|ritual|1990', added => 10);
        $ins->($d, status => 'played', artist => 'Sigur Ros', album => 'Takk', year => 2005,
               key => 'sigur ros|takk|2005', added => 20);
        # The merge that will therefore fail: two spellings of one album, same status.
        $ins->($d, artist => "Jane's Addiction", album => 'Ritual', year => 1990,
               key => 'jane s addiction|ritual|1990', added => 100, play_count => 3);
        $ins->($d, artist => 'Janes Addiction', album => 'Ritual', year => 1990,
               key => 'janes addiction|ritual|1990x', added => 200,
               ref_kind => 'album_id', ref_json => '{"album_id":"z9"}');
    });
    my $r = $h->selectall_arrayref('SELECT * FROM albums ORDER BY added_at', { Slice => {} });
    is('nothing is deleted when the rekey cannot land', scalar(@$r), 4);
    is('the survivor keeps its old key',       $r->[2]{dedupe_key}, 'jane s addiction|ritual|1990');
    is('...and the loser is still there',      $r->[3]{dedupe_key}, 'janes addiction|ritual|1990x');
    is('...with its ref intact',               $r->[3]{ref_kind}, 'album_id');
    is('a failed group withholds the stamp',   ($h->selectrow_array('PRAGMA user_version'))[0], 4);

    # …and because the stamp was withheld, resolving the collision heals it at the next
    # start. A mixed-status skip on its own would NOT hold the ladder back like this.
    $h->do("UPDATE albums SET dedupe_key = 'sigur ros|takk|2005x' WHERE album_title = 'Takk'
             AND status = 'later'");
    Plugins::ListenLater::DB::_migrate($h);
    my $r2 = $h->selectall_arrayref("SELECT * FROM albums WHERE album_title = 'Ritual'",
                                    { Slice => {} });
    is('the retry merges the pair',            scalar(@$r2), 1);
    is('...under the folded key',              $r2->[0]{dedupe_key}, 'janes addiction|ritual|1990');
    is('...keeping the higher play count',     $r2->[0]{play_count}, 3);
    is('...and the loser\'s ref',              $r2->[0]{ref_kind}, 'album_id');
    is('...and now the ladder is stamped',     ($h->selectrow_array('PRAGMA user_version'))[0], 9);
}

section('4i. A ROLLBACK THAT FAILS MUST NOT POISON THE HANDLE');
{
    # begin_work turns AutoCommit OFF and only a COMPLETED commit/rollback turns it back on.
    # The failure branch logged a rollback that raised and carried on, leaving AutoCommit off on
    # a handle the migration neither owns nor closes. The migration itself is the small half of
    # that: every later begin_work dies "Already in a transaction" so the rest of the groups run
    # unwrapped, and every plugin write for the REST OF THE SERVER RUN joins a transaction
    # nothing ever commits — discarded at handle destruction, silently, hours later.
    # The failing group is 4h's planted collision, which needs no injected failure of its own;
    # only the rollback is injected, because DBD::SQLite will not fail one on demand.
    package RBFail;     our @ISA = ('DBI');
    package RBFail::st; our @ISA = ('DBI::st');
    package RBFail::db; our @ISA = ('DBI::db');
    our $BOOM = 0;
    sub rollback { my $s = shift; die "simulated rollback failure\n" if $BOOM; $s->SUPER::rollback(@_) }
    package main;

    my $f = "$dir/refold-rbfail-" . int(rand(1e9)) . '.db';
    my $h = DBI->connect("dbi:SQLite:dbname=$f", '', '',
        { RaiseError => 1, AutoCommit => 1, RootClass => 'RBFail' });
    Plugins::ListenLater::DB::_migrate($h);
    $h->do('PRAGMA user_version = 4');
    $h->do('DELETE FROM albums');
    # The squatter pair is deliberately ASCII, differing only by an apostrophe, rather than 4h's
    # "Sigur R\x{f3}s"/'Sigur Ros'. The whole scenario rests on those two rows landing in ONE
    # group so the mixed-status skip strands the squatter on the key the merge below wants; if
    # they group separately the squatter is simply rekeyed out of the way, no collision happens,
    # and the outcome then rides on `values %group` order — which is exactly what this test did,
    # passing and failing run to run, while the diacritic seed was in it. An apostrophe folds
    # identically whether the artist comes back from SQLite as octets or as characters, so the
    # grouping is not a variable here and the collision is guaranteed.
    $ins->($h, status => 'later',  artist => "Takk's Band", album => 'Takk', year => 2005,
           key => 'janes addiction|ritual|1990', added => 10);
    $ins->($h, status => 'played', artist => 'Takks Band', album => 'Takk', year => 2005,
           key => 'takks band|takk|2005', added => 20);
    $ins->($h, artist => "Jane's Addiction", album => 'Ritual', year => 1990,
           key => 'jane s addiction|ritual|1990', added => 100);
    $ins->($h, artist => 'Janes Addiction', album => 'Ritual', year => 1990,
           key => 'janes addiction|ritual|1990x', added => 200);

    $RBFail::db::BOOM = 1;
    eval { Plugins::ListenLater::DB::_migrate($h); 1 };
    $RBFail::db::BOOM = 0;

    is('AutoCommit is restored after a rollback that itself failed',
        ($h->{AutoCommit} ? 1 : 0), 1);
    is('...so a later transaction can still be opened',
        (eval { $h->begin_work; $h->rollback; 1 } ? 'opened' : 'died'), 'opened');

    # The damage that actually loses data is not in the migration at all — it is the next
    # ordinary write, which must reach the disk rather than join a transaction nothing commits.
    $h->do("INSERT INTO albums (status,kind,source,artist,album_title,dedupe_key,added_at)
            VALUES ('later','album','qobuz','After','Row','after|row|',300)");
    eval { $h->disconnect; 1 };
    my $h2 = DBI->connect("dbi:SQLite:dbname=$f", '', '', { RaiseError => 1, AutoCommit => 1 });
    is('...and a write made after the failure is durable, not discarded at shutdown',
        scalar(@{ $h2->selectall_arrayref("SELECT id FROM albums WHERE artist = 'After'") }), 1);
    is('the failed pass still withholds the ladder stamp',
        ($h2->selectrow_array('PRAGMA user_version'))[0], 4);
    $h2->disconnect;
}

section('4g. A FAILED PASS DOES NOT STAMP THE LADDER');
{
    # _migrateRefold reads the whole table in ONE select and bails if it cannot. Stamping
    # user_version anyway would retire the migration for good: every key stays on the OLD
    # fold, invisible to add()'s dedupe and to Played's lookups, and nothing ever runs to
    # fix them. The version is the only retry there is, so it is stamped on a COMPLETED
    # pass only — an empty table included (nothing to rewrite is a pass).
    my $h = $mig->(sub {
        $ins->($_[0], artist => "Jane's Addiction", album => 'Ritual', year => 1990,
               key => 'jane s addiction|ritual|1990');
    });
    # Put it back to where an upgrading user starts: old key, previous ladder height.
    $h->do("UPDATE albums SET dedupe_key = 'jane s addiction|ritual|1990'");
    $h->do('PRAGMA user_version = 4');

    {   # the one SELECT the refold makes fails
        no warnings 'redefine';
        my $orig = \&DBI::db::selectall_arrayref;
        local *DBI::db::selectall_arrayref = sub {
            die "simulated read failure\n" if ($_[1] // '') =~ /FROM albums/s;
            goto &$orig;
        };
        Plugins::ListenLater::DB::_migrate($h);
    }
    is('a failed refold leaves the version alone',
       ($h->selectrow_array('PRAGMA user_version'))[0], 4);
    is('...and the key is still the stale one',
       ($h->selectrow_array('SELECT dedupe_key FROM albums'))[0],
       'jane s addiction|ritual|1990');

    # …so the next start retries it, which is the whole point of not stamping.
    Plugins::ListenLater::DB::_migrate($h);
    is('the retry rekeys the row',
       ($h->selectrow_array('SELECT dedupe_key FROM albums'))[0],
       'janes addiction|ritual|1990');
    is('...and stamps the ladder',
       ($h->selectrow_array('PRAGMA user_version'))[0], 9);
}

# ---------------------------------------------------------------------------
section('4f. THE OCTET PATH KEYS THE SAME AS THE CHARACTER PATH');
# foldLatin accepts both, because Plugin.pm's request handlers take `artist` / `album`
# straight off `$request->getParam` and the raw CLI hands those over as OCTETS, while
# everything else (service JSON, SQLite with sqlite_unicode) is characters. Two callers,
# one UNIQUE column, so the two paths MUST agree.
#
# They did not. `lc` ran BEFORE the decode, and on a byte string `lc` is ASCII-only: an
# uppercase accented letter survived as bytes, decoded to an uppercase codepoint, and the
# `[^a-z0-9]` pass then DELETED it — 'SIGUR ROS' with the accent keyed 'sigur r s' from the
# CLI against 'sigur ros' from everywhere else. LOWERCASE input hid it completely (the fold
# is already lowercase, so both paths agreed), which is why a live Sigur Ros add looked fine.
sub oct_ { my $s = shift; utf8::encode($s); return $s }   # what the raw CLI delivers
sub dbo  { Plugins::ListenLater::DB::_norm(oct_($_[0])) }

for my $t ("Sigur R\x{f3}s", "SIGUR R\x{d3}S", "Bj\x{f6}rk", "BJ\x{d6}RK",
           "M\x{f6}tley Cr\x{fc}e", "M\x{d6}TLEY CR\x{dc}E") {
    is("octets key as characters do: $t", dbo($t), dbn($t));
}
is('and the uppercase octet form still folds to the plain key',
   dbo("SIGUR R\x{d3}S"), 'sigur ros');
is('...as does the uppercase ligature',  dbo("\x{c6}THER"),  'aether');
ok('the fold is not merely lowercasing the bytes',
   dbo("BJ\x{d6}RK") eq 'bjork');

# ---------------------------------------------------------------------------
section('4c4. RUNG 7 MUST NOT MERGE ROWS THE CURRENT FOLD TELLS APART');
# THE WORST BUG THIS FILE HAS CARRIED, and it was shipped by the release written to prevent
# it. Rung 7 groups by the STORED key and deletes every row in a group but one. That key was
# written under whatever fold was current at the time, so after a fold change it can be a
# collision the current fold does not make. 0.1.143 was exactly that change: before it _norm
# ERASED a non-Latin name, so three unrelated albums on three services all stored '||'.
#
# The ladder ran rung 7 BEFORE the new refold, so on a database sitting at 5 or 6 the merge
# deleted two real saves and the refold then had one row to split. MEASURED: three albums in,
# one out. Rung 8 cannot undo it — the rows are gone.
#
# The fix is a precondition on the DELETE rather than a reordering, because a reordering only
# holds for one ladder shape and this has to hold on every later retry too. Sections 4c2/4c3
# are the CONTROL for it: a genuine cross-source duplicate must still merge, or the guard has
# simply disabled rung 7. Both halves are asserted here as well, at versions 5 and 6, because
# those are the two the shipped ladder destroyed rows at.
for my $startVer (5, 6) {
    my $f = "$dir/rung7guard-$startVer-" . int(rand(1e9)) . '.db';
    my $h = DBI->connect("dbi:SQLite:dbname=$f", '', '',
                         { RaiseError => 1, AutoCommit => 1, sqlite_unicode => 1 });
    Plugins::ListenLater::DB::_migrate($h);
    $h->do('DELETE FROM albums');
    $h->do("PRAGMA user_version = $startVer");

    # Three unrelated albums, three services, one stored key — as 0.1.142 left them.
    my @seed = (
        ['qobuz',  "\x{4e2d}\x{5cf6}\x{307f}\x{3086}\x{304d}", "\x{6b4c}\x{59eb}"],
        ['tidal',  "\x{30b5}\x{30ab}\x{30ca}\x{30af}\x{30b7}\x{30e7}\x{30f3}",
                   "\x{65b0}\x{5b9d}\x{5cf6}"],
        ['deezer', "\x{041a}\x{0438}\x{043d}\x{043e}",
                   "\x{0413}\x{0440}\x{0443}\x{043f}\x{043f}\x{0430} \x{043a}\x{0440}\x{043e}\x{0432}\x{0438}"],
    );
    my $n = 0;
    $ins->($h, source => $_->[0], artist => $_->[1], album => $_->[2],
           key => '||', added => 100 + $n++) for @seed;

    Plugins::ListenLater::DB::_migrate($h);
    my $got = $h->selectall_arrayref('SELECT artist, dedupe_key FROM albums', { Slice => {} });
    is("from version $startVer: no non-Latin album is merged away", scalar(@$got), scalar(@seed));
    is("...and each ends on its own key",
       scalar(keys %{{ map { ($_->{dedupe_key} => 1) } @$got }}), scalar(@seed));
    is("...and none is left on the erased key", (grep { $_->{dedupe_key} eq '||' } @$got) ? 'still ||' : 'rekeyed',
       'rekeyed');
}
# THE CONTROL. A guard that refused every merge would pass all six assertions above, so this
# asserts the other direction: rows the current fold agrees about are still collapsed, even
# when their stored key is an erased one the fold no longer produces.
{
    my $f = "$dir/rung7guardctl-" . int(rand(1e9)) . '.db';
    my $h = DBI->connect("dbi:SQLite:dbname=$f", '', '',
                         { RaiseError => 1, AutoCommit => 1, sqlite_unicode => 1 });
    Plugins::ListenLater::DB::_migrate($h);
    $h->do('DELETE FROM albums');
    $h->do('PRAGMA user_version = 6');
    $ins->($h, source => 'qobuz', artist => 'Sigur Ros', album => 'Takk', year => 2005,
           key => 'sigur ros|takk|2005', added => 100);
    $ins->($h, source => 'tidal', artist => 'Sigur Ros', album => 'Takk', year => 2005,
           key => 'sigur ros|takk|2005', added => 101);
    Plugins::ListenLater::DB::_migrate($h);
    my $got = $h->selectall_arrayref('SELECT artist FROM albums', { Slice => {} });
    is('a genuine cross-source duplicate is STILL merged', scalar(@$got), 1);
}

# ---------------------------------------------------------------------------
section('4j. THE REFOLD RUNG (stamps 9 since 0.1.144) — the refold under a fold that no longer DELETES a non-Latin name');
# 0.1.143. Until then the key pass was `s/[^a-z0-9]+/ /g`, which does not fold 米津玄師 or
# Кино, it ERASES them — so their rows carry a key built from nothing and unrelated releases
# share it in a UNIQUE column. A stamped database never revisits rung 5, so the new fold needs
# its own rung, exactly as rung 7 needed one over rung 5's own repair.
#
# WHAT MAKES THIS RUNG CHEAP IS A PROPERTY OF THE FOLD, NOT OF THE MIGRATION: the new pass only
# stops deleting characters, so it can only SPLIT a group, never merge two. _migrateRefold's
# collision path — the expensive half of this file — is unreachable here. Both halves below
# are needed to say that: the rekey, and the Latin control that must NOT move.
{
    my $f = "$dir/rung8-" . int(rand(1e9)) . '.db';
    # sqlite_unicode, because PRODUCTION sets it (DB::dbh) and this section is about what a
    # NON-LATIN key reads back as. Without it the handle answers octets, the assertions below
    # compare bytes against characters, and a correct migration looks broken. The older
    # sections here predate any non-ASCII stored value, which is why they do not set it.
    my $h = DBI->connect("dbi:SQLite:dbname=$f", '', '',
                         { RaiseError => 1, AutoCommit => 1, sqlite_unicode => 1 });
    Plugins::ListenLater::DB::_migrate($h);
    $h->do('DELETE FROM albums');
    $h->do('PRAGMA user_version = 7');       # a database that already ran every earlier rung

    # Three unrelated releases as the OLD fold left them: artist and title both erased, so all
    # three hold the same key. Only one could ever have been stored through add() — the other
    # two were refused "already saved" — but a UNIQUE column is on (source,key), so two
    # SERVICES could each hold one, and rung 5 could leave a third behind. Seed them directly.
    $ins->($h, source => 'qobuz', artist => u("\x{7c73}\x{6d25}\x{7384}\x{5e2b}"),
           album => u("STRAY SHEEP"), year => 2020, key => '|stray sheep|2020', added => 100);
    $ins->($h, source => 'tidal', artist => u("\x{4e2d}\x{5cf6}\x{307f}\x{3086}\x{304d}"),
           album => u("\x{6b4c}\x{59eb}"), key => '||', added => 200);
    $ins->($h, source => 'deezer', artist => u("\x{41a}\x{438}\x{43d}\x{43e}"),
           album => u("\x{413}\x{440}\x{443}\x{43f}\x{43f}\x{430} \x{43a}\x{440}\x{43e}\x{432}\x{438}"),
           key => '||', added => 300);
    # ...and a punctuation-only act, which the \w pass alone does not reach.
    $ins->($h, source => 'qobuz', artist => '!!!', album => '!!!', year => 2004,
           key => '||2004', added => 400);

    Plugins::ListenLater::DB::_migrate($h);

    my $rows = $h->selectall_arrayref('SELECT * FROM albums ORDER BY added_at', { Slice => {} });
    is('the refold rung loses no row', scalar(@$rows), 4);
    is('...and stamps the ladder', ($h->selectrow_array('PRAGMA user_version'))[0], 9);
    is('a CJK artist is now IN the key',
       $rows->[0]{dedupe_key}, u("\x{7c73}\x{6d25}\x{7384}\x{5e2b}") . '|stray sheep|2020');
    is('an all-CJK row no longer keys as nothing',
       $rows->[1]{dedupe_key},
       u("\x{4e2d}\x{5cf6}\x{307f}\x{3086}\x{304d}|\x{6b4c}\x{59eb}") . '|');
    is('...and the Cyrillic row is its own key, not that one',
       $rows->[2]{dedupe_key},
       u("\x{43a}\x{438}\x{43d}\x{43e}|\x{433}\x{440}\x{443}\x{43f}\x{43f}\x{430} \x{43a}\x{440}\x{43e}\x{432}\x{438}") . '|');
    is('a punctuation-only act keeps its punctuation', $rows->[3]{dedupe_key}, '!!!|!!!|2004');
    is('...so all four keys are distinct',
       scalar(keys %{ { map { ($_->{dedupe_key} => 1) } @$rows } }), 4);

    # IDEMPOTENT — the rung is stamped, so a second start rewrites nothing.
    my @before = map { $_->{dedupe_key} } @$rows;
    Plugins::ListenLater::DB::_migrate($h);
    my $again = $h->selectall_arrayref('SELECT dedupe_key FROM albums ORDER BY added_at', { Slice => {} });
    is('a second start changes no key',
       join('~', map { $_->{dedupe_key} } @$again), join('~', @before));
}

section('4j2. …and a LATIN-ONLY library is rekeyed ZERO rows');
# THE CONTROL THAT MAKES THE RUNG AFFORDABLE, and it is not decoration: without it every
# assertion above would still pass against a fold that quietly moved every existing key, which
# is the one outcome a UNIQUE column cannot absorb. These keys are what the CURRENT fold
# produces, so if any of them moves, the "pure split" claim in _norm's header is false.
{
    my $f = "$dir/rung8latin-" . int(rand(1e9)) . '.db';
    my $h = DBI->connect("dbi:SQLite:dbname=$f", '', '',
                         { RaiseError => 1, AutoCommit => 1, sqlite_unicode => 1 });
    Plugins::ListenLater::DB::_migrate($h);
    $h->do('DELETE FROM albums');
    $h->do('PRAGMA user_version = 7');

    my @seed = (
        ['Sigur Ros',        'Takk',            2005, 'sigur ros|takk|2005'],
        ['Janes Addiction',  'Ritual',          1990, 'janes addiction|ritual|1990'],
        ['Chanel Beads',     'Album (Deluxe)',  2024, 'chanel beads|album deluxe|2024'],
        ['Fontaines DC',     '834.194',         2019, 'fontaines dc|834 194|2019'],
        ['The Band',         '100% Free',       2019, 'the band|100 free|2019'],
        # THE SHAPE THAT BROKE THIS CONTROL IN 0.1.143, and the reason the seeds above
        # could not catch it: every one of them separates words with a character that is
        # already non-\w, so the two substitutions in _norm commute and the order cannot
        # show. An underscore ADJACENT to other punctuation does not commute — with the
        # non-word pass first it stays \w, misses the run beside it and becomes an extra
        # space, keying '01_-_Intro' as '01   intro'. Ripped files are full of this.
        ['Boards_of_Canada', 'Music_-_Has_The_Right', 1998,
                                        'boards of canada|music has the right|1998'],
        ['Autechre',         '01_-_Intro',      1994, 'autechre|01 intro|1994'],
    );
    $ins->($h, artist => $_->[0], album => $_->[1], year => $_->[2], key => $_->[3],
           added => 100 + $_->[2]) for @seed;

    Plugins::ListenLater::DB::_migrate($h);
    my $got = $h->selectall_arrayref('SELECT album_title, dedupe_key FROM albums', { Slice => {} });
    my %want = map { ($_->[1] => $_->[3]) } @seed;
    my $moved = join(', ', map { "$_->{album_title} -> $_->{dedupe_key}" }
                           grep { ($want{ $_->{album_title} } // '') ne $_->{dedupe_key} } @$got);
    is('the refold rung moves no Latin key at all', ($moved || 'none moved'), 'none moved');
    is('...and every row is still there', scalar(@$got), scalar(@seed));
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
