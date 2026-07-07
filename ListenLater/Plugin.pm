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
    debug_log            => 0,         # verbose diagnostics for the Material custom-action wiring
    material_debug_snapshot => '',     # latest debug dump (set by _dumpMaterialState; shown in Settings)
});

# Verbose diagnostics, gated on the `debug_log` pref so a user can turn them on from
# Settings, reproduce (e.g. "Add missing on Tidal"), and paste the log — then turn it
# back off. Logged at WARN so it appears whatever the category's configured level is
# (INFO lines don't show unless the category is at INFO). See _dumpMaterialState.
sub _dbg {
    return unless $prefs->get('debug_log');
    $log->warn('LL[dbg]: ' . shift);
}

# The running Material Skin version as an "X.Y.Z" string (undef if unavailable, or a
# non-numeric dev/test build). The streaming/online "Add" custom action ONLY exists on
# Material >= 6.4.4 (PR #1235, released there); below that, streaming rows get NO "Add"
# and only the local library works — exactly the "only working for local library"
# symptom. This tells us whether the OTHER user's box can render the online action AT ALL.
sub _materialVersion {
    return eval { Plugins::MaterialSkin::Plugin->getPluginVersion() };
}

# Can we actually save AND replay an album from this source? Only the local library and
# the streaming services with an adapter in Sources.pm (Qobuz/Bandcamp/Tidal, when their
# plugin is installed). Everything else — Deezer, Spotify, BBC Sounds, radio stations,
# any service we haven't added support for — would store a record that can never resolve
# to a playable album (it fails at play time with "Could not find this album to play"), so
# we REJECT the add instead of storing junk. NB the test is adapter support, NOT whether a
# favurl was supplied: Deezer sends a perfectly good `deezer://album:<id>` favurl and still
# can't play, because there's no Deezer adapter. This is the one reliable gate — it runs on
# every add path regardless of which (often flaky) Material surface triggered it, which is
# why we no longer try to scope the "Add" button itself per service.
sub _isReplayableSource {
    my ($source) = @_;
    # No source at all = we couldn't identify what this is (e.g. an LB "Created for You"
    # playlist row: no favurl, a plugin-PNG image, and a hyphenated svc that isn't a
    # service) → reject rather than guess. (The add commands pass an explicit 'library'
    # for real library items, so empty here never means library.)
    return 0 unless defined $source && length $source;
    return 1 if lc $source eq 'library';
    return Plugins::ListenLater::Sources::_serviceCan(lc $source) ? 1 : 0;
}

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
sub _writeMaterialActionsDeferred {
    return unless $prefs->get('material_action')
        && Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin');
    eval { _writeMaterialActions(); 1 }
        or $log->error("LL: deferred Material custom-action write failed: $@");
}

sub postinitPlugin {
    my $class = shift;

    if ( $prefs->get('material_action')
      && Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin') ) {
        eval { _writeMaterialActions(); 1 }
            or $log->error("LL: failed to write Material custom actions: $@");

        # The internet-radio directory (TuneIn's Music/News/Sports/… categories) is
        # fetched ASYNCHRONOUSLY from mysqueezebox.com and is usually NOT ready at
        # postinit — so the radio enumeration in _writeMaterialActions above sees only
        # locally-registered radio plugins (e.g. BBC Sounds) and misses TuneIn, leaving
        # "Add" on TuneIn station rows. Re-run once the directory has had time to load
        # so those commands get their suppressing empty categories too. Idempotent —
        # actions.json is fully rewritten each call.
        Slim::Utils::Timers::killTimers(undef, \&_writeMaterialActionsDeferred);
        Slim::Utils::Timers::setTimer(undef, time() + 60, \&_writeMaterialActionsDeferred);
    }
    elsif ( Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin') ) {
        # Pref is OFF but a previous (enabled) run may have written our actions. Strip
        # them so turning the toggle off actually removes the "Add" entries instead of
        # leaving them until the pref is re-enabled.
        eval { _clearMaterialActions(); 1 }
            or $log->error("LL: failed to clear Material custom actions: $@");
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

# Read the shared actions.json into a hashref (empty on missing/corrupt).
sub _readMaterialActions {
    my ($file) = @_;
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
    return $data;
}

# Write atomically: actions.json is SHARED with Material and every other
# plugin/user custom action, so a truncated write (crash mid-write) would
# corrupt all of them. Write a temp file then rename() over the original.
sub _writeMaterialActionsFile {
    my ($file, $data) = @_;
    my $tmp = "$file.tmp.$$";
    open my $fh, '>:raw', $tmp or die "open $tmp: $!";
    print $fh $JSON->encode($data) or do { close $fh; unlink $tmp; die "write $tmp: $!" };
    close $fh                      or do {            unlink $tmp; die "close $tmp: $!" };
    rename($tmp, $file)            or do {            unlink $tmp; die "rename $tmp -> $file: $!" };
    return;
}

# Remove every Listen Later custom action from the shared actions.json. Used when the
# user turns the material_action pref OFF — postinitPlugin then skips the write, so
# without this our entries (and the empty radio suppressors) would linger and keep
# showing "Add"/keep suppressing another plugin's online-* fallback. Strips our actions
# from every category, drops our own + legacy namespaces, then deletes any category WE
# wrote that is now empty. Only-empty and only-ours, so a third party's entries survive.
sub _clearMaterialActions {
    my $file = _materialActionsFile();
    return unless -e $file;   # nothing ever written
    my $data = _readMaterialActions($file);

    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY';
        $data->{$cat} = [ grep { !_isOurAction($_) } @{ $data->{$cat} } ];
    }

    delete $data->{$_} for qw(
        listenlater-album listenlater-track listenlater-artist
        LLHome-album LLHome-track LLHome-artist
        listentolater-album listentolater-track listentolater-artist
        LtLHome-album LtLHome-track LtLHome-artist
    );

    # Delete the categories we populate/suppress once they're empty: our top-level
    # pairs (album/playlist/online-*) plus any per-command "<cmd>-album/-track/-artist"
    # radio/scoping suppressor. Guarded on empty so another plugin's real entries stay.
    my %ourCats = map { $_ => 1 }
        qw(album album-track playlist playlist-track online-album online-track);
    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY' && !@{ $data->{$cat} };
        delete $data->{$cat} if $ourCats{$cat} || $cat =~ /-(?:album|track|artist)$/;
    }

    _writeMaterialActionsFile($file, $data);
    $log->warn("LL: cleared Material custom actions from $file");
    return;
}

# Commands we can save & replay. A service that also appears under the server's
# 'radios' menu (e.g. Qobuz) is skipped by _unsupportedRadioCommands so its radio
# rows keep "Add". BBC Sounds is dual-listed (apps + radios) but unsupported, so
# it is NOT here and gets blocked wherever it shows.
my %SUPPORTED_CMD = map { $_ => 1 }
    qw(qobuz bandcamp tidal deezer listenbrainzfreshreleases listenlater);

# TuneIn's top-level radio categories are fetched ASYNC from mysqueezebox.com, so they
# aren't in the 'radios' menu when the plugin initialises. But Material reads
# customactions.json ONCE at app start and browser-caches it (the `?r=` cache-buster is
# the Material version, not our writes), so a category written LATE (the deferred pass)
# is missed by any already-loaded tab until a hard refresh. These command names are
# stable, so seed them at INIT to guarantee the suppressing empty categories exist before
# Material ever loads the file. Unioned with the live 'radios' enumeration
# (_unsupportedRadioCommands) so other radio plugins are still covered.
my @KNOWN_RADIO_CMDS =
    qw(music news sports talk location language podcast search presets local);

# Radio stations are live streams — never a valid "Listen Later" item. We hide the
# streaming "Add" on radio BROWSE rows (see _writeMaterialActions) by giving each
# radio browse command an empty "<cmd>-album"/"-track" category. The command list is
# read from the server's own 'radios' menu (works with no player; every user installs
# different radio plugins), minus the ones we actually support. Returns a de-duped list.
sub _unsupportedRadioCommands {
    my $req = eval {
        Slim::Control::Request::executeRequest(undef, [ 'radios', 0, 500 ]);
    };
    return () unless $req;
    my $loop = $req->getResult('radioss_loop') || [];
    my %cmds;
    for my $entry (@$loop) {
        my $cmd = $entry->{cmd} or next;
        next if $SUPPORTED_CMD{$cmd};
        $cmds{$cmd} = 1;
    }
    return keys %cmds;
}

sub _writeMaterialActions {
    my $file = _materialActionsFile();
    my $dir  = File::Spec->catdir(Slim::Utils::Prefs::dir(), 'material-skin');
    File::Path::make_path($dir) unless -d $dir;

    my $data = _readMaterialActions($file);

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
    # These `online-*` categories are the generic fallback for every streaming/app
    # item (and the home-shelf cards, which have no per-service command). Only does
    # anything on a Material build that wires up custom actions for online items.
    my $onlineCmd = [ 'listenlater', 'addctx',
        'name:$TITLE', 'artist:$ARTISTNAME', 'svc:$SERVICE', 'favurl:$FAVURL', 'image:$IMAGE' ];

    # Track-context categories that put a TOP-LEVEL "Add" on a track's "…" menu (each
    # is a distinct Material surface, verified in the served bundle):
    #   'track'       → the Now Playing screen's info panel
    #                   (nowplaying-page.js: getCustomActions("track"))       — restored 0.1.62
    #   'queue-track' → each item in the PLAY QUEUE list
    #                   (getCustomActions("queue-track"))                     — added 0.1.63
    #   'album-track' / 'playlist-track' → library album / playlist track lists
    # (streaming rows use 'online-track'.) All map to $trackCmd (name:$ALBUMNAME), so they
    # add the ALBUM the track belongs to, NOT the track — the trackname/trackid params are
    # informational only (see _addCtxCommand). For a streaming track $FAVURL is the TRACK
    # url (no album:<id>), so replay resolves the album by artist+title search
    # (Sources::_searchService); a library track adds by $ALBUMID. Same end result as the
    # "… → More" info-provider, just at the top of the menu. (0.1.34 had dropped 'track' as
    # a design choice — Now Playing is track-oriented, we save albums — restored by request;
    # 'queue-track' was simply never written, which is why the queue only showed Add in More.)
    my %cats = (
        'album'          => $albumCmd,
        'album-track'    => $trackCmd,
        'playlist'       => $albumCmd,
        'playlist-track' => $trackCmd,
        'track'          => $trackCmd,
        'queue-track'    => $trackCmd,
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

    # Clean up the stale per-command categories the 0.1.46–0.1.50 scoping experiments left
    # in the SHARED actions.json. They persist across plugin updates, and an EMPTY
    # "<service>-album" takes precedence over "online-*" — so a leftover empty
    # "qobuz-album"/"tidal-album"/"bandcamp-album"/"listenbrainzfreshreleases-album" (etc.)
    # HIDES "Add" on the very services we support (the 0.1.51 regression). We no longer scope
    # per command — adds are gated at add time — so after the strip pass above every such
    # category we wrote is empty. Delete every empty "*-album"/"*-track"/"*-artist" EXCEPT the
    # ones we actively write (album/online-*/… below) and our own suppressors
    # (listenlater-*/LLHome-*). Only-empty so another plugin's real entries are never touched;
    # no other plugin in this stack writes empty per-command categories (LBF verified), so an
    # empty one is our own cruft. This restores fall-through to the populated "online-*".
    # Radio browse commands we want to suppress "Add" on (see the empty-category
    # write below). Union the live 'radios' enumeration with the hardcoded TuneIn
    # seed list (@KNOWN_RADIO_CMDS — present at init even before the async directory
    # loads), minus any command we actually support. Their "<cmd>-album"/"-track"
    # keys are exempted from the delete-empties pass below — otherwise the very
    # empties we write here get deleted again (the 0.1.52 rule: an empty category is
    # not neutral, it actively suppresses, which is exactly what we want here).
    my %radioCmd = map { $_ => 1 } _unsupportedRadioCommands(), @KNOWN_RADIO_CMDS;
    delete @radioCmd{ keys %SUPPORTED_CMD };
    my @radioCats = map { ("$_-album", "$_-track") } sort keys %radioCmd;

    my %keep = ( map { $_ => 1 } keys %cats, @radioCats,
        qw(listenlater-album listenlater-track listenlater-artist
           LLHome-album LLHome-track LLHome-artist) );
    for my $cat (keys %$data) {
        next unless $cat =~ /-(?:album|track|artist)$/;
        next if $keep{$cat};
        delete $data->{$cat} if ref $data->{$cat} eq 'ARRAY' && !@{ $data->{$cat} };
    }

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
    # Defining these (empty) categories tells Material (the per-app category feature,
    # released in Material 6.4.4) to use them instead of "online-*" for those items —
    # so an album already in the list isn't offered
    # "Add to Listen Later" again (re-adding would bounce a Played album back to
    # Listen Later). Remove/Move live in each row's "…" → More menu (which refreshes
    # the list in place), since putting them at the top of the "…" would need a further
    # Material change.
    $data->{$_} = [] for qw(
        listenlater-album listenlater-track listenlater-artist
        LLHome-album LLHome-track LLHome-artist
    );

    # Hide "Add" on radio BROWSE rows. Radio stations are live streams, never a valid
    # "Listen Later" item. An empty "<cmd>-album"/"-track" wins over "online-*" so the
    # action doesn't render on those rows. `||=` (0.1.48): only create when absent — a
    # "<cmd>-*" namespace isn't ours to reset, so another plugin's real entries survive
    # (and any present category, ours or theirs, still overrides "online-*" → Add hidden).
    # These keys are in %keep, so the delete-empties pass above leaves our empties intact.
    for my $cat (@radioCats) {
        $data->{$cat} ||= [];
    }

    # NB: apart from the radio-browse block above, we deliberately do NOT scope "Add" per
    # streaming service — that's unreliable (Material home-shelf cards carry no command/favurl
    # and its custom actions are leftover-view-state flaky) and unnecessary: the add COMMANDS
    # reject any source we can't replay (_isReplayableSource), so an unsupported service's
    # "Add" is a harmless no-op rather than a stored-but-unplayable record. The radio block is
    # the one exception because radios ARE cleanly command-scoped in the browse menu and are
    # never legitimately addable. It covers browse rows only; a radio HOME-SHELF card has no
    # per-command identity (all shelves arrive in one 'material-skin' home-extra call) and
    # falls back to "online-*", so its Add can't be hidden here — it stays an add-time reject.

    _writeMaterialActionsFile($file, $data);
    $log->warn("LL: wrote Material custom actions to $file");

    _dumpMaterialState($file, $data, \@radioCats) if $prefs->get('debug_log');
    return;
}

# Diagnostic dump of everything that decides whether "Add to Listen Later" renders on a
# streaming/online row (Tidal, ListenBrainz Fresh Releases, home shelves). Gated on
# `debug_log`. Written for the "works for local library only" report we can't reproduce
# on our own box — the user enables the pref, restarts, browses Tidal/LBF, then pastes
# the log. The three things that break online "Add", in order of likelihood:
#   1. Material < 6.4.4          → online custom actions don't exist → local-only.
#   2. online-album/-track empty → nothing to render on any streaming row.
#   3. a NON-empty "<svc>-album"  → a leftover/foreign category SHADOWS "online-*" and
#      hides Add on that one service (Material prefers a present per-command category).
# (A separate, expected cause the log can't show is Material's app-start cache of
# customactions.json — if the file below is correct but the UI still lacks Add, it's a
# stale cached tab; hard-refresh Material once. See CLAUDE.md 0.1.57.)
sub _dumpMaterialState {
    my ($file, $data, $radioCats) = @_;

    # Accumulate every line so we can BOTH log it (server.log, tagged LL[dbg]) AND stash the
    # whole snapshot in a pref, which the Settings page renders in a copy-paste textarea — so
    # a remote user can hand over the diagnostics without touching server.log. Latest run wins.
    my @lines;
    my $emit = sub { my $m = shift; push @lines, $m; _dbg($m); };

    my $ver = _materialVersion();
    my $online_ok = 0;
    if (!defined $ver) {
        # unknown — can't confirm either way
    } elsif ($ver =~ /^(\d+)\.(\d+)\.(\d+)/) {
        $online_ok = ( $1 <=> 6 || $2 <=> 4 || $3 <=> 4 ) >= 0 ? 1 : 0;
    } else {
        $online_ok = 1;   # dev/test build — assume it carries the feature
    }

    my $llver = eval {
        Slim::Utils::PluginManager->dataForPlugin(__PACKAGE__)->{version};
    };
    $emit->('==== Listen Later Material diagnostics ('
        . localtime() . ') ====');
    $emit->("Listen Later version = " . ($llver // '?'));
    $emit->("material_action pref = " . ($prefs->get('material_action') ? 'ON' : 'OFF'));
    $emit->("MaterialSkin enabled = "
        . (Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin') ? 'yes' : 'NO'));
    $emit->("Material version = " . (defined $ver ? $ver : '(unknown)')
        . " -> online 'Add' supported (>=6.4.4): "
        . (defined $ver ? ($online_ok ? 'YES' : 'NO — streaming rows get NO Add on this Material; only local works')
                        : 'UNKNOWN'));
    $emit->("actions.json = $file");

    # online-* must be populated or NO streaming row shows Add anywhere.
    for my $c (qw(online-album online-track)) {
        my $n = ref $data->{$c} eq 'ARRAY' ? scalar @{ $data->{$c} } : -1;
        $emit->("category '$c' = " . ($n < 0 ? 'MISSING (!)' : "$n entr" . ($n == 1 ? 'y' : 'ies'))
            . ($n > 0 ? ' — streaming Add active' : ' — streaming Add WILL NOT SHOW'));
    }

    # Radio browse commands we deliberately suppress Add on (empty <cmd>-album/-track).
    my @radios = sort keys %{ { map { my $c = $_; ($c =~ s/-(?:album|track)$//r) => 1 } @$radioCats } };
    $emit->("supported commands (Add kept) = " . join(', ', sort keys %SUPPORTED_CMD));
    $emit->("radio/unsupported commands suppressed (Add hidden on their browse rows) = "
        . (@radios ? join(', ', @radios) : '(none)'));

    # Any NON-empty per-command "<svc>-album/-track" category shadows online-* and hides
    # Add on that service. Ours are always empty; a populated one is foreign/leftover and
    # is the thing to look at if Add is missing on exactly one service.
    my @shadow;
    for my $cat (sort keys %$data) {
        next unless $cat =~ /^(.+)-(?:album|track)$/;
        my $svc = $1;
        next if $svc eq 'online' || $svc eq 'listenlater' || $svc eq 'LLHome';
        my $n = ref $data->{$cat} eq 'ARRAY' ? scalar @{ $data->{$cat} } : 0;
        push @shadow, "$cat($n)" if $n > 0;
    }
    $emit->(@shadow
        ? "NON-EMPTY per-service categories that SHADOW online-* (hide Add there): " . join(', ', @shadow)
        : "no non-empty per-service shadow categories (good — nothing foreign is hiding Add)");

    # Cross-check every installed service against what's written, so the user sees, per
    # service, whether its browse rows will show Add. Enumerate BOTH menus: streaming apps
    # live under 'apps', while internet radio AND the sibling ListenBrainz Fresh Releases
    # ("via LBF") register under 'radios' (menu=>'radios', tag=listenbrainzfreshreleases) —
    # so a report about "LBF" is only covered if we scan 'radios' too. De-duped by command.
    my %seen;
    my $online_pop = ref $data->{'online-album'} eq 'ARRAY' && @{ $data->{'online-album'} };
    for my $menu (['apps', 'appss_loop'], ['radios', 'radioss_loop']) {
        my $loop = eval {
            my $req = Slim::Control::Request::executeRequest(undef, [$menu->[0], 0, 500]);
            $req ? ($req->getResult($menu->[1]) || []) : [];
        } || [];
        for my $a (@$loop) {
            my $cmd = $a->{cmd} or next;
            next if $seen{$cmd}++;
            my $name = $a->{name} // $cmd;
            my $shadowed = (ref $data->{"$cmd-album"} eq 'ARRAY' && @{ $data->{"$cmd-album"} })
                || (grep { $_ eq "$cmd-album" } @$radioCats);
            my $verdict = !$online_ok      ? "no Add (Material < 6.4.4)"
                        : $shadowed        ? "Add HIDDEN (per-command category present)"
                        : $online_pop      ? "Add shown (via online-*)"
                        :                    "no Add (online-* empty)";
            $emit->("service '$cmd' ($name) [$menu->[0]]: $verdict");
        }
    }
    _dbg('==== end diagnostics ====');
    $prefs->set('material_debug_snapshot', join("\n", @lines));
    _dbg('==== end diagnostics ====');
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
    # fallback: our titles (current + pre-rebrand). ONLY when the entry carries no
    # lmscommand at all — an entry with its own command whose title happens to match
    # ours belongs to someone else in this shared file, so never strip that.
    return 0 if defined $lc;
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

    # Don't save an album from a source we can't replay — reject instead of
    # storing a record that only fails later at play time (see _isReplayableSource).
    return _rejectAdd($request, $source, $rec->{album_title}) unless _isReplayableSource($source);

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

# Reject an add whose source we can't replay: no DB row, request completed cleanly.
# Silent by necessity — Material renders no toast for a custom-action/menu command
# (server-side showBriefly reaches physical player displays only, not the web UI),
# and its only feedback hook is a generic "'…' failed" snackbar we can't customise.
# The point of the gate is to keep unplayable junk out of the list. Shared by both paths.
sub _rejectAdd {
    my ($request, $source, $album) = @_;
    $log->warn("LL: rejected add — unsupported source '" . ($source // '?')
        . "' (" . ($album // '?') . ")");
    $request->addResult('count', 0);
    $request->setStatusDone;
    return;
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

    # Bandcamp items: a "Buy on Bandcamp" entry.
    #   - URL already known (ref.album_url captured at add time, or ref.buy_url cached on a
    #     prior open): make the entry ITSELF a weblink → one tap opens the page in the
    #     browser, no intermediate "Open on Bandcamp" drill.
    #   - URL not known (older saves): fall back to a `go` drill into the `buy` query,
    #     which resolves the page once, caches it, and shows the weblink (see _buyCommand).
    if ($rec && ($rec->{source} || '') eq 'bandcamp') {
        my $ref   = (ref $rec->{ref} eq 'HASH') ? $rec->{ref} : {};
        my $known = $ref->{buy_url} || $ref->{album_url};
        if ($known && $known =~ m{^https?://}i) {
            push @entries, {
                text    => cstring($client, 'PLUGIN_LL_BUY_BANDCAMP'),
                weblink => $known,
            };
        }
        else {
            push @entries, {
                text => cstring($client, 'PLUGIN_LL_BUY_BANDCAMP'),
                go   => { player => 0, cmd => [ 'listenlater', 'buy' ], params => { id => $id } },
            };
        }
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
        if ($e->{weblink}) {
            # Direct external link: one tap opens the page in the browser, no drill.
            $request->addResultLoop('item_loop', $i, 'weblink', $e->{weblink});
        }
        elsif ($e->{go}) {
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

    # Already have the page URL → open it directly, no resolve.
    #   - buy_url:   resolved + cached on a previous open.
    #   - album_url: the exact album page URL captured at add time (LBF 0.9.53+ packs it
    #                into the favurl's ?b= blob). The album page IS the buy page, so a
    #                newly-added title opens instantly without searching.
    # Older records have neither → fall through to the resolve/search route below.
    my $ref    = (ref $rec->{ref} eq 'HASH') ? $rec->{ref} : {};
    my $cached = $ref->{buy_url} || $ref->{album_url};
    return $emit->($cached) if $cached && $cached =~ m{^https?://}i;

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
    # Bandcamp matches pack the cover art AND the album page url into a single escaped
    # '?b=' param ('<art>|<url>'): get_album needs the page url for an exact replay.
    # Unpack it — art = cover, url = exact replay key (and the Buy link). The full ~164-
    # char favurl is confirmed to survive Material intact (an earlier "long favurls are
    # dropped" theory was a shadowed-install artifact, not real); the album_id resolve in
    # Sources is just a safety net if the url half is ever absent. Other services use the
    # plain '?cover=' (art only). NOTE: this strip runs BEFORE the addctx log below, so
    # the logged favurl always reads as a bare 'bandcamp://album:<id>'.
    my $favCover;
    my $favBandcampUrl;
    if ($p{favurl} && $p{favurl} =~ s{[?&]b=([^&?]*)}{}) {
        require URI::Escape;
        my ($a, $u) = split /\|/, URI::Escape::uri_unescape($1), 2;
        $favCover       = $a if defined $a && length $a;
        $favBandcampUrl = $u if defined $u && length $u;
    }
    elsif ($p{favurl} && $p{favurl} =~ s{[?&]cover=([^&]*)}{}) {
        require URI::Escape;
        $favCover = URI::Escape::uri_unescape($1);
    }

    # LBF also packs the release artist (and optionally year) into the favurl as
    # private '&a='/'&y=' params, because Material sends its matched rows NO
    # $ARTISTNAME — so without this the record is artist-less and never auto-moves to
    # Played (Played matching keys on source+artist+album). Read them as a fallback and
    # strip so the album:<id> logic below sees a clean "<scheme>://album:<id>". Native
    # streaming-plugin favurls carry no query string, so these never fire for a normal
    # streaming Add. Runs before the addctx log so the logged favurl is the clean id.
    my $favArtist;
    my $favYear;
    if ($p{favurl} && $p{favurl} =~ s{[?&]a=([^&]*)}{}) {
        require URI::Escape;
        $favArtist = URI::Escape::uri_unescape($1);
    }
    if ($p{favurl} && $p{favurl} =~ s{[?&]y=([^&]*)}{}) {
        $favYear = $1;
    }

    my $list = _wantedList($request->getParam('list'));

    $log->warn('LL: addctx params -> '
        . join(', ', map { "$_=" . (defined $p{$_} ? $p{$_} : '(undef)') } qw(name artist albumid year trackname trackid favurl image svc)));

    my $artist  = $p{artist};
    # Fall back to the artist packed in the favurl (LBF rows arrive with an empty
    # $ARTISTNAME) so the stored record has an artist for display AND Played matching.
    $artist = $favArtist if (!defined $artist || !length $artist) && defined $favArtist && length $favArtist;
    my $artwork = $favCover // $p{image};
    my $year    = $p{year} || $favYear;
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
        # Drop the format qualifier streaming rows append. Bandcamp tacks "(Album)" /
        # "(Track)" onto its result titles (the ListenBrainz Fresh Releases match rows
        # carry it) — strip those too so the stored name is clean AND the Bandcamp
        # search-replay (_searchService) can match the album.
        $album =~ s/\s*\((?:Hi-Res[^)]*|Explicit|Mono|Stereo|Album|Track)\)\s*$//i;
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
        # Bandcamp: if the favurl carried the page url (the ?b= blob survived Material),
        # stash it for an exact get_album replay; otherwise buildPlayableItems resolves
        # it once by album_id instead.
        $ref->{album_url} = $favBandcampUrl if defined $favBandcampUrl && length $favBandcampUrl;
    }
    else {
        # Streaming album rows carry no favorites_url; the browsing service id is passed
        # explicitly as svc (a Material view belongs to one service), else inferred from
        # the cover host. NB: do NOT invent a default service here — if svc and the cover
        # host both come up empty we genuinely can't identify the item (e.g. an LB
        # playlist row: hyphenated svc that fails the ^[a-z0-9]+$ test + a plugin-PNG
        # image), so leave $source empty and let the reject gate below refuse it, rather
        # than guessing 'qobuz' and storing an unplayable row.
        my $svc = ($p{svc} && $p{svc} =~ /^[a-z0-9]+$/i) ? lc $p{svc} : '';
        $source = $svc || Plugins::ListenLater::Sources::sourceFromImage($artwork) || '';
        $ref    = { _svc => $source };
        # Qobuz browse rows carry no favurl/album id, but the cover URL embeds the album
        # id — recover it so we replay the EXACT album by id instead of an artist/title
        # search (the search can miss a specific same-titled edition, e.g. "American
        # Football (LP2)", and the row has no other identity). Uses the raw $p{image}
        # (the proxied Qobuz cover), not $artwork, which a favurl handshake could override.
        if ($source eq 'qobuz') {
            my $aid = Plugins::ListenLater::Sources::qobuzAlbumIdFromImage($p{image});
            $ref = { _svc => 'qobuz', album_id => $aid, passthrough => { album_id => $aid } }
                if defined $aid && length $aid;
        }
    }

    # Now Playing fallback. Material's Now Playing "track" action supplies only
    # album+artist — its now-playing item has no presetParams.favorites_url and no
    # album_id, so $FAVURL/$ALBUMID/$SERVICE arrive empty and $source came up ''
    # above (which would reject). But this Add IS for the track currently PLAYING on
    # the client, so recover the real play URL (→ source, and library album id)
    # straight from the player's current song. Guarded inside _nowPlayingFallback by
    # matching the playing track's album/artist to the params, so a stray empty-favurl
    # Add (e.g. an LB playlist tile) can never adopt an unrelated playing track.
    if (!length($source // '') && $request->client) {
        my ($npSrc, $npRef, $npAlbum, $npArtist, $npYear, $npArt)
            = _nowPlayingFallback($request->client, $album, $artist);
        if ($npSrc) {
            $source  = $npSrc;
            $ref     = $npRef;
            $album   = $npAlbum  if defined $npAlbum  && length $npAlbum;
            $artist  = $npArtist if defined $npArtist && length $npArtist;
            $year  ||= $npYear;
            $artwork = $npArt // $artwork;
            $log->warn("LL: now-playing fallback recovered source=$source for '" . ($album // '?') . "'");
        }
    }

    # Reject a source we can't replay (Deezer/Spotify/radio/…): don't store a record that
    # would only fail at play time — reject it (silently) instead. This is the one reliable
    # gate, so we no longer bother hiding the Material "Add" button per service.
    return _rejectAdd($request, $source, $album) unless _isReplayableSource($source);

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

    # Tidal browse rows send no $ARTISTNAME (Material doesn't map their subtitle) and the
    # Tidal cover URL has no artist/id — but the favurl gives us the album id, so fetch the
    # artist from the album's tracks in the background and backfill the record. Without an
    # artist the row shows album-only and never auto-moves to Played (Played keys on
    # source+artist+album). Fire-and-forget; only for a fresh add that has no artist yet.
    if ($id && !$already && ($source eq 'tidal' || $source eq 'deezer')
            && (!defined $artist || !length $artist)
            && $ref->{album_id}) {
        _backfillStreamingArtist($request->client, $id, $ref->{album_id}, $source);
    }

    if (my $client = $request->client) {
        eval { $client->showBriefly({ line => [ cstring($client, 'PLUGIN_LL'), _addedMsg($client, $list, $already, $existingSource, $source) ] }, { duration => 2 }); };
    }

    $request->setStatusDone;
}

# Fetch a streaming album's artist from its tracks and backfill it onto the saved
# record. Some services' browse rows arrive with an empty $ARTISTNAME (Material doesn't
# map their subtitle) and a cover URL with no recoverable artist/id — **Tidal and Deezer
# both do this** — but the favurl carries the album id, so we fetch the album's tracks
# (getAlbum → albumTracks → each rendered track's line2 = artist name) and update the
# record. Without an artist the row shows album-only and never auto-moves to Played
# (Played keys on source+artist+album). Both plugins' getAlbum share the same shape
# ($client,$cb,$args,{id=>…} → {items=>…}), so one helper covers both. Async /
# best-effort; guarded so an API hiccup can never break the add.
sub _backfillStreamingArtist {
    my ($client, $recId, $albumId, $source) = @_;
    return unless $client && $recId && defined $albumId && length $albumId;

    my $getAlbum = ($source eq 'tidal'  && Plugins::TIDAL::Plugin->can('getAlbum'))  ? \&Plugins::TIDAL::Plugin::getAlbum
                 : ($source eq 'deezer' && Plugins::Deezer::Plugin->can('getAlbum')) ? \&Plugins::Deezer::Plugin::getAlbum
                 : undef;
    return unless $getAlbum;

    eval {
        $getAlbum->($client, sub {
            my $res   = shift;
            my $items = (ref $res eq 'HASH') ? $res->{items} : $res;
            my $first = (ref $items eq 'ARRAY') ? $items->[0] : undef;
            # The album artist is the tracks' line2 (or a nested artist->{name}).
            my $artist = $first && (
                (defined $first->{line2} && !ref $first->{line2}) ? $first->{line2}
              : (ref $first->{artist} eq 'HASH') ? $first->{artist}{name}
              : undef );
            return unless defined $artist && length $artist;
            Plugins::ListenLater::DB::updateArtist($recId, $artist);
            $log->info("LL: backfilled $source artist '$artist' onto rec $recId");
        }, {}, { id => $albumId });
        1;
    } or $log->warn("LL: $source artist backfill failed: $@");
    return;
}

# Recover source + album for a Now Playing "Add" that arrived with no favurl/id, from
# the client's CURRENTLY-PLAYING track. Only adopts it when the playing track's album
# (and artist, when both are known) matches the requested album+artist — so an Add that
# is NOT actually the now-playing item (a stray empty-favurl row) never picks up whatever
# happens to be playing. Returns () on no/again match; otherwise:
#   library streaming: ('library', {album_id=>…}, title, artist, year, artwork)
#   streaming service: (scheme, {_svc=>scheme, +album:<id> if the url carries one}, album, artist)
# The scheme comes from the real play URL, so the reject gate (_serviceCan) still applies.
sub _nowPlayingFallback {
    my ($client, $wantAlbum, $wantArtist) = @_;
    return () unless defined $wantAlbum && length $wantAlbum;

    my $song = eval { $client->playingSong }
        or do { $log->warn("LL: np-fallback: no playingSong"); return (); };

    # Two track handles: ->track is the playlist entry (canonical service URL, e.g.
    # qobuz://…/deezer://…), ->currentTrack can resolve to the raw http(s) stream for
    # some plugins — which would hide the service scheme. Prefer a URL that ISN'T http
    # so the scheme still names the service; fall back to whatever we have.
    my $ptrack = eval { $song->track };
    my $ctrack = eval { $song->currentTrack };
    my $track  = $ptrack || $ctrack
        or do { $log->warn("LL: np-fallback: no track"); return (); };
    my $purl = eval { $ptrack->url };
    my $curl = eval { $ctrack->url };
    my $url  = (defined $purl && $purl !~ m|^https?://|) ? $purl
             : (defined $curl && $curl !~ m|^https?://|) ? $curl
             : ($purl // $curl);
    return () unless defined $url && length $url;

    # Confirm this playing track IS the one being added (guard against adopting an
    # unrelated playing track). Album must match; artist too when both sides have it.
    # A REMOTE/streaming track has no $track->album object (it's only set for library
    # tracks) — its album title lives on ->albumname, which is why the play-detector
    # reads it that way too (Played.pm). Fall back to it, or the streaming Now Playing
    # add never matches and gets rejected.
    my $trAlbum  = eval { $track->album ? $track->album->title : undef };
    $trAlbum     = eval { $track->albumname } if !(defined $trAlbum && length $trAlbum);
    my $trArtist = eval { $track->artistName }
                // eval { $track->album && $track->album->contributor ? $track->album->contributor->name : undef };

    $log->warn(sprintf("LL: np-fallback: want album='%s' artist='%s'; playing url='%s' album='%s' artist='%s'",
        $wantAlbum // '', $wantArtist // '', $url, $trAlbum // '', $trArtist // ''));

    # Sanity guard: when the playing track exposes its OWN album title, require it to
    # match what we were asked to add — that stops a stray empty-source add from some
    # surface OTHER than Now Playing from adopting whatever happens to be playing. But a
    # remote/streaming Track very often exposes NO album/artist at all: Qobuz/Tidal/etc.
    # serve metadata dynamically (via a metadata provider), not on the Track row, so
    # ->albumname/->artistName come back empty (confirmed live: qobuz:// track → both '').
    # The `track` custom action is Now-Playing-ONLY, and we've already recovered the real
    # play URL of the *currently-playing* track — so when there's no track metadata to
    # match on, trust the album/artist Material sent and proceed on the URL scheme rather
    # than rejecting a perfectly valid add.
    if (defined $trAlbum && length $trAlbum) {
        my ($wa, $ta) = (Plugins::ListenLater::Sources::_norm($wantAlbum),
                         Plugins::ListenLater::Sources::_norm($trAlbum));
        unless ($wa eq $ta || index($ta, "$wa ") == 0 || index($wa, "$ta ") == 0) {
            $log->warn("LL: np-fallback: album mismatch ('$wa' vs '$ta') — not adopting the playing track");
            return ();
        }
        if (defined $wantArtist && length $wantArtist && defined $trArtist && length $trArtist) {
            unless (Plugins::ListenLater::Sources::_artistMatch(
                    Plugins::ListenLater::Sources::_norm($wantArtist),
                    Plugins::ListenLater::Sources::_norm($trArtist))) {
                $log->warn("LL: np-fallback: artist mismatch — not adopting the playing track");
                return ();
            }
        }
    }
    else {
        $log->warn("LL: np-fallback: playing track exposes no album/artist — trusting Material's album/artist + the recovered URL scheme");
    }

    my $scheme = ($url =~ m|^(\w+)://|) ? lc $1 : '';

    # Local file (or db:/tmp: local schemes) → library album, added by its id.
    if (!$scheme || $scheme eq 'file' || $scheme eq 'db' || $scheme eq 'tmp') {
        my $alb = eval { $track->album }
            or do { $log->warn("LL: np-fallback: local track but no album object"); return (); };
        my $aid = eval { $alb->id }      or return ();
        return ('library', { album_id => $aid },
            (eval { $alb->title }),
            (eval { $alb->contributor ? $alb->contributor->name : undef }),
            (eval { $alb->year } || undef),
            (eval { $alb->artwork ? 'music/' . $alb->artwork . '/cover' : undef }));
    }

    # Streaming track: source = the play-url scheme. A track url carries no album:<id>,
    # so replay resolves the album by artist+title search (Sources::_searchService) using
    # the album/artist we already have. (If the url ever does carry album:<id>, keep it.)
    # Material builds the Now Playing $ALBUMNAME as "Album (YYYY)" (+ "• disc/grouping"),
    # so strip that trailing decoration off the title we store/search — the year is
    # carried separately, and DB dedupe keeps parens so an unstripped "(YYYY)" would skew
    # the dedupe key and the row label.
    my $album = $wantAlbum;
    $album =~ s/\s*[•·].*$//;
    $album =~ s/\s*\((?:19|20)\d{2}\)\s*$//;
    my ($year) = $wantAlbum =~ /\((\d{4})\)/;
    my ($aid) = $url =~ m{(?:[:/])album:([A-Za-z0-9._-]+)};
    my $ref = $aid
        ? { _svc => $scheme, album_id => $aid, passthrough => { album_id => $aid } }
        : { _svc => $scheme };

    # One handler metadata fetch (same source Played uses) → recover BOTH the cover AND the
    # artist. Material's now-playing item often sends an empty $ARTISTNAME for a streaming
    # track, and a track url carries no album:<id> to backfill from — so without this the
    # stored row is artist-less and never auto-moves to Played (which keys on
    # source+artist+album). Prefer the artist Material did send; fall back to the handler's.
    my $meta   = Plugins::ListenLater::Sources::playingMeta($client, $url);
    my $artist = (defined $wantArtist && length $wantArtist) ? $wantArtist
               : (defined $meta->{artist} && length $meta->{artist}) ? $meta->{artist}
               : $wantArtist;
    return ($scheme, $ref, $album, $artist, $year, _coverFromMeta($meta));
}

# Cover art from an already-fetched handler metadata hash. Like album/artist, the art isn't
# on the LMS Track row for a streaming service — the Now Playing cover comes from the
# protocol handler's getMetadataFor (the very source LMS's status 'artwork_url' uses), so
# Material's $IMAGE (playerStatus.current has no .image) arrives empty and the saved row
# would be art-less. Take the handler's cover; store the URL as-is (a raw https CDN cover
# renders directly in Material, no imageproxy/GD needed — keeps to the "no server image
# libs" rule). $meta comes from Sources::playingMeta (always a hashref). Guarded.
sub _coverFromMeta {
    my ($meta) = @_;
    for my $k (qw(cover image icon)) {
        my $v = $meta->{$k};
        return $v if defined $v && !ref $v && length $v;
    }
    return undef;
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

# Tear down the play-detector's subscription on plugin disable/reload (a full server
# restart clears it anyway, but a plain disable would otherwise leave it subscribed).
sub shutdownPlugin {
    eval { Plugins::ListenLater::Played->shutdown; 1 }
        or $log->error("LL: Played shutdown failed: $@");
    return;
}

sub getDisplayName { 'PLUGIN_LL' }

sub playerMenu { undef }

1;
