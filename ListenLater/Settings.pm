package Plugins::ListenLater::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::PluginManager;

my $prefs = preferences('plugin.listenlater');
my $log   = logger('plugin.listenlater');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_LL');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/ListenLater/settings.html');
}

sub prefs {
    return ($prefs, qw(
        sort played_threshold streaming_min_tracks watch_outside material_action
        played_retention_days debug_log
    ));
}

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;

    if ($params->{saveSettings}) {
        # Sanitise the raw form values IN PLACE. SUPER::handler saves every pref in
        # prefs() straight from $params->{pref_*}, and it runs after us — so setting
        # the prefs directly here would just be overwritten. Clamp the params instead
        # and let the base class store the clean values.
        my $thr = $params->{pref_played_threshold};
        $thr = 90  unless defined $thr && $thr =~ /^\d+$/;   # matches the pref default
        $thr = 10  if $thr < 10;
        $thr = 100 if $thr > 100;
        $params->{pref_played_threshold} = $thr + 0;

        my $min = $params->{pref_streaming_min_tracks};
        $min = 4 unless defined $min && $min =~ /^\d+$/;
        $min = 1 if $min < 1;
        $params->{pref_streaming_min_tracks} = $min + 0;

        my $ret = $params->{pref_played_retention_days};
        $ret = 7 unless defined $ret && $ret =~ /^\d+$/;   # 0 = keep forever
        $ret = 3650 if $ret > 3650;
        $params->{pref_played_retention_days} = $ret + 0;

        # AN UNTICKED CHECKBOX POSTS NOTHING AT ALL, so `pref_material_action` is ABSENT from
        # $params rather than 0 — and Slim::Web::Settings::handler does an UNCONDITIONAL
        # `$prefsClass->set($pref, $paramRef->{'pref_'.$pref})` for every pref in prefs()
        # (Settings.pm:162). Setting the pref directly here is therefore not enough: SUPER
        # runs afterwards and writes **undef** straight over our 0. `Prefs::Base::init` then
        # re-seeds any pref that "exists as an undef value" (Base.pm:200) at the next module
        # load, so the default 1 came back and the box reappeared TICKED on every restart —
        # the toggle could not be turned off at all, and with it stuck on, postinitPlugin
        # never reached the branch that clears actions.json.
        #
        # So MATERIALISE the value into $params, exactly as the numeric prefs above do, and
        # let the base class store it. The direct set stays because the write/clear below has
        # to see the chosen value live, in this same request.
        $params->{pref_material_action} = $params->{pref_material_action} ? 1 : 0;
        $params->{pref_debug_log}       = $params->{pref_debug_log}       ? 1 : 0;
        $prefs->set('material_action', $params->{pref_material_action});
        $prefs->set('debug_log',       $params->{pref_debug_log});

        # Re-run Material's delivery now, mirroring postinitPlugin's two branches EXACTLY, so
        # the toggle takes effect on THIS save rather than at the next restart:
        #   * ON  — register, then write. Both, in that order, as postinit does.
        #   * OFF — _clearMaterialActions removes our file entries. Anything registered at
        #           startup can only go at the next restart; it says so.
        #
        # **THE SAVE MUST REGISTER, and 0.1.110 shipped without that (reported live).** The
        # comment here used to claim it "cannot register — registerCustomAction has no de-dupe
        # and no unregister, so it runs once per server run, in postinit", and that the FILE
        # write was "precisely why turning it on mid-run works at all". Both halves were wrong
        # the moment tier 2 removed the file write:
        #   * `$REGISTERED` IS the de-dupe. It is a per-run latch, so calling
        #     _registerMaterialActions here is a no-op whenever postinit already registered.
        #   * It is FALSE in exactly the case this branch exists for. The pref being off at
        #     startup is what sent postinit down its `elsif`, so nothing registered and there
        #     is nothing to double.
        # Without it, on Material >= 6.4.8 ticking the box wrote nothing (the prune writes
        # only refused entries) and registered nothing, so the toggle did nothing at all until
        # a server restart. On tier 0/1 the file write still carries it, exactly as before.
        #
        # The user still needs a Material reload to SEE it — the client fetches both lists at
        # app start — but that is the same one-refresh cost the file path always had (0.1.57),
        # not a restart.
        #
        # debug_log deliberately does NOT gate this — it gates only the diagnostics SNAPSHOT
        # that the write stashes for the textarea below. Gating the write on it (as we did
        # before 0.1.97) meant the Material toggle silently did nothing on the default config,
        # where debug logging is off.
        if ( Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin') ) {
            eval {
                if ( $prefs->get('material_action') ) {
                    Plugins::ListenLater::Plugin::_registerMaterialActions();
                    Plugins::ListenLater::Plugin::_writeMaterialActions();
                }
                else {
                    Plugins::ListenLater::Plugin::_clearMaterialActions();
                }
                1;
            } or $log->error("LL: settings-page Material action rewrite failed: $@");
        }

        $log->info('Listen Later settings saved');
    }

    # Hand the latest diagnostics snapshot to the template (copy-paste textarea). Set before
    # SUPER::handler renders, so it's available whether this is a save or a plain page load.
    $params->{material_debug_snapshot} = $prefs->get('material_debug_snapshot');

    return $class->SUPER::handler($client, $params);
}

1;
