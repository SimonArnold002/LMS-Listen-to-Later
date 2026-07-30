#!/usr/bin/env perl
# Regression tests for the Played thresholds — the part of this plugin that has been
# broken and re-fixed most often, in both directions:
#
#   0.1.82  a single/short EP could NEVER reach Played (stuck under the 4-track floor)
#   0.1.83  a one-track release reached Played the INSTANT it started
#   0.1.88  a multi-track release wrongly typed 'single' reached Played after one track,
#           and a short streaming release still could never reach it at all
#
# Each is a one-line change away from coming back, and none of them is visible until a
# list quietly stops clearing or an album vanishes into Played after a skip. So the two
# decisions are pinned here: how many tracks a release is judged to HAVE
# (_totalTracks) and how many of them must be heard (_maybeMark's threshold).
use strict;
use warnings;
use FindBin;
require "$FindBin::Bin/t_stubs.pl";

ll_require('DB', 'Sources', 'Played');

my ($pass, $fail) = (0, 0);
sub is {
    my ($desc, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && "$got" eq "$want");
    $ok ? $pass++ : $fail++;
    printf "%s %-58s got=%-9s want=%s\n", ($ok ? 'ok  ' : 'FAIL'), $desc,
        (defined $got ? "'$got'" : '(undef)'), (defined $want ? "'$want'" : '(undef)');
}
sub section { printf "\n== %s\n", $_[0] }

my $total = \&Plugins::ListenLater::Played::_totalTracks;

# ---------------------------------------------------------------------------
section('_totalTracks — how many tracks the release is judged to have');

# A library album is counted LIVE from the library, never from a stored column: the
# library is the authority on itself and a rescan can change it.
$Slim::Schema::TRACK_COUNT = 11;
is('library album: counted live',
   $total->({ source => 'library', ref => { album_id => 7 } }), 11);
is('library album: a stale stored count is ignored',
   $total->({ source => 'library', ref => { album_id => 7 }, track_count => 3 }), 11);
is('library album with no id: unknown',
   $total->({ source => 'library', ref => {} }), undef);

# 0.1.88 — a resolved streaming release has a real total, so the percentage threshold
# applies to it exactly as to a library album.
is('0.1.88 streaming, resolved to 9',
   $total->({ source => 'qobuz', rel_type => 'album', track_count => 9 }), 9);
is('0.1.88 MIRROR: a ONE-track album has a total of 1',
   $total->({ source => 'qobuz', rel_type => 'album', track_count => 1 }), 1);
is('0.1.88 a stored count beats the type',
   $total->({ source => 'qobuz', rel_type => 'single', track_count => 4 }), 4);

# The release TYPE supplies NO total, in any direction. It is a bibliographic label from
# MusicBrainz or a service catalogue, not a count: MB calls a lead track plus B-sides a
# Single, and calls a 1-track release an EP (adieu - Wanna me, reported 2026-07-30). Both
# readings cost a real bug when a threshold was derived from them. A length is now only ever
# MEASURED — the library, or a resolved tracklist — and 0.1.82's rescue of a short release
# comes from measuring it on first play (Played::_learnTrackCount), not from its label.
is('a "single" with no measured count: unknown',
   $total->({ source => 'qobuz', rel_type => 'single' }), undef);
is('an "ep" with no measured count: unknown',
   $total->({ source => 'qobuz', rel_type => 'ep' }), undef);
is('a MEASURED 1-track release: total 1',
   $total->({ source => 'qobuz', rel_type => 'ep', track_count => 1 }), 1);
is('...whatever its label says',
   $total->({ source => 'qobuz', rel_type => 'single', track_count => 3 }), 3);

# Unresolved anything-else stays unknown → the floor applies (0.1.82 kept legacy rows
# on the floor deliberately; do not "helpfully" invent a total here).
is('unresolved album: unknown',
   $total->({ source => 'qobuz', rel_type => 'album' }), undef);
is('unresolved EP: unknown',
   $total->({ source => 'qobuz', rel_type => 'ep' }), undef);
is('legacy row, no type at all: unknown',
   $total->({ source => 'qobuz' }), undef);
is('a junk stored count is ignored',
   $total->({ source => 'qobuz', rel_type => 'album', track_count => 'x' }), undef);
is('a stored count of 0 is ignored',
   $total->({ source => 'qobuz', rel_type => 'album', track_count => 0 }), undef);

# ---------------------------------------------------------------------------
section('the threshold — how many of those tracks must actually be heard');
# CALLS the real arithmetic (Played::tracksNeeded) rather than restating it. It used to be
# mirrored here — the formula copied out alongside _maybeMark, on the grounds that _maybeMark
# needs %tracking and writes to the DB — but a copied formula passes just as happily when the
# original is wrong, which is the one thing this file exists to catch. tracksNeeded was split
# out of _maybeMark so the sum could be pinned directly.
Slim::Utils::Prefs::set_test_pref('played_threshold', 60);
Slim::Utils::Prefs::set_test_pref('streaming_min_tracks', 4);

sub need {
    my ($rec) = @_;
    my $t = $total->($rec);
    return Plugins::ListenLater::Played::tracksNeeded($t) if defined $t && $t > 0;
    return 4;   # the flat floor — NOT adjusted by release type any more (see below)
}

is('12-track album needs 7 (60%)',        need({ source=>'qobuz', track_count=>12 }), 7);
is('9-track album needs 5',               need({ source=>'qobuz', track_count=>9  }), 5);
is('0.1.88 5-track album needs 3, not 4', need({ source=>'qobuz', track_count=>5  }), 3);
is('0.1.88 3-track album needs 2, not 4', need({ source=>'qobuz', track_count=>3  }), 2);
is('0.1.88 1-track album needs 1, not 4', need({ source=>'qobuz', track_count=>1  }), 1);
is('a MEASURED 1-track release needs 1',  need({ source=>'qobuz', rel_type=>'ep', track_count=>1 }), 1);
# The EP floor cap is GONE. Dropping the floor to 2 for an 'ep' reads as helpful and was the
# direct cause of the reported bug: a 1-track release MB labels an EP still cannot reach 2.
# A smaller wrong guess is not better than a bigger one — measure instead.
is('an unmeasured "ep" keeps the 4 floor',need({ source=>'qobuz', rel_type=>'ep' }), 4);
is('unmeasured album keeps the 4 floor',  need({ source=>'qobuz', rel_type=>'album' }), 4);
is('legacy untyped row keeps the 4 floor',need({ source=>'qobuz' }), 4);
# When the length is unknown the floor may be unreachable, and that is the SAFE direction:
# failing to mark is recoverable, but marking wrongly moves the row to Played and auto-tidy
# then deletes it. Uncertainty must never destroy a saved row.
is('unmeasured 1-track release is NOT marked early',
   (need({ source=>'qobuz', rel_type=>'ep' }) > 1 ? 'waits' : 'marks'), 'waits');
$Slim::Schema::TRACK_COUNT = 10;
is('library 10-track album needs 6',      need({ source=>'library', ref=>{album_id=>1} }), 6);

# ---------------------------------------------------------------------------
section('the threshold at 90% — the default since 2026-07-30');
# Once a release's length is MEASURED rather than guessed from its type, 60% was a hedge
# against a number we only half-trusted, and there is nothing left to hedge against.
#
# Rounding DOWN is what makes 90% usable at all. ceil() would demand every track of any
# release under ten (0.9*N > N-1 for N < 10, so it rounds back up to N), and one skipped or
# region-blocked track would then make a release permanently unmarkable. These are the exact
# numbers that difference turns on — pin them, because "90%" reads harmless and isn't.
Slim::Utils::Prefs::set_test_pref('played_threshold', 90);

is('90%: 12 tracks needs 10',   Plugins::ListenLater::Played::tracksNeeded(12), 10);
is('90%: 10 tracks needs 9',    Plugins::ListenLater::Played::tracksNeeded(10), 9);
is('90%: 9 tracks needs 8, NOT 9 (ceil would say 9)',
                                Plugins::ListenLater::Played::tracksNeeded(9),  8);
is('90%: 5 tracks needs 4, NOT 5',
                                Plugins::ListenLater::Played::tracksNeeded(5),  4);
is('90%: 3 tracks needs 2',     Plugins::ListenLater::Played::tracksNeeded(3),  2);

# The guard that keeps rounding down from re-opening 0.1.83: floor(0.9*2) is 1, and "1 of 2
# seen" is true on the first newsong — so a 2-track release would be marked the instant it
# started, then auto-purged days later. A multi-track release must always need at least two.
is('90%: 2 tracks needs 2, never 1',
                                Plugins::ListenLater::Played::tracksNeeded(2),  2);
is('60%: 2 tracks needs 2 as well',
   do { Slim::Utils::Prefs::set_test_pref('played_threshold', 60);
        Plugins::ListenLater::Played::tracksNeeded(2) }, 2);
is('even at 10%, a 2-track release still needs both',
   do { Slim::Utils::Prefs::set_test_pref('played_threshold', 10);
        Plugins::ListenLater::Played::tracksNeeded(2) }, 2);
# A 1-track release never reaches this path (it takes _armDeferredMark's played-through
# check), but if it ever did it must ask for its one track, not zero.
is('a 1-track total still asks for 1, not 0',
                                Plugins::ListenLater::Played::tracksNeeded(1),  1);
Slim::Utils::Prefs::set_test_pref('played_threshold', 60);

# ---------------------------------------------------------------------------
section('0.1.83 — anything complete after ONE track must not mark when it STARTS');
# The routing rule in _onChange: total==1 bypasses the distinct-track counter entirely
# and takes the deferred played-through check (90% of the track). If this stops being
# true, skipping past a saved single marks it Played and auto-purge deletes it later.
sub routes_deferred { my $t = $total->($_[0]); return (defined $t && $t == 1) ? 'deferred' : 'counter' }

is('a MEASURED 1-track release takes the played-through route',
   routes_deferred({ source=>'qobuz', rel_type=>'single', track_count=>1 }), 'deferred');
is('...and an UNmeasured one cannot yet (nothing to route on)',
   routes_deferred({ source=>'qobuz', rel_type=>'single' }), 'counter');
is('0.1.88 a 1-track ALBUM takes it too',
   routes_deferred({ source=>'qobuz', rel_type=>'album', track_count=>1 }), 'deferred');
$Slim::Schema::TRACK_COUNT = 1;
is('a 1-track library release takes it too',
   routes_deferred({ source=>'library', ref=>{album_id=>1} }), 'deferred');
$Slim::Schema::TRACK_COUNT = 11;
is('a real album takes the counter route',
   routes_deferred({ source=>'library', ref=>{album_id=>1} }), 'counter');
is('a 3-track release takes the counter route',
   routes_deferred({ source=>'qobuz', rel_type=>'ep', track_count=>3 }), 'counter');
is('an unresolved release takes the counter route',
   routes_deferred({ source=>'qobuz', rel_type=>'album' }), 'counter');

is('0.1.83 played-through fraction is still 90%',
   Plugins::ListenLater::Played::TRACK_MARK_FRACTION(), 0.9);
is('0.1.83 no-duration fallback is still 60s',
   Plugins::ListenLater::Played::TRACK_MARK_FALLBACK_SECS(), 60);

# ---------------------------------------------------------------------------
section('_learnTrackCount — measuring a release at the moment it starts playing');
# This is what replaced guessing from the label. A streaming row arrives with no measured
# length (the count comes only from the service, and the add must not wait on one), so the
# first play is where we ask.
{
    my (@asked, @stored, $answer);
    no warnings qw(redefine once);
    local *Plugins::ListenLater::Sources::resolveTrackCount = sub {
        my ($cl, $rec, $cb) = @_;
        push @asked, $rec->{id};
        $cb->($answer) if defined $answer;      # undef = a service that never answers
    };
    local *Plugins::ListenLater::DB::updateTrackCount = sub { push @stored, [ @_[0,1] ] };
    my $client = bless {}, 'FakeClient';
    sub FakeClient::id         { 'aa:bb:cc:dd:ee:ff' }
    sub FakeClient::playingSong { undef }
    my $learn  = \&Plugins::ListenLater::Played::_learnTrackCount;

    $answer = 11;
    $learn->($client, { id => 7, source => 'qobuz' }, 'qobuz://a.flac');
    is('it asks the service',            scalar @asked, 1);
    is('...and stores what came back',   ($stored[0] ? $stored[0][1] : '-'), 11);
    is('...against the right record',    ($stored[0] ? $stored[0][0] : '-'), 7);

    # A library release is counted live from the library and must never be asked for.
    @asked = @stored = ();
    $learn->($client, { id => 8, source => 'library' }, 'file:///x.flac');
    is('a library row is never asked',   scalar @asked, 0);

    # Fired once per record while in flight — an album fires this on its FIRST track only,
    # but the guard is what stops a slow service being asked again and again.
    @asked = ();
    $answer = undef;                             # never calls back → stays in flight
    $learn->($client, { id => 9, source => 'qobuz' }, 'qobuz://b.flac');
    $learn->($client, { id => 9, source => 'qobuz' }, 'qobuz://b.flac');
    $learn->($client, { id => 9, source => 'qobuz' }, 'qobuz://b.flac');
    is('a pending measure is not repeated', scalar @asked, 1);

    # A measure that comes back empty must not be stored as a length, and must say so.
    @asked = @stored = (); $answer = undef;
    Slim::Utils::Log::clear();
    local *Plugins::ListenLater::Sources::resolveTrackCount = sub { $_[2]->(undef) };
    $learn->($client, { id => 10, source => 'qobuz' }, 'qobuz://c.flac');
    is('an unanswered measure stores nothing', scalar @stored, 0);
    is('...and is not silent',
       ((join ' ', Slim::Utils::Log::lines()) =~ /couldn't measure/ ? 'logged' : 'SILENT'), 'logged');
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
