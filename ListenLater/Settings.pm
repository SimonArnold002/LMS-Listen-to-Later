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

        # Persist the two Material toggles straight from the form NOW (SUPER::handler saves
        # them too, but only after it has rendered the page). We need them live so the
        # regenerate below reflects the just-chosen values, and the fresh snapshot is in the
        # pref before the template is rendered in this same request.
        $prefs->set('material_action', $params->{pref_material_action} ? 1 : 0);
        $prefs->set('debug_log',       $params->{pref_debug_log}       ? 1 : 0);

        # Rewrite Material's actions.json now so the diagnostics snapshot shown on the page
        # reflects the current state (otherwise the user would enable debug logging, save,
        # and see nothing until the next restart). _writeMaterialActions writes the snapshot
        # pref when debug_log is on. Guarded exactly like postinitPlugin — only touch the
        # shared file when the feature is on and Material is installed.
        if ( $prefs->get('debug_log')
          && $prefs->get('material_action')
          && Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin') ) {
            eval { Plugins::ListenLater::Plugin::_writeMaterialActions(); 1 }
                or $log->error("LL: settings-page diagnostics rewrite failed: $@");
        }

        $log->info('Listen Later settings saved');
    }

    # Hand the latest diagnostics snapshot to the template (copy-paste textarea). Set before
    # SUPER::handler renders, so it's available whether this is a save or a plain page load.
    $params->{material_debug_snapshot} = $prefs->get('material_debug_snapshot');

    return $class->SUPER::handler($client, $params);
}

1;
