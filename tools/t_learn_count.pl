#!/usr/bin/env perl
# Played::_learnTrackCount — the in-flight guard, and specifically its EXPIRY.
#
# The measure is what replaced guessing a release's length from its type, so everything
# downstream of Played depends on it eventually succeeding. It is asked once per release,
# guarded so a stubborn service isn't hammered — and that guard is the failure point:
# a request the service ACCEPTS AND NEVER ANSWERS runs none of our code, so a boolean flag
# would never be cleared and the release could never be measured again for the life of the
# server. It would then sit on the flat streaming_min_tracks floor permanently, which
# anything shorter than the floor can never reach — the exact bug the measure exists to fix,
# coming back through the measure's own failure route.
#
# Found by code review 2026-07-30 and confirmed against the pre-fix code, where cases 2-4
# below fail (the service is asked exactly once, ever, and nothing recovers it).
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

my $client = bless {}, 'FakeClient';
{ package FakeClient; sub id { 'aa:bb:cc' } sub playingSong { undef } }

my $rec = { id => 42, source => 'qobuz', kind => 'album', artist => 'adieu',
            album_title => 'Wanna me', rel_type => 'ep', ref => { album_id => 'x1' } };

# Count the asks. Nothing here answers, which is the whole point: this is the service that
# accepts the request and goes quiet.
my $asks = 0;
my $answer;                       # set to a coderef-arg to make the service reply instead
{
    no warnings 'redefine', 'once';
    *Plugins::ListenLater::Sources::resolveTracks = sub {
        my ($c, $r, $cb) = @_;
        $asks++;
        $cb->($answer) if $answer;
        return;
    };
}
my $learn = \&Plugins::ListenLater::Played::_learnTrackCount;

# ---------------------------------------------------------------------------
section('a service that never answers');

TestClock::reset();
$learn->($client, $rec, 'qobuz://1.flac');
is('first play asks the service', $asks, 1);

# Still in flight — asking again now would be the hammering the guard exists to prevent.
$learn->($client, $rec, 'qobuz://1.flac');
is('a second play moments later does NOT re-ask', $asks, 1);

TestClock::advance(30);
$learn->($client, $rec, 'qobuz://1.flac');
is('still held inside the window', $asks, 1);

# Past the window the request is presumed lost, and the NEXT play is what re-asks —
# rate-limited by the user pressing play, so no attempt counter is needed.
TestClock::advance(31);           # 61s total, past COUNT_STALE_SECS
$learn->($client, $rec, 'qobuz://1.flac');
is('once stale, a later play re-asks', $asks, 2);

# ...and it must not fail SILENTLY. Nothing ran when the request was lost, so this warn is
# the only record that it ever happened.
my $warned = grep { /never answered/ } Slim::Utils::Log::lines();
is('the lost request is logged, not swallowed', ($warned ? 1 : 0), 1);

# ---------------------------------------------------------------------------
section('a service that answers');

# Success clears the guard outright rather than waiting out the window — and in real use
# the row now has a stored count, so _onChange stops asking at all.
TestClock::reset();
Slim::Utils::Log::clear();
$asks = 0;
$answer = [ map { { type => 'audio', url => "qobuz://$_.flac" } } 1 .. 9 ];
my $rec2 = { %$rec, id => 43 };

$learn->($client, $rec2, 'qobuz://1.flac');
is('answered service was asked', $asks, 1);
$learn->($client, $rec2, 'qobuz://1.flac');
is('and is immediately re-askable, no window wait', $asks, 2);
is('an answered request logs no lost-request warning',
   (grep { /never answered/ } Slim::Utils::Log::lines()) ? 1 : 0, 0);

# ---------------------------------------------------------------------------
section('what the guard must NOT do');

# The guard is per RECORD. Two different releases playing on two players must not block
# each other — that would be one release silently costing another its measurement.
TestClock::reset();
$asks = 0;
$answer = undef;
$learn->($client, { %$rec, id => 44 }, 'qobuz://a.flac');
$learn->($client, { %$rec, id => 45 }, 'qobuz://b.flac');
is('a different record is asked independently', $asks, 2);

# A library release is counted live from the library and never stored, so it must never
# reach the service at all.
$asks = 0;
$learn->($client, { %$rec, id => 46, source => 'library' }, 'file:///a.flac');
is('a library release is never asked', $asks, 0);

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
