package Plugins::ListenToLater::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $prefs = preferences('plugin.listentolater');
my $log   = logger('plugin.listentolater');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_LTL');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/ListenToLater/settings.html');
}

sub prefs {
    return ($prefs, qw(
        sort played_threshold streaming_min_tracks watch_outside material_action
    ));
}

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;

    if ($params->{saveSettings}) {
        my $thr = $params->{pref_played_threshold} // 60;
        $thr = 60  unless $thr =~ /^\d+$/;
        $thr = 10  if $thr < 10;
        $thr = 100 if $thr > 100;
        $prefs->set('played_threshold', $thr + 0);

        my $min = $params->{pref_streaming_min_tracks} // 4;
        $min = 4 unless $min =~ /^\d+$/;
        $min = 1 if $min < 1;
        $prefs->set('streaming_min_tracks', $min + 0);

        $log->info('Listen to Later settings saved');
    }

    return $class->SUPER::handler($client, $params);
}

1;
