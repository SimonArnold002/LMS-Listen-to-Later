#!/usr/bin/env perl
# Regression tests for release-type classification (Sources.pm) — the 0.1.88 rule and
# the decision table around it.
#
# The rule: a type a SOURCE ASSERTS wins, EXCEPT a 'single' contradicted by a real track
# count. MusicBrainz (via the ListenBrainz plugin's '&rt=' handshake) and Qobuz's own
# release_type both call a release a Single when it holds a lead track plus B-sides or
# remixes; LL's 'single' means "exactly ONE track" and Played acts on that. So a claimed
# single must be checked against what the release actually contains.
#
# Note what a demotion goes TO: the count's own verdict (2-6 = ep, 7+ = album), NOT
# unconditionally 'ep'. Calling a 9-track release an EP would re-run the same early-mark
# bug against the EP's 2-track floor.
use strict;
use warnings;
use FindBin;
require "$FindBin::Bin/t_stubs.pl";

ll_require('DB', 'Sources');
my $S = 'Plugins::ListenLater::Sources';

my ($pass, $fail) = (0, 0);
sub is {
    my ($desc, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && "$got" eq "$want");
    $ok ? $pass++ : $fail++;
    printf "%s %-56s got=%-9s want=%s\n", ($ok ? 'ok  ' : 'FAIL'), $desc,
        (defined $got ? "'$got'" : '(undef)'), (defined $want ? "'$want'" : '(undef)');
}
sub section { printf "\n== %s\n", $_[0] }

my $rt = \&Plugins::ListenLater::Sources::relTypeFor;
my $wrong = \&Plugins::ListenLater::Sources::singleIsWrong;

# ---------------------------------------------------------------------------
section('singleIsWrong — is a claimed single contradicted by the count?');
is('single + 1 track: consistent',        $wrong->('single', 1), 0);
is('single + 2 tracks: contradicted',     $wrong->('single', 2), 1);
is('single + 3 tracks: contradicted',     $wrong->('single', 3), 1);
is('single + no count: nothing to go on', $wrong->('single', undef), 0);
is('single + 0: not a count',             $wrong->('single', 0), 0);
is('ep is never contradicted here',       $wrong->('ep', 5), 0);
is('album is never contradicted here',    $wrong->('album', 1), 0);
is('no claim, nothing to contradict',     $wrong->(undef, 3), 0);

# ---------------------------------------------------------------------------
section('relTypeFor — the asserted type wins, except a disproved single');
is('MB Single, really 1 track',           $rt->(service => 'Single', count => 1), 'single');
is('MB Single, 3 tracks -> ep',           $rt->(service => 'Single', count => 3), 'ep');
is('MB Single, 6 tracks -> ep',           $rt->(service => 'single', count => 6), 'ep');
is('MB Single, 9 tracks -> ALBUM not ep', $rt->(service => 'single', count => 9), 'album');
is('MB Single, no count: claim stands',   $rt->(service => 'single'), 'single');
is('MB Single, 0 count: claim stands',    $rt->(service => 'single', count => 0), 'single');
is('MB EP + 1 track stays an EP',         $rt->(service => 'EP', count => 1), 'ep');
is('MB Album + 2 tracks stays an album',  $rt->(service => 'Album', count => 2), 'album');
is('MB Album + 1 track stays an album',   $rt->(service => 'Album', count => 1), 'album');

section('relTypeFor — with no assertion, the count classifies');
is('1 track  -> single',                  $rt->(count => 1),  'single');
is('2 tracks -> ep',                      $rt->(count => 2),  'ep');
is('6 tracks -> ep',                      $rt->(count => 6),  'ep');
is('7 tracks -> album',                   $rt->(count => 7),  'album');
is('nothing known -> unclassified',       $rt->(),            undef);
is('a junk count -> unclassified',        $rt->(count => 'x'), undef);
is('an unmappable word + count',          $rt->(service => 'Broadcast', count => 3), 'ep');

# ---------------------------------------------------------------------------
section('classifyRelType — one resolve settles both type and count');
# resolveTracks is the only outside call; replace it so the decision logic is what's
# under test. Also counts the calls: the Qobuz path must not fetch a tracklist when the
# album object already states a count.
my @LIST;
my $resolves = 0;
{
    no warnings 'redefine';
    *Plugins::ListenLater::Sources::resolveTracks = sub {
        my (undef, undef, $cb) = @_; $resolves++; $cb->([@LIST]);
    };
}
my $tracks = sub { [ map { { type => 'audio', url => "x$_" } } 1 .. $_[0] ] };

sub classify {
    my ($source, $albumId, $items, $claim) = @_;
    @LIST = @$items; $resolves = 0;
    my ($type, $count);
    $S->can('classifyRelType')->(undef, $source, $albumId, {},
        sub { ($type, $count) = @_ }, $claim);
    return ($type, $count, $resolves);
}

my ($t, $c, $r) = classify('tidal', 'aid', $tracks->(3), 'Single');
is('claimed single, 3 resolved -> ep',    $t, 'ep');
is('...and the count comes back',         $c, 3);
my ($t2, $c2) = classify('tidal', 'aid', $tracks->(1), 'Single');
is('claimed single, 1 resolved -> single', $t2, 'single');
my ($t3, $c3) = classify('tidal', 'aid', $tracks->(1), 'Album');
is('MIRROR: claimed album, 1 resolved',   $t3, 'album');
is('...with a total of 1 (was unknown)',  $c3, 1);
my ($t4, $c4) = classify('tidal', 'aid', [], 'Single');
is('nothing resolves: claim stands',      $t4, 'single');
is('...and no count is invented',         $c4, undef);
my ($t5, $c5) = classify('tidal', 'aid', $tracks->(5), undef);
is('no claim: the count classifies',      $t5, 'ep');
my ($t6, $c6) = classify('tidal', 'aid',
    [ { type => 'text', name => 'Download album from…' },
      { weblink => 1, name => 'page' }, @{ $tracks->(2) } ], 'Album');
is('service helper rows are not tracks',  $c6, 2);

# The Qobuz shortcut: its album object states release_type AND tracks_count, so both
# answers come from the one fetch and no tracklist is resolved.
our $ALBUM;
{
    package Plugins::Qobuz::API;
    sub getAlbum { my ($s, $cb, $id) = @_; $cb->($main::ALBUM) }
    package Plugins::Qobuz::Plugin;
    sub getAPIHandler { return bless {}, 'Plugins::Qobuz::API' }
}
my $lastYear;
sub qobuz {
    my ($album, $claim, $fallback) = @_;
    $ALBUM = $album; @LIST = @{ $fallback || [] }; $resolves = 0;
    my ($type, $count, $prov);
    $lastYear = undef;
    $S->can('classifyRelType')->(undef, 'qobuz', 'aid', {},
        sub { ($type, $count, $prov, $lastYear) = @_ }, $claim);
    return ($type, $count, $resolves, $prov);
}
my ($q1, $qc1, $qr1, $qp1) = qobuz({ release_type => 'single', tracks_count => 4 }, undef, $tracks->(4));
is('Qobuz single/4 -> ep',                 $q1, 'ep');
is('...count is the RESOLVED one',         $qc1, 4);
is('...so the tracklist WAS resolved',     $qr1, 1);
my ($q2, $qc2, $qr2) = qobuz({ release_type => 'single', tracks_count => 4 }, 'Album');
is('an MB claim outranks release_type',    $q2, 'album');
my ($q3, $qc3, $qr3, $qp3) = qobuz({ release_type => 'album' }, 'Album', $tracks->(3));
is('no tracks_count -> falls back',        $q3, 'album');
is('...by resolving once',                 $qr3, 1);

# ---------------------------------------------------------------------------
section('a CATALOGUE count is PROVISIONAL — it settles the type, never the total');
# Qobuz's tracks_count describes the release, not your account: region/licensing gaps drop
# tracks from the TRACKLIST but not from the album object, so it can only ever be >= what's
# playable. Thresholding on it made a 12-track catalogue entry with 5 playable tracks need
# ceil(60% of 12) = 8 — unreachable, and worse than the 4-track floor it replaced. So the
# third callback value flags it, and the caller must not store it (Plugin::_verifyRelease,
# _classifyThenAdd). The flag is the ONLY thing that keeps that decision honest.
is('resolved count NOT flagged',           $qp3, 0);

my ($q4, $qc4, $qr4, $qp4) = qobuz({ release_type => 'album', tracks_count => 12 }, undef);
is('a 12-track catalogue album',           $q4,  'album');
is('...count returned',                    $qc4, 12);
is('...flagged provisional (not a total)', $qp4, 1);
is('...and NO tracklist fetched',          $qr4, 0);

# ---------------------------------------------------------------------------
section('a provisional count may LOWER the Played bar, never RAISE it');
# The one use that raises it is demoting a claimed 'single': a single needs 1 track, an EP
# with no stored total needs 2. If the catalogue figure is inflated — it says 3, the region
# serves 1 — that release could never be marked at all, where 0.1.87 marked it. So THAT case
# is not decided on the catalogue count: it resolves the real tracklist and gets both the
# true count and a type settled from it. Everything else keeps the zero-call path.
my ($d1, $dc1, $dr1, $dp1) = qobuz({ release_type => 'single', tracks_count => 3 }, undef, $tracks->(3));
is('a contradicted single RESOLVES',       $dr1, 1);
is('...demoted on the REAL count',         $d1,  'ep');
is('...which is a real total, storable',   $dp1, 0);
is('...and is the resolved count',         $dc1, 3);

# The catalogue said 3; the region actually serves 1. Resolving is what catches that — and
# 'single' with a true count of 1 is correct, so it keeps its total of 1 and can be marked.
my ($d2, $dc2, $dr2, $dp2) = qobuz({ release_type => 'single', tracks_count => 3 }, undef, $tracks->(1));
is('inflated catalogue count is caught',   $dc2, 1);
is('...so it stays a single',              $d2,  'single');
is('...not an unreachable ep',             ($d2 eq 'ep' ? 'REGRESSION' : 'ok'), 'ok');

# A count that AGREES with the claim never needs proving.
my ($d3, undef, $dr3, $dp3) = qobuz({ release_type => 'single', tracks_count => 1 }, undef);
is('an uncontradicted single: no resolve', $dr3, 0);
is('...still provisional',                 $dp3, 1);
is('...and still a single',                $d3,  'single');

# Non-Qobuz services never produce a provisional count: their getAlbum IS the tracklist, so
# what they return has already been region-filtered.
$ALBUM = undef; @LIST = @{ $tracks->(9) }; $resolves = 0;
my ($tt, $tc, $tp);
$S->can('classifyRelType')->(undef, 'tidal', 'aid', {}, sub { ($tt, $tc, $tp) = @_ }, undef);
is('Tidal: count from the tracklist',      $tc, 9);
is('...never provisional',                 $tp, 0);

# ---------------------------------------------------------------------------
section('the release YEAR comes back off the same album object');
# A plain streaming browse row carries no year — only the siblings' '&y=' handshake and
# Material's Now Playing "Album (YYYY)" label supply one, so ~1 in 5 saved rows had none.
# Qobuz is the one service whose ID call returns an album OBJECT rather than a tracklist, and
# that object states the date, so it is free on a fetch already being made. It matters beyond
# display: the year is part of the dedupe key, so a yearless row can be duplicated by a later
# add that has one.
qobuz({ release_type => 'album', tracks_count => 9, release_date_original => '2026-06-12' }, undef);
is('year read from release_date_original', $lastYear, 2026);

qobuz({ release_type => 'album', tracks_count => 9, release_date_stream => '2019-01-30' }, undef);
is('...or release_date_stream',            $lastYear, 2019);
qobuz({ release_type => 'album', tracks_count => 9, release_date => '1971-11-08' }, undef);
is('...or release_date',                   $lastYear, 1971);

# An epoch 'released_at' is CONVERTED, not pattern-matched (changed 2026-07-30). It used to
# yield nothing, on the correct reasoning that mining a digit run for something that looks
# like a year gives nonsense — 1767225600 must never become "1767". But refusing it outright
# meant an album object stating ONLY the epoch produced no year at all, which is precisely
# what Pitchfork Reviews was getting right and this plugin wasn't. serviceYear converts it
# through localtime and sanity-bounds the result, so the digit-mining hazard stays closed.
qobuz({ release_type => 'album', tracks_count => 9, released_at => 1767225600 }, undef);
is('an epoch date is converted, not mined', $lastYear, 2026);
qobuz({ release_type => 'album', tracks_count => 9 }, undef);
is('no date at all yields no year',        ($lastYear || '(none)'), '(none)');

# Sources::serviceYear — the reader itself, across every spelling the four services use.
# Taking the HASH rather than a hand-picked field or two is the whole point: the earlier
# version asked for three Qobuz keys by name, so a service that spells it differently, or an
# object carrying only the epoch, silently produced nothing. Ported from PFR's _svcYear so
# the two plugins read a service identically — they were disagreeing, and that difference was
# the entire reason native adds lost their years while PFR's kept them.
my $sy = $S->can('serviceYear');
is('Qobuz release_date_original', $sy->({ release_date_original => '2026-07-10' }), 2026);
is('Qobuz release_date_stream',   $sy->({ release_date_stream   => '2019-01-05' }), 2019);
is('Qobuz release_date',          $sy->({ release_date          => '1998-05-26' }), 1998);
is('Qobuz epoch released_at',     $sy->({ released_at => 1767225600 }),              2026);
is('TIDAL releaseDate',           $sy->({ releaseDate => '2025-03-01' }),            2025);
is('TIDAL streamStartDate',       $sy->({ streamStartDate => '2024-11-08T00:00' }),  2024);
is('Deezer release_date',         $sy->({ release_date => '2019-02-22' }),           2019);
is('a bare year field',           $sy->({ year => 2011 }),                           2011);
# Precedence: the ORIGINAL release date wins over the streaming one, so a reissue keeps the
# year it was actually made rather than the year it reached the service.
is('original beats stream date',
   $sy->({ release_date_original => '1971-06-01', release_date_stream => '2015-09-09' }), 1971);
is('nothing usable yields empty',  $sy->({ title => 'x' }), '');
is('a non-hash yields empty',      $sy->('2026-01-01'),     '');
# A junk epoch must not produce a year from the far future/past rather than admitting defeat.
is('an out-of-range epoch is refused', $sy->({ released_at => 99999999999 }), '');

# Sources::libraryAlbumYear — the LOCAL half of the same problem. Material's custom action
# has no $YEAR variable at all, so a library album added from a Material menu arrived with no
# year while the same album added from the info-provider menu (which does send one) got it —
# the two then keyed differently and could not dedupe. The library always knows.
my $ly = $S->can('libraryAlbumYear');
$Slim::Schema::ALBUM_YEAR = 1994;
is('library year read from the album row', $ly->(42), 1994);
is('a non-numeric album id is refused',    $ly->('abc'), '');
is('no album id is refused',               $ly->(undef), '');
$Slim::Schema::ALBUM_YEAR = undef;                      # album not found
is('an unknown album yields empty',        $ly->(42), '');
$Slim::Schema::ALBUM_YEAR = 0;                          # LMS stores 0 for "no year"
is('a library year of 0 is not a year',    $ly->(42), '');

# It must survive the path that gives up on the object count and resolves the tracklist —
# the year came off the object either way and must not be dropped on the floor.
qobuz({ release_type => 'single', tracks_count => 3, release_date_original => '2026-02-02' },
      undef, $tracks->(3));
is('year survives the resolve fallback',   $lastYear, 2026);
qobuz({ release_type => 'album', release_date_original => '2024-09-09' }, 'Album', $tracks->(5));
is('...and the no-count fallback',         $lastYear, 2024);

# Non-Qobuz services return a tracklist, not an album object — no year to be had.
$ALBUM = undef; @LIST = @{ $tracks->(4) }; $resolves = 0;
my $ty;
$S->can('classifyRelType')->(undef, 'tidal', 'aid', {}, sub { $ty = $_[3] }, undef);
is('tidal offers no year',                 ($ty || '(none)'), '(none)');

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
