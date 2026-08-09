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
use Plugins::ListenLater::Podcast;
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
    played_threshold     => 90,        # % of a release's MEASURED tracks → Played
    streaming_min_tracks => 4,         # distinct streaming tracks → Played (no total available)
    watch_outside        => 1,         # mark Played from plays started outside the plugin
    material_action      => 1,         # add an "Add to Listen Later" entry to Material's context menus
    played_retention_days => 7,        # auto-remove Played albums after N days (0 = keep forever)
    debug_log            => 0,         # verbose diagnostics for the Material custom-action wiring
    material_debug_snapshot => '',     # latest debug dump (set by _dumpMaterialState; shown in Settings)
    threshold_90_migrated => 0,        # VERSION of the 60% -> 90% bump that has run (see below)
    rebrand_migrated      => 0,        # the pre-rebrand pref copy has run (see _migrateRebrandPrefs)
});

# A PREF-MIGRATION FLAG MUST NOT START WITH AN UNDERSCORE.
#
# `Slim::Utils::Prefs::Base::set` stores a value only `if ($valid && $pref !~ /^_/)` — a pref
# whose name begins with `_` is DISCARDED, with no error, no warning and no return value to
# check, and `get` then returns undef for ever. (The namespace reserves that prefix for its own
# `_ts_<pref>` write stamps.) `_rebrand_migrated`, the one-shot flag added with the 0.1.25
# rebrand, was exactly that shape — so it never persisted and `_migrateRebrandPrefs` ran on
# EVERY server start, copying the pre-rebrand `plugin.listentolater` namespace over the user's
# current settings each time.
#
# That is what made 0.1.93 look like it hadn't shipped: the bump below set 90 at module load and
# `initPlugin` overwrote it with the old namespace's 60 seconds later, on every restart. Diagnosed
# live 2026-07-31 — `played_threshold`=60 alongside `threshold_90_migrated`=1, `_rebrand_migrated`
# undef, and both `_ts_` stamps sitting on the last restart. It silently reverted every Settings
# change to `sort` / `streaming_min_tracks` / `played_retention_days` too.
#
# The Played threshold moved from 60% to 90% once a release's length stopped being GUESSED
# from its type and started being MEASURED from its real tracklist (2026-07-30): 60% of a
# number we half-trusted was a hedge, and there is nothing left to hedge against.
#
# init() above only fills a pref that is ABSENT, so every existing install would silently
# keep 60 for ever and the change would look like it simply hadn't worked. Bump it once,
# gated on its own flag so it can never fight a user who then picks their own value in
# Settings. Deliberately unconditional on the current value rather than "only if it's still
# 60" — this is a change of default for everyone, not a repair of one setting.
#
# The flag is a VERSION, not a boolean (0.1.94). Every install that ran it as version 1 had the
# bump undone within the same startup by the broken rebrand copy above, so the setting they are
# actually running is still 60 while the flag says the migration is done. Version 2 re-applies it
# once, now that the copy can no longer overwrite it. A user who deliberately chose 60 in the
# meantime never kept it either — it was being rewritten from the old namespace at every restart —
# so there is no considered choice here to overrule.
use constant THRESHOLD_MIGRATION => 2;

_migratePrefs();

# Both one-shot pref migrations, in a sub purely so a test can drive them over a prepared
# store — the bug they exist to fix is a migration that ran when it shouldn't have, and
# top-level code that runs once per process can't be asked to do that twice.
sub _migratePrefs {
    # Mark the rebrand copy done for anyone who has been here before, so the properly-gated
    # version in _migrateRebrandPrefs cannot run one final time and re-import the very values
    # this release exists to stop. `threshold_90_migrated` is the proxy for "this install is
    # not new": only a fresh install lacks it, and a fresh install has nothing to migrate.
    if (!$prefs->get('rebrand_migrated') && $prefs->get('threshold_90_migrated')) {
        $prefs->set('rebrand_migrated', 1);
    }

    if (($prefs->get('threshold_90_migrated') || 0) < THRESHOLD_MIGRATION) {
        $prefs->set('played_threshold', 90);
        $prefs->set('threshold_90_migrated', THRESHOLD_MIGRATION);
    }
    return;
}

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
#
# ONCE is the whole contract, and until 0.1.94 it was not honoured: the flag was
# `_rebrand_migrated`, which a leading underscore made unstorable, so this ran at every
# start and reverted the user's settings to their 0.1.25-era values. See the note beside
# $prefs->init. The flag must stay underscore-free.
sub _migrateRebrandPrefs {
    return if $prefs->get('rebrand_migrated');
    my $old = preferences('plugin.listentolater');
    for my $k (qw(sort played_threshold streaming_min_tracks watch_outside material_action played_retention_days)) {
        my $ov = $old->get($k);
        $prefs->set($k, $ov) if defined $ov;
    }
    $prefs->set('rebrand_migrated', 1);
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
    # Library/queue track rows: save the individual TRACK (kind:track). $TRACKNAME is the
    # track title, $ALBUMNAME its parent album, $TRACKID/$FAVURL the play key. addctx stores
    # the track (Now Playing carries no favurl → recovered from the playing song).
    my $trackCmd = [ 'listenlater', 'addctx', 'kind:track',
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
    # An online TRACK row's $TITLE is the track title and $FAVURL its track play url — so
    # save the track (kind:track). No $ALBUMNAME on online rows, so the parent album is left
    # blank (the subtitle just omits it).
    my $onlineTrackCmd = [ 'listenlater', 'addctx', 'kind:track',
        'trackname:$TITLE', 'artist:$ARTISTNAME', 'svc:$SERVICE', 'favurl:$FAVURL', 'image:$IMAGE' ];

    # A PODCAST episode row in the built-in Podcasts app. Verified in the served bundle:
    # those rows have no stdItem and no metadata, so Material's is-track flag is false and
    # the category it resolves is "<command>-album" = 'podcasts-album' — and it prefers a
    # PRESENT per-command category over the generic online-*. So writing a POPULATED
    # podcasts-album is what replaces the generic "Add album …" with "Add podcast …" there,
    # and nowhere else. (The same per-app override we already use EMPTY for suppression;
    # populated it can only ever add, never hide.)
    # The row carries no favurl and no id — only $TITLE and $IMAGE — so the episode is
    # resolved at add time against the user's subscribed feeds (Podcast.pm).
    my $podcastCmd = [ 'listenlater', 'addctx', 'kind:podcast',
        'name:$TITLE', 'artist:$ARTISTNAME', 'svc:$SERVICE', 'image:$IMAGE' ];

    # Each context menu category maps to a list of { cmd, role } bases — one per "Add"
    # pair (Add to Listen Later + Add to Wish List) written for it. The distinction is by
    # SURFACE: an ALBUM "…" menu saves the album; a TRACK "…" menu (album-track /
    # playlist-track / queue-track / online-track — each a distinct Material surface verified
    # in the served bundle) saves the track. The Now Playing panel (`track`,
    # nowplaying-page.js getCustomActions("track")) is ambiguous, and a Material top-level
    # custom action CAN'T open a chooser sub-menu (verified: doCustomAction does exactly one
    # of iframe/weblink/command/script/lmscommand, and getSectionActions renders a FLAT list)
    # — so its default action is **Add the playing TRACK**, and the album option lives in the
    # "… → More" menu (the TrackInfo provider, which CAN drill/list).
    my $albumBase       = { cmd => $albumCmd,       role => 'plain' };
    my $trackBase       = { cmd => $trackCmd,       role => 'plain' };
    my $npBase          = { cmd => $trackCmd,       role => 'nowplaying' };
    my $onlineAlbumBase = { cmd => $onlineCmd,      role => 'plain' };
    my $onlineTrackBase = { cmd => $onlineTrackCmd, role => 'plain' };
    my $podcastBase     = { cmd => $podcastCmd,     role => 'podcast' };
    my %cats = (
        'album'          => [ $albumBase ],
        'album-track'    => [ $trackBase ],
        'playlist'       => [ $albumBase ],
        'playlist-track' => [ $trackBase ],
        'track'          => [ $npBase ],      # Now Playing — default = Add track; album is in "… → More"
        'queue-track'    => [ $trackBase ],
        'online-album'   => [ $onlineAlbumBase ],
        'online-track'   => [ $onlineTrackBase ],
        # NB: deliberately NO 'online-artist' — we save albums/tracks, not artists. An
        # artist row's $TITLE is the artist name (no album, no favurl), so adding
        # one would store a junk record that can never replay.
    );

    # The built-in Podcasts app, keyed on ITS browse command. '-album' is the category
    # Material actually resolves for those rows (see $podcastCmd); '-track' is written with
    # the same pair purely as insurance, in case a future Material starts classifying them
    # as tracks — a populated category can only add an entry, never suppress one.
    # Only written when the Podcast plugin holds subscriptions, because an episode can only
    # be resolved against a subscribed feed; with none, the generic "Add album" stays and
    # keeps rejecting exactly as it does today, rather than promising a podcast add we
    # can't honour.
    if (Plugins::ListenLater::Podcast::hasFeeds()) {
        $cats{'podcasts-album'} = [ $podcastBase ];
        $cats{'podcasts-track'} = [ $podcastBase ];
    }

    # NB: deliberately NO 'favorites-*' category. FAVOURITES is the other route people take
    # to a podcast (favourite the feed, browse into it), and 0.1.85 gave it its own category
    # purely to get type-neutral wording there. Now that EVERY row-level entry is neutral,
    # favourites inherit exactly the right wording from the online-* fallback — and the
    # last-resort podcast resolve in _addCtxCommand covers the behaviour — so the extra
    # category would be pure duplication. (Anything a previous build wrote is emptied by the
    # strip pass and then removed by the delete-empties pass below, which is what stops an
    # empty leftover from SUPPRESSING the online-* fallback — the 0.1.52 rule.)

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

    # Per base command, two entries: "Add … to Listen Later" (the base command, which
    # defaults to the Listen Later list) and "Add … to Wish List" (the same command plus
    # list:wishlist). Titles are qualified by role (album/track) so a menu offering both —
    # Now Playing — reads unambiguously; single-role menus still say which they save. All
    # carry the 'listenlater' verb, so _isOurAction strips/rewrites them on each run.
    my %roleTitle = (
        # A browse ROW already tells you what it is — you're looking at an album, a track,
        # a podcast episode — so naming the type in the menu is noise, and naming it per
        # CONTAINER (which is all Material can do) gets it wrong on any mixed list. Every
        # row-level entry therefore reads the same plain "Add to Listen Later".
        plain      => { later => 'Add to Listen Later',       wishlist => 'Add to Wish List' },
        # The exception: Material's Now Playing panel is outside any listing, so both "this
        # track" and "the album it's from" are plausible and the entry MUST say which. Its
        # top-level action adds the TRACK; the album option lives in "… → More" (the
        # TrackInfo provider, which can drill) and is qualified there for the same reason.
        nowplaying => { later => 'Add track to Listen Later', wishlist => 'Add track to Wish List' },
        # NO wishlist entry for a podcast: the Wish List is for things you might BUY, and
        # you don't buy podcast episodes. A role with no wishlist title writes one entry.
        podcast    => { later => 'Add to Listen Later' },
    );
    for my $cat (keys %cats) {
        for my $base (@{ $cats{$cat} }) {
            my $t = $roleTitle{ $base->{role} };
            push @{ $data->{$cat} ||= [] }, {
                title      => $t->{later},
                icon       => 'playlist_add',
                lmscommand => $base->{cmd},
            };
            push @{ $data->{$cat} }, {
                title      => $t->{wishlist},
                icon       => 'shopping_cart',
                lmscommand => [ @{ $base->{cmd} }, 'list:wishlist' ],
            } if $t->{wishlist};
        }
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

    # The track "… → More" menu offers "Add album …" (the album this track belongs to). The
    # individual TRACK is added from the top-level custom action (album-track / online-track /
    # queue-track, and the Now Playing `track` default) — so More carries the *album* option,
    # which is otherwise unreachable from a track row. (On Material this is where the Now
    # Playing "Add album" lives, since a top-level action can't drill.)
    my $albumRec = Plugins::ListenLater::Sources::captureFromTrack($client, $url, $track, $remoteMeta);
    unless ($albumRec && $albumRec->{album_title}) {
        $log->warn('LL: TrackInfo handler: no album captured, no menu item');
        return;
    }
    $log->warn("LL: TrackInfo handler: captured album $albumRec->{source} / $albumRec->{album_title}");
    return [
        _addItemFor($client, $albumRec, 'later',    'PLUGIN_LL_ADD'),
        _addItemFor($client, $albumRec, 'wishlist', 'PLUGIN_LL_ADD_WISHLIST'),
    ];
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

    my %params = (
        source  => $rec->{source}      // 'library',
        artist  => $rec->{artist}      // '',
        album   => $rec->{album_title} // '',
        year    => $rec->{year}        // '',
        artwork => $rec->{artwork}     // '',
        albumid => $albumid,
        svc     => $ref->{_svc}        // '',
        list    => $list,
    );

    my $go = {
        player     => 0,
        cmd        => [ 'listenlater', 'add' ],
        params     => \%params,
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

    # Classify a library release now (its track count is local + free).
    if ($source eq 'library' && defined $albumid && length $albumid) {
        $rec->{rel_type} = Plugins::ListenLater::Sources::relTypeFor(
            count => Plugins::ListenLater::Sources::libraryTrackCount($albumid));
    }

    # Don't save an album from a source we can't replay — reject instead of
    # storing a record that only fails later at play time (see _isReplayableSource).
    return _rejectAdd($request, $source, $rec->{album_title}) unless _isReplayableSource($source);

    # Same classify-before-insert rule as the Material path: a streaming release whose type
    # isn't yet known is classified first (async) so the list never shows a wrong "Album"
    # that flips on refresh. Library / known-type inserts immediately.
    $request->addResult('count', 1);
    return _finishAlbumAdd($request, $rec, $list, $source, $albumid, $rec->{artist})
        if $rec->{rel_type} || $source eq 'library';
    return _classifyThenAdd($request, $rec, $list, $source, $albumid, $rec->{artist});
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

# Track-save: build a kind='track' record from resolved fields and store it. The play url
# + source are worked out from the given url (a streaming scheme names its own source), a
# library track id, or — for a Material Now Playing add that carries neither — the
# currently-playing track (_nowPlayingTrackFallback). Rejects (silently, like the album
# path) a source we can't replay or a track with no resolvable play url. Reached ONLY from
# the Material custom action (addctx kind:track / a track-shaped favurl); the local
# info-providers offer the ALBUM only, so on Classic there is no individual-track add.
sub _saveTrackRecord {
    my ($request, $list, %f) = @_;

    my $source  = $f{source} || '';
    my $url     = $f{url};
    my $trackId = $f{trackid};
    my ($track, $artist, $album, $year, $artwork)
        = @f{qw(track artist album year artwork)};

    my $scheme = ($url && $url =~ m|^(\w+)://|) ? lc $1 : '';
    if ($scheme && $scheme ne 'file') {
        $source = Plugins::ListenLater::Sources::sourceFromUrl($url);
    }
    elsif (defined $trackId && $trackId =~ /^\d+$/) {
        # Library track by id — take the canonical url + metadata from the object.
        my $t = eval { Slim::Schema->find('Track', $trackId) };
        if ($t) {
            $source  = 'library';
            $url     = $t->url;
            $track   = (eval { $t->title }) // $track;
            $artist  = (eval { $t->artistName }) // $artist;
            my $alb  = eval { $t->album };
            $album   = (eval { $alb ? $alb->title : undef }) // $album;
            $year  ||= (eval { $alb ? $alb->year  : undef });
            $artwork = (eval { $alb && $alb->artwork ? 'music/' . $alb->artwork . '/cover' : undef }) // $artwork;
        }
    }
    elsif ($scheme eq 'file') {
        $source = 'library';
    }

    # Now Playing track add (Material's `track` category): no favurl, no track id — recover
    # the play url straight from the currently-playing song on this client.
    if ((!defined $url || !length $url) && $request->client) {
        my ($npSrc, $npUrl, $npTrack, $npArtist, $npAlbum, $npYear, $npArt)
            = _nowPlayingTrackFallback($request->client, $track, $artist);
        if ($npSrc && $npUrl) {
            $source  = $npSrc;
            $url     = $npUrl;
            $track   = $npTrack  if defined $npTrack  && length $npTrack;
            $artist  = $npArtist if defined $npArtist && length $npArtist;
            $album   = $npAlbum  if defined $npAlbum  && length $npAlbum;
            $year  ||= $npYear;
            $artwork = $npArt // $artwork;
            $log->warn("LL: now-playing fallback recovered track url for '" . ($track // '?') . "'");
        }
    }

    # Strip a trailing " (YYYY)" off the album (Material appends it) for a clean subtitle.
    if (defined $album && $album =~ s/\s*\((\d{4})\)\s*$//) { $year ||= $1; }

    return _rejectAdd($request, $source, $track)
        unless _isReplayableSource($source)
            && defined $url   && length $url
            && defined $track && length $track;

    my %tf = (
        source => $source, url  => $url,  track   => $track,   artist  => $artist,
        album  => $album,  year => $year, artwork => $artwork, trackId => $trackId,
    );

    # A STREAMING track whose release is a SINGLE is the same recording as that single, so
    # store it AS the Single (album form): it then shows "Single" and shares the album
    # dedupe key with "Add album" (no duplicate). Needs the album id (from the service's
    # cached metadata) and a single verdict; every other case — multi-track release, no
    # recoverable album id, Bandcamp/library — falls through to storing the individual track.
    # Services that can't classify still can't DUPLICATE: the album-add path reconciles
    # against an existing track (_finishAlbumAdd cross-kind), and _insertTrackRow reconciles
    # a track against an existing single. See _saveTrackClassify.
    # NB: do NOT gate on an album NAME here — a streaming BROWSE track row carries none
    # ($ALBUMNAME is empty, and a browse add has no Now-Playing fallback), yet it's exactly a
    # single we want to detect. Classification needs only the album ID (recovered inside
    # _saveTrackClassify); the Single's title falls back to the track title (a single's
    # release title is the track title). Requiring the name here skipped every browse-track
    # single (the "Tidal singles add purely as tracks" bug).
    if (_canClassifyTrack($source) && $request->client) {
        return _saveTrackClassify($request, $list, \%tf);
    }
    return _insertTrackRow($request, $list, \%tf);
}

# Save a podcast EPISODE from a Podcasts-app browse row. That row carries no play url and
# no durable id (only $TITLE and $IMAGE), so the episode is resolved against the user's
# subscribed feeds first — see Podcast.pm for why that's the only identity available. The
# resolved enclosure is stored as an ordinary kind='track' row, so replay, dedupe and the
# played-through Played check all come from the existing track machinery unchanged.
# Async — setStatusProcessing holds the request open — with a timeout so an unreachable
# feed can't leave the add hanging.
sub _savePodcastEpisode {
    my ($request, $list, $p, $rejectSource) = @_;

    # When called as the last-resort fallback the add wasn't a podcast action at all, so a
    # rejection should name the source it really came in as, not 'podcast'.
    $rejectSource = 'podcast' unless defined $rejectSource && length $rejectSource;

    my $title = $p->{name};
    unless (defined $title && length $title) {
        $log->warn('LL: podcast add with no title — rejected');
        return _rejectAdd($request, $rejectSource, undef);
    }

    # The Wish List is for things you might BUY — which a podcast episode never is. The
    # podcast action therefore offers no Wish List entry at all; this only fires when the
    # episode came in through a GENERIC container's "Add to Wish List" (Favourites etc.),
    # where the menu can't know it's a podcast. Save it to Listen Later rather than drop it
    # into a list where it makes no sense.
    if ($list eq 'wishlist') {
        $log->warn("LL: podcast episode sent to the Wish List — saving to Listen Later instead");
        $list = 'later';
    }

    # Same gate every other add path runs: don't store what we can't replay. This path
    # inserts via _insertTrackRow directly (it doesn't go through _saveTrackRecord), so the
    # check has to be made here — and it's made BEFORE the async feed work, so a server
    # without the podcast:// handler costs nothing.
    return _rejectAdd($request, $rejectSource, $title) unless _isReplayableSource('podcast');

    # A show/section row (not an episode) resolves to nothing and is rejected below. The
    # per-command category can't be scoped to episodes only: Material's per-action filter
    # keys on the favurl, and these rows have none.
    $request->setStatusProcessing;

    my $done = 0;
    my $finish = sub {
        my ($ep) = @_;
        return if $done; $done = 1;

        return _rejectAdd($request, $rejectSource, $title) unless $ep && $ep->{url};

        # artist is left EMPTY and the show goes in album_title: the row then reads
        # "♪ <episode>" with "Podcast · <show>" beneath it, rather than repeating the show
        # on both lines. Dedupe still separates episodes (the key's track segment is the
        # episode title, the album segment the show).
        return _insertTrackRow($request, $list, {
            source  => 'podcast',
            url     => $ep->{url},
            track   => ($ep->{title} // $title),
            artist  => undef,
            album   => $ep->{show},
            year    => $ep->{year},
            artwork => ($ep->{image} // $p->{image}),
            trackId => undef,
        });
    };

    my $timeout = sub {
        $log->warn('LL: podcast episode resolve timed out — rejected');
        $finish->(undef);
    };
    Slim::Utils::Timers::setTimer(undef, time() + 20, $timeout);

    Plugins::ListenLater::Podcast::resolveEpisode($title, $p->{image}, sub {
        my ($ep) = @_;
        Slim::Utils::Timers::killTimers(undef, $timeout);
        $finish->($ep);
    });
    return;
}

# Insert an individual-track row (kind='track'). Split out of _saveTrackRecord so the
# single-detection path can fall back to it. TWO dedupe guards, both requiring a known
# artist (a bare title match across artists would be too loose):
#   (1) cross-KIND — this release is already saved as a Single album: same recording, so
#       don't add a second row for it.
#   (2) same-kind, album-AGNOSTIC — this track is already saved as a track. Needed because
#       the track dedupe key carries the PARENT ALBUM, and the album name differs by add
#       SURFACE: a queue/Now-Playing row sends $ALBUMNAME, a streaming BROWSE track row
#       sends none (online-track has no name: param), so the same track saved from both
#       yields 'artist|the album||t:x' vs 'artist|||t:x' — different keys, which DB::add's
#       exact-key findAnyByKey can't reconcile. findTrackByArtistTitle matches on
#       artist + title with the album segment wild, which catches it.
sub _insertTrackRow {
    my ($request, $list, $tf) = @_;
    my ($source, $url, $track, $artist, $album, $year, $artwork, $trackId)
        = @{$tf}{qw(source url track artist album year artwork trackId)};

    if (defined $artist && length $artist && defined $track && length $track) {
        my $sing = eval { Plugins::ListenLater::DB::findByArtistAlbum($source, $artist, $track) };
        undef $sing unless $sing && ($sing->{rel_type} // '') eq 'single';
        my $dup = $sing
            || eval { Plugins::ListenLater::DB::findTrackByArtistTitle($source, $artist, $track) };
        if ($dup) {
            $log->warn("LL: track '" . ($track // '?') . "' already saved as a "
                . ($sing ? 'single' : 'track') . " (id=" . ($dup->{id} // '?')
                . ") — not adding a duplicate track row");
            if (my $client = $request->client) {
                eval { $client->showBriefly({ line => [ cstring($client, 'PLUGIN_LL'),
                    _addedMsg($client, $list, 1, $dup->{source}, $source) ] }, { duration => 2 }); };
            }
            $request->addResult('count', 0);
            $request->setStatusDone;
            return;
        }
    }

    my $rec = {
        kind        => 'track',
        source      => $source,
        artist      => $artist,
        album_title => $album,
        track_title => $track,
        year        => ($year && $year =~ /(\d{4})/) ? $1 : undef,
        artwork     => $artwork,
        ref_kind    => 'url',
        ref         => { _svc => $source, url => $url,
                         (defined $trackId && length $trackId ? (track_id => $trackId) : ()) },
    };

    my ($id, $already, $existingSource) = eval { Plugins::ListenLater::DB::add($rec, $list) };
    if ($@) { $log->error("LL: track add failed: $@"); }
    else {
        $log->warn("LL: track add -> $source / " . ($track // '?')
            . " (id=" . ($id // '?') . ", already=" . ($already // 0) . ", list=$list)");
    }

    if (my $client = $request->client) {
        eval { $client->showBriefly({ line => [ cstring($client, 'PLUGIN_LL'),
            _addedMsg($client, $list, $already, $existingSource, $source) ] }, { duration => 2 }); };
    }

    $request->addResult('count', $id ? 1 : 0);
    $request->setStatusDone;
    return;
}

# Services whose streaming track-adds we try to classify (single → store as the Single).
# Qobuz gives an authoritative release_type; Tidal falls back to a resolved track count.
# Deezer/Bandcamp can't cheaply yield an album id from a playing track, so they degrade to
# storing the track (the cross-kind guards still prevent a duplicate).
sub _canClassifyTrack {
    my ($source) = @_;
    return defined $source && $source =~ /^(?:qobuz|tidal|deezer)$/;
}

# Streaming track-add single-detection. Read the release's album id from the service's
# cached metadata; if we can classify it as a SINGLE, store it as the Single (album form)
# so it dedupes with "Add album" and shows "Single". Anything else (no id, multi-track
# release, classify timeout) stores the individual track. Async — setStatusProcessing holds
# the request open, with a safety timeout so the add always completes.
sub _saveTrackClassify {
    my ($request, $list, $tf) = @_;
    my $client = $request->client;
    my $source = $tf->{source};

    my $albumId = eval { Plugins::ListenLater::Sources::trackAlbumId($client, $tf->{url}) };
    $log->warn("LL: track-classify source=$source url=" . ($tf->{url} // '?')
        . " albumId=" . (defined $albumId && length $albumId ? $albumId : '(none)'));
    return _insertTrackRow($request, $list, $tf) unless defined $albumId && length $albumId;

    # The record we'd store IF this is a single — same shape the album-add path builds, so
    # the dedupe key matches an "Add album" of the same release. A browse-track add has no
    # album name → fall back to the track title (a single's release title == the track).
    my $albumRec = {
        source      => $source,
        artist      => $tf->{artist},
        album_title => (defined $tf->{album} && length $tf->{album}) ? $tf->{album} : $tf->{track},
        rel_type    => 'single',
        year        => ($tf->{year} && $tf->{year} =~ /(\d{4})/) ? $1 : undef,
        artwork     => $tf->{artwork},
        ref_kind    => 'search',
        ref         => { _svc => $source, album_id => $albumId, passthrough => { album_id => $albumId } },
    };

    $request->setStatusProcessing;

    my $done = 0;
    my $finish = sub {
        my ($rt, $count, $prov, $year) = @_;
        return if $done; $done = 1;
        if (($rt // '') eq 'single') {
            # A PROVISIONAL count (Qobuz's catalogue tracks_count) settles the type but is
            # never stored as Played's total — see Sources::classifyRelType. _provisionalCount
            # tells _finishAlbumAdd not to re-ask for one it has already declined.
            $albumRec->{track_count}      = $count if $count && !$prov;
            $albumRec->{_provisionalCount} = 1     if $count && $prov;
            $albumRec->{year} = $year if $year && !$albumRec->{year};
            return _finishAlbumAdd($request, $albumRec, $list, $source, $albumId, $tf->{artist});
        }
        return _insertTrackRow($request, $list, $tf);
    };

    my $timeout = sub {
        $log->warn('LL: track relType classify timed out — storing as a track');
        $finish->(undef);
    };
    Slim::Utils::Timers::setTimer(undef, time() + 6, $timeout);

    Plugins::ListenLater::Sources::classifyRelType($client, $source, $albumId, $albumRec, sub {
        my ($rt, $count, $prov, $year) = @_;
        Slim::Utils::Timers::killTimers(undef, $timeout);
        $finish->($rt, $count, $prov, $year);
    });
    return;
}

# Recover (source, url, title, artist, album, year, artwork) for a Now Playing TRACK add
# from the client's currently-playing song — the Material `track` action supplies no
# favurl/id. Unlike the album Now-Playing fallback there's no album-match guard: a track
# add from Now Playing is unambiguously *this* playing track. Prefers a non-http url so the
# scheme still names the service; fills streaming album/artist/cover from the handler meta.
sub _nowPlayingTrackFallback {
    my ($client, $wantTrack, $wantArtist) = @_;

    my $song   = eval { $client->playingSong } or return ();
    my $ptrack = eval { $song->track };
    my $ctrack = eval { $song->currentTrack };
    my $track  = $ptrack || $ctrack or return ();
    my $purl   = eval { $ptrack->url };
    my $curl   = eval { $ctrack->url };
    my $url    = (defined $purl && $purl !~ m|^https?://|) ? $purl
               : (defined $curl && $curl !~ m|^https?://|) ? $curl
               : ($purl // $curl);
    return () unless defined $url && length $url;

    my $scheme = ($url =~ m|^(\w+)://|) ? lc $1 : '';
    my $source = (!$scheme || $scheme =~ /^(?:file|db|tmp)$/) ? 'library' : $scheme;

    my $title  = (eval { $track->title }      // $wantTrack);
    my $artist = (eval { $track->artistName } // $wantArtist);
    my ($album, $year, $art);

    if ($source eq 'library') {
        my $alb = eval { $track->album };
        $album = eval { $alb ? $alb->title : undef };
        $year  = eval { $alb ? $alb->year  : undef } || undef;
        $art   = eval { $alb && $alb->artwork ? 'music/' . $alb->artwork . '/cover' : undef };
    }
    else {
        $album = eval { $track->albumname };
        my $meta = Plugins::ListenLater::Sources::playingMeta($client, $url);
        $title  = $meta->{title}  if (!defined $title  || !length $title)  && defined $meta->{title}  && length $meta->{title};
        $artist = $meta->{artist} if (!defined $artist || !length $artist) && defined $meta->{artist} && length $meta->{artist};
        $album  = $meta->{album}  if (!defined $album  || !length $album)  && defined $meta->{album}  && length $meta->{album};
        $art    = _coverFromMeta($meta);
    }

    return ($source, $url, $title, $artist, $album, $year, $art);
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

# ---------------------------------------------------------------------------
# The PRIVATE favurl params — the handshake a sibling plugin uses to hand over what
# Material's own $VARS can't carry (cover art, Bandcamp page url, artist, year, clean
# album title, release type, track count). Each is stripped from the favurl IN PLACE,
# whatever its value, so nothing is ever left behind for the downstream source /
# 'album:<id>' logic, and only THEN validated. Native streaming-plugin favurls carry no
# query string, so none of these fire for an ordinary streaming Add and such a favurl
# comes back byte-for-byte unchanged. All of it runs BEFORE the addctx log in the caller,
# so the logged favurl always reads as the clean id.
#
# This lives in its own sub, apart from _addCtxCommand, so the extraction is directly
# testable: 0.1.89's '&tc=' bug (see the tc block below) survived a 24-check suite that
# pulled these regexes out of this file by grep and applied them standalone — it never ran
# the validation that sits beside them. tools/t_favurl.pl drives THIS sub instead. Param
# order is significant and is preserved. Returns a hashref of what was found;
# $p->{favurl} is modified in place.
# ---------------------------------------------------------------------------
sub _stripPrivateParams {
    my ($p) = @_;
    my %out;

    # A favurl from the sibling ListenBrainz Fresh Releases plugin carries the album
    # cover as a "?cover=<url-encoded>" param: its matched rows show the streaming
    # SERVICE LOGO as the thumbnail, so $IMAGE is the logo, not the art. Pull the
    # cover out and prefer it over $IMAGE, then strip the param so the source /
    # album:<id> logic downstream sees a clean "<scheme>://album:<id>". Strip the param
    # with its OWN leading delimiter ([?&]): removing "&cover=…" (cover as a later param)
    # or "?cover=…" (cover as the lone param — what LBF actually appends) both leave a
    # well-formed favurl. [^&]* (not +) tolerates an empty value. We don't consume a
    # trailing "&", so nothing is glued together.
    # Bandcamp matches pack the cover art AND the album page url into a single escaped
    # '?b=' param ('<art>|<url>'): get_album needs the page url for an exact replay.
    # Unpack it — art = cover, url = exact replay key (and the Buy link). The full ~164-
    # char favurl is confirmed to survive Material intact (an earlier "long favurls are
    # dropped" theory was a shadowed-install artifact, not real); the album_id resolve in
    # Sources is just a safety net if the url half is ever absent. Other services use the
    # plain '?cover=' (art only).
    if ($p->{favurl} && $p->{favurl} =~ s{[?&]b=([^&?]*)}{}) {
        require URI::Escape;
        my ($a, $u) = split /\|/, URI::Escape::uri_unescape($1), 2;
        $out{cover}        = $a if defined $a && length $a;
        $out{bandcamp_url} = $u if defined $u && length $u;
    }
    elsif ($p->{favurl} && $p->{favurl} =~ s{[?&]cover=([^&]*)}{}) {
        require URI::Escape;
        $out{cover} = URI::Escape::uri_unescape($1);
    }

    # LBF also packs the release artist (and optionally year) into the favurl as
    # private '&a='/'&y=' params, because Material sends its matched rows NO
    # $ARTISTNAME — so without this the record is artist-less and never auto-moves to
    # Played (Played matching keys on source+artist+album).
    if ($p->{favurl} && $p->{favurl} =~ s{[?&]a=([^&]*)}{}) {
        require URI::Escape;
        $out{artist} = URI::Escape::uri_unescape($1);
    }
    if ($p->{favurl} && $p->{favurl} =~ s{[?&]y=([^&]*)}{}) {
        $out{year} = $1;
    }

    # Some sibling plugins label their browse rows "Artist - Album" (e.g. Pitchfork
    # Reviews' review rows), and Material forces $ALBUMNAME/$TITLE to that whole label for
    # online items — so the album name arrives with the artist prefixed. Those plugins pack
    # the CLEAN album title into the favurl as '&al=' (the symmetric partner of the '&a='
    # artist above); the caller prefers it over $TITLE so the stored album is clean ("Extra
    # Mile", not "Will Sheff - Extra Mile"). The list display AND Played auto-detection both
    # key on the album name, so a polluted title shows doubled and never auto-moves to
    # Played. ([?&]a= above can't match '&al=' — it needs '=' right after 'a'.)
    if ($p->{favurl} && $p->{favurl} =~ s{[?&]al=([^&]*)}{}) {
        require URI::Escape;
        $out{album} = URI::Escape::uri_unescape($1);
    }

    # A sibling plugin that resolves MusicBrainz release-groups (ListenBrainz Fresh
    # Releases) can pack the TRUE release type into the favurl as '&rt=' (album|ep|single) —
    # the only authoritative type signal we get, since the streaming plugins' track coderefs
    # expose none. Used by the caller for rel_type.
    if ($p->{favurl} && $p->{favurl} =~ s{[?&]rt=([^&]*)}{}) {
        $out{rel_type} = $1;
    }

    # …and, alongside it, that release's TRACK COUNT as '&tc=' (LBF 0.9.142+). The sibling
    # already holds it: it reads the count off the streaming service's own album hash while
    # matching (its _candReleaseType), so sending it costs nothing and saves us the album
    # fetch _verifyRelease would otherwise make after the insert. It matters most as the
    # check on '&rt=' — MusicBrainz calls a release with B-sides a Single, which is not what
    # 'single' means here (see Sources::singleIsWrong) — and having it at INSERT time means
    # the row is right immediately, with no service call at all.
    #
    # Validated as 1-3 digits, non-zero. A bogus or huge value would set an unreachable
    # Played threshold (60% of a nonsense total) and no real release runs to 1000 tracks, so
    # anything else is dropped and we fall back to resolving, exactly as an add from a
    # pre-0.9.142 sibling does.
    if ($p->{favurl} && $p->{favurl} =~ s{[?&]tc=([^&]*)}{}) {
        # Copy the capture out BEFORE validating it. The validation match has no capture
        # group of its own, and in Perl a SUCCESSFUL match still resets $1 to undef — so the
        # original '$1 =~ /^\d{1,3}$/ && $1 > 0' discarded EVERY count (the second $1 was
        # always undef) and left a "Use of uninitialized value $1 in numeric gt" warning in
        # the log on every LBF add. That was 0.1.89's bug: the whole handshake was inert.
        my $tc = $1;
        $out{tracks} = $tc + 0 if defined $tc && $tc =~ /^\d{1,3}$/ && $tc > 0;
    }

    return \%out;
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

    # The private sibling-plugin handshake params, pulled out of the favurl (and stripped
    # from it) in one place — see _stripPrivateParams.
    my $priv = _stripPrivateParams(\%p);
    my ($favCover, $favBandcampUrl, $favArtist, $favYear, $favAlbum, $favRelType, $favTracks)
        = @{$priv}{qw(cover bandcamp_url artist year album rel_type tracks)};

    my $list = _wantedList($request->getParam('list'));

    $log->warn('LL: addctx params -> '
        . join(', ', map { "$_=" . (defined $p{$_} ? $p{$_} : '(undef)') } qw(name artist albumid year trackname trackid favurl image svc)));

    # Track save. Two signals decide album-vs-track:
    #  (1) an explicit kind:track category — library album-track / playlist-track /
    #      queue-track / online-track / the Now Playing `track`; and
    #  (2) a track-shaped favurl — because Material collapses a STREAMING album's track rows
    #      onto 'online-album' (verified live: a Qobuz album-drill track fires online-album
    #      with name=$TITLE, no kind), so the category alone misses them; the play url
    #      (…​.flac, /track/…) is the reliable tiebreaker (Sources::favurlIsTrack).
    # $TRACKNAME carries the track title on real track-context rows; an online row redirected
    # here by its favurl has only $TITLE (mapped to `name`), which IS the track title.
    # Podcast episode (the podcasts-* custom action carries kind:podcast). Checked BEFORE
    # the track branch: the row has no favurl at all, so neither the kind:track test nor
    # favurlIsTrack would catch it, and it would fall through to the album path.
    if (($request->getParam('kind') || '') eq 'podcast') {
        return _savePodcastEpisode($request, $list, \%p);
    }

    my $explicitTrack = ($request->getParam('kind') || '') eq 'track';
    if ($explicitTrack || Plugins::ListenLater::Sources::favurlIsTrack($p{favurl})) {
        my $trackTitle = $p{trackname} // $p{name};
        # Only a real track-context command ($TRACKNAME present) means $ALBUMNAME is the
        # parent album; for a favurl-redirected online row `name` is the TRACK title, so the
        # parent album is unknown → leave it to the '&al=' handshake (usually undef).
        my $album = defined $p{trackname} ? ($favAlbum // $p{name}) : $favAlbum;
        return _saveTrackRecord($request, $list,
            source  => (($p{svc} && $p{svc} =~ /^[a-z0-9]+$/i) ? lc $p{svc} : ''),
            artist  => ($p{artist} // $favArtist),
            album   => $album,
            track   => $trackTitle,
            year    => ($p{year} || $favYear),
            artwork => ($favCover // $p{image}),
            url     => $p{favurl},
            trackid => $p{trackid},
        );
    }

    my $artist  = $p{artist};
    # Fall back to the artist packed in the favurl (LBF rows arrive with an empty
    # $ARTISTNAME) so the stored record has an artist for display AND Played matching.
    $artist = $favArtist if (!defined $artist || !length $artist) && defined $favArtist && length $favArtist;
    my $artwork = $favCover // $p{image};
    my $year    = $p{year} || $favYear;
    # Prefer the clean album packed in the favurl (&al=) over the "Artist - Album" row label.
    my $album   = (defined $favAlbum && length $favAlbum) ? $favAlbum : $p{name};
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
        # Keep the label the SERVICE printed on the row, when '&al=' replaced it (0.1.92).
        # A sibling's '&al=' hands us the MusicBrainz release name, which is the better
        # title for DISPLAY and for the dedupe key — but MB deliberately holds the
        # distinguisher OUTSIDE the title (all four American Football LPs are titled
        # "American Football"; "LP2"/"LP3" live in MB's `disambiguation`), whereas the
        # service prints "American Football (LP2)". Played's streaming path matches on the
        # album TITLE only (no id anchor — see Played::_matchRecord), so storing MB's bare
        # name alone would stop the playing track ever matching this row. Keep both: the
        # clean name is what we show and key on, this is what the service will call it
        # when it plays. Only when they actually differ — an identical label is noise.
        # NB `$album` is already stripped of a trailing "(YYYY)"/format qualifier by here;
        # `$p{name}` is the raw label, which is exactly what the player will report.
        $ref->{svc_title} = $p{name}
            if defined $p{name} && length $p{name}
            && defined $album && $p{name} ne $album;
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

    # Last resort before rejecting: this may be a PODCAST EPISODE reached through some
    # container OTHER than the Podcasts app. Material picks the custom action by the
    # CONTAINER's browse command, so an episode under a favourited feed arrives as
    # svc='favorites' (a home-shelf card or a search hit likewise) and never reaches the
    # kind:podcast action — it lands here with no favurl, no id, just $TITLE and $IMAGE.
    # Resolving it here catches every such container at once instead of chasing them one
    # category at a time. It costs nothing on a working add: it only runs on one that was
    # already going to be rejected, and the feeds are cached.
    if (!_isReplayableSource($source)
            && !(defined $p{favurl}  && length $p{favurl})
            && !(defined $p{albumid} && length $p{albumid})
            && Plugins::ListenLater::Podcast::hasFeeds()) {
        return _savePodcastEpisode($request, $list, \%p, $source);
    }

    # Reject a source we can't replay (Deezer/Spotify/radio/…): don't store a record that
    # would only fail at play time — reject it (silently) instead. This is the one reliable
    # gate, so we no longer bother hiding the Material "Add" button per service.
    return _rejectAdd($request, $source, $album) unless _isReplayableSource($source);

    # Release type. Library releases classify instantly (local track count); a '&rt='
    # handshake is authoritative. A streaming release with NEITHER must be classified BEFORE
    # the row is inserted — otherwise the list shows a wrong "Album" that flips to EP/Single
    # on the next refresh (unacceptable). See _finishAlbumAdd / _classifyThenAdd.
    # The count comes from the library (free, local) or from the sibling's '&tc=' handshake;
    # either way relTypeFor gets to check a claimed 'single' against it here and now, with no
    # service round trip. A streaming add with neither still resolves later.
    #
    # That check is the ONE thing only an add-time count can do, and it's worth having: if a
    # claimed 'single' is still standing when the row is inserted, _finishAlbumAdd's cross-kind
    # dedupe can match it against an already-saved TRACK of the same name and drop the add
    # entirely — and no background correction repairs a row that was never inserted.
    my $relCount = ($source eq 'library' && defined $p{albumid} && $p{albumid} =~ /^\d+$/)
        ? Plugins::ListenLater::Sources::libraryTrackCount($p{albumid})
        : $favTracks;

    my $relType = Plugins::ListenLater::Sources::relTypeFor(
        service => $favRelType,
        (defined $relCount ? (count => $relCount) : ()),
    );

    # A LIBRARY album's year, read straight from the local database. Material's custom action
    # has no $YEAR variable at all (its map is $ALBUMNAME/$ARTISTNAME/$TITLE/$FAVURL/$IMAGE/
    # $ALBUMID), so a library album added from a Material menu arrived with no year even
    # though $ALBUMID is passed and LMS knows the answer — the info-provider path
    # (_addItemFor) has always sent one, so the same album keyed differently depending on
    # which menu you used, and the two rows could not dedupe. Free and local, exactly like
    # the track count above; never overrides a year that did arrive.
    if (!$year && $source eq 'library' && defined $p{albumid} && $p{albumid} =~ /^\d+$/) {
        $year = Plugins::ListenLater::Sources::libraryAlbumYear($p{albumid}) || undef;
    }

    # track_count is Played's total, and ONLY a count resolved from a real TRACKLIST may fill
    # it — the same rule the Qobuz catalogue count is held to (Sources::classifyRelType).
    #
    # So '&tc=' does NOT go in here, even though it's a perfectly good number for the type
    # check above. The sibling reads it off a streaming service's own album hash, which makes
    # it a CATALOGUE count: it describes the release, not what this account can play in this
    # region, and it can only ever be >= the playable count. Storing it would set Played's bar
    # at 60% of a total some users can never reach — the exact bug the Qobuz path had. It
    # arrives as a bare integer with no provenance, so LL cannot tell a resolved count from a
    # catalogue one and must assume the unsafe case.
    #
    # Consequence, deliberate: leaving this NULL means _finishAlbumAdd still runs the
    # background _verifyRelease, so '&tc=' no longer saves that call. On Tidal/Deezer that's a
    # gain — the verify resolves a real tracklist and stores a true total. On Qobuz it fetches
    # the album object, gets a provisional count it won't store, and the total waits for the
    # first play from the list. That's the same call an add without '&tc=' has always made, so
    # nothing is worse than before; the handshake just stops being a saving. A provisional
    # number should not suppress the hunt for a real one.
    #
    # A library release is counted live from the library at play time (Played::_totalTracks),
    # which can't go stale, so it stores nothing here either.
    my $rec = {
        source      => $source,
        artist      => $artist,
        album_title => $album,
        rel_type    => $relType,
        track_count => undef,
        year        => ($year && $year =~ /(\d{4})/) ? $1 : undef,
        artwork     => $artwork,
        ref_kind    => ($source eq 'library' ? 'album_id' : 'search'),
        ref         => $ref,
    };

    my $albumId = $ref->{album_id} || ($ref->{passthrough} && $ref->{passthrough}{album_id});

    # Known type (library, or the &rt= handshake) → insert NOW: the add must never wait on
    # a service. What we don't have for a streaming release is its track count, and Played
    # needs that — but it is not needed at add time, so _finishAlbumAdd chases it in the
    # background once the row is in (_verifyRelease), which is also where a claimed 'single'
    # is confirmed. Only an UNKNOWN streaming type still blocks: there the label itself is
    # missing, and a row that appears as "Album" and flips to EP/Single on refresh is worse
    # than a moment's wait.
    return _finishAlbumAdd($request, $rec, $list, $source, $albumId, $artist)
        if $relType || $source eq 'library';
    return _classifyThenAdd($request, $rec, $list, $source, $albumId, $artist);
}

# Insert an album record, backfill a missing streaming artist, and confirm. The common tail
# of both the immediate and the classify-first add paths.
sub _finishAlbumAdd {
    my ($request, $rec, $list, $source, $albumId, $artist) = @_;

    # A single already saved as an individual TRACK — or as another SINGLE row whose only
    # difference is the year segment — is the SAME recording, so don't add a second row.
    # Only when we KNOW it's a single and the artist is known (a bare title match across
    # artists would be too loose). The year case is real because the year reaching us
    # depends on the add SURFACE: a Now Playing add recovers it from Material's
    # "Album (YYYY)" label, a Qobuz/Tidal browse row sends none, so the same single lands
    # as 'artist|title|2026' one way and 'artist|title|' the other — different dedupe keys.
    # findByArtistAlbum is year-agnostic, and the rel_type='single' gate on BOTH rows keeps
    # 0.1.43 intact (two same-titled ALBUMS from different years still coexist).
    if (($rec->{rel_type} // '') eq 'single'
            && defined $artist && length $artist
            && defined $rec->{album_title} && length $rec->{album_title}) {
        my $dup = eval { Plugins::ListenLater::DB::findTrackByArtistTitle($source, $artist, $rec->{album_title}) };
        my $asTrack = $dup ? 1 : 0;
        if (!$dup) {
            my $other = eval { Plugins::ListenLater::DB::findByArtistAlbum($source, $artist, $rec->{album_title}) };
            $dup = $other if $other && ($other->{rel_type} // '') eq 'single';
        }
        if ($dup) {
            $log->warn("LL: single '" . ($rec->{album_title} // '?') . "' already saved as a "
                . ($asTrack ? 'track' : 'single') . " (id="
                . ($dup->{id} // '?') . ") — not adding a duplicate album row");
            if (my $client = $request->client) {
                eval { $client->showBriefly({ line => [ cstring($client, 'PLUGIN_LL'),
                    _addedMsg($client, $list, 1, $dup->{source}, $source) ] }, { duration => 2 }); };
            }
            $request->setStatusDone;
            return;
        }
    }

    my ($id, $already, $existingSource) = eval { Plugins::ListenLater::DB::add($rec, $list) };
    if ($@) {
        $log->error("LL: album add failed: $@");
    }
    else {
        $log->warn("LL: add -> $source / " . ($rec->{album_title} // '?') . " (id=" . ($id // '?')
            . ", already=" . ($already // 0) . ", list=$list, rel=" . ($rec->{rel_type} // '-') . ")");
    }

    # Chase the release's real track count once the row is safely in — Played thresholds on
    # it, and a claimed 'single' is only disprovable against it. Deliberately AFTER the
    # insert and fire-and-forget: the add is a button press and must not wait on a service.
    # Skipped when the count is already known — either the classify-first path resolved it or
    # the sibling handed it over as '&tc=', which is the point of that handshake: no call at
    # all — and for library rows (Played counts those live from the library). Also skipped when
    # a classify already got a PROVISIONAL count for this row (_provisionalCount): that is
    # Qobuz's catalogue count, deliberately not stored as the total (Sources::classifyRelType),
    # and re-fetching the same album object would return the same number and store it no more —
    # a wasted call, and one whose "no count stored" outcome would read like a failure.
    if ($id && !$already && $source ne 'library'
            && !$rec->{track_count} && !$rec->{_provisionalCount}) {
        _verifyRelease($request->client, $id, $rec, $source, $albumId);
    }

    # Tidal/Deezer browse rows send no $ARTISTNAME (Material doesn't map their subtitle) and
    # their cover URL has no artist/id — but the favurl gives the album id, so fetch the
    # artist from the album's tracks in the background. Without it the row never auto-moves to
    # Played (keys on source+artist+album). Fire-and-forget; only for a fresh artist-less add.
    if ($id && !$already && ($source eq 'tidal' || $source eq 'deezer')
            && (!defined $artist || !length $artist) && $albumId) {
        _backfillStreamingArtist($request->client, $id, $albumId, $source);
    }

    if (my $client = $request->client) {
        eval { $client->showBriefly({ line => [ cstring($client, 'PLUGIN_LL'),
            _addedMsg($client, $list, $already, $existingSource, $source) ] }, { duration => 2 }); };
    }

    $request->setStatusDone;
    return;
}

# Classify a streaming release whose type NOTHING told us, before inserting, so the list
# never shows a wrong "Album" that flips on refresh. Qobuz gives a release_type; other
# services fall back to the resolved track count (Sources::classifyRelType) — and a REAL
# count is kept too, so this path needs no background _verifyRelease afterwards. Qobuz's
# catalogue count is provisional and is not kept (it settles the type only), but the row is
# marked so _finishAlbumAdd doesn't go and ask the same question again.
# This is the one add that waits: a release whose type is known inserts immediately.
# Async — setStatusProcessing holds the request open — with a safety timeout so the add
# always completes (worst case the type is NULL, shown neutrally, still no wrong label).
sub _classifyThenAdd {
    my ($request, $rec, $list, $source, $albumId, $artist) = @_;
    my $client = $request->client;

    $request->setStatusProcessing;

    my $done = 0;
    my $finish = sub {
        my ($rt, $count, $prov, $year) = @_;
        return if $done; $done = 1;
        $rec->{rel_type} = $rt if $rt;
        # A year off the service's album object, for a row that arrived without one — a plain
        # streaming browse row carries no year. Set BEFORE the insert so it reaches the dedupe
        # key too (DB::add builds the key from artist|album|year); a yearless row keys
        # differently from the same album added later with a year, and they can't dedupe.
        $rec->{year} = $year if $year && !$rec->{year};
        # A PROVISIONAL count (Qobuz's catalogue tracks_count) settles the type but is never
        # stored as Played's total — see Sources::classifyRelType. _provisionalCount tells
        # _finishAlbumAdd not to chase a count this path has already seen and declined.
        $rec->{track_count}      = $count if $count && !$prov;
        $rec->{_provisionalCount} = 1     if $count && $prov;
        _finishAlbumAdd($request, $rec, $list, $source, $albumId, $artist);
    };

    my $timeout = sub { $log->warn('LL: relType classify timed out — inserting unclassified'); $finish->(undef); };
    Slim::Utils::Timers::setTimer(undef, time() + 6, $timeout);

    Plugins::ListenLater::Sources::classifyRelType($client, $source, $albumId, $rec, sub {
        my ($rt, $count, $prov, $year) = @_;
        Slim::Utils::Timers::killTimers(undef, $timeout);
        $finish->($rt, $count, $prov, $year);
    });
    return;
}

# Find out what a just-saved streaming release really contains, in the background, and
# correct the row. Two things come back from the one lookup (Sources::classifyRelType):
#
#   • the TRACK COUNT — stored so Played can threshold on the real thing. Without it a
#     streaming release falls on the flat streaming_min_tracks floor, which a release with
#     fewer tracks than the floor can never reach, so it would never move to Played. Only a
#     count from a resolved TRACKLIST is stored; Qobuz's catalogue count comes back flagged
#     provisional and is used for the type check only, never as the total (it can exceed
#     what's playable here, and 60% of an inflated total is unreachable —
#     Sources::classifyRelType). It still proves the service ANSWERED, so it never retries.
#   • a corrected TYPE, in exactly two cases: a claimed 'single' the tracklist disproves
#     (Sources::singleIsWrong), and a row that carries NO type at all — the shape
#     _classifyThenAdd's safety timeout leaves behind, which otherwise shows the neutral
#     "Album" default for good. Any OTHER claim is left alone: MusicBrainz and Qobuz know an
#     EP from an album better than a track count does.
#
# Fire-and-forget by design. The add already completed and the row is already on screen;
# this is a slower, optional improvement to it, so nothing waits on it, nothing times it
# out, and a service that never answers costs only a missing count — which the first
# drill/play from the list fills in anyway (Browse::_albumTracks), from a resolve that
# would have happened regardless. Needs a client for the service API handlers.
#
# Cost is one album fetch, and only when the tracklist can be fetched DIRECTLY
# (Sources::hasDirectAlbumRef — a native album id, or for Bandcamp the album PAGE url its
# get_album actually scrapes). Otherwise the lookup falls back to SEARCHING the service by
# artist (Sources::_searchService) — far too much work to spend on a background nicety, and
# the least reliable answer of the lot. Those rows simply wait for their first play. On
# Qobuz it's cheaper still: the album object states its own track count, so no tracklist is
# fetched at all (and that count is provisional — see above).
# A failed verify is RETRIED ONCE, because of what the failure costs on a claimed single: the
# claim stands, `Played::_totalTracks` reads 'single' as a real total of 1, and the release is
# marked Played after ONE of its tracks — then auto-purged days later. That is the very bug
# 0.1.88 set out to fix, so a transient outage at add time must not be allowed to reinstate it.
# A retry is the right shape because the alternative — refusing to trust the label until a count
# corroborates it — would put every pre-0.1.88 single (which has no stored count) back on the
# 4-track floor, re-opening 0.1.82. Heal the row; don't punish the rows that predate the check.
use constant VERIFY_RETRY_SECS   => 60;
use constant VERIFY_MAX_ATTEMPTS => 2;   # the first go plus one retry
use constant VERIFY_TIMEOUT_SECS => 6;   # a callback that never arrives (same wait as _classifyThenAdd)

sub _verifyRelease {
    my ($client, $recId, $rec, $source, $albumId, $attempt) = @_;
    return unless $client && $recId;
    # Only when the tracklist can be fetched DIRECTLY. Asking Sources means this can't drift
    # from what a resolve actually costs: an album id is enough for Qobuz/Tidal/Deezer, but
    # Bandcamp replays off the album PAGE url, so an id-only Bandcamp row would resolve via a
    # full service SEARCH — precisely the cost this gate exists to refuse (see the header).
    return unless Plugins::ListenLater::Sources::hasDirectAlbumRef($rec);
    return unless defined $albumId && length $albumId;
    $attempt ||= 1;

    my $claim = $rec->{rel_type};

    # A callback that NEVER ARRIVES is the third failure route, and it used to be the silent
    # one: the two guarded below are a callback reporting no count and a synchronous die, but
    # an HTTP request that is accepted and then never answered fires neither, so the row kept
    # its unverified claim with nothing in the log. Same shape _classifyThenAdd guards with
    # its own 6s timer. $done makes the timeout and the callback mutually exclusive, so a
    # late answer can't act after the retry was armed (and vice versa).
    my $done = 0;
    my $timeout;
    $timeout = sub {
        return if $done; $done = 1;
        $log->warn("LL: rec $recId — release verify never answered");
        _armVerifyRetry($client, $recId, $rec, $source, $albumId, $attempt);
    };
    Slim::Utils::Timers::setTimer(undef, time() + VERIFY_TIMEOUT_SECS, $timeout);

    my $ok = eval {
        Plugins::ListenLater::Sources::classifyRelType($client, $source, $albumId, $rec, sub {
            my ($rt, $count, $prov, $year) = @_;
            Slim::Utils::Timers::killTimers(undef, $timeout);
            return if $done; $done = 1;

            # A missing release year, filled from the album object this lookup already
            # fetched. Done BEFORE the count check below, because it is worth having even on
            # the path where no count comes back — and it costs nothing extra.
            # DB::updateYear won't overwrite a year we already hold, and recomputes the
            # dedupe key so the row can't be duplicated by a later add that carries one.
            Plugins::ListenLater::DB::updateYear($recId, $year) if $year;

            # No count: the service couldn't be reached, or returned nothing playable. Never
            # silent — this was invisible before, which is exactly why it could sit unnoticed.
            # A PROVISIONAL count still counts as an answer here (the service replied), so it
            # must not trigger the retry — it just isn't stored as the total.
            return _armVerifyRetry($client, $recId, $rec, $source, $albumId, $attempt)
                unless $count;

            Plugins::ListenLater::DB::updateTrackCount($recId, $count) unless $prov;
            return unless $rt;
            # A type the source CLAIMED is only ever overwritten to demote a wrong 'single'
            # — MusicBrainz and Qobuz read an EP from an album better than a count does.
            if (Plugins::ListenLater::Sources::singleIsWrong($claim, $count)) {
                Plugins::ListenLater::DB::updateRelType($recId, $rt, 1);
                $log->warn("LL: rec $recId was added as a single but has $count tracks"
                    . " — reclassified as $rt");
            }
            # No claim at all — the row went in with a NULL type, which happens when
            # _classifyThenAdd's safety timeout fired and inserted unclassified. We have just
            # been handed the answer it was waiting for, and throwing it away left the row
            # showing the neutral default ("Album", per Browse::_typeLabel) forever. Unforced,
            # so it only ever fills a NULL (updateRelType's WHERE rel_type IS NULL) and can't
            # race over a type a drill/play stored in the meantime. Mirrors the same repair in
            # Browse::_albumTracks, which does this on every resolve.
            elsif (!defined $claim || !length $claim) {
                Plugins::ListenLater::DB::updateRelType($recId, $rt);
                $log->warn("LL: rec $recId had no type — classified as $rt from $count tracks");
            }
        }, $claim);
        1;
    };
    unless ($ok) {
        Slim::Utils::Timers::killTimers(undef, $timeout);
        return if $done; $done = 1;
        $log->warn("LL: release verify failed for rec $recId: $@");
        _armVerifyRetry($client, $recId, $rec, $source, $albumId, $attempt);
    }
    return;
}

# Schedule the single retry (or give up, loudly). Kept separate so both failure routes — a
# callback with no count, and a synchronous die — go through the same attempt accounting and
# can never chain into a third try.
sub _armVerifyRetry {
    my ($client, $recId, $rec, $source, $albumId, $attempt) = @_;

    if (($attempt || 1) >= VERIFY_MAX_ATTEMPTS) {
        # Worth a WARN, not silence: the row keeps the type its source claimed, which for a
        # 'single' means Played may act on a total of 1 it never confirmed. Opening or playing
        # the release from the list still fixes it (Browse::_albumTracks).
        $log->warn("LL: rec $recId — no track count after " . ($attempt || 1)
            . " attempts; keeping the claimed type '" . ($rec->{rel_type} // '-')
            . "'. It will be corrected on first play from the list.");
        return;
    }

    $log->warn("LL: rec $recId — release verify got no track count, retrying in "
        . VERIFY_RETRY_SECS . "s");
    Slim::Utils::Timers::setTimer($client, time() + VERIFY_RETRY_SECS, \&_verifyRetryTick, {
        recId   => $recId,
        source  => $source,
        albumId => $albumId,
        attempt => ($attempt || 1) + 1,
    });
    return;
}

# The retry itself. A NAMED sub, not a closure, so setTimer/killTimers pair on one coderef and
# a re-arm can't build a self-referencing chain (the 0.1.83 lesson from _deferredMarkTick).
# Re-reads the row rather than trusting the captured copy: in the intervening minute it may have
# been removed, or a drill/play may have resolved it and stored the real count already, in which
# case there is nothing left to do.
sub _verifyRetryTick {
    my ($client, $args) = @_;
    return unless ref $args eq 'HASH' && $args->{recId};

    my $rec = eval { Plugins::ListenLater::DB::get($args->{recId}) } or return;
    return if $rec->{track_count};

    # No live player, no service API handler — give up rather than pretend.
    return unless $client;
    my $live = eval { Slim::Player::Client::getClient($client->id) };
    return unless $live;

    _verifyRelease($live, $args->{recId}, $rec, $args->{source}, $args->{albumId},
                   $args->{attempt});
    return;
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
