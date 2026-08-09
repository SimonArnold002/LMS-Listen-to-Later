#!/usr/bin/env perl
# The one-shot pref migrations, and the rule that makes them one-shot.
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
# Confirmed against the pre-fix code, where the underscore flag makes cases in "the copy runs
# exactly once" fail (the second run re-imports the old values over the user's).
use strict;
use warnings;
# The stub's %VALUES/%NAMESPACES are declared when t_stubs.pl is REQUIRED, i.e. after this
# file has compiled — so the aliasing below names them exactly once and 'once' fires. It is
# noise, not a typo, and it would otherwise print above every run's report.
no warnings 'once';
use FindBin;
require "$FindBin::Bin/t_stubs.pl";

ll_require('DB', 'Sources', 'Podcast', 'Plugin');

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
# the plugin's namespace. This is what a real USER's box looks like: the rebrand landed in
# 0.1.25 and the first release was tagged v0.1.69, so no installed copy ever wrote a
# `plugin.listentolater` pref. Use the seeded variant below for the boxes that did.
sub reset_prefs_no_legacy {
    my (%have) = @_;
    our (%VALUES, %NAMESPACES);
    *VALUES     = \%Slim::Utils::Prefs::VALUES;
    *NAMESPACES = \%Slim::Utils::Prefs::NAMESPACES;
    %VALUES     = %have;
    %NAMESPACES = ();
}

# The same, plus a populated pre-rebrand namespace — a pre-0.1.25 install (Simon's dev box,
# where these values were verified live). These are what the migration keeps re-importing.
sub reset_prefs {
    my (%have) = @_;
    reset_prefs_no_legacy(%have);
    Slim::Utils::Prefs::set_test_pref_ns($OLD_NS, 'played_threshold',      60);
    Slim::Utils::Prefs::set_test_pref_ns($OLD_NS, 'sort',                  'added');
    Slim::Utils::Prefs::set_test_pref_ns($OLD_NS, 'streaming_min_tracks',  4);
    Slim::Utils::Prefs::set_test_pref_ns($OLD_NS, 'played_retention_days', 7);
}

section('the flag rule itself — an underscore pref cannot be stored');
# The stub mirrors the server here. If this ever passes with a value, the stub has drifted
# from Slim::Utils::Prefs::Base::set and every assertion below stops meaning anything.
reset_prefs();
$prefs->set('_a_flag', 1);
is('a leading-underscore pref does not persist', $prefs->get('_a_flag'), undef);
$prefs->set('a_flag', 1);
is('the same flag without the underscore does',  $prefs->get('a_flag'),  1);

section('the rebrand copy runs exactly once');
# A genuine pre-0.1.25 install: no flags at all, old namespace populated.
reset_prefs();
Plugins::ListenLater::Plugin::_migrateRebrandPrefs();
is('old values are imported on the first run',  $prefs->get('played_threshold'), 60);
is('the flag is recorded',                      $prefs->get('rebrand_migrated'), 1);

# The user then changes their mind in Settings, and the server restarts.
$prefs->set('played_threshold',      90);
$prefs->set('played_retention_days', 30);
Plugins::ListenLater::Plugin::_migrateRebrandPrefs();
is('a later restart does not revert the threshold', $prefs->get('played_threshold'),      90);
is('nor the retention days',                        $prefs->get('played_retention_days'), 30);

section('an install that already ran the broken copy is not copied over again');
# What every existing install looks like: 0.1.93's flag set, the threshold clobbered back to
# 60 by the copy, and no usable record that the copy ever happened.
reset_prefs(played_threshold => 60, threshold_90_migrated => 1, sort => 'artist');
Plugins::ListenLater::Plugin::_migratePrefs();
is('the copy is marked done from the 0.1.93 flag', $prefs->get('rebrand_migrated'), 1);
Plugins::ListenLater::Plugin::_migrateRebrandPrefs();
is('so it imports nothing',                        $prefs->get('sort'), 'artist');

section('the threshold bump re-applies once for those installs');
reset_prefs(played_threshold => 60, threshold_90_migrated => 1);
Plugins::ListenLater::Plugin::_migratePrefs();
is('60 left behind by the clobber becomes 90', $prefs->get('played_threshold'),      90);
is('and the flag moves to version 2',          $prefs->get('threshold_90_migrated'), 2);

# Having re-applied it, it must leave a chosen value alone from then on — this is the half
# that stops it becoming an every-restart clobber of its own.
$prefs->set('played_threshold', 75);
Plugins::ListenLater::Plugin::_migratePrefs();
is('a value chosen afterwards survives the next start', $prefs->get('played_threshold'), 75);

section('a fresh install');
# Nothing to migrate: the flag seeding must NOT mark the copy done, or a genuine pre-0.1.25
# upgrader would silently lose their settings.
reset_prefs_no_legacy();
Plugins::ListenLater::Plugin::_migratePrefs();
is('the rebrand copy is still pending',   ($prefs->get('rebrand_migrated') ? 1 : 0), 0);
is('the threshold is the new default',    $prefs->get('played_threshold'),       90);
is('at the current migration version',    $prefs->get('threshold_90_migrated'),  2);

# ...and then initPlugin runs the copy, which is where this section used to stop. With no
# pre-rebrand namespace it has nothing to import, so the threshold it just set survives and
# the flag records that the copy is done. Without this call the fresh-install path was never
# driven through the real startup order at all.
Plugins::ListenLater::Plugin::_migrateRebrandPrefs();
is('the copy has nothing to import',      $prefs->get('played_threshold'),       90);
is('and records itself done',             $prefs->get('rebrand_migrated'),       1);

section('the two migrations in the real startup order');
# _migratePrefs runs at module load, _migrateRebrandPrefs from initPlugin — so the copy gets
# the last word, and this is the ordering that decides whose value wins. Simon's box: the
# bump set 90 and the copy put 60 straight back, at every restart.
reset_prefs(played_threshold => 60, threshold_90_migrated => 1);
Plugins::ListenLater::Plugin::_migratePrefs();
Plugins::ListenLater::Plugin::_migrateRebrandPrefs();
is('90 survives the copy that used to undo it', $prefs->get('played_threshold'), 90);

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
