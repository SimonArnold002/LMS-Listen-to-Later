#!/usr/bin/env perl
# actions.json STATE-MACHINE invariants (0.1.104).
#
# WHY THIS EXISTS, given t_material_actions.pl already covers this file in detail:
# every bug this area has produced since 0.1.46 has had the same two properties, and the
# scenario-style suite is structurally blind to both.
#
#   1. It is a TWO-TRANSITION bug. t_material_actions.pl asserts the file's state directly
#      after one call. But the 0.1.102/0.1.103 husks are not created by a wrong call — the
#      clear pass writing podcasts-* EMPTY while registrations are live is correct and
#      deliberate. They become permanent at the NEXT write, where the "is this ours?" test
#      (%emptied — "we emptied it, so we wrote it") answers no for a category that arrived
#      empty. The defect lives in the handoff between two passes that are each right alone,
#      so no single-call assertion can see it.
#
#   2. It is an UNTESTED CELL, not a wrong assertion. The podcast block covers
#      {live, not-live} x {subscribed, unsubscribed} in three of four cells: every $live case
#      there subscribes a feed first. (live, unsubscribed) is the missing one, and it is
#      exactly where _clearMaterialActions's hardcoded @fileOnlySup disagrees with
#      _materialActionSet's hasFeeds()-gated %fileOnly.
#
# So this suite does not add scenarios. It enumerates a MATRIX — starting file x Material
# API x podcast subscriptions x user journey — drives real op SEQUENCES over it, and checks
# four invariants after every step. The invariants are deliberately written to need almost no
# vocabulary of "which categories are ours": that list is hand-maintained in six places in
# Plugin.pm and disagreeing copies of it are the bug generator, so a test that restated it
# would inherit the fault it is meant to catch. Instead the reference is a BASELINE file
# produced by a clean run of the same config — whatever LL writes from nothing is by
# definition what LL owns.
#
#   I1  withdrawal   after a pref-OFF terminal, LL has no entries left in the file at all;
#                    and with nothing registered, none of its categories remain either.
#   I2  foreign      a category this plugin does not own is byte-identical before and after
#                    every operation — entries AND deliberate empty suppressors.
#   I3  no self-harm no EMPTY "<cmd>-album/-track" exists for a command we can replay: by the
#                    0.1.52 rule that category overrides online-* and hides "Add" on a service
#                    we support. This is the 0.1.51 regression stated as a property.
#   I4  convergence  any journey ending pref-ON leaves the file equal to the clean baseline,
#                    whatever route it took. A husk is precisely a failure to converge, so
#                    I4 catches the whole class without naming a single category.
use strict;
use warnings;
use FindBin;
use File::Temp ();
use File::Path ();
use JSON::XS ();
require "$FindBin::Bin/t_stubs.pl";

ll_require('DB', 'Sources', 'Podcast', 'Browse', 'Played', 'Settings', 'Plugin');

my ($pass, $fail) = (0, 0);
sub is {
    my ($desc, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && "$got" eq "$want");
    $ok ? $pass++ : $fail++;
    printf "%s %-62s got=%-24s want=%s\n", ($ok ? 'ok  ' : 'FAIL'), $desc,
        (defined $got ? "'$got'" : '(undef)'), (defined $want ? "'$want'" : '(undef)');
}
sub section { printf "\n== %s\n", $_[0] }

my $JSON = JSON::XS->new->utf8->canonical;
my $tmp  = File::Temp::tempdir(CLEANUP => 1);
$Slim::Utils::Prefs::DIR = $tmp;
sub actions_file { return "$tmp/material-skin/actions.json" }
sub read_file {
    my $f = actions_file();
    return {} unless -e $f;
    open my $fh, '<:raw', $f or die $!;
    local $/; my $raw = <$fh>; close $fh;
    return $JSON->decode($raw);
}
sub write_seed {
    my ($data) = @_;
    File::Path::make_path("$tmp/material-skin");
    open my $fh, '>:raw', actions_file() or die $!;
    print $fh $JSON->encode($data); close $fh;
}

our @REG;
sub install_api {
    no strict 'refs'; no warnings 'redefine';
    *{'Plugins::MaterialSkin::Plugin::registerCustomAction'} = sub { push @REG, [ @_ ] };
}
sub remove_api {
    no strict 'refs';
    delete $Plugins::MaterialSkin::Plugin::{registerCustomAction};
}

# A server RESTART: a fresh process still sees the file on disk, but every in-memory
# registration fact is gone. Keeping these two things separate is the whole point — the
# husk bugs live in what one process leaves on disk for the next one to misread.
sub new_process {
    @REG = ();
    $Plugins::ListenLater::Plugin::REGISTERED   = 0;
    $Plugins::ListenLater::Plugin::REGISTERED_N = 0;
    %Plugins::ListenLater::Plugin::UNREGISTERED = ();
}
sub set_feeds {
    Slim::Utils::Prefs::set_test_pref_ns('plugin.podcast', 'feeds',
        $_[0] ? [ { name => 'Darko.Audio', value => 'https://darko.audio/feed' } ] : []);
}

# %SUPPORTED_CMD is a file-scoped lexical, so it cannot be read from here — and copying the
# list into the test would make I3 assert against a stale duplicate, which is the exact
# failure mode this suite exists to catch. Read it out of the source instead, and die loudly
# if the declaration ever moves rather than silently testing nothing.
my $SRC = do {
    open my $fh, '<', "$FindBin::Bin/../ListenLater/Plugin.pm" or die $!;
    local $/; <$fh>;
};
my ($SUPQW) = $SRC =~ /%SUPPORTED_CMD\s*=\s*map\s*\{[^}]*\}\s*qw\(([^)]*)\)/s;
die "t_material_matrix: could not read %SUPPORTED_CMD out of Plugin.pm\n" unless $SUPQW;
# 'listenlater' is in that list but is exempt: our OWN empty listenlater-* pair is the
# deliberate suppressor that keeps "Add" off the rows inside our own list (0.1.52).
my @REPLAYABLE = grep { $_ ne 'listenlater' } split ' ', $SUPQW;

# --- the ops, mirroring the four real entry points exactly -------------------------------
#   boot_on  postinitPlugin, pref ON  — register (6.4.6+) then write
#   boot_off postinitPlugin, pref OFF — clear; nothing registered this run, so $live is 0
#   on       Settings save, pref ON   — write only; a save can never register (no de-dupe)
#   off      Settings save, pref OFF  — clear; $live is whatever THIS process registered
sub do_op {
    my ($op) = @_;
    if ($op eq 'boot_on')  { new_process();
                             Plugins::ListenLater::Plugin::_registerMaterialActions();
                             Plugins::ListenLater::Plugin::_writeMaterialActions(); }
    elsif ($op eq 'boot_off') { new_process();
                             Plugins::ListenLater::Plugin::_clearMaterialActions(); }
    elsif ($op eq 'on')    { Plugins::ListenLater::Plugin::_writeMaterialActions(); }
    elsif ($op eq 'off')   { Plugins::ListenLater::Plugin::_clearMaterialActions(); }
    else { die "unknown op $op" }
}

my %SEED = (
    absent       => { data => undef, foreign => [] },
    empty        => { data => {},    foreign => [] },
    # A real foreign plugin: one populated category and one deliberately EMPTY suppressor.
    # The empty one is the load-bearing half — it is indistinguishable from our own litter
    # by shape, and sweeping it silently breaks another plugin's hiding (0.1.101).
    foreign      => { data => { 'otherplugin-album' => [ { title => 'Other plugin',
                                                           lmscommand => [ 'otherplugin', 'add' ] } ],
                                'otherplugin-track' => [] },
                      foreign => [ 'otherplugin-album', 'otherplugin-track' ] },
    # What 0.1.47-0.1.50 left on an upgrading install: EMPTY per-service categories, written
    # by us, containing none of our entries. They arrive empty, so "we emptied it" is false.
    legacy_husks => { data => { 'deezer-album' => [], 'qobuz-album' => [], 'tidal-track' => [] },
                      foreign => [] },
    # What 0.1.102/0.1.103 leave behind on the (live, unsubscribed) path, seeded directly so
    # the recovery is tested independently of the journey that creates it.
    pod_husks    => { data => { 'podcasts-album' => [], 'podcasts-track' => [] },
                      foreign => [] },
);
my @SEEDS = qw(absent empty foreign legacy_husks pod_husks);

my @SEQS = (
    { name => 'boot with the pref on',                 ops => [qw(boot_on)],                    end => 'on'  },
    { name => 'two consecutive boots (idempotence)',    ops => [qw(boot_on boot_on)],            end => 'on'  },
    { name => 'boot on, toggle off',                    ops => [qw(boot_on off)],                end => 'off' },
    { name => 'boot on, toggle off, toggle back on',    ops => [qw(boot_on off on)],             end => 'on'  },
    { name => 'boot on, off, on, then restart',         ops => [qw(boot_on off on boot_on)],     end => 'on'  },
    { name => 'boot on, off, then restart still off',   ops => [qw(boot_on off boot_off)],       end => 'off' },
    { name => 'boot on, off, restart off, restart on',  ops => [qw(boot_on off boot_off boot_on)],end => 'on' },
    { name => 'boot with the pref off',                 ops => [qw(boot_off)],                   end => 'off' },
    { name => 'boot off, then turn it on',              ops => [qw(boot_off on)],                end => 'on'  },
);

my @CONFIGS = (
    { name => 'Material 6.4.6+ / podcasts subscribed',   api => 1, feeds => 1 },
    { name => 'Material 6.4.6+ / no subscriptions',      api => 1, feeds => 0 },
    { name => 'Material 6.4.5- / podcasts subscribed',   api => 0, feeds => 1 },
    { name => 'Material 6.4.5- / no subscriptions',      api => 0, feeds => 0 },
);

sub apply_config {
    my ($cfg) = @_;
    $cfg->{api} ? install_api() : remove_api();
    set_feeds($cfg->{feeds});
}
sub start_world {
    my ($cfg, $seedname) = @_;
    new_process();
    # A new world is a new INSTALL: the plugin's own prefs start at defaults. Without this
    # a pref written by one journey leaks into the next, which silently turns an
    # upgrade-from-an-older-build case into an already-migrated one — and that is exactly
    # the case these husks live in. (Found by running the suite against a candidate fix
    # that stores what it wrote: every journey after the first inherited the store.)
    %Slim::Utils::Prefs::VALUES = ();
    File::Path::remove_tree("$tmp/material-skin");
    apply_config($cfg);
    my $seed = $SEED{$seedname};
    write_seed($seed->{data}) if defined $seed->{data};
    return $seed;
}

# The clean-run reference for each config: what LL writes starting from nothing. Everything
# I4 knows about "our categories" comes from here, so it can never drift from the code.
my %BASELINE;
for my $cfg (@CONFIGS) {
    start_world($cfg, 'absent');
    do_op('boot_on');
    $BASELINE{ $cfg->{name} } = merged_view(read_file());
}

sub minus_keys {
    my ($data, @drop) = @_;
    my %drop = map { $_ => 1 } @drop;
    return { map { $_ => $data->{$_} } grep { !$drop{$_} } keys %$data };
}

# What Material actually ends up with: the file list PLUS this process's registrations,
# merged the way customactions.js merges them. Comparing the FILE alone would make I4 cry
# wolf on one legitimate journey — a Settings save cannot register (registerCustomAction has
# no de-dupe and no unregister, so it runs once per server run, in postinit), so enabling the
# pref mid-run deliberately delivers the positives through the file instead. Same entries
# reaching the same menus by the other half of a two-path design is convergence, not drift.
# Empty categories survive the merge untouched: an empty category IS the suppressor, and it
# only ever exists in the file.
sub merged_view {
    my ($data) = @_;
    my %m;
    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY';
        $m{$cat} = [ @{ $data->{$cat} } ];
    }
    push @{ $m{ $_->[0] } ||= [] }, $_->[1] for @REG;
    # Sorted, so which path delivered an entry never decides the comparison.
    $_ = [ sort { $JSON->encode($a) cmp $JSON->encode($b) } @$_ ] for values %m;
    return \%m;
}

# --- the invariants ----------------------------------------------------------------------
# Each returns a list of human-readable violations; empty means the property held.
sub v_foreign {
    my ($data, $seed) = @_;
    my @bad;
    my $want = $seed->{data} or return ();
    for my $cat (@{ $seed->{foreign} }) {
        push(@bad, "$cat vanished"), next unless exists $data->{$cat};
        push @bad, "$cat altered"
            if $JSON->encode($data->{$cat}) ne $JSON->encode($want->{$cat});
    }
    return @bad;
}
sub v_no_self_harm {
    my ($data) = @_;
    my @bad;
    for my $cmd (@REPLAYABLE) {
        for my $type (qw(album track)) {
            my $cat = "$cmd-$type";
            push @bad, "$cat is an empty suppressor on a service we replay"
                if ref $data->{$cat} eq 'ARRAY' && !@{ $data->{$cat} };
        }
    }
    return @bad;
}
sub v_withdrawn {
    my ($data, $cfg, $live) = @_;
    my @bad;
    my $ours = 0;
    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY';
        $ours += grep { Plugins::ListenLater::Plugin::_isOurAction($_) } @{ $data->{$cat} };
    }
    push @bad, "$ours of our entries survived a pref-OFF" if $ours;
    # With entries registered this run they cannot be withdrawn, so the empty suppressors
    # must STAY until the restart — that is the one case where leftover categories are right.
    return @bad if $live;
    for my $cat (keys %{ $BASELINE{ $cfg->{name} } }) {
        push @bad, "$cat survived with nothing registered" if exists $data->{$cat};
    }
    return @bad;
}
sub v_converged {
    my ($data, $cfg, $seed) = @_;
    my @drop = @{ $seed->{foreign} };
    my $g = minus_keys(merged_view($data), @drop);
    my $w = minus_keys($BASELINE{ $cfg->{name} }, @drop);
    return () if $JSON->encode($g) eq $JSON->encode($w);
    # Name the difference in category terms — a whole-file diff is unreadable at this size.
    my @bad;
    push @bad, map { "extra $_" }   grep { !exists $w->{$_} } sort keys %$g;
    push @bad, map { "missing $_" } grep { !exists $g->{$_} } sort keys %$w;
    push @bad, map { "differs $_" }
        grep { exists $w->{$_} && $JSON->encode($g->{$_}) ne $JSON->encode($w->{$_}) }
        sort keys %$g;
    return @bad;
}

# --- drive the matrix --------------------------------------------------------------------
# One assertion per (config x journey x invariant), with every failing seed and the step it
# first broke at named in the output — 4 x 9 x 4 lines instead of 720, without losing which
# starting state did it.
for my $cfg (@CONFIGS) {
    section($cfg->{name});
    for my $seq (@SEQS) {
        my (@bForeign, @bHarm, @bTerm);
        for my $seedname (@SEEDS) {
            my $seed = start_world($cfg, $seedname);
            my $step = 0;
            for my $op (@{ $seq->{ops} }) {
                $step++;
                do_op($op);
                my $data = read_file();
                push @bForeign, map { "$seedname\@$step($op): $_" } v_foreign($data, $seed);
                push @bHarm,    map { "$seedname\@$step($op): $_" } v_no_self_harm($data);
            }
            my $data = read_file();
            my @t = $seq->{end} eq 'off'
                  ? v_withdrawn($data, $cfg, $Plugins::ListenLater::Plugin::REGISTERED_N ? 1 : 0)
                  : v_converged($data, $cfg, $seed);
            push @bTerm, map { "$seedname: $_" } @t;
        }
        my $j = sub { @{ $_[0] } ? join('; ', @{ $_[0] }) : '' };
        is("I2 foreign untouched  — $seq->{name}", $j->(\@bForeign), '');
        is("I3 no self-harm       — $seq->{name}", $j->(\@bHarm),    '');
        is(($seq->{end} eq 'off' ? 'I1 withdrawal        — ' : 'I4 convergence       — ')
            . $seq->{name}, $j->(\@bTerm), '');
    }
}

printf "\n%s  %d passed, %d failed\n", ($fail ? 'FAILURES' : 'all ok'), $pass, $fail;
exit($fail ? 1 : 0);
