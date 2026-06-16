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

    # CLI commands: [needClient, isQuery, hasTags, func]
    Slim::Control::Request::addDispatch(['listentolater', 'add'],         [0, 0, 1, \&_addCommand]);
    Slim::Control::Request::addDispatch(['listentolater', 'contextmenu'], [0, 1, 1, \&_contextMenuQuery]);
    Slim::Control::Request::addDispatch(['listentolater', 'remove'],      [0, 0, 1, \&_removeCommand]);
    Slim::Control::Request::addDispatch(['listentolater', 'move'],        [0, 0, 1, \&_moveCommand]);

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
        # NB: registerInfoProvider is ($class, $name, %details) — pass a FLAT
        # list, NOT a hashref. A hashref makes %details=(HASH=>undef) so `func`
        # is lost and the provider is silently skipped.
        Slim::Menu::TrackInfo->registerInfoProvider( listentolater => (
            menuMode => 1,
            before   => 'artwork',   # sit with the play actions, not buried in "More"
            func     => \&_trackInfoHandler,
        ) );
        $log->warn('LTL: registered TrackInfo provider');
        1;
    } or $log->error("LTL: TrackInfo provider registration failed: $@");

    eval {
        require Slim::Menu::AlbumInfo;
        Slim::Menu::AlbumInfo->registerInfoProvider( listentolater => (
            menuMode => 1,
            before   => 'contributors',   # after the play cluster, not in "More"
            func     => \&_albumInfoHandler,
        ) );
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

# The shared menu item. Modelled on the built-in `playitem`: a jive ACTION item
# (not a `url` drill — that rendered as a blank page) that fires the registered
# `listentolater add` command. The album is carried as flat string params; the
# command rebuilds the replayable ref from them.
sub _addItem {
    my ($client, $rec) = @_;

    my $ref     = $rec->{ref} || {};
    my $albumid = $ref->{album_id}
        || ($ref->{passthrough} && $ref->{passthrough}{album_id})
        || '';

    my $go = {
        player     => 0,
        cmd        => [ 'listentolater', 'add' ],
        params     => {
            source  => $rec->{source}      // 'library',
            artist  => $rec->{artist}      // '',
            album   => $rec->{album_title} // '',
            year    => $rec->{year}        // '',
            artwork => $rec->{artwork}     // '',
            albumid => $albumid,
            svc     => $ref->{_svc}        // '',
        },
        nextWindow => 'parent',
    };

    return {
        type => 'text',
        name => cstring($client, 'PLUGIN_LTL_ADD'),
        jive => {
            actions => { go => $go, play => $go, add => $go },
            style   => 'item',
        },
    };
}

# CLI command behind the menu item: write the album to the DB and confirm.
sub _addCommand {
    my $request = shift;

    my $source  = $request->getParam('source') || 'library';
    my $albumid = $request->getParam('albumid');
    my $svc     = $request->getParam('svc');

    my $ref;
    if ($source eq 'library') {
        $ref = { album_id => $albumid };
    }
    elsif (defined $albumid && length $albumid) {
        $ref = { _svc => $svc, album_id => $albumid, passthrough => { album_id => $albumid } };
    }
    else {
        $ref = { _svc => $svc };
    }

    my $rec = {
        source      => $source,
        artist      => $request->getParam('artist'),
        album_title => $request->getParam('album'),
        year        => ($request->getParam('year')    || undef),
        artwork     => ($request->getParam('artwork')  || undef),
        ref_kind    => ($source eq 'library' ? 'album_id' : ($albumid ? 'passthrough' : 'search')),
        ref         => $ref,
    };

    my ($id, $already) = eval { Plugins::ListenToLater::DB::add($rec) };
    if ($@) {
        $log->error("LTL: add command failed: $@");
    }
    else {
        $log->warn("LTL: add command -> id=" . ($id // '?') . " already=" . ($already // 0)
            . " ($rec->{source} / " . ($rec->{album_title} // '?') . ")");
    }

    if (my $client = $request->client) {
        my $msg = cstring($client, $already ? 'PLUGIN_LTL_ALREADY' : 'PLUGIN_LTL_ADDED');
        eval { $client->showBriefly({ line => [ cstring($client, 'PLUGIN_LTL'), $msg ] }, { duration => 2 }); };
    }

    $request->addResult('count', 1);
    $request->setStatusDone;
}

# The "…" → More context menu for an album row: Remove + Move. Each entry is a
# `do` action (runs the command without drilling) that pops back and refreshes
# the list (nextWindow => grandparent).
sub _contextMenuQuery {
    my $request = shift;

    my $id     = $request->getParam('id');
    my $client = $request->client;
    my $rec    = eval { Plugins::ListenToLater::DB::get($id) };

    my $status  = ($rec && $rec->{status}) ? $rec->{status} : 'later';
    my $target  = $status eq 'later' ? 'played' : 'later';
    my $moveStr = $status eq 'later' ? 'PLUGIN_LTL_MOVE_PLAYED' : 'PLUGIN_LTL_MOVE_LATER';

    my @entries = (
        {
            text    => cstring($client, 'PLUGIN_LTL_REMOVE'),
            cmd     => [ 'listentolater', 'remove' ],
            params  => { id => $id },
        },
        {
            text    => cstring($client, $moveStr),
            cmd     => [ 'listentolater', 'move' ],
            params  => { id => $id, status => $target },
        },
    );

    my $i = 0;
    for my $e (@entries) {
        $request->addResultLoop('item_loop', $i, 'text', $e->{text});
        $request->addResultLoop('item_loop', $i, 'actions', {
            do => { player => 0, cmd => $e->{cmd}, params => $e->{params} },
        });
        $request->addResultLoop('item_loop', $i, 'nextWindow', 'grandparent');
        $i++;
    }

    $request->addResult('offset', 0);
    $request->addResult('count', $i);
    $request->setStatusDone;
}

sub _removeCommand {
    my $request = shift;
    my $id = $request->getParam('id');
    eval { Plugins::ListenToLater::DB::remove($id); 1 } or $log->error("LTL: remove failed: $@");
    $request->setStatusDone;
}

sub _moveCommand {
    my $request = shift;
    my $id     = $request->getParam('id');
    my $status = $request->getParam('status') || 'later';
    eval { Plugins::ListenToLater::DB::setStatus($id, $status); 1 } or $log->error("LTL: move failed: $@");
    $request->setStatusDone;
}

sub getDisplayName { 'PLUGIN_LTL' }

sub playerMenu { undef }

1;
