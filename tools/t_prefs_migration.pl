#!/usr/bin/env perl
# The one-shot pref migration, and the rule that makes it one-shot.
#
# A pref whose name starts with '_' is silently DISCARDED by the server
# (Slim::Utils::Prefs::Base::set stores only `if ($valid && $pref !~ /^_/)`), so a flag of
# that shape reads undef for ever and the migration it guards runs at EVERY server start.
# `_rebrand_migrated` was exactly that, from 0.1.25 until 0.1.94: the pre-rebrand
# `plugin.listentolater` namespace was copied over the user's live settings on every restart,
# which reverted `sort` / `streaming_min_tracks` / `played_retention_days` — and reverted
# 0.1.93's 90% threshold to 60 within the same startup, seconds after the bump set it.
#
# Diagnosed live 2026-07-31 from `played_threshold`=60 sitting next to
# `threshold_90_migrated`=1: the migration had run AND its result was gone.
#
# **The rebrand copy was DELETED in 0.1.108.** It was never released to anyone under the old
# name — only Simon's own box ever wrote a `plugin.listentolater` pref — so it was guarding
# nobody while costing two settings-reverting bugs. The last section here pins the deletion:
# a populated legacy namespace must now have no effect at all. The underscore rule stays,
# because `threshold_90_migrated` still depends on it.
use strict;
use warnings;
# The stub's %VALUES/%NAMESPACES are declared when t_stubs.pl is REQUIRED, i.e. after this
# file has compiled — so the aliasing below names them exactly once and 'once' fires. It is
# noise, not a typo, and it would otherwise print above every run's report.
no warnings 'once';
use FindBin;
require "$FindBin::Bin/t_stubs.pl";

ll_require('DB', 'Sources', 'Plugin');

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

my $OLD_NS = 'plugin.listentolater';
my $prefs  = Slim::Utils::Prefs::preferences('plugin.listenlater');

# Put the store back to a chosen starting state, with NO pre-rebrand namespace. %VALUES is
# the plugin's namespace. This is what every box looks like: the rebrand landed in 0.1.25
# and no installed copy anywhere ever wrote a `plugin.listentolater` pref.
sub reset_prefs_no_legacy {
    my (%have) = @_;
    our (%VALUES, %NAMESPACES);
    *VALUES     = \%Slim::Utils::Prefs::VALUES;
    *NAMESPACES = \%Slim::Utils::Prefs::NAMESPACES;
    %VALUES     = %have;
    %NAMESPACES = ();
}

# The same, plus a populated pre-rebrand namespace — a pre-0.1.25 install (Simon's dev box,
# where these values were verified live). Nothing may read these any more.
sub reset_prefs_with_legacy {
    my (%have) = @_;
    reset_prefs_no_legacy(%have);
    Slim::Utils::Prefs::set_test_pref_ns($OLD_NS, 'played_threshold',      60);
    Slim::Utils::Prefs::set_test_pref_ns($OLD_NS, 'sort',                  'added');
    Slim::Utils::Prefs::set_test_pref_ns($OLD_NS, 'streaming_min_tracks',  4);
    Slim::Utils::Prefs::set_test_pref_ns($OLD_NS, 'played_retention_days', 7);
    Slim::Utils::Prefs::set_test_pref_ns($OLD_NS, 'material_action',       1);
}

section('the flag rule itself — an underscore pref cannot be stored');
# The stub mirrors the server here. If this ever passes with a value, the stub has drifted
# from Slim::Utils::Prefs::Base::set and every assertion below stops meaning anything.
reset_prefs_no_legacy();
$prefs->set('_a_flag', 1);
is('a leading-underscore pref does not persist', $prefs->get('_a_flag'), undef);
$prefs->set('a_flag', 1);
is('the same flag without the underscore does',  $prefs->get('a_flag'),  1);

section('the threshold bump re-applies once for installs the copy clobbered');
reset_prefs_no_legacy(played_threshold => 60, threshold_90_migrated => 1);
Plugins::ListenLater::Plugin::_migratePrefs();
is('60 left behind by the clobber becomes 90', $prefs->get('played_threshold'),      90);
is('and the flag moves to version 2',          $prefs->get('threshold_90_migrated'), 2);

# Having re-applied it, it must leave a chosen value alone from then on — this is the half
# that stops it becoming an every-restart clobber of its own.
$prefs->set('played_threshold', 75);
Plugins::ListenLater::Plugin::_migratePrefs();
is('a value chosen afterwards survives the next start', $prefs->get('played_threshold'), 75);

section('a fresh install');
reset_prefs_no_legacy();
Plugins::ListenLater::Plugin::_migratePrefs();
is('the threshold is the new default',    $prefs->get('played_threshold'),       90);
is('at the current migration version',    $prefs->get('threshold_90_migrated'),  2);

section('the pre-rebrand namespace is never consulted (0.1.108 deletion)');
# The regression guard for removing _migrateRebrandPrefs. A populated plugin.listentolater
# used to overwrite these at EVERY start — material_action back on after the user turned it
# off, and the threshold back to 60. Nothing may read that namespace now, so a user's chosen
# values must survive a full startup with the legacy namespace sitting right there.
reset_prefs_with_legacy(
    played_threshold      => 85,
    sort                  => 'artist',
    played_retention_days => 30,
    material_action       => 0,
    threshold_90_migrated => 2,
);
Plugins::ListenLater::Plugin::_migratePrefs();
is('the chosen threshold is untouched',        $prefs->get('played_threshold'),      85);
is('the chosen sort is untouched',             $prefs->get('sort'),                  'artist');
is('the chosen retention is untouched',        $prefs->get('played_retention_days'), 30);
is('material_action stays OFF',                $prefs->get('material_action'),       0);

# And again, because "reverts at every restart" was the actual symptom.
Plugins::ListenLater::Plugin::_migratePrefs();
is('still off after a second start',           $prefs->get('material_action'),       0);
is('and the threshold still 85',               $prefs->get('played_threshold'),      85);

# The sub itself must be gone, not merely uncalled — an orphan left behind is one call site
# away from reintroducing the bug.
is('_migrateRebrandPrefs no longer exists',
    (Plugins::ListenLater::Plugin->can('_migrateRebrandPrefs') ? 1 : 0), 0);

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
