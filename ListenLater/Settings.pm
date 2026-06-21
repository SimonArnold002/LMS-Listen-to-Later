package Plugins::ListenLater::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;

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
        played_retention_days
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
        $thr = 60  unless defined $thr && $thr =~ /^\d+$/;
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

        $log->info('Listen Later settings saved');
    }

    return $class->SUPER::handler($client, $params);
}

1;
