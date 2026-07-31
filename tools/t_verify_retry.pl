#!/usr/bin/env perl
# Regression tests for the release-verify retry (Plugin.pm, 0.1.90).
#
# Why it exists: a claimed 'single' is stored at insert and corrected a moment later by
# _verifyRelease. If that check fails — service briefly unreachable — the unverified
# claim STANDS, Played reads 'single' as a real total of 1, and the release is marked
# heard after one of its tracks and auto-purged days later. That is the bug 0.1.88 set
# out to fix, so a transient outage must not reinstate it. Before 0.1.90 the failure was
# also completely silent.
#
# What must hold, and is easy to get wrong:
#   • it retries — otherwise the hole stays open
#   • it retries EXACTLY ONCE — an unbounded retry would hammer the service, which is far
#     worse than the bug
#   • the retry re-reads the row, so a removed row or one already resolved by a
#     drill/play (Browse::_albumTracks stores the count) is left alone
#   • the timer body is a NAMED sub, so setTimer/killTimers pair on one coderef and a
#     re-arm cannot build a self-referencing closure chain (the 0.1.83 lesson)
use strict;
use warnings;
use FindBin;
require "$FindBin::Bin/t_stubs.pl";

ll_require('DB', 'Sources', 'Podcast', 'Browse', 'Plugin');
my $P = 'Plugins::ListenLater::Plugin';

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

my $client = bless {}, 'FakeClient';
sub FakeClient::id { 'aa:bb:cc:dd:ee:ff' }

my $arm  = \&Plugins::ListenLater::Plugin::_armVerifyRetry;
my $tick = \&Plugins::ListenLater::Plugin::_verifyRetryTick;
my $rec  = sub { { id => 42, rel_type => 'single', @_ } };

sub armed_after {
    my (@args) = @_;
    Slim::Utils::Timers::clear();
    Slim::Utils::Log::clear();
    $arm->(@args);
    return Slim::Utils::Timers::armed();
}

# ---------------------------------------------------------------------------
section('it retries, exactly once');
my @a = armed_after($client, 42, $rec->(), 'deezer', 'aid', 1);
is('a first failure arms a retry',          scalar @a, 1);
is('...carrying attempt 2',                 ($a[0]{args}[0]{attempt} // '-'), 2);
is('...carrying the record id',             ($a[0]{args}[0]{recId} // '-'), 42);
is('...and the album id to re-check',       ($a[0]{args}[0]{albumId} // '-'), 'aid');
is('...targeting the NAMED tick sub',       (($a[0]{cb} // 0) == $tick ? 'yes' : 'no'), 'yes');

my @b = armed_after($client, 42, $rec->(), 'deezer', 'aid', 2);
is('the retry failing arms NOTHING',        scalar @b, 0);
my @c = armed_after($client, 42, $rec->(), 'deezer', 'aid', 99);
is('an already-high attempt gives up',      scalar @c, 0);
my @d = armed_after($client, 42, $rec->(), 'deezer', 'aid', undef);
is('a missing attempt counts as the first', scalar @d, 1);

# ---------------------------------------------------------------------------
section('giving up is never silent');
armed_after($client, 42, $rec->(), 'deezer', 'aid', 2);
my @lines = Slim::Utils::Log::lines();
is('the give-up logs a line',               (scalar @lines ? 'yes' : 'no'), 'yes');
is('...naming the record',                  ((join ' ', @lines) =~ /\b42\b/ ? 'yes' : 'no'), 'yes');
is('...and the type it is keeping',         ((join ' ', @lines) =~ /single/  ? 'yes' : 'no'), 'yes');
armed_after($client, 42, $rec->(), 'deezer', 'aid', 1);
is('arming a retry logs it too',            (scalar Slim::Utils::Log::lines() ? 'yes':'no'), 'yes');

# ---------------------------------------------------------------------------
section('the retry re-reads the row before doing anything');
sub tick_with {
    my ($row, $args) = @_;
    no warnings 'redefine';
    local *Plugins::ListenLater::DB::get = sub { $row };
    Slim::Utils::Timers::clear();
    $tick->($client, $args // { recId => 42, source => 'deezer', albumId => 'aid', attempt => 2 });
    return Slim::Utils::Timers::armed();
}
is('a row already resolved is left alone',
   scalar tick_with({ id => 42, track_count => 9, rel_type => 'single' }), 0);
is('a removed row is left alone',
   scalar tick_with(undef), 0);
is('junk args cannot crash the timer',
   (eval { tick_with({ id => 42 }, undef); $tick->($client, undef); $tick->($client, {}); 1 } ? 'ok' : 'died'), 'ok');

# ---------------------------------------------------------------------------
section('what _verifyRelease does with each kind of answer');
# The three outcomes must stay distinct. A PROVISIONAL count (Qobuz's catalogue
# tracks_count) is an ANSWER — the service replied — so it must not retry; but it is not a
# playable total, so it must not be stored either. Conflating "provisional" with "no answer"
# would spend a pointless retry on every Qobuz add and then log a failure that never was.
our @YEARS;
sub verify_with {
    my ($type, $count, $prov, %o) = @_;
    my (@stored, @typed);
    @YEARS = ();
    no warnings 'redefine';
    local *Plugins::ListenLater::Sources::classifyRelType = sub {
        my ($cl, $src, $aid, $r, $cb, $claim) = @_;
        return $cb->($type, $count, $prov, $o{year});
    };
    local *Plugins::ListenLater::DB::updateYear = sub { push @YEARS, [ @_[0,1] ] };
    local *Plugins::ListenLater::DB::updateTrackCount = sub { push @stored, $_[1] };
    local *Plugins::ListenLater::DB::updateRelType    = sub { push @typed, [ @_[1, 2] ] };
    Slim::Utils::Timers::clear();
    Slim::Utils::Log::clear();
    my $row = $o{rec} || $rec->();
    Plugins::ListenLater::Plugin::_verifyRelease($client, 42, $row,
        ($o{source} // 'qobuz'), ($o{albumId} // 'aid'), 1);
    return (scalar(@stored) ? $stored[0] : undef, scalar Slim::Utils::Timers::armed(), \@typed);
}

my ($st, $rt2) = verify_with('ep', 3, 0);
is('a REAL count is stored',                $st,  3);
is('...and nothing is retried',             $rt2, 0);

($st, $rt2) = verify_with('album', 12, 1);
is('a PROVISIONAL count is NOT stored',     $st,  undef);
is('...and is NOT treated as a failure',    $rt2, 0);

($st, $rt2) = verify_with(undef, undef, 0);
is('NO count is still a failure',           $st,  undef);
is('...which retries',                      $rt2, 1);

# ---------------------------------------------------------------------------
section('the resolved TYPE is not thrown away');
# Three cases, and the middle one was the bug: a row inserted with NO type (what
# _classifyThenAdd's safety timeout leaves behind) got its answer here and discarded it,
# so it showed Browse::_typeLabel's neutral "Album" default for good.
my $typed;
(undef, undef, $typed) = verify_with('ep', 3, 0, rec => { id => 42, rel_type => 'single' });
is('a disproved single is FORCED to ep',    ($typed->[0] ? $typed->[0][0] : '-'), 'ep');
is('...forced, so it overwrites the claim', ($typed->[0] ? $typed->[0][1] : '-'), 1);

(undef, undef, $typed) = verify_with('ep', 3, 0, rec => { id => 42, rel_type => undef });
is('a NULL type is filled in',              ($typed->[0] ? $typed->[0][0] : 'DISCARDED'), 'ep');
is('...unforced, so it only fills the NULL',
   ($typed->[0] ? ($typed->[0][1] ? 'forced' : 'unforced') : '-'), 'unforced');

(undef, undef, $typed) = verify_with('single', 1, 0, rec => { id => 42, rel_type => 'album' });
is('a standing claim is left alone',        scalar @$typed, 0);

# ---------------------------------------------------------------------------
section('it only runs when the tracklist is cheap to fetch');
# The gate's whole point is to avoid a service SEARCH for a background nicety. An album id
# is enough for Qobuz/Tidal/Deezer — but Bandcamp's get_album scrapes the album PAGE url, so
# an id-only Bandcamp row resolves via a full search: exactly what this refuses to spend.
my $bc = sub { { id => 42, rel_type => 'single', source => 'bandcamp', ref => { @_ } } };
(undef, my $armed) = verify_with(undef, undef, 0,
    source => 'bandcamp', rec => $bc->(album_id => '1234567'));
is('bandcamp with only an album_id: skipped', $armed, 0);
my @after = Slim::Utils::Log::lines();
is('...and silently, since nothing was tried', scalar @after, 0);

(undef, $armed, $typed) = verify_with('ep', 4, 0,
    source => 'bandcamp', rec => $bc->(album_id => '1', album_url => 'https://a.bandcamp.com/album/x'));
is('bandcamp WITH the page url: runs',      ($typed->[0] ? $typed->[0][0] : 'skipped'), 'ep');

(undef, $armed, $typed) = verify_with('ep', 4, 0,
    source => 'qobuz', rec => { id => 42, rel_type => 'single', source => 'qobuz',
                                ref => { album_id => 'abc' } });
is('qobuz needs only the id',               ($typed->[0] ? $typed->[0][0] : 'skipped'), 'ep');

# ---------------------------------------------------------------------------
section('a missing YEAR is backfilled from the same lookup');
# Free: the album object was fetched for the type and count anyway. This is what heals rows
# already saved without a year — and with them the dedupe key, so they stop being duplicable
# by a later add that does carry one. DB::updateYear itself refuses to overwrite a year the
# row already holds, so this hands over unconditionally and lets the DB layer decide.
verify_with('album', 9, 0, year => 2026);
is('the year reaches the DB',            (@YEARS ? $YEARS[0][1] : '-'), 2026);
is('...against the right record',        (@YEARS ? $YEARS[0][0] : '-'), 42);

verify_with('album', 9, 0);
is('no year offered, nothing written',   scalar @YEARS, 0);

# It must also land on the paths where the COUNT is useless — a provisional count, and no
# count at all (which retries). The year is good regardless of what the count turned out to be.
verify_with('album', 12, 1, year => 2019);
is('backfilled even when the count is provisional', (@YEARS ? $YEARS[0][1] : '-'), 2019);
verify_with(undef, undef, 0, year => 1998);
is('...and even when no count came back', (@YEARS ? $YEARS[0][1] : '-'), 1998);

# ---------------------------------------------------------------------------
section('a callback that NEVER ARRIVES is the third failure route');
# The two guarded routes are a callback reporting no count and a synchronous die. A request
# that is accepted and then never answered fires neither — so before this the row kept its
# unverified 'single' claim with nothing in the log at all, which is the silent give-up the
# retry was supposed to have removed.
{
    no warnings 'redefine';
    local *Plugins::ListenLater::Sources::classifyRelType = sub { return 1 };   # never calls back
    local *Plugins::ListenLater::DB::updateTrackCount = sub { };
    local *Plugins::ListenLater::DB::updateRelType    = sub { };
    Slim::Utils::Timers::clear();
    Slim::Utils::Log::clear();
    Plugins::ListenLater::Plugin::_verifyRelease($client, 42, $rec->(source => 'qobuz',
        ref => { album_id => 'abc' }), 'qobuz', 'abc', 1);

    my @armed = Slim::Utils::Timers::armed();
    is('a timeout is armed while we wait',  scalar @armed, 1);

    # Fire it, as the server would after 6s with no answer. Clear first: the real timer
    # system drops a timer once it has fired, but these stubs keep it on the list, so
    # anything still armed afterwards is what the timeout itself put there.
    my $fire = $armed[0]{cb};
    Slim::Utils::Timers::clear();
    $fire->();
    my @now = Slim::Utils::Timers::armed();
    is('...firing it arms the RETRY',       scalar @now, 1);
    is('...targeting the named tick sub',   ((($now[0]{cb} // 0) == $tick) ? 'yes' : 'no'), 'yes');
    is('...and it is not silent',
       ((join ' ', Slim::Utils::Log::lines()) =~ /never answered/ ? 'logged' : 'SILENT'), 'logged');
}

# A late answer after the timeout has already acted must not act again.
{
    my (@stored, $late);
    no warnings 'redefine';
    local *Plugins::ListenLater::Sources::classifyRelType = sub { $late = $_[4]; return 1 };
    local *Plugins::ListenLater::DB::updateTrackCount = sub { push @stored, $_[1] };
    local *Plugins::ListenLater::DB::updateRelType    = sub { };
    Slim::Utils::Timers::clear();
    Plugins::ListenLater::Plugin::_verifyRelease($client, 42, $rec->(source => 'qobuz',
        ref => { album_id => 'abc' }), 'qobuz', 'abc', 1);
    my @armed = Slim::Utils::Timers::armed();
    $armed[0]{cb}->();            # timeout fires first
    $late->('ep', 5, 0);          # the service finally answers
    is('a late answer is ignored',          scalar @stored, 0);
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
