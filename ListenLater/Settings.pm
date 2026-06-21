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
        my $thr = $params->{pref_played_threshold} // 60;
        $thr = 60  unless $thr =~ /^\d+$/;
        $thr = 10  if $thr < 10;
        $thr = 100 if $thr > 100;
        $prefs->set('played_threshold', $thr + 0);

        my $min = $params->{pref_streaming_min_tracks} // 4;
        $min = 4 unless $min =~ /^\d+$/;
        $min = 1 if $min < 1;
        $prefs->set('streaming_min_tracks', $min + 0);

        my $ret = $params->{pref_played_retention_days} // 7;
        $ret = 7 unless $ret =~ /^\d+$/;   # 0 = keep forever
        $ret = 3650 if $ret > 3650;
        $prefs->set('played_retention_days', $ret + 0);

        $log->info('Listen Later settings saved');
    }

    return $class->SUPER::handler($client, $params);
}

1;
