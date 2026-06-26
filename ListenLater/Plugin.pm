package Plugins::ListenLater::Plugin;

# Listen Later — save an album from any source (library / Qobuz / Bandcamp)
# into a curated list, browse it as a "playlist of albums", and have albums move
# to a Played section once you've listened to most of them.
#
# Add path: a Slim::Menu::TrackInfo provider (fires for local AND remote tracks)
# plus a Slim::Menu::AlbumInfo provider (library albums) put an "Add album to
# Listen Later" entry in the "…" menu. Both return an OPML drill coderef that
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

use Plugins::ListenLater::DB;
use Plugins::ListenLater::Sources;

my $JSON = JSON::XS->new->utf8->canonical->pretty;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.listenlater',
    'defaultLevel' => 'INFO',
    'description'  => 'PLUGIN_LL',
});

my $prefs = preferences('plugin.listenlater');

$prefs->init({
    sort                 => 'added',   # added|artist|album|year|played
    played_threshold     => 60,        # % of library album tracks → Played
    streaming_min_tracks => 4,         # distinct streaming tracks → Played (no total available)
    watch_outside        => 1,         # mark Played from plays started outside the plugin
    material_action      => 1,         # add an "Add to Listen Later" entry to Material's context menus
    played_retention_days => 7,        # auto-remove Played albums after N days (0 = keep forever)
});

sub initPlugin {
    my $class = shift;

    # One-time rebrand migration: copy settings from the old plugin.listentolater
    # prefs namespace (the plugin was "Listen to Later" before this release).
    _migrateRebrandPrefs();

    if (main::WEBUI) {
        require Plugins::ListenLater::Settings;
        Plugins::ListenLater::Settings->new();
    }

    require Plugins::ListenLater::Browse;

    # Open / migrate the DB up front so the first add is instant and errors show
    # at startup rather than mid-interaction.
    eval { Plugins::ListenLater::DB::dbh(); 1 }
        or $log->error("Listen Later DB init failed: $@");

    # CLI commands: [needClient, isQuery, hasTags, func]
    Slim::Control::Request::addDispatch(['listenlater', 'add'],         [0, 0, 1, \&_addCommand]);
    Slim::Control::Request::addDispatch(['listenlater', 'addctx'],      [0, 0, 1, \&_addCtxCommand]);
    Slim::Control::Request::addDispatch(['listenlater', 'contextmenu'], [0, 1, 1, \&_contextMenuQuery]);
    Slim::Control::Request::addDispatch(['listenlater', 'remove'],      [0, 0, 1, \&_removeCommand]);
    Slim::Control::Request::addDispatch(['listenlater', 'move'],        [0, 0, 1, \&_moveCommand]);
    Slim::Control::Request::addDispatch(['listenlater', 'buy'],         [0, 1, 1, \&_buyCommand]);

    _registerInfoProviders();

    require Plugins::ListenLater::Played;
    Plugins::ListenLater::Played->init();

    $class->SUPER::initPlugin(
        tag    => 'listenlater',
        feed   => \&Plugins::ListenLater::Browse::topLevel,
        is_app => 1,
        menu   => 'radios',
        weight => 10,
    );

    return;
}

# Copy prefs from the pre-rebrand namespace (plugin.listentolater) into ours once.
# Runs after $prefs->init (top of module), so it overrides defaults with the user's
# previous values where they were set.
sub _migrateRebrandPrefs {
    return if $prefs->get('_rebrand_migrated');
    my $old = preferences('plugin.listentolater');
    for my $k (qw(sort played_threshold streaming_min_tracks watch_outside material_action played_retention_days)) {
        my $ov = $old->get($k);
        $prefs->set($k, $ov) if defined $ov;
    }
    $prefs->set('_rebrand_migrated', 1);
    $log->info('Listen Later: migrated prefs from plugin.listentolater');
    return;
}

# Runs after all plugins have initialised — Material is then loadable. We add an
# "Add to Listen Later" entry to Material's context menus via its custom-action
# file, so it sits in the MAIN menu (next to Add to Favourites) rather than buried
# in the providers' "More" submenu. Local item categories get it directly; the
# per-app qobuz/bandcamp categories carry it onto streaming pages.
sub postinitPlugin {
    my $class = shift;

    if ( $prefs->get('material_action')
      && Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin') ) {
        eval { _writeMaterialActions(); 1 }
            or $log->error("LL: failed to write Material custom actions: $@");
    }

    # Material Skin home-page shelf for the Listen Later list (guarded on the
    # registerHomeExtra API, like Qobuz/Bandcamp/ListenBrainz do).
    if ( Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin')
      && Plugins::MaterialSkin::Plugin->can('registerHomeExtra') ) {
        eval {
            require Plugins::ListenLater::HomeExtras;
            Plugins::ListenLater::HomeExtras->initPlugin();
            $log->info('LL: registered Material home shelf');
            1;
        } or $log->error("LL: failed to register Material home shelf: $@");
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
        my $n = eval { Plugins::ListenLater::DB::purgePlayed($days) } || 0;
        $log->error("LL: purgePlayed failed: $@") if $@;
        $log->info("LL: purged $n played album(s) older than $days day(s)") if $n;
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
    my $albumCmd = [ 'listenlater', 'addctx',
        'name:$ALBUMNAME', 'artist:$ARTISTNAME', 'albumid:$ALBUMID', 'year:$YEAR',
        'favurl:$FAVURL', 'image:$IMAGE' ];
    my $trackCmd = [ 'listenlater', 'addctx',
        'name:$ALBUMNAME', 'artist:$ARTISTNAME', 'albumid:$ALBUMID', 'year:$YEAR',
        'trackname:$TRACKNAME', 'trackid:$TRACKID', 'favurl:$FAVURL', 'image:$IMAGE' ];

    # Online (streaming) items don't expose $ALBUMNAME/$ARTISTNAME/$ALBUMID, but they
    # DO expose $TITLE (name), $FAVURL (qobuz://album:… — the source + id), and $IMAGE.
    # The merged upstream Material (PR #1235, dev) sets i.service=<browse command> and
    # exposes it as $SERVICE — the clean replacement for the old "bake svc:<command>
    # into the lmscommand" hack. So pass svc:$SERVICE; addctx reads it as the
    # authoritative source. (Unpopulated → literal "$SERVICE", which addctx's
    # ^[a-z0-9]+$ check rejects → empty → cover-host fallback.)
    # These `online-*` categories only do anything on a Material build that wires up
    # custom actions for online items (see docs/material-online-custom-actions-proposal).
    my $onlineCmd = [ 'listenlater', 'addctx',
        'name:$TITLE', 'artist:$ARTISTNAME', 'svc:$SERVICE', 'favurl:$FAVURL', 'image:$IMAGE' ];

    # NB: deliberately NO plain 'track' category. Material's Now Playing screen is
    # the ONLY consumer of 'track' (nowplaying-page.js getCustomActions("track")) —
    # browse track lists use 'album-track'/'playlist-track', the queue uses
    # 'queue-track', streaming rows use 'online-track'. Writing 'track' would put
    # "Add to Listen Later" on Now Playing only, which we don't want. Omitting it
    # suppresses it there with no effect on any browse surface — and the strip pass
    # above clears any 'track' entry a previous version wrote.
    my %cats = (
        'album'          => $albumCmd,
        'album-track'    => $trackCmd,
        'playlist'       => $albumCmd,
        'playlist-track' => $trackCmd,
        'online-album'   => $onlineCmd,
        'online-track'   => $onlineCmd,
        # NB: deliberately NO 'online-artist' — we save albums, not artists. An
        # artist row's $TITLE is the artist name (no album, no favurl), so adding
        # one would store a junk record (album_title = artist) that can never replay.
    );

    # First strip OUR entries from EVERY existing category (clears legacy 0.1.7 hash
    # entries and any stale local ones); then add the current entry where we want it.
    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY';
        $data->{$cat} = [ grep { !_isOurAction($_) } @{ $data->{$cat} } ];
    }

    # Drop our pre-rebrand suppression categories (the old command was 'listentolater'
    # and the old home-shelf tag 'LtLHome') so they don't linger as empty keys.
    delete $data->{$_} for qw(
        listentolater-album listentolater-track listentolater-artist
        LtLHome-album LtLHome-track LtLHome-artist
    );

    # Two entries per category: "Add to Listen Later" (the base command, which
    # defaults to the Listen Later list) and "Add to Wish List" (the same command
    # plus list:wishlist). Both are stripped/rewritten on each run by _isOurAction.
    for my $cat (keys %cats) {
        my $base = $cats{$cat};
        push @{ $data->{$cat} ||= [] },
            {
                title      => 'Add to Listen Later',
                icon       => 'playlist_add',
                lmscommand => $base,
            },
            {
                title      => 'Add to Wish List',
                icon       => 'shopping_cart',
                lmscommand => [ @$base, 'list:wishlist' ],
            };
    }

    # Suppress the generic streaming "Add" inside our OWN surfaces (the plugin list
    # view, command 'listenlater'; and the Material home shelf, command 'LLHome').
    # Defining these (empty) categories tells the patched Material to use them instead
    # of "online-*" for those items — so an album already in the list isn't offered
    # "Add to Listen Later" again (re-adding would bounce a Played album back to
    # Listen Later). Remove/Move live in each row's "…" → More menu (which refreshes
    # the list in place), since putting them at the top of the "…" would need a further
    # Material change.
    $data->{$_} = [] for qw(
        listenlater-album listenlater-track listenlater-artist
        LLHome-album LLHome-track LLHome-artist
    );

    # Write atomically: actions.json is SHARED with Material and every other
    # plugin/user custom action, so a truncated write (crash mid-write) would
    # corrupt all of them. Write a temp file then rename() over the original.
    my $tmp = "$file.tmp.$$";
    open my $fh, '>:raw', $tmp or die "open $tmp: $!";
    print $fh $JSON->encode($data) or do { close $fh; unlink $tmp; die "write $tmp: $!" };
    close $fh                      or do {            unlink $tmp; die "close $tmp: $!" };
    rename($tmp, $file)            or do {            unlink $tmp; die "rename $tmp -> $file: $!" };

    $log->warn("LL: wrote Material custom actions to $file");
    return;
}

sub _isOurAction {
    my ($entry) = @_;
    return 0 unless ref $entry eq 'HASH';
    # Match the current verb 'listenlater' AND the pre-rebrand 'listentolater', so a
    # startup after the rename strips stale "Add to Listen to Later"/"Add to To Buy"
    # entries left in actions.json by the old plugin.
    my $isOurs = sub { my $v = shift // ''; $v eq 'listenlater' || $v eq 'listentolater' };
    my $lc = $entry->{lmscommand};
    # current format: a flat array
    return 1 if ref $lc eq 'ARRAY' && $isOurs->($lc->[0]);
    # legacy 0.1.7 format: { command => [...] }
    return 1 if ref $lc eq 'HASH' && ref $lc->{command} eq 'ARRAY' && $isOurs->($lc->{command}[0]);
    # fallback: our titles (current + pre-rebrand)
    my %ours = map { $_ => 1 }
        ('Add to Listen Later', 'Add to Wish List', 'Add to Listen to Later', 'Add to To Buy');
    return 1 if $ours{ $entry->{title} // '' };
    return 0;
}

# ---------------------------------------------------------------------------
# "Add album to Listen Later" entries in the track / album "…" menus
# ---------------------------------------------------------------------------
sub _registerInfoProviders {
    # Load the menu modules explicitly — if they aren't already loaded the
    # register call below dies and aborts the whole plugin, so guard each.
    eval {
        require Slim::Menu::TrackInfo;
        # NB: registerInfoProvider is ($class, $name, %details) — pass a FLAT
        # list, NOT a hashref. A hashref makes %details=(HASH=>undef) so `func`
        # is lost and the provider is silently skipped.
        Slim::Menu::TrackInfo->registerInfoProvider( listenlater => (
            menuMode => 1,
            before   => 'artwork',   # sit with the play actions, not buried in "More"
            func     => \&_trackInfoHandler,
        ) );
        $log->warn('LL: registered TrackInfo provider');
        1;
    } or $log->error("LL: TrackInfo provider registration failed: $@");

    eval {
        require Slim::Menu::AlbumInfo;
        Slim::Menu::AlbumInfo->registerInfoProvider( listenlater => (
            menuMode => 1,
            before   => 'contributors',   # after the play cluster, not in "More"
            func     => \&_albumInfoHandler,
        ) );
        $log->warn('LL: registered AlbumInfo provider');
        1;
    } or $log->error("LL: AlbumInfo provider registration failed: $@");
}

sub _trackInfoHandler {
    my ($client, $url, $track, $remoteMeta, $tags, $filter) = @_;
    $log->warn('LL: TrackInfo handler called: url=' . ($url // '?')
        . ' track=' . (ref($track) || '?')
        . ' remoteMeta=' . (ref($remoteMeta) || '-'));
    my $rec = Plugins::ListenLater::Sources::captureFromTrack($client, $url, $track, $remoteMeta);
    unless ($rec && $rec->{album_title}) {
        $log->warn('LL: TrackInfo handler: no album captured, no menu item');
        return;
    }
    $log->warn("LL: TrackInfo handler: captured $rec->{source} / $rec->{album_title}");
    return _addItem($client, $rec);
}

sub _albumInfoHandler {
    my ($client, $url, $album, $remoteMeta, $tags, $filter) = @_;
    $log->warn('LL: AlbumInfo handler called: url=' . ($url // '?')
        . ' album=' . (ref($album) || ($album // '?'))
        . ' remoteMeta=' . (ref($remoteMeta) || '-'));
    my $rec = Plugins::ListenLater::Sources::captureFromAlbum($client, $url, $album, $remoteMeta);
    unless ($rec && $rec->{album_title}) {
        $log->warn('LL: AlbumInfo handler: no album captured, no menu item');
        return;
    }
    $log->warn("LL: AlbumInfo handler: captured $rec->{album_title}");
    return _addItem($client, $rec);
}

# The shared menu item. Modelled on the built-in `playitem`: a jive ACTION item
# (not a `url` drill — that rendered as a blank page) that fires the registered
# `listenlater add` command. The album is carried as flat string params; the
# command rebuilds the replayable ref from them. Two entries are offered — "Add to
# Listen Later" and "Add to Wish List" — differing only in the `list` param.
sub _addItem {
    my ($client, $rec) = @_;

    return [
        _addItemFor($client, $rec, 'later', 'PLUGIN_LL_ADD'),
        _addItemFor($client, $rec, 'wishlist', 'PLUGIN_LL_ADD_WISHLIST'),
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
        cmd        => [ 'listenlater', 'add' ],
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

# Normalise the requested target list. Only 'wishlist' and the default 'later' are
# valid add targets ('played' is reached by playing or by an explicit Move).
sub _wantedList {
    my ($v) = @_;
    return (defined $v && $v eq 'wishlist') ? 'wishlist' : 'later';
}

# The confirmation toast, varying by list and whether it was already present.
# When it's already saved from a DIFFERENT service, name that service so it's
# clear why the add was a no-op (e.g. "Already saved from Qobuz").
sub _addedMsg {
    my ($client, $list, $already, $existingSource, $newSource) = @_;
    if ($already) {
        if ($existingSource && $newSource && lc($existingSource) ne lc($newSource)) {
            return sprintf(cstring($client, 'PLUGIN_LL_ALREADY_FROM'), ucfirst($existingSource));
        }
        return cstring($client, 'PLUGIN_LL_ALREADY');
    }
    return cstring($client, $list eq 'wishlist' ? 'PLUGIN_LL_ADDED_WISHLIST' : 'PLUGIN_LL_ADDED');
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

    my ($id, $already, $existingSource) = eval { Plugins::ListenLater::DB::add($rec, $list) };
    if ($@) {
        $log->error("LL: add command failed: $@");
    }
    else {
        $log->warn("LL: add command -> id=" . ($id // '?') . " already=" . ($already // 0)
            . " list=$list ($rec->{source} / " . ($rec->{album_title} // '?') . ")");
    }

    if (my $client = $request->client) {
        eval { $client->showBriefly({ line => [ cstring($client, 'PLUGIN_LL'), _addedMsg($client, $list, $already, $existingSource, $rec->{source}) ] }, { duration => 2 }); };
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
    my $rec    = eval { Plugins::ListenLater::DB::get($id) };

    my $status = ($rec && $rec->{status}) ? $rec->{status} : 'later';

    # Offer a "Move to …" for each of the other two lists, then Remove. Order is
    # fixed (later, wishlist, played) so the menu is stable regardless of which list
    # the row is currently in.
    my %moveStr = (
        later  => 'PLUGIN_LL_MOVE_LATER',
        wishlist  => 'PLUGIN_LL_MOVE_WISHLIST',
        played => 'PLUGIN_LL_MOVE_PLAYED',
    );

    my @entries;

    # Bandcamp items: a "Buy on Bandcamp" entry that drills into the `buy` query,
    # which resolves the album's bandcamp.com page and opens it (see _buyCommand).
    # A `go` (drill) entry, not a `do` — so it navigates to the link rather than
    # firing-and-refreshing in place.
    if ($rec && ($rec->{source} || '') eq 'bandcamp') {
        push @entries, {
            text => cstring($client, 'PLUGIN_LL_BUY_BANDCAMP'),
            go   => { player => 0, cmd => [ 'listenlater', 'buy' ], params => { id => $id } },
        };
    }

    for my $target (qw(later wishlist played)) {
        next if $target eq $status;
        push @entries, {
            text   => cstring($client, $moveStr{$target}),
            cmd    => [ 'listenlater', 'move' ],
            params => { id => $id, status => $target },
        };
    }
    push @entries, {
        text   => cstring($client, 'PLUGIN_LL_REMOVE'),
        cmd    => [ 'listenlater', 'remove' ],
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
    my $rec    = eval { Plugins::ListenLater::DB::get($id) };

    if (!$rec || ($rec->{source} || '') ne 'bandcamp') {
        $request->addResult('offset', 0);
        $request->addResult('count', 0);
        return $request->setStatusDone;
    }

    # Guard so the request completes exactly once, whether from the resolve
    # callback or the timeout below.
    my $done = 0;
    my $emit = sub {
        my ($url) = @_;
        return if $done;
        $done = 1;
        $request->addResultLoop('item_loop', 0, 'text', cstring($client, 'PLUGIN_LL_BUY_OPEN'));
        $request->addResultLoop('item_loop', 0, 'weblink', $url);
        $request->addResult('offset', 0);
        $request->addResult('count', 1);
        $request->setStatusDone;
    };

    # Cached from a previous open → instant.
    my $cached = (ref $rec->{ref} eq 'HASH') ? $rec->{ref}{buy_url} : undef;
    return $emit->($cached) if $cached;

    # Fallback used if the exact page can't be resolved OR the resolve stalls: a
    # Bandcamp album search for "artist album" still lands the user on Bandcamp to
    # buy it. Not cached — so a later open can still resolve the real page.
    require URI::Escape;
    my $q = URI::Escape::uri_escape_utf8(
        join(' ', grep { defined && length } ($rec->{artist}, $rec->{album_title})));
    my $searchUrl = "https://bandcamp.com/search?item_type=a&q=$q";

    $request->setStatusProcessing;

    # Bandcamp's async search may never call back (network stall, no error path);
    # guarantee completion so the Material query doesn't spin forever.
    my $timeout = sub {
        return if $done;
        $log->warn("LL: buy resolve timed out (rec $id) — using search URL");
        $emit->($searchUrl);
    };
    Slim::Utils::Timers::setTimer(undef, time() + 15, $timeout);

    Plugins::ListenLater::Sources::bandcampBuyUrl($client, $rec, sub {
        my $url = shift;
        # Resolve won the race — cancel the fallback timer so its closure (and the
        # held request) is freed now rather than lingering for the full 15s.
        Slim::Utils::Timers::killTimers(undef, $timeout);
        if ($url) {
            eval { Plugins::ListenLater::DB::setRefValue($id, 'buy_url', $url); 1 }
                or $log->error("LL: cache buy_url failed: $@");
        }
        else {
            $url = $searchUrl;
        }
        $log->warn("LL: buy -> " . ($url // '?') . " (rec $id)");
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

    # A favurl from the sibling ListenBrainz Fresh Releases plugin carries the album
    # cover as a "?cover=<url-encoded>" param: its matched rows show the streaming
    # SERVICE LOGO as the thumbnail, so $IMAGE is the logo, not the art. Pull the
    # cover out and prefer it over $IMAGE, then strip the param so the source /
    # album:<id> logic below sees a clean "<scheme>://album:<id>". Only fires when
    # the param is present, so native streaming-plugin favurls are byte-unchanged.
    # Strip the param with its OWN leading delimiter ([?&]): removing "&cover=…"
    # (cover as a later param) or "?cover=…" (cover as the lone param — what LBF
    # actually appends) both leave a well-formed favurl. [^&]* (not +) tolerates an
    # empty value. We don't consume a trailing "&", so nothing is glued together.
    my $favCover;
    if ($p{favurl} && $p{favurl} =~ s{[?&]cover=([^&]*)}{}) {
        require URI::Escape;
        $favCover = URI::Escape::uri_unescape($1);
    }

    my $list = _wantedList($request->getParam('list'));

    $log->warn('LL: addctx params -> '
        . join(', ', map { "$_=" . (defined $p{$_} ? $p{$_} : '(undef)') } qw(name artist albumid year trackname trackid favurl image svc)));

    my $artist  = $p{artist};
    my $artwork = $favCover // $p{image};
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
        $log->warn('LL: addctx had no album name — nothing added');
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
        $source = Plugins::ListenLater::Sources::sourceFromUrl($p{favurl});
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
                  || Plugins::ListenLater::Sources::sourceFromImage($artwork)
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

    my ($id, $already, $existingSource) = eval { Plugins::ListenLater::DB::add($rec, $list) };
    if ($@) {
        $log->error("LL: addctx add failed: $@");
    }
    else {
        $log->warn("LL: addctx -> $source / " . ($album // '?') . " (id=" . ($id // '?') . ", already=" . ($already // 0) . ", list=$list)");
    }

    if (my $client = $request->client) {
        eval { $client->showBriefly({ line => [ cstring($client, 'PLUGIN_LL'), _addedMsg($client, $list, $already, $existingSource, $source) ] }, { duration => 2 }); };
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
    eval { Plugins::ListenLater::DB::remove($id); 1 } or $log->error("LL: remove failed: $@");
    $request->setStatusDone;
}

sub _moveCommand {
    my $request = shift;
    my $id     = $request->getParam('id');
    my $status = $request->getParam('status') || 'later';
    $status = 'later' unless $status =~ /^(?:later|played|wishlist)$/;
    eval { Plugins::ListenLater::DB::setStatus($id, $status); 1 } or $log->error("LL: move failed: $@");
    $request->setStatusDone;
}

sub getDisplayName { 'PLUGIN_LL' }

sub playerMenu { undef }

1;
