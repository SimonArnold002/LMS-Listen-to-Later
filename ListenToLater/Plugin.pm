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

use JSON::XS ();
use File::Path ();
use File::Spec ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::PluginManager;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::ListenToLater::DB;
use Plugins::ListenToLater::Sources;

my $JSON = JSON::XS->new->utf8->canonical->pretty;

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
    material_action      => 1,         # add an "Add to Listen to Later" entry to Material's context menus
    played_retention_days => 7,        # auto-remove Played albums after N days (0 = keep forever)
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
    Slim::Control::Request::addDispatch(['listentolater', 'addctx'],      [0, 0, 1, \&_addCtxCommand]);
    Slim::Control::Request::addDispatch(['listentolater', 'contextmenu'], [0, 1, 1, \&_contextMenuQuery]);
    Slim::Control::Request::addDispatch(['listentolater', 'remove'],      [0, 0, 1, \&_removeCommand]);
    Slim::Control::Request::addDispatch(['listentolater', 'move'],        [0, 0, 1, \&_moveCommand]);
    Slim::Control::Request::addDispatch(['listentolater', 'buy'],         [0, 1, 1, \&_buyCommand]);

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

# Runs after all plugins have initialised — Material is then loadable. We add an
# "Add to Listen to Later" entry to Material's context menus via its custom-action
# file, so it sits in the MAIN menu (next to Add to Favourites) rather than buried
# in the providers' "More" submenu. Local item categories get it directly; the
# per-app qobuz/bandcamp categories carry it onto streaming pages.
sub postinitPlugin {
    my $class = shift;

    if ( $prefs->get('material_action')
      && Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin') ) {
        eval { _writeMaterialActions(); 1 }
            or $log->error("LTL: failed to write Material custom actions: $@");
    }

    # Material Skin home-page shelf for the Listen to Later list (guarded on the
    # registerHomeExtra API, like Qobuz/Bandcamp/ListenBrainz do).
    if ( Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin')
      && Plugins::MaterialSkin::Plugin->can('registerHomeExtra') ) {
        eval {
            require Plugins::ListenToLater::HomeExtras;
            Plugins::ListenToLater::HomeExtras->initPlugin();
            $log->info('LTL: registered Material home shelf');
            1;
        } or $log->error("LTL: failed to register Material home shelf: $@");
    }

    # Periodically purge Played albums older than the retention window. First run
    # shortly after startup, then once a day.
    Slim::Utils::Timers::killTimers(undef, \&_purgeTick);
    Slim::Utils::Timers::setTimer(undef, time() + 60, \&_purgeTick);

    return;
}

# Remove Played albums older than `played_retention_days`, then re-arm for ~24h.
sub _purgeTick {
    my $days = $prefs->get('played_retention_days');
    if (defined $days && $days =~ /^\d+$/ && $days > 0) {
        my $n = eval { Plugins::ListenToLater::DB::purgePlayed($days) } || 0;
        $log->error("LTL: purgePlayed failed: $@") if $@;
        $log->info("LTL: purged $n played album(s) older than $days day(s)") if $n;
    }
    Slim::Utils::Timers::setTimer(undef, time() + 86400, \&_purgeTick);
}

# ---------------------------------------------------------------------------
# Material custom actions (prefs/material-skin/actions.json)
# ---------------------------------------------------------------------------
sub _materialActionsFile {
    my $dir = File::Spec->catdir(Slim::Utils::Prefs::dir(), 'material-skin');
    return File::Spec->catfile($dir, 'actions.json');
}

sub _writeMaterialActions {
    my $file = _materialActionsFile();
    my $dir  = File::Spec->catdir(Slim::Utils::Prefs::dir(), 'material-skin');
    File::Path::make_path($dir) unless -d $dir;

    my $data = {};
    if (-e $file) {
        local $/;
        if (open my $fh, '<:raw', $file) {
            my $raw = <$fh>;
            close $fh;
            $data = eval { JSON::XS->new->utf8->decode($raw) } || {};
            $data = {} unless ref $data eq 'HASH';
        }
    }

    # `lmscommand` must be a FLAT array (verb + tag params); Material substitutes the
    # $VARS from the item and runs it fire-and-forget. $FAVURL carries the item's play
    # URL (qobuz://… etc.), which tells addctx the source. Unpopulated $VARS arrive as
    # the literal token ("$ALBUMNAME") — addctx ignores those.
    my $albumCmd = [ 'listentolater', 'addctx',
        'name:$ALBUMNAME', 'artist:$ARTISTNAME', 'albumid:$ALBUMID', 'year:$YEAR',
        'favurl:$FAVURL', 'image:$IMAGE' ];
    my $trackCmd = [ 'listentolater', 'addctx',
        'name:$ALBUMNAME', 'artist:$ARTISTNAME', 'albumid:$ALBUMID', 'year:$YEAR',
        'trackname:$TRACKNAME', 'trackid:$TRACKID', 'favurl:$FAVURL', 'image:$IMAGE' ];

    # Online (streaming) items don't expose $ALBUMNAME/$ARTISTNAME/$ALBUMID, but they
    # DO expose $TITLE (name), $FAVURL (qobuz://album:… — the source + id), and $IMAGE.
    # These `online-*` categories only do anything on a Material build that wires up
    # custom actions for online items (see docs/material-online-custom-actions-proposal).
    my $onlineCmd = [ 'listentolater', 'addctx',
        'name:$TITLE', 'artist:$ARTISTNAME', 'favurl:$FAVURL', 'image:$IMAGE' ];

    my %cats = (
        'album'          => $albumCmd,
        'album-track'    => $trackCmd,
        'track'          => $trackCmd,
        'playlist'       => $albumCmd,
        'playlist-track' => $trackCmd,
        'online-album'   => $onlineCmd,
        'online-track'   => $onlineCmd,
        'online-artist'  => $onlineCmd,
    );

    # First strip OUR entries from EVERY existing category (clears legacy 0.1.7 hash
    # entries and any stale local ones); then add the current entry where we want it.
    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY';
        $data->{$cat} = [ grep { !_isOurAction($_) } @{ $data->{$cat} } ];
    }

    # Two entries per category: "Add to Listen to Later" (the base command, which
    # defaults to the Listen to Later list) and "Add to To Buy" (the same command
    # plus list:tobuy). Both are stripped/rewritten on each run by _isOurAction.
    for my $cat (keys %cats) {
        my $base = $cats{$cat};
        push @{ $data->{$cat} ||= [] },
            {
                title      => 'Add to Listen to Later',
                icon       => 'playlist_add',
                lmscommand => $base,
            },
            {
                title      => 'Add to To Buy',
                icon       => 'shopping_cart',
                lmscommand => [ @$base, 'list:tobuy' ],
            };
    }

    # Suppress the generic streaming "Add" inside our OWN surfaces (the plugin list
    # view, command 'listentolater'; and the Material home shelf, command 'LtLHome').
    # Defining these (empty) categories tells the patched Material to use them instead
    # of "online-*" for those items — so an album already in the list isn't offered
    # "Add to Listen to Later" again (re-adding would bounce a Played album back to
    # Listen to Later). Remove/Move live in each row's "…" → More menu (which refreshes
    # the list in place), since putting them at the top of the "…" would need a further
    # Material change.
    $data->{$_} = [] for qw(
        listentolater-album listentolater-track listentolater-artist
        LtLHome-album LtLHome-track LtLHome-artist
    );

    open my $fh, '>:raw', $file or die "open $file: $!";
    print $fh $JSON->encode($data);
    close $fh;

    $log->warn("LTL: wrote Material custom actions to $file");
    return;
}

sub _isOurAction {
    my ($entry) = @_;
    return 0 unless ref $entry eq 'HASH';
    my $lc = $entry->{lmscommand};
    # current format: a flat array
    return 1 if ref $lc eq 'ARRAY' && ($lc->[0] // '') eq 'listentolater';
    # legacy 0.1.7 format: { command => [...] }
    return 1 if ref $lc eq 'HASH' && ref $lc->{command} eq 'ARRAY' && ($lc->{command}[0] // '') eq 'listentolater';
    # fallback: our title
    return 1 if ($entry->{title} // '') eq 'Add to Listen to Later';
    return 0;
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
# command rebuilds the replayable ref from them. Two entries are offered — "Add to
# Listen to Later" and "Add to To Buy" — differing only in the `list` param.
sub _addItem {
    my ($client, $rec) = @_;

    return [
        _addItemFor($client, $rec, 'later', 'PLUGIN_LTL_ADD'),
        _addItemFor($client, $rec, 'tobuy', 'PLUGIN_LTL_ADD_TOBUY'),
    ];
}

sub _addItemFor {
    my ($client, $rec, $list, $labelStr) = @_;

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
            list    => $list,
        },
        nextWindow => 'parent',
    };

    return {
        type => 'text',
        name => cstring($client, $labelStr),
        jive => {
            actions => { go => $go, play => $go, add => $go },
            style   => 'item',
        },
    };
}

# Normalise the requested target list. Only 'tobuy' and the default 'later' are
# valid add targets ('played' is reached by playing or by an explicit Move).
sub _wantedList {
    my ($v) = @_;
    return (defined $v && $v eq 'tobuy') ? 'tobuy' : 'later';
}

# The confirmation toast, varying by list and whether it was already present.
sub _addedMsg {
    my ($client, $list, $already) = @_;
    return cstring($client, 'PLUGIN_LTL_ALREADY') if $already;
    return cstring($client, $list eq 'tobuy' ? 'PLUGIN_LTL_ADDED_TOBUY' : 'PLUGIN_LTL_ADDED');
}

# CLI command behind the menu item: write the album to the DB and confirm.
sub _addCommand {
    my $request = shift;

    my $source  = $request->getParam('source') || 'library';
    my $albumid = $request->getParam('albumid');
    my $svc     = $request->getParam('svc');
    my $list    = _wantedList($request->getParam('list'));

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

    my ($id, $already) = eval { Plugins::ListenToLater::DB::add($rec, $list) };
    if ($@) {
        $log->error("LTL: add command failed: $@");
    }
    else {
        $log->warn("LTL: add command -> id=" . ($id // '?') . " already=" . ($already // 0)
            . " list=$list ($rec->{source} / " . ($rec->{album_title} // '?') . ")");
    }

    if (my $client = $request->client) {
        eval { $client->showBriefly({ line => [ cstring($client, 'PLUGIN_LTL'), _addedMsg($client, $list, $already) ] }, { duration => 2 }); };
    }

    $request->addResult('count', 1);
    $request->setStatusDone;
}

# The "…" → More context menu for an album row: Remove + Move. Each entry is a
# `do` action (runs the command without drilling) that refreshes the list in
# place (nextWindow => parent on a More menu).
sub _contextMenuQuery {
    my $request = shift;

    my $id     = $request->getParam('id');
    my $client = $request->client;
    my $rec    = eval { Plugins::ListenToLater::DB::get($id) };

    my $status = ($rec && $rec->{status}) ? $rec->{status} : 'later';

    # Offer a "Move to …" for each of the other two lists, then Remove. Order is
    # fixed (later, tobuy, played) so the menu is stable regardless of which list
    # the row is currently in.
    my %moveStr = (
        later  => 'PLUGIN_LTL_MOVE_LATER',
        tobuy  => 'PLUGIN_LTL_MOVE_TOBUY',
        played => 'PLUGIN_LTL_MOVE_PLAYED',
    );

    my @entries;

    # Bandcamp items: a "Buy on Bandcamp" entry that drills into the `buy` query,
    # which resolves the album's bandcamp.com page and opens it (see _buyCommand).
    # A `go` (drill) entry, not a `do` — so it navigates to the link rather than
    # firing-and-refreshing in place.
    if ($rec && ($rec->{source} || '') eq 'bandcamp') {
        push @entries, {
            text => cstring($client, 'PLUGIN_LTL_BUY_BANDCAMP'),
            go   => { player => 0, cmd => [ 'listentolater', 'buy' ], params => { id => $id } },
        };
    }

    for my $target (qw(later tobuy played)) {
        next if $target eq $status;
        push @entries, {
            text   => cstring($client, $moveStr{$target}),
            cmd    => [ 'listentolater', 'move' ],
            params => { id => $id, status => $target },
        };
    }
    push @entries, {
        text   => cstring($client, 'PLUGIN_LTL_REMOVE'),
        cmd    => [ 'listentolater', 'remove' ],
        params => { id => $id },
    };

    my $i = 0;
    for my $e (@entries) {
        $request->addResultLoop('item_loop', $i, 'text', $e->{text});
        if ($e->{go}) {
            # Drill into the buy query; no nextWindow (we want to navigate, not refresh).
            $request->addResultLoop('item_loop', $i, 'actions', { go => $e->{go} });
        }
        else {
            $request->addResultLoop('item_loop', $i, 'actions', {
                do => { player => 0, cmd => $e->{cmd}, params => $e->{params} },
            });
            # 'parent' on a "More" menu action makes Material refresh the list in place
            # (browse-functions.js: isMoreMenu && nextWindow=="parent" -> refreshList),
            # so Remove/Move update the list without jumping back to the home screen.
            $request->addResultLoop('item_loop', $i, 'nextWindow', 'parent');
        }
        $i++;
    }

    $request->addResult('offset', 0);
    $request->addResult('count', $i);
    $request->setStatusDone;
}

# Resolve a Bandcamp item's purchase page and return it as a clickable weblink
# (opens in the browser). Async: resolves the album on first use and caches the
# URL in the DB so later opens are instant. Always returns a link — falls back to
# a Bandcamp album search if the exact page can't be found.
sub _buyCommand {
    my $request = shift;

    my $client = $request->client;
    my $id     = $request->getParam('id');
    my $rec    = eval { Plugins::ListenToLater::DB::get($id) };

    if (!$rec || ($rec->{source} || '') ne 'bandcamp') {
        $request->addResult('offset', 0);
        $request->addResult('count', 0);
        return $request->setStatusDone;
    }

    my $emit = sub {
        my ($url) = @_;
        $request->addResultLoop('item_loop', 0, 'text', cstring($client, 'PLUGIN_LTL_BUY_OPEN'));
        $request->addResultLoop('item_loop', 0, 'weblink', $url);
        $request->addResult('offset', 0);
        $request->addResult('count', 1);
        $request->setStatusDone;
    };

    # Cached from a previous open → instant.
    my $cached = (ref $rec->{ref} eq 'HASH') ? $rec->{ref}{buy_url} : undef;
    return $emit->($cached) if $cached;

    $request->setStatusProcessing;
    Plugins::ListenToLater::Sources::bandcampBuyUrl($client, $rec, sub {
        my $url = shift;
        if ($url) {
            eval { Plugins::ListenToLater::DB::setRefValue($id, 'buy_url', $url); 1 }
                or $log->error("LTL: cache buy_url failed: $@");
        }
        else {
            # No exact page — a Bandcamp album search for "artist album" still lands
            # the user on Bandcamp to buy it.
            require URI::Escape;
            my $q = URI::Escape::uri_escape_utf8(
                join(' ', grep { defined && length } ($rec->{artist}, $rec->{album_title})));
            $url = "https://bandcamp.com/search?item_type=a&q=$q";
        }
        $log->warn("LTL: buy -> " . ($url // '?') . " (rec $id)");
        $emit->($url);
    });
}

# Add triggered by a Material custom action. The variables Material substitutes
# for online (Qobuz/Bandcamp) items are uncertain, so log everything we receive,
# then add best-effort: if the album id resolves to a matching local library
# album it's stored as a library album (reliable replay); otherwise it's treated
# as a streaming album (replayed via the service's search — proven to work).
sub _addCtxCommand {
    my $request = shift;

    # Unpopulated Material $VARS arrive as the literal token (e.g. "$ALBUMNAME") —
    # treat those as undef.
    my %p = map {
        my $v = $request->getParam($_);
        $v = undef if defined $v && $v =~ /^\$[A-Z]/;
        ($_ => $v)
    } qw(name artist albumid trackname trackid year favurl image svc);

    my $list = _wantedList($request->getParam('list'));

    $log->warn('LTL: addctx params -> '
        . join(', ', map { "$_=" . (defined $p{$_} ? $p{$_} : '(undef)') } qw(name artist albumid year trackname trackid favurl image svc)));

    my $artist  = $p{artist};
    my $artwork = $p{image};
    my $year    = $p{year};
    my $album   = $p{name};
    # Material appends " (YYYY)" to album display titles — strip it for a clean
    # album name (and use it as the year if none was passed).
    if (defined $album && $album =~ s/\s*\((\d{4})\)\s*$//) {
        $year ||= $1;
    }
    # Streaming browse rows often carry the year on the artist line ("Artist (2026)")
    # and a quality/format qualifier on the album ("Album (Hi-Res)"); clean both so the
    # stored name/artist are searchable.
    if (defined $artist && $artist =~ s/\s*\((\d{4})\)\s*$//) {
        $year ||= $1;
    }
    if (defined $album) {
        $album =~ s/\s*\((?:Hi-Res[^)]*|Explicit|Mono|Stereo)\)\s*$//i;
    }
    unless (defined $album && length $album) {
        $log->warn('LTL: addctx had no album name — nothing added');
        return $request->setStatusDone;
    }

    # A streaming play URL (qobuz://…, bandcamp://…) names the source. file:// / db:
    # / empty are local. A numeric album id that resolves in the library is the
    # authoritative "this is a local album" signal — trust it over the (year-suffixed,
    # often empty) display fields, and take the real metadata from the album object.
    my $favScheme = ($p{favurl} && $p{favurl} =~ m|^(\w+)://|) ? lc($1) : '';
    my $streaming = ($favScheme && $favScheme ne 'file') ? $favScheme : '';

    my $libAlbum;
    if (!$streaming && defined $p{albumid} && $p{albumid} =~ /^\d+$/) {
        $libAlbum = eval { Slim::Schema->find('Album', $p{albumid}) };
    }

    my ($source, $ref);
    if ($libAlbum) {
        $source  = 'library';
        $ref     = { album_id => $p{albumid} };
        $album   = $libAlbum->title;
        $artist  = (eval { $libAlbum->contributor ? $libAlbum->contributor->name : undef }) // $artist;
        $year  ||= (eval { $libAlbum->year } || undef);
        $artwork = (eval { $libAlbum->artwork ? 'music/' . $libAlbum->artwork . '/cover' : undef }) // $artwork;
    }
    elsif ($streaming) {
        $source = Plugins::ListenToLater::Sources::sourceFromUrl($p{favurl});
        # Some services put the native album id in the favurl (e.g. Tidal
        # tidal://album:529626253) — capture it so we replay through the service's own
        # album node instead of a fuzzy artist+album search.
        my ($aid) = $p{favurl} =~ m{(?:[:/])album:([A-Za-z0-9._-]+)};
        $ref = $aid
            ? { _svc => $source, album_id => $aid, passthrough => { album_id => $aid } }
            : { _svc => $source };
    }
    else {
        # Streaming album rows carry no favorites_url; the browsing service id is
        # passed explicitly as svc (a Material view belongs to one service). Fall back
        # to the cover host, then the default streaming service.
        my $svc = ($p{svc} && $p{svc} =~ /^[a-z0-9]+$/i) ? lc $p{svc} : '';
        $source = $svc
                  || Plugins::ListenToLater::Sources::sourceFromImage($artwork)
                  || _defaultStreamingSource();
        $ref    = { _svc => $source };
    }

    my $rec = {
        source      => $source,
        artist      => $artist,
        album_title => $album,
        year        => ($year && $year =~ /(\d{4})/) ? $1 : undef,
        artwork     => $artwork,
        ref_kind    => ($source eq 'library' ? 'album_id' : 'search'),
        ref         => $ref,
    };

    my ($id, $already) = eval { Plugins::ListenToLater::DB::add($rec, $list) };
    if ($@) {
        $log->error("LTL: addctx add failed: $@");
    }
    else {
        $log->warn("LTL: addctx -> $source / " . ($album // '?') . " (id=" . ($id // '?') . ", already=" . ($already // 0) . ", list=$list)");
    }

    if (my $client = $request->client) {
        eval { $client->showBriefly({ line => [ cstring($client, 'PLUGIN_LTL'), _addedMsg($client, $list, $already) ] }, { duration => 2 }); };
    }

    $request->setStatusDone;
}

sub _defaultStreamingSource {
    return 'qobuz'    if Slim::Utils::PluginManager->isEnabled('Plugins::Qobuz::Plugin');
    return 'bandcamp' if Slim::Utils::PluginManager->isEnabled('Plugins::Bandcamp::Plugin');
    return 'qobuz';
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
    $status = 'later' unless $status =~ /^(?:later|played|tobuy)$/;
    eval { Plugins::ListenToLater::DB::setStatus($id, $status); 1 } or $log->error("LTL: move failed: $@");
    $request->setStatusDone;
}

sub getDisplayName { 'PLUGIN_LTL' }

sub playerMenu { undef }

1;
