#!/usr/bin/env perl
# Shared bootstrap for the t_*.pl regression tests: fakes just enough of the LMS
# (Slim::*) tree that the plugin's own modules can be loaded and exercised on a
# development machine with no server installed.
#
# Why this exists: the plugin's invariants — how Played thresholds work, which adds
# dedupe against which, what a migration does to existing rows — were documented in
# CLAUDE.md but never testable outside the server, so each round of work re-derived
# them by hand and one of them regressed. These stubs make the DB and the pure logic
# runnable in a second, offline.
#
# The stubs are deliberately minimal and DUMB. They exist to let real code load, not
# to simulate LMS. Anything a test actually depends on (a track count, a pref) is
# overridden IN that test, visibly, so no test ever passes because of behaviour hidden
# in here. Registering via %INC means no files on disk and no @INC juggling.
#
# Usage:   require "$FindBin::Bin/t_stubs.pl";   (before loading any Plugins:: module)
use strict;
use warnings;

# Slim::Utils::Log — logger()/addLogCategory() both hand back an object that records
# every line, so a test can assert on what was logged (several of the behaviours here
# are only observable as a WARN).
{
    package Slim::Utils::Log;
    require Exporter; our @ISA = ('Exporter'); our @EXPORT = ('logger');
    our @LINES;
    sub addLogCategory { return bless {}, 'Slim::Utils::Log::Obj' }
    sub logger         { return bless {}, 'Slim::Utils::Log::Obj' }
    sub lines          { return @LINES }
    sub clear          { @LINES = () }
    package Slim::Utils::Log::Obj;
    sub warn  { push @Slim::Utils::Log::LINES, $_[1] }
    sub error { push @Slim::Utils::Log::LINES, $_[1] }
    sub info  {} sub debug {} sub is_debug {0} sub is_info {0}
    sub AUTOLOAD {} sub DESTROY {}
    $INC{'Slim/Utils/Log.pm'} = __FILE__;
}

# Slim::Utils::Prefs — a pref reads undef unless a test sets it, with set_test_pref() for
# the plugin's own namespace and set_test_pref_ns() for any other. DB::_path builds the
# SQLite path from preferences('server')->get('cachedir'), so a suite touching the DB sets
# that one on the 'server' namespace or lands in /tmp.
#
# Two behaviours of the real thing are reproduced here because plugin code depends on
# them and got both wrong (0.1.94):
#
#   * A pref whose name starts with '_' is silently DISCARDED by set. The server stores
#     only `if ($valid && $pref !~ /^_/)` (Slim::Utils::Prefs::Base::set) — no error, no
#     warning, and get() returns undef for ever after. A one-shot migration flag of that
#     shape therefore re-runs on every single start.
#   * Namespaces are SEPARATE stores. The plugin reads its own AND the pre-rebrand
#     `plugin.listentolater` one, and a stub that conflated them would make the copy
#     between them look like a no-op — hiding exactly the bug worth testing.
#
# %VALUES stays the plugin's own namespace so set_test_pref and every existing suite are
# unaffected; other namespaces get their own store in %NAMESPACES.
{
    package Slim::Utils::Prefs;
    require Exporter; our @ISA = ('Exporter'); our @EXPORT = ('preferences');
    our %VALUES;                        # the plugin's own namespace
    our %NAMESPACES;                    # every other namespace, keyed by name
    our $NS = 'plugin.listenlater';
    sub _store {
        my ($ns) = @_;
        return \%VALUES if !defined $ns || $ns eq $NS;
        return $NAMESPACES{$ns} ||= {};
    }
    sub preferences { return bless { ns => $_[0] }, 'Slim::Utils::Prefs::Obj' }
    sub set_test_pref { $VALUES{$_[0]} = $_[1] }
    sub set_test_pref_ns { my ($ns,$k,$v) = @_; _store($ns)->{$k} = $v }
    package Slim::Utils::Prefs::Obj;
    sub _s   { return Slim::Utils::Prefs::_store($_[0]->{ns}) }
    sub get  { return $_[0]->_s->{ $_[1] } }
    sub set  { return if $_[1] =~ /^_/; $_[0]->_s->{ $_[1] } = $_[2] }
    sub init { my ($self,$h) = @_; my $s = $self->_s; $s->{$_} //= $h->{$_} for keys %$h; }
    sub setValidate {} sub setChange {} sub migrateClient {} sub AUTOLOAD {} sub DESTROY {}
    $INC{'Slim/Utils/Prefs.pm'} = __FILE__;
}

# Slim::Utils::Strings — cstring() returns the token itself, so a test asserting on a
# label sees 'PLUGIN_LL_TYPE_EP' rather than an empty string.
{
    package Slim::Utils::Strings;
    require Exporter; our @ISA = ('Exporter'); our @EXPORT_OK = ('cstring','string');
    sub cstring { return $_[1] // '' }
    sub string  { return $_[0] // '' }
    $INC{'Slim/Utils/Strings.pm'} = __FILE__;
}

# A controllable clock. Behaviour that turns on ELAPSED TIME — a guard that goes stale, a
# retry window — is otherwise untestable without really sleeping, which no suite should do.
# Tests move the clock with TestClock::advance(60).
#
# The override must be installed BEFORE any plugin module is compiled: a CORE::GLOBAL
# override only binds in code compiled after it. This file is require'd first and the
# modules come later via ll_require(), so they pick it up — but that ordering is load-
# bearing, so don't move ll_require() above this.
{
    package TestClock;
    our $OFFSET = 0;
    sub advance { $OFFSET += $_[0] }
    sub reset   { $OFFSET = 0 }
    $INC{'TestClock.pm'} = __FILE__;
}
BEGIN { *CORE::GLOBAL::time = sub () { CORE::time() + ($TestClock::OFFSET || 0) } }

# Slim::Utils::Timers — records what was armed instead of arming it, so timer-driven
# behaviour (the release-verify retry, the Played deferred mark) is testable without
# waiting or running an event loop. @ARMED is the assertion surface.
{
    package Slim::Utils::Timers;
    our @ARMED;
    sub setTimer     { my ($obj,$when,$cb,@a) = @_; push @ARMED, { obj=>$obj, when=>$when, cb=>$cb, args=>\@a }; return \$ARMED[-1] }
    sub setHighTimer { goto &setTimer }
    sub killTimers   { my ($obj,$cb) = @_; @ARMED = grep { $_->{cb} != $cb } @ARMED; }
    sub killSpecific {}
    sub armed        { return @ARMED }
    sub clear        { @ARMED = () }
    $INC{'Slim/Utils/Timers.pm'} = __FILE__;
}

# The rest only need to exist so `use` succeeds.
{
    package Slim::Utils::Cache;
    sub new { bless {}, shift } sub get {} sub set {} sub remove {}
    $INC{'Slim/Utils/Cache.pm'} = __FILE__;
}
{
    package Slim::Utils::PluginManager;
    sub AUTOLOAD {} sub DESTROY {}
    $INC{'Slim/Utils/PluginManager.pm'} = __FILE__;
}
{
    package Slim::Networking::SimpleAsyncHTTP;
    sub AUTOLOAD {} sub DESTROY {}
    $INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = __FILE__;
}
{
    package Slim::Plugin::OPMLBased;
    sub AUTOLOAD {} sub DESTROY {}
    $INC{'Slim/Plugin/OPMLBased.pm'} = __FILE__;
}
# Base class for Settings.pm.
{
    package Slim::Web::Settings;
    sub new {} sub name {} sub page {} sub prefs {} sub handler {} sub saveSettings {}
    sub AUTOLOAD {} sub DESTROY {}
    $INC{'Slim/Web/Settings.pm'} = __FILE__;
}
# Base class for HomeExtras.pm. This one belongs to ANOTHER plugin (Material Skin) and is
# genuinely absent unless Material is installed — which is why Plugin.pm only `require`s
# HomeExtras inside its `MaterialSkin->can('registerHomeExtra')` guard. Stubbed purely so
# the module can be compile-checked here; its absence at runtime is handled correctly.
{
    package Plugins::MaterialSkin::HomeExtraBase;
    sub new {} sub initPlugin {} sub tag {} sub title {}
    sub AUTOLOAD {} sub DESTROY {}
    $INC{'Plugins/MaterialSkin/HomeExtraBase.pm'} = __FILE__;
}
# getClient() returns whatever it was handed, so a fake client stays "live" — the
# release-verify retry gives up without one.
{
    package Slim::Player::Client;
    sub getClient { return $_[0] }
    $INC{'Slim/Player/Client.pm'} = __FILE__;
}
# Slim::Schema — library track counts. A test sets the count it wants to see.
{
    package Slim::Schema;
    our $TRACK_COUNT = 0;
    # find('Album', $id) — set $ALBUM_YEAR to what the local library should report, or leave
    # it undef for "no such album" (the default, so nothing passes by accident).
    our $ALBUM_YEAR;
    sub search { return bless {}, 'Slim::Schema::Rs' }
    sub find   {
        my (undef, $kind, $id) = @_;
        return undef unless ($kind // '') eq 'Album' && defined $ALBUM_YEAR;
        return bless { year => $ALBUM_YEAR }, 'Slim::Schema::Album';
    }
    package Slim::Schema::Album;
    sub year { return $_[0]->{year} }
    package Slim::Schema::Rs;
    sub count { return $Slim::Schema::TRACK_COUNT }
    $INC{'Slim/Schema.pm'} = __FILE__;
}

# main::WEBUI is a compile-time constant the LMS build supplies; Plugin.pm reads it.
{
    package main;
    eval 'use constant WEBUI => 1;' unless defined &main::WEBUI;
}

# Load one of the plugin's OWN modules. Needed because the package names
# (Plugins::ListenLater::*) match the INSTALLED layout — LMS puts the plugin under a
# Plugins/ directory — but the repo has no such parent, so `use Plugins::ListenLater::DB`
# can't be resolved from a checkout. Load the file by path, then register it in %INC under
# the name it calls itself, so any later `use` of it from a sibling module is a no-op.
#
# Call in dependency order: DB before Sources, Sources before Plugin/Browse.
sub main::ll_require {
    require File::Basename;
    require Cwd;
    # Locate the plugin from THIS file, not from the caller or the cwd, so the tests run
    # the same from the repo root, from tools/, or from a runner script.
    my $dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) . '/../ListenLater';
    for my $name (@_) {
        my $key  = "Plugins/ListenLater/$name.pm";
        next if $INC{$key};
        my $path = "$dir/$name.pm";
        die "no such module: $path\n" unless -f $path;
        $INC{$key} = $path;          # set FIRST: the module may `use` a sibling that uses it back
        require $path;
    }
    return 1;
}

1;
