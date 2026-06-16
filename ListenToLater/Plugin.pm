package Plugins::ListenToLater::Plugin;

# Listen to Later — save an album from any source (library / Qobuz / Bandcamp)
# into a curated list, browse it as a "playlist of albums", and have albums move
# to a Played section once you've listened to most of them.
#
# Add path: a Slim::Menu::TrackInfo provider (fires for local AND remote tracks)
# plus a Slim::Menu::AlbumInfo provider (library albums) put an "Add album to
# Listen to Later" entry in the "…" menu. Both return an OPML drill coderef that
# does the add and shows a brief confirmation — works in Material and classic.

use strict;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::ListenToLater::DB;
use Plugins::ListenToLater::Sources;

use constant ICON => 'plugins/ListenToLater/html/images/ListenToLaterIcon_svg.png';

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.listentolater',
    'defaultLevel' => 'INFO',
    'description'  => 'PLUGIN_LTL',
});

my $prefs = preferences('plugin.listentolater');

$prefs->init({
    sort                 => 'added',   # added|artist|album|year|played
    played_threshold     => 60,        # % of library album tracks → Played
    streaming_min_tracks => 4,         # distinct streaming tracks → Played (no total available)
    watch_outside        => 1,         # mark Played from plays started outside the plugin
});

sub initPlugin {
    my $class = shift;

    if (main::WEBUI) {
        require Plugins::ListenToLater::Settings;
        Plugins::ListenToLater::Settings->new();
    }

    require Plugins::ListenToLater::Browse;

    # Open / migrate the DB up front so the first add is instant and errors show
    # at startup rather than mid-interaction.
    eval { Plugins::ListenToLater::DB::dbh(); 1 }
        or $log->error("Listen to Later DB init failed: $@");

    _registerInfoProviders();

    require Plugins::ListenToLater::Played;
    Plugins::ListenToLater::Played->init();

    $class->SUPER::initPlugin(
        tag    => 'listentolater',
        feed   => \&Plugins::ListenToLater::Browse::topLevel,
        is_app => 1,
        menu   => 'radios',
        weight => 10,
    );

    return;
}

# ---------------------------------------------------------------------------
# "Add album to Listen to Later" entries in the track / album "…" menus
# ---------------------------------------------------------------------------
sub _registerInfoProviders {
    # Load the menu modules explicitly — if they aren't already loaded the
    # register call below dies and aborts the whole plugin, so guard each.
    eval {
        require Slim::Menu::TrackInfo;
        Slim::Menu::TrackInfo->registerInfoProvider(listentolater => {
            func => \&_trackInfoHandler,
        });
        $log->warn('LTL: registered TrackInfo provider');
        1;
    } or $log->error("LTL: TrackInfo provider registration failed: $@");

    eval {
        require Slim::Menu::AlbumInfo;
        Slim::Menu::AlbumInfo->registerInfoProvider(listentolater => {
            func => \&_albumInfoHandler,
        });
        $log->warn('LTL: registered AlbumInfo provider');
        1;
    } or $log->error("LTL: AlbumInfo provider registration failed: $@");
}

sub _trackInfoHandler {
    my ($client, $url, $track, $remoteMeta, $tags, $filter) = @_;
    $log->warn('LTL: TrackInfo handler called: url=' . ($url // '?')
        . ' track=' . (ref($track) || '?')
        . ' remoteMeta=' . (ref($remoteMeta) || '-'));
    my $rec = Plugins::ListenToLater::Sources::captureFromTrack($client, $url, $track, $remoteMeta);
    unless ($rec && $rec->{album_title}) {
        $log->warn('LTL: TrackInfo handler: no album captured, no menu item');
        return;
    }
    $log->warn("LTL: TrackInfo handler: captured $rec->{source} / $rec->{album_title}");
    return _addItem($client, $rec);
}

sub _albumInfoHandler {
    my ($client, $url, $album, $remoteMeta, $tags, $filter) = @_;
    $log->warn('LTL: AlbumInfo handler called: url=' . ($url // '?')
        . ' album=' . (ref($album) || ($album // '?'))
        . ' remoteMeta=' . (ref($remoteMeta) || '-'));
    my $rec = Plugins::ListenToLater::Sources::captureFromAlbum($client, $url, $album, $remoteMeta);
    unless ($rec && $rec->{album_title}) {
        $log->warn('LTL: AlbumInfo handler: no album captured, no menu item');
        return;
    }
    $log->warn("LTL: AlbumInfo handler: captured $rec->{album_title}");
    return _addItem($client, $rec);
}

# The shared menu item: a drill that performs the add and confirms briefly.
sub _addItem {
    my ($client, $rec) = @_;
    return {
        type  => 'link',
        name  => cstring($client, 'PLUGIN_LTL_ADD'),
        image => ICON,
        url   => sub {
            my ($c, $cb) = @_;
            my ($id, $already) = eval { Plugins::ListenToLater::DB::add($rec) };
            if ($@) {
                $log->error("add failed: $@");
                return $cb->({ items => [{ name => cstring($c, 'PLUGIN_LTL_ERROR'), type => 'text' }] });
            }
            $cb->({ items => [{
                name        => cstring($c, $already ? 'PLUGIN_LTL_ALREADY' : 'PLUGIN_LTL_ADDED'),
                type        => 'text',
                showBriefly => 1,
            }] });
        },
    };
}

sub getDisplayName { 'PLUGIN_LTL' }

sub playerMenu { undef }

1;
