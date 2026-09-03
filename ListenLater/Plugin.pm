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
});

# A PREF-MIGRATION FLAG MUST NOT START WITH AN UNDERSCORE.
#
# `Slim::Utils::Prefs::Base::set` stores a value only `if ($valid && $pref !~ /^_/)` — a pref
# whose name begins with `_` is DISCARDED, with no error, no warning and no return value to
# check, and `get` then returns undef for ever. (The namespace reserves that prefix for its own
# `_ts_<pref>` write stamps.) The 0.1.25 rebrand's one-shot flag was exactly that shape, so it
# never persisted and its migration re-ran on EVERY server start, silently reverting every
# Settings change. That migration is gone (0.1.108) — the rule it cost us is not.
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
# bump undone within the same startup by the broken rebrand copy (since removed), so the setting
# they are actually running is still 60 while the flag says the migration is done. Version 2 re-applies it
# once, now that the copy can no longer overwrite it. A user who deliberately chose 60 in the
# meantime never kept it either — it was being rewritten from the old namespace at every restart —
# so there is no considered choice here to overrule.
use constant THRESHOLD_MIGRATION => 2;

_migratePrefs();

# The one-shot pref migration, in a sub purely so a test can drive it over a prepared
# store — the bug it exists to fix is a migration that ran when it shouldn't have, and
# top-level code that runs once per process can't be asked to do that twice.
sub _migratePrefs {
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

# Material 6.4.6 added a REGISTRATION API for custom actions — a plugin hands its entries to
# Material (`registerCustomAction($section, $action)`), which serves them over the CLI query
# ["material-skin","plugin-actions"]; the JS fetches that at app start and merges it with the
# shared actions.json (customactions.js `getSectionActions` iterates BOTH lists, file first).
# That is the right home for our "Add" entries: no writing to a file we don't own, no stale
# categories surviving an uninstall, and no browser cache of it (the file is fetched with a
# `?r=<material version>` cache-buster, the CLI query is not — see 0.1.57).
#
# THE DELIVERY TIER. The API arrived in two steps, and the middle step is actively dangerous
# to call the way the final one wants to be called — so "does the sub exist" is no longer a
# sufficient test, and this replaces the plain `->can` gate 0.1.95 used.
#
#   0  no registerCustomAction (Material < 6.4.6, or no Material at all) — everything goes in
#      the shared actions.json, byte for byte as it did before 0.1.95.
#   1  registerCustomAction exists, Material 6.4.6 / 6.4.7 — the POSITIVE entries register; the
#      two client-resolved surfaces, the podcasts override and every empty suppressor still have
#      to be written to the file (see _materialActionSet). This is 0.1.95-0.1.109 behaviour.
#   2  Material >= 6.4.8 (upstream PR #1257) — ALL of it registers, empty suppressors included,
#      and the file is PRUNED instead of written (see _pruneMaterialActions).
#
# **Tier 2 requires BOTH tests, and the version half is not belt-and-braces.** #1257 is what
# made `registerCustomAction($section)` — one argument, no action — mean "declare an EMPTY
# category". On 6.4.6/6.4.7 that identical call pushes **undef** into the section; Material
# serves it as `{"<cat>":[null]}`; customactions.js then reads `sect[i].locked` off the null and
# throws — taking out every custom action in that section, other plugins' included, not just
# ours. So the empty-section call is tier-2-only and must never be reached by capability alone.
#
# There is no side-effect-free capability probe to prefer over the version parse:
# `$PLUGIN_CUSTOM_ACTIONS` is a file-scoped `my` in Material's Plugin.pm, so it cannot be read
# back, and probing by registering a section cannot be undone (there is no unregister).
#
# A dev/test Material (non-numeric version) is treated as newest, same as `Browse::_headerType`.
# The window that makes that wrong — a dev build cut between 6.4.6 and the #1257 merge
# (2026-08-30) — is closed and shrinking; anything built from master since carries the fix.
#
# Returns ($tier, $coderef), and the caller calls THROUGH the code ref. Not cosmetic: a compiled
# `Plugins::MaterialSkin::Plugin::registerCustomAction(...)` binds to that glob at OUR compile
# time, which on a server is fine but ties the call to whatever the symbol table held when this
# module loaded. Looking it up through ->can each run is what the capability test already does,
# so use its answer rather than a second, staler route to the same sub.
sub _materialActionTier {
    my $register = Plugins::MaterialSkin::Plugin->can('registerCustomAction')
        or return (0, undef);
    # undef (can't tell) falls to tier 1 with the false case — the safe API tier, which is
    # what the unknown case wanted anyway. A dev/test build answers 1, so it reaches tier 2.
    #
    # ASSIGN TO A SCALAR FIRST — do not inline _materialVersion() into the argument list.
    # It is `return eval { ... }`, and a failed eval BLOCK yields an EMPTY LIST in list
    # context, not undef. Inlined, the args collapse from (undef, 6, 4, 8) to (6, 4, 8),
    # so $ver becomes 6, fails the numeric match, and takes the dev-build branch — every
    # install without Material silently reaching tier 2. Caught by t_material_actions.pl.
    my $ver  = _materialVersion();
    my $tier = Plugins::ListenLater::Sources::materialAtLeast($ver, 6, 4, 8) ? 2 : 1;
    return ($tier, $register);
}

# Just the tier, for the callers that don't need the code ref.
sub _actionTier { my ($t) = _materialActionTier(); return $t }

# registerCustomAction PUSHES — there is no unregister and no de-dupe, so registering twice
# puts every entry in the menu twice. Register exactly once per server run (postinitPlugin);
# the Settings save and the deferred radio re-write must not reach it.
#
# `our`, not `my`, purely so t_material_actions.pl can reset it between cases — "registers
# exactly once" is the whole contract here, and a file-scoped lexical cannot be re-armed.
#
# It latches on the ATTEMPT, not on success: a retry inside the same server run would only
# re-push whatever DID land. What Material refused is recovered by the FILE instead —
# %UNREGISTERED holds those entries (cat => [ action, … ]) and _writeMaterialActions writes
# exactly them, so a failed registration degrades to the legacy path rather than leaving the
# user with the entry in neither place. Per ACTION, not per category, because the two lists
# are merged client-side: file-writing one Material already took would show it twice.
our $REGISTERED   = 0;
our $REGISTERED_N = 0;   # how many entries Material actually took (0 = the API gave us nothing)
our %UNREGISTERED;       # cat => [ actions registerCustomAction refused ] — file fallback

# The EMPTY suppressor sections registered this run (tier 2 only), cat => 1.
#
# `$REGISTERED` above is a single latch because the positive entries are built once and never
# grow. The suppressors do grow: the radio browse commands are DISCOVERED ASYNC — TuneIn's
# directory is fetched from mysqueezebox.com and is not ready at postinit — so the +60s deferred
# pass finds commands the first pass could not (0.1.56). On tier 2 that pass has to REGISTER
# those, not write them, and a single latch would either block it entirely or re-push everything.
#
# Registering a brand-new empty section late is safe (nothing to double). Re-registering an
# existing one is a no-op in Material too — its one-arg branch only creates the section when it
# does not `exist` — but that is Material's internal, not a contract, so track ours here and
# only ever ask for sections we have not asked for.
our %REGISTERED_EMPTY;

# Which POSITIVE sections have already been handed to Material. `$REGISTERED` alone was enough
# while the positive set was fixed at startup, which is what its comment above claims — and on
# tier 2 that stopped being true: the `podcasts-*` override is gated on
# Podcast::hasFeeds() and FOLDS INTO %positive there, so a user who subscribes to their first
# podcast mid-session grows a section the latch then refuses to ever offer. It reached neither
# half — the prune only writes back what registration REFUSED — so podcast rows had no "Add"
# until a server restart. Per category, latched on the ATTEMPT exactly as the single flag was,
# so a section present at startup behaves precisely as before and only a NEW one is offered.
our %REGISTERED_POS;

# How many entries per category the API half actually DELIVERED: what we built, minus what
# registerCustomAction refused. ONE carrier, because "delivered" was written out three times and
# two of the copies subtracted the caller's %fallback instead of %UNREGISTERED. That reads
# correctly in _writeMaterialActions — there %fallback IS %UNREGISTERED — but _pruneMaterialActions
# zeroes %fallback on the $departing / $prefOff paths as a WRITE-POLICY decision, and the copied
# expression then reported every refused entry as registered: turning the pref off after a total
# registration failure had the dump claim "plugin API", "registered sections = …", "streaming Add
# active" and per-service "Add shown (via its own registered '<cmd>-album' section)" while nothing
# was live at all. The refusal ledger is the only honest input here, so take it directly and never
# let a caller pass a substitute.
sub _deliveredCounts {
    my ($positive) = @_;
    my %n;
    for my $cat (keys %$positive) {
        my $d = scalar(@{ $positive->{$cat} }) - scalar(@{ $UNREGISTERED{$cat} || [] });
        $n{$cat} = $d if $d > 0;
    }
    return %n;
}

# Can we actually save AND replay an album from this source? Only the local library and
# the streaming services with an adapter in Sources.pm (Qobuz/Bandcamp/Tidal/Deezer/Spotify,
# each when its plugin is installed). Everything else — BBC Sounds, radio stations, any
# service we haven't added support for — would store a record that can never resolve
# to a playable album (it fails at play time with "Could not find this album to play"), so
# we REJECT the add instead of storing junk. NB the test is adapter support, NOT whether a
# favurl was supplied: a service can send a perfectly good `<scheme>://album:<id>` favurl
# and still not play, if nothing here knows how to replay it — which is exactly what Deezer
# and Spotify did before their adapters existed. This is the one reliable gate — it runs on
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

# Re-run 60s after startup: the internet-radio directory loads asynchronously, so the radio
# suppressors created at postinit miss TuneIn's categories (0.1.56).
#
# On tier 0/1 that is a FILE re-write and nothing more — the positives are already registered,
# `registerCustomAction` has no de-dupe, and nothing registered depends on that directory.
#
# On tier 2 the suppressors ARE registered, so this pass has real registration work: the radio
# commands the first pass could not see. `_registerMaterialActions` skips the positives (the
# `$REGISTERED` latch) and registers only empty sections it has not already asked for
# (`%REGISTERED_EMPTY`), so re-running it here cannot double anything.
#
# NB the late-discovery race is unchanged by the move to the API, and is not fixable from here:
# a Material tab already loaded took its `pluginCustomActions` snapshot at app start, so a
# section registered at +60s is invisible to it either way — exactly as a late FILE write is
# invisible to the browser-cached customactions.json (0.1.57). Both recover on the next app load.
sub _writeMaterialActionsDeferred {
    return unless $prefs->get('material_action')
        && Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin');
    eval { _registerMaterialActions(); 1 }
        or $log->error("LL: deferred Material custom-action registration failed: $@");
    eval { _writeMaterialActions(); 1 }
        or $log->error("LL: deferred Material custom-action write failed: $@");
}

sub postinitPlugin {
    my $class = shift;

    if ( $prefs->get('material_action')
      && Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin') ) {
        # Material 6.4.6+: hand our entries straight to Material. On an older Material this is
        # a no-op and _writeMaterialActions writes them to actions.json as before. Either way
        # the file write runs — it still carries the parts the API cannot express (see
        # _materialActionSet), and on the API path it is also what STRIPS our old file entries
        # so an upgraded install doesn't show every "Add" twice.
        eval { _registerMaterialActions(); 1 }
            or $log->error("LL: failed to register Material custom actions: $@");

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

    # The podcasts-* override is the one part of the set that is not fixed for the run:
    # _materialActionSet emits it only while Podcast::hasFeeds() is true, so a user who
    # subscribes to their first feed GROWS a category after both passes above have run. On
    # tier 0/1 the next file write picks it up, but on tier 2 it is registered, and nothing
    # re-registers on its own — the prune writes back only what registration REFUSED, so the
    # pair reached NEITHER half and podcast rows had no "Add" until a server restart.
    # Watching the Podcast plugin's own pref is what closes that; the deferred pass is
    # exactly the right callback, since it re-registers what is new and rewrites the file.
    #
    # OUTSIDE the branch above, and gated only on Material being present, because the pref
    # is not the only way in. Ticking the box on the Settings page mid-run registers and
    # writes (Settings.pm) but installs nothing — so had this stayed in the ON arm, a server
    # that started with the box UNTICKED would run the rest of its life with no watcher, and
    # a first feed subscribed after the box was ticked would reach neither half. The callback
    # self-gates on the pref (see _writeMaterialActionsDeferred), so installing it here while
    # the box is off costs nothing and does nothing until the box is ticked. Installing it
    # from Settings.pm instead would be wrong: setChange STACKS callbacks, so it would add
    # one per save.
    #
    # UNSUBSCRIBING the last feed is NOT the mirror case on tier 2, and the same call
    # does NOT handle it: `registerCustomAction` PUSHES with no unregister (see the
    # note above %REGISTERED_POS), so once `podcasts-*` is registered it stays live for
    # the rest of the run with our "Add" on it — which `_savePodcastEpisode` can no
    # longer honour, since it resolves an episode against the subscribed feeds. Tier
    # 0/1 DO mirror it: the pair leaves %fileCats and the next file write drops it.
    # The tier-2 residue is bounded — with no feeds there are few podcast rows left to
    # press Add on, and it clears at the next restart — so it is accepted rather than
    # worked around. If it ever needs closing, the fix is a hasFeeds() check inside the
    # add handler at invocation time, not more registration bookkeeping.
    # NB a Material tab already open took its snapshot at app start, so the new entry
    # appears on the next app load — the standing late-registration caveat, not a new one.
    if ( Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin') ) {
        eval {
            Slim::Utils::Prefs::preferences('plugin.podcast')
                ->setChange(\&_writeMaterialActionsDeferred, 'feeds');
            1;
        } or $log->error("LL: could not watch the podcast subscription list: $@");
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
# Material custom actions — registered with Material on 6.4.6+ (see _materialActionTier),
# written to the shared prefs/material-skin/actions.json on older Material and, either
# way, for the categories the registration API cannot express (see _materialActionSet).
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
#
# It can only clean the FILE. On Material 6.4.6+ the "Add" entries are registered with
# Material at startup and there is no unregister API, so turning the pref off takes them out
# of the menus at the NEXT RESTART (we simply don't register). Said in the log, and in the
# pref's own description in strings.txt.
#
# **While those registered entries are still live, the EMPTY SUPPRESSORS MUST STAY** — they are
# the only thing standing between the registered `online-*` pair and our own list / home shelf /
# radio browse rows (an empty "<cmd>-<type>" category overrides "online-*", the 0.1.52 rule used
# in reverse). Deleting them while the positives can't be withdrawn doesn't remove "Add", it
# ADDS it where it was suppressed: every Listen Later/Played row would offer "Add to Listen
# Later" until the restart, and using it on a Played row bounces that row back to Listen Later.
# So the empties are kept — and re-asserted — until the run that registered them ends.
# $departing — the plugin is being uninstalled or disabled (shutdownPlugin). It forces the
# full clean: the whole $live dance below exists to protect the empty suppressors while our
# registered positives are still live IN THIS RUN, and on the way out there is no next run to
# protect. Nothing re-registers, so leaving the empties behind would strand them for ever,
# suppressing another plugin's online-* actions on podcasts and every radio command with
# nothing of ours left to clean them up.
sub _clearMaterialActions {
    my ($departing) = @_;
    my $file = _materialActionsFile();

    # TIER 2 — the whole $live dance below is moot, and this is the one place where the tier
    # makes turning the pref off SIMPLER rather than harder.
    #
    # That dance exists because the registered positives cannot be withdrawn while the file
    # empties protecting our own rows are being deleted. On >= 6.4.8 the suppressors are
    # REGISTERED too, so they are exactly as live as the positives they hold back: there is
    # nothing in the file left to protect, and re-asserting file copies of sections Material
    # already holds would just put litter back into a file we are here to clean. So prune, and
    # say what the user will actually see.
    #
    # $departing (uninstall/disable) takes the same path: the prune removes everything of ours
    # from the file, and the registrations die with the server that holds them.
    #
    # The second argument says "the pref is OFF" — every route into this sub is the pref being
    # off or the plugin leaving — so the prune's positive file fallback goes too. Without it the
    # prune would put the entries registration REFUSED straight back into a file the user just
    # asked to be rid of, while tier 0/1 (below) deletes those same entries immediately: one
    # concept, two answers, which is how this pair drifts apart.
    if (_actionTier() >= 2) {
        # Two clauses, two independent facts — a dead $register coderef can leave either half at
        # zero, and the pair used to be announced together on `$REGISTERED_N || %REGISTERED_EMPTY`.
        # Whichever half was empty, the message asserted it anyway: the same class of untrue
        # diagnostic as the per-service verdict in _dumpMaterialState, in the log a "why is Add
        # still there / why has Add gone" report starts from.
        if (!$departing && ($REGISTERED_N || %REGISTERED_EMPTY)) {
            # The suppressor clause must report what the PRUNE ON THE NEXT LINE will leave live,
            # not merely what registered — the two are not the same on this path. With the pref
            # off the prune's %fallback is empty, so its %emptyFallback gate collapses to
            # $REGISTERED_N and it writes every suppressor registration REFUSED into actions.json.
            # Saying "no suppressor registered either, so another plugin's Add is not being held
            # off those rows" was therefore contradicted three lines later by the code that wrote
            # exactly those suppressors — and inside this branch it is not even reachable as a
            # true statement: the outer condition means an empty %REGISTERED_EMPTY implies
            # $REGISTERED_N, which is precisely when the file half is written. Computed the same
            # way _pruneMaterialActions computes it, so the two cannot drift.
            my @toFile = $REGISTERED_N
                ? grep { !$REGISTERED_EMPTY{$_} }
                       ( _ownSurfaceSuppressorCats(), _radioSuppressorCats() )
                : ();
            $log->warn('LL: material_action is off — '
                . ($REGISTERED_N
                    ? 'the registered "Add" entries go at the next server restart (Material has no '
                    . 'unregister API)'
                    : 'nothing of ours registered, so no "Add" entry of ours is live')
                . (%REGISTERED_EMPTY || @toFile
                    ? '. The suppressors are '
                    . (%REGISTERED_EMPTY && @toFile
                        ? 'registered, and the ' . scalar(@toFile) . ' the API refused go to '
                        . 'actions.json'
                        : %REGISTERED_EMPTY
                            ? 'registered'
                            : 'not registered, so the ' . scalar(@toFile) . ' of them go to '
                            . 'actions.json instead')
                    . ', so until then "Add" still does not appear inside our own list or on '
                    . 'radio rows'
                    : '. No suppressor is live and none is being written, so another plugin\'s '
                    . '"Add" is not being held off those rows'));
        }
        return _pruneMaterialActions($departing, 1);
    }

    # Only when something was actually registered — if the API refused every entry they are
    # in the FILE, which this sub clears here and now, so promising a restart would be wrong.
    # Reachable from the SETTINGS save only: postinit calls this from the branch where the
    # pref was already off at startup, so nothing can have registered on that path.
    my $live = (!$departing && $REGISTERED_N) ? 1 : 0;
    $log->warn('LL: material_action is off — the registered "Add" entries go at the next '
        . 'server restart (Material has no unregister API); the empty suppressor categories '
        . 'stay in actions.json until then, so "Add" does not appear inside our own list')
        if $live;

    # Nothing ever written AND nothing live to suppress. When entries ARE live the file has to
    # be (re)written even if it has gone missing — the suppressors are all that is holding
    # "Add" off our own rows.
    return unless $live || -e $file;
    my $data = _readMaterialActions($file);

    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY';
        $data->{$cat} = [ grep { !_isOurAction($_) } @{ $data->{$cat} } ];
    }

    my @ourSuppressors = _ownSurfaceSuppressorCats();
    delete $data->{$_} for (
        ($live ? () : @ourSuppressors),
        qw(listentolater-album listentolater-track listentolater-artist
           LtLHome-album LtLHome-track LtLHome-artist),
    );

    # Delete the categories we populate/suppress once they're empty: our top-level
    # pairs (album/playlist/online-*) plus the per-command radio suppressors WE wrote.
    # Guarded on empty so another plugin's real entries stay.
    # With registrations live the radio suppressors are exempt (see the header) — only
    # the top-level pairs go, and those suppress nothing: Material's per-app override reads
    # "<command>-<type>", never a bare 'album'/'online-album'.
    #
    # The suppressor list is _radioSuppressorCats(), NOT a "*-album/-track/-artist" regex:
    # an EMPTY per-command category is a deliberate Add-suppressor, so a regex here deletes
    # any OTHER plugin's suppressors along with ours and silently breaks their hiding. This
    # branch now runs from every Settings save, not just install, so that reach is real
    # (0.1.101).
    #
    # The FILE-ONLY per-app categories go with them, NOT with %ourCats below: 'podcasts-*' is
    # a "<command>-<type>" override, so once the strip pass has emptied it it SUPPRESSES the
    # 0.1.52 rule the same way a radio empty does — deleting it while our online-* pair is
    # still registered would put "Add" back on Podcasts rows, and leaving it behind when
    # nothing is registered hides Add there for good (nothing else ever cleans it: the write
    # pass that would is the one the pref being OFF stops from running). Hardcoded rather than
    # read from _materialActionSet's %fileOnly, because that only emits 'podcasts-*' while
    # Podcast::hasFeeds() is true — a user who unsubscribed everything would keep the husks.
    my @radioSup = _radioSuppressorCats();
    my @fileOnlySup = qw( podcasts-album podcasts-track );
    my %suppressor = map { $_ => 1 } @radioSup, @fileOnlySup;
    my %owned = %{ _ownedCats() };
    my %ourCats = map { $_ => 1 }
        qw(album album-track playlist playlist-track track queue-track
           online-album online-track);
    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY' && !@{ $data->{$cat} };
        delete $data->{$cat}
            if $ourCats{$cat} || (!$live && ($suppressor{$cat} || $owned{$cat}));
    }

    # Re-assert our own empties while the registered pair is live — the file may never have
    # had them (a first-ever write that failed) or may have lost them to an older build.
    # The RADIO empties go back with them, and that is not decoration: on the one path this
    # branch exists for — registrations live, file gone — the delete-empties pass above has
    # nothing to preserve, so leaving them out would let the registered online-* pair put
    # "Add" back on every TuneIn/BBC Sounds row until the restart. Same regression class as
    # the own-view suppressors, same reason — and the same argument covers the FILE-ONLY
    # per-app categories, which are per-command overrides too. `||=` for both of those: the
    # "<cmd>-*" namespace isn't ours to reset, so another plugin's real entries survive (and a
    # present category, ours or theirs, still overrides online-* → Add hidden either way).
    my $record;
    if ($live) {
        my $dir = File::Spec->catdir(Slim::Utils::Prefs::dir(), 'material-skin');
        File::Path::make_path($dir) unless -d $dir;
        $data->{$_} = [] for @ourSuppressors;
        $data->{$_} ||= [] for @radioSup, @fileOnlySup;
        # Write down what we just asserted. THIS is the half that produced the 0.1.103 husks:
        # the branch CREATES podcasts-* for a user with no subscriptions, a pair no write pass
        # can emit — so a category written here and not recorded is one the next write cannot
        # recognise as ours, and therefore can never sweep. Held until the write lands, for the
        # same reason as the write path — a ledger set against a failed write retires the seed.
        $record = { %owned, map { $_ => 1 } @ourSuppressors, @radioSup, @fileOnlySup };
    }

    _writeMaterialActionsFile($file, $data);
    _setOwnedCats($record) if $record;
    $log->warn("LL: cleared Material custom actions from $file");
    return;
}

# Commands we can save & replay. A service that also appears under the server's
# 'radios' menu (e.g. Qobuz) is skipped by _unsupportedRadioCommands so its radio
# rows keep "Add". BBC Sounds is dual-listed (apps + radios) but unsupported, so
# it is NOT here and gets blocked wherever it shows.
# NB these are browse COMMANDS, not source tags, and Spotify's differ: the Spotty plugin
# registers `tag => 'spotty'` (its Plugin.pm:130) for the service everything else here
# calls 'spotify' (Sources::%SVC_ALIAS folds the two).
my %SUPPORTED_CMD = map { $_ => 1 }
    qw(qobuz bandcamp tidal deezer spotty listenbrainzfreshreleases listenlater);

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

# The OWNERSHIP LEDGER — what "this category is ours" is allowed to mean.
#
# Every husk this file has produced (0.1.51, 0.1.102, 0.1.103) is the same defect: ownership
# was INFERRED, and the two passes inferred it differently. The write pass asked "did the
# strip pass just empty it?" (%emptied); the clear pass asked a hardcoded list. Both are
# guesses, and a category one of them creates is a category the other cannot recognise —
# which is exactly the podcasts-* case, since the clear path's $live re-assert writes a pair
# no write pass would ever emit (Podcast::hasFeeds() is false for a user with no
# subscriptions). No single derived set fixes that, because there is nothing to derive it
# from: the category is not in %fileOnly, by design.
#
# So don't infer it — RECORD it. Both passes read this list, and the rule is simply that
# whatever LL writes to the file, LL writes down.
#
# An install that predates the ledger has no list, and gets a one-time seed of the only
# pre-ledger litter that can exist: the empty per-service categories the 0.1.46-0.1.50
# scoping experiments left, and the podcasts-* pair. Both are ours by construction — no other
# plugin suppresses a service WE replay (an empty <cmd>-* there hides only our own Add), and
# the Podcasts app override is one we wrote. 'listenlater' is excluded from the seed: our own
# empty listenlater-* pair is the deliberate 0.1.52 suppressor and must never be swept.
#
# **GATING THE SEED ON "has LL ever touched this file" WAS TRIED IN 0.1.110 AND REVERTED — do
# not re-propose it.** The concern is real: every category the seed claims is `<cmd>-album`/
# `-track`, an EMPTY one of those is a deliberate Add-suppressor by this plugin's own 0.1.52
# rule, and a hand-written `qobuz-album` is indistinguishable from ours by content. But the
# husks the seed exists to sweep have EXACTLY that shape — 0.1.47-0.1.50 wrote `||= []`, i.e.
# an empty category with no entries and no other mark — so any test for "a trace of LL" also
# withholds the seed from the file that needs it, and the 0.1.51 regression comes straight back
# (`t_material_matrix.pl`'s I3/I4 fail on `legacy_husks`, which is how this was caught).
# There is nothing in the file to tell the two apart. The seed stays, on its original
# reasoning, and the protection for a third party's file lives where it can actually be exact:
# `_isOurAction` (no title guessing) and the prune's only-empty / only-ours / never-unlink-a-
# non-empty-file rules.
#
# 'spotty' is excluded from the SEED alongside 'listenlater', for a different reason but the
# same rule: the seed may only claim what LL can have written. It sweeps the husks left by
# the 0.1.46-0.1.50 scoping experiments — and those wrote empty categories only for services
# LL SUPPORTED (a per-service Add scope) and, via _radioSuppressorCats, for RADIO commands.
# Spotty is a music service that has never been either: it was unsupported until Spotify
# support was added, and it does not appear under 'radios'. So no pre-ledger install can
# hold a spotty-album/-track husk of ours, and a seed that claimed them would be claiming
# categories only somebody ELSE can have written — which the prune could then delete. A
# service that is supported from the day it arrives needs no seed entry; the ledger records
# its categories the first time we actually write them.
sub _ownedCats {
    my $l = $prefs->get('material_owned_cats');
    return { map { $_ => 1 } @$l } if ref $l eq 'ARRAY';
    return { map { ("$_-album" => 1, "$_-track" => 1) }
        'podcasts', grep { $_ ne 'listenlater' && $_ ne 'spotty' } keys %SUPPORTED_CMD };
}
sub _setOwnedCats { $prefs->set('material_owned_cats', [ sort keys %{ $_[0] } ]) }

# The empty "<cmd>-album"/"-track" suppressor categories, for every radio browse command we
# do not support. Its own sub because BOTH writers need the identical list and they compute
# it from file-scoped lexicals declared BELOW _clearMaterialActions — a sub call resolves at
# runtime, the variables would not resolve at all. _writeMaterialActions creates them;
# _clearMaterialActions re-asserts them when it rebuilds a missing file with registrations
# still live (see there). Sorted, so both writers produce the same order.
sub _radioSuppressorCats {
    my %radioCmd = map { $_ => 1 } _unsupportedRadioCommands(), @KNOWN_RADIO_CMDS;
    delete @radioCmd{ keys %SUPPORTED_CMD };
    return map { ("$_-album", "$_-track") } sort keys %radioCmd;
}

# Our OWN surfaces: the plugin's list view (browse command 'listenlater') and its Material home
# shelf ('LLHome'). Their categories are declared EMPTY, which by the 0.1.52 rule suppresses the
# generic online-* pair there — an album already in the list must not be offered "Add" again
# (re-adding bounces a Played album back to Listen Later).
#
# Its own sub because four passes need the identical list, and on tier 2 it is also the set
# REGISTERED as empty sections rather than written. The radio suppressors are the other half and
# come from _radioSuppressorCats(), kept separate because that one enumerates the server's
# 'radios' menu and must not be called from the pure action-set builder.
sub _ownSurfaceSuppressorCats {
    return qw(
        listenlater-album listenlater-track listenlater-artist
        LLHome-album LLHome-track LLHome-artist
    );
}

# Build every custom action we offer, ONCE, for every delivery path — so there is only one
# spelling of the commands however they reach Material. Takes the tier (see
# _materialActionTier) and returns three things:
#
#   %positive   the "Add to Listen Later" / "Add to Wish List" entries that are REGISTERED.
#   %fileOnly   entries that must be written to actions.json on this tier.
#   @emptyCats  our own-surface categories to declare EMPTY *by registration*. Non-empty on
#               tier 2 only; on tier 0/1 the file write creates them instead.
#
# What sits in which set is entirely a function of the tier:
#
#   tier 0/1 — %fileOnly holds `track` + `queue-track` (Material resolves those two in the
#              BROWSER and snapshots them ONCE, off a bus event only the customactions.json
#              fetch fires — so a registered entry is typically not there yet and never
#              recovers; 0.1.97) and the `podcasts-*` per-app override (Material tests
#              `appCat in customActions`, the FILE object alone). @emptyCats is empty because
#              `registerCustomAction` on those Materials takes an action and pushes it, so
#              "this category exists and is empty" has no spelling at all.
#   tier 2   — upstream PR #1257 closed all three of those gaps (customactions.js re-emits
#              `customActions` when the plugin list lands; browse-resp.js checks
#              `pluginCustomActions` for the per-app category; and a one-argument
#              registerCustomAction declares an empty section). So %fileOnly is EMPTY, its
#              contents fold into %positive, and the suppressors register.
sub _materialActionSet {
    my ($tier) = @_;
    $tier = 1 unless defined $tier;
    # `lmscommand` must be a FLAT array (verb + tag params); Material substitutes the
    # $VARS from the item and runs it fire-and-forget. $FAVURL carries the item's play
    # URL (qobuz://… etc.), which tells addctx the source.
    # An unpopulated $VAR usually arrives EMPTY, not as the literal token: doReplacements
    # ends by stripping every name in its ACTION_KEYS list to ''. **$IMAGE is not in that
    # list** (checked in the served bundle), so an item with no image really does send the
    # literal "$IMAGE" — which is why addctx keeps its unsubstituted-$VAR filter. Every
    # 0.1.98 gate tests length, so both spellings read as absent either way.
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
    # authoritative source. (Unpopulated → EMPTY — $SERVICE is in doReplacements' strip
    # list — which addctx reads as "no container command"; a populated one is believed only when
    # Sources::knownSource says it NAMES a service, else the cover-host fallback decides.)
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
    # PRESENT per-command category over the generic online-*. Writing a POPULATED
    # podcasts-album is therefore what REPLACES the generic pair on those rows, and nowhere
    # else. (The same per-app override we already use EMPTY for suppression; populated it
    # swaps the list wholesale, so it can hide an entry by not carrying it.)
    #
    # NB the win is NOT the wording — every row-level title went type-neutral ("Add to Listen
    # Later") in 0.1.85, so the generic entries read correctly here too. What the override
    # actually buys is (a) 'kind:podcast', which routes straight to _savePodcastEpisode
    # instead of leaning on the last-resort resolve at the bottom of _addCtxCommand, and
    # (b) NO "Add to Wish List" entry, because you don't buy a podcast episode (the same rule
    # _savePodcastEpisode enforces on the command side).
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
    # Registered with Material (6.4.6+). Every one of these is RE-RESOLVED per browse
    # response — so it does not matter when the plugin list reaches the client. ('track' and
    # 'queue-track' are resolved client-side too, but ONCE, off a bus event; that is what
    # they can't survive, so they are in %fileCats below.)
    my %cats = (
        'album'          => [ $albumBase ],
        'album-track'    => [ $trackBase ],
        'playlist'       => [ $albumBase ],
        'playlist-track' => [ $trackBase ],
        'online-album'   => [ $onlineAlbumBase ],
        'online-track'   => [ $onlineTrackBase ],
        # NB: deliberately NO 'online-artist' — we save albums/tracks, not artists. An
        # artist row's $TITLE is the artist name (no album, no favurl), so adding
        # one would store a junk record that can never replay.
    );

    # ---- The FILE half. Two separate reasons, both hard constraints. ----

    # 1. Now Playing ('track') and the play queue ('queue-track'). FILE-ONLY because these are
    # the only two of our categories Material resolves in the BROWSER, and it resolves them
    # exactly once, on a bus event our half of the wiring never fires. Verified in the served
    # 6.4.7 bundle: nowplaying-page and queue-page each do
    #     bus.$on("customActions", () => getCustomActions("track"|"queue-track", false))
    # and the ONLY $emit("customActions") is inside the `.then` of the axios GET of
    # customactions.json. initCustomActions fires that GET and the ["material-skin",
    # "plugin-actions"] CLI call side by side, and only the GET emits — so the snapshot is
    # taken when the GET lands, whoever won. Whenever the CLI call lands SECOND,
    # `pluginCustomActions` is still undefined at snapshot time and there is NO "Add" in either
    # panel for the whole page session; nothing re-emits, so it never recovers.
    #
    # It is a genuine race rather than a guaranteed loss: MEASURED 2026-08-29 over http, the two
    # are neck and neck (~19ms for the file GET vs ~20ms for the CLI POST) — an earlier version
    # of this comment claimed the static file wins "essentially every time", which the numbers
    # do not support. What does settle it is CACHING: the GET carries `?r=<revision>`, so on any
    # load served from the browser cache it returns at once and wins outright. Either way the
    # plugin cannot depend on the order, and an action that appears on some page loads and not
    # others is worse to diagnose than one that is reliably absent — hence file-only.
    # Every other category above is re-resolved per browse response, and is immune to load order.
    # (Neither is a per-app override, so the file costs us nothing here. The one price is the
    # 0.1.57 stale-tab caching of customactions.json — a hard refresh after install.)
    my %fileCats = (
        'track'       => [ $npBase ],   # Now Playing — default = Add track; album is in "… → More"
        'queue-track' => [ $trackBase ],
    );

    # 2. The built-in Podcasts app, keyed on ITS browse command. '-album' is the category
    # Material actually resolves for those rows (see $podcastCmd); '-track' is written with
    # the same pair purely as insurance, in case a future Material starts classifying them
    # as tracks.
    # Only written when the Podcast plugin holds subscriptions, because an episode can only
    # be resolved against a subscribed feed; with none, the generic "Add album" stays and
    # keeps rejecting exactly as it does today, rather than promising a podcast add we
    # can't honour.
    #
    # FILE-ONLY up to tier 1, and it has to be there: this is a per-app "<command>-<type>"
    # override, and a Material before 6.4.8 only consults one of those when the category is
    # present in actions.json. 6.4.8 made that test read the plugin list too, so the tier-2
    # branch below folds this pair in with the rest — see the %fileCats fold, and the
    # per-service diagnostic in _dumpMaterialState, which names whichever half it came from.
    if (Plugins::ListenLater::Podcast::hasFeeds()) {
        $fileCats{'podcasts-album'} = [ $podcastBase ];
        $fileCats{'podcasts-track'} = [ $podcastBase ];
    }

    # NB: deliberately NO 'favorites-*' category. FAVOURITES is the other route people take
    # to a podcast (favourite the feed, browse into it), and 0.1.85 gave it its own category
    # purely to get type-neutral wording there. Now that EVERY row-level entry is neutral,
    # favourites inherit exactly the right wording from the online-* fallback — and the
    # last-resort podcast resolve in _addCtxCommand covers the behaviour — so the extra
    # category would be pure duplication. (Anything a previous build wrote is emptied by the
    # strip pass and then removed by the delete-empties pass below, which is what stops an
    # empty leftover from SUPPRESSING the online-* fallback — the 0.1.52 rule.)

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

    my $build = sub {
        my ($cats) = @_;
        my %out;
        for my $cat (keys %$cats) {
            for my $base (@{ $cats->{$cat} }) {
                my $t = $roleTitle{ $base->{role} };
                push @{ $out{$cat} ||= [] }, {
                    title      => $t->{later},
                    icon       => 'playlist_add',
                    lmscommand => $base->{cmd},
                };
                push @{ $out{$cat} }, {
                    title      => $t->{wishlist},
                    icon       => 'shopping_cart',
                    lmscommand => [ @{ $base->{cmd} }, 'list:wishlist' ],
                } if $t->{wishlist};
            }
        }
        return \%out;
    };

    # Tier 2: every gap that forced the file half is closed upstream, so the whole set
    # registers. Folded here rather than at the call sites so "which delivery path" is decided
    # in exactly one place and the two writers cannot disagree about it.
    if ($tier >= 2) {
        %cats = (%cats, %fileCats);
        %fileCats = ();
        return ($build->(\%cats), $build->(\%fileCats), [ _ownSurfaceSuppressorCats() ]);
    }

    return ($build->(\%cats), $build->(\%fileCats), []);
}

# Hand %positive to Material (6.4.6+). No-op on an older Material, and no-op on every call
# after the first — see $REGISTERED. Returns the number of entries registered.
sub _registerMaterialActions {
    my ($tier, $register) = _materialActionTier();
    return 0 unless $tier;

    my ($positive, undef, $emptyCats) = _materialActionSet($tier);

    # --- the POSITIVE entries: once per SECTION per server run, latched on the ATTEMPT ---
    my ($n, %failed) = (0);
    my @fresh = grep { !$REGISTERED_POS{$_} } sort keys %$positive;
    for my $cat (@fresh) {
        # Latch before the actions, not after: a section half-taken must never be offered a
        # second time, or Material appends the survivors and every "Add" in it shows twice.
        $REGISTERED_POS{$cat} = 1;
        for my $action (@{ $positive->{$cat} }) {
            # NB a plain sub, not a method — Material's own signature is ($section,
            # $action), so calling it with `->` would pass the class name as the section.
            if ( eval { $register->($cat, $action); 1 } ) {
                $n++;
            }
            else {
                # Hand it back to the file write rather than losing it — see %UNREGISTERED.
                push @{ $failed{$cat} ||= [] }, $action;
                $log->error("LL: registerCustomAction('$cat') failed: $@");
            }
        }
    }
    if (@fresh) {
        # MERGED, not assigned: a later pass that registers one new section must not drop the
        # refusals an earlier pass recorded, or _writeMaterialActions stops writing their file
        # fallback and those entries vanish from both halves at once.
        %UNREGISTERED  = (%UNREGISTERED, %failed);
        $REGISTERED_N += $n;
        $log->warn("LL: registered $n Material custom action(s) in "
            . scalar(@fresh) . " section(s) via the plugin API (tier $tier)");
        $log->error('LL: Material refused ' . scalar(map { @$_ } values %failed)
            . ' custom action(s) — writing those to actions.json instead') if %failed;
    }
    # Set even when the set was empty: this is the flag that says the API half RAN, which is
    # what the diagnostics read to tell "delivered nothing" from "never asked".
    $REGISTERED = 1;

    # --- the EMPTY suppressor sections: tier 2 only, per category, re-runnable ---
    #
    # @$emptyCats is our own surfaces (list view + home shelf); the radio browse commands are
    # unioned in here rather than inside _materialActionSet because that list is enumerated
    # from the server's 'radios' menu and GROWS — TuneIn's directory arrives asynchronously, so
    # the +60s deferred pass calls this again and picks up what postinit could not see (0.1.56).
    #
    # Guarded per category, never by a single latch: re-registering an existing empty section
    # would be a no-op inside Material anyway (its one-arg branch only creates a section that
    # does not `exist`), but that is an internal, not a promised contract.
    #
    # A refused empty section is NOT put in %UNREGISTERED. That structure exists so a refused
    # POSITIVE can fall back to the file without doubling, and it is keyed to actions. A
    # suppressor is a category NAME; the file fallback for it is written by _writeMaterialActions
    # from %REGISTERED_EMPTY, which only ever records what Material actually took.
    my $e = 0;
    if ($tier >= 2) {
        for my $cat (@$emptyCats, _radioSuppressorCats()) {
            next if $REGISTERED_EMPTY{$cat};
            if ( eval { $register->($cat); 1 } ) {
                $REGISTERED_EMPTY{$cat} = 1;
                $e++;
            }
            else {
                $log->error("LL: registerCustomAction('$cat') as an empty section failed: $@");
            }
        }
        $log->warn("LL: registered $e empty suppressor section(s) via the plugin API") if $e;
    }

    return $n + $e;
}

# Write the parts of the action set that live in Material's SHARED actions.json. On Material
# 6.4.6+ that is only what the registration API cannot express (the podcasts override and the
# empty suppressors); on an older Material it is everything, exactly as before 0.1.95.
#
# On the API path this is ALSO the upgrade path: the strip pass below removes the entries a
# previous version wrote to the file, which is what stops every "Add" appearing twice (the
# two lists are MERGED client-side, file first, then plugin-registered).
sub _writeMaterialActions {
    my $tier = _actionTier();

    # Tier 2 writes NOTHING. Everything we offer is registered, so the only work left in the
    # shared file is taking our old entries back out — see _pruneMaterialActions.
    return _pruneMaterialActions() if $tier >= 2;

    my $file = _materialActionsFile();
    my $dir  = File::Spec->catdir(Slim::Utils::Prefs::dir(), 'material-skin');
    File::Path::make_path($dir) unless -d $dir;

    my $data = _readMaterialActions($file);

    my ($positive, $fileOnly) = _materialActionSet($tier);

    # The API path is "registration has RUN", not "the API exists". Two cases the capability
    # test alone gets wrong, both ending with the entry in neither place:
    #   * registerCustomAction died — %UNREGISTERED holds what it refused, and those entries
    #     are written to the file below (per action, so nothing Material took is doubled);
    #   * registration hasn't run at all — the pref was off at startup and has just been
    #     turned on from Settings, which re-runs THIS write but cannot register (no de-dupe,
    #     no unregister, so registering outside postinit is not safe). Writing the full set
    #     to the file is then correct AND is what makes the toggle work before a restart;
    #     the next startup registers and this same write strips the file entries again.
    my $api      = ($REGISTERED && $tier) ? 1 : 0;
    my %fallback = $api ? %UNREGISTERED : ();

    # First strip OUR entries from EVERY existing category (clears legacy 0.1.7 hash
    # entries and any stale local ones); then add the current entry where we want it.
    #
    # %emptied records the categories this strip pass took from non-empty to EMPTY — i.e.
    # the ones that held nothing but our own entries. It is the provenance signal the
    # delete-empties pass below needs: it says "this empty is our leftover" without having to
    # name the category, which is the whole problem there (see the comment on that pass).
    my %emptied;
    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY';
        my $had = scalar @{ $data->{$cat} };
        $data->{$cat} = [ grep { !_isOurAction($_) } @{ $data->{$cat} } ];
        $emptied{$cat} = 1 if $had && !@{ $data->{$cat} };
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
    # (listenlater-*/LLHome-*). This restores fall-through to the populated "online-*".
    #
    # …and EXCEPT any empty category that was ALREADY empty when we read the file (%emptied).
    # "Only-empty" is not the safe test it reads as: by this plugin's own 0.1.52 rule an empty
    # per-command category is not litter, it is a deliberate Add-SUPPRESSOR — it is why we
    # write our own — so sweeping empties disarms another plugin's hiding just as surely as
    # deleting its entries would. That is the hazard `_clearMaterialActions` was hardened
    # against in 0.1.101; this twin was left alone then because it "has to delete cruft it
    # cannot name". It doesn't have to NAME it: the cruft is exactly the categories the strip
    # pass just emptied, because the 0.1.46–0.1.50 scoping experiments wrote OUR entries into
    # them (that is what makes them ours). An empty that arrived empty was never ours — no
    # run of this code can leave one behind, since the same pass that creates one deletes it —
    # so %emptied loses nothing and stops us touching a category we never wrote.
    # Matters more than the clear path does: this write runs at every startup, on every
    # Settings save (0.1.97) and on the +60s deferred write.
    # Radio browse commands we want to suppress "Add" on (see the empty-category
    # write below). Union the live 'radios' enumeration with the hardcoded TuneIn
    # seed list (@KNOWN_RADIO_CMDS — present at init even before the async directory
    # loads), minus any command we actually support. Their "<cmd>-album"/"-track"
    # keys are exempted from the delete-empties pass below — otherwise the very
    # empties we write here get deleted again (the 0.1.52 rule: an empty category is
    # not neutral, it actively suppresses, which is exactly what we want here).
    my @radioCats = _radioSuppressorCats();

    # The categories THIS FILE still owns. On the API path the positive ones are no longer
    # written here, so they must NOT be in %keep — an emptied leftover has to be deleted, not
    # preserved (the 0.1.52 rule: an empty category is not neutral, it suppresses).
    my %owned = %{ _ownedCats() };
    my %keep = ( map { $_ => 1 } keys %$fileOnly, @radioCats,
        _ownSurfaceSuppressorCats() );
    $keep{$_} = 1 for $api ? keys %fallback : keys %$positive;
    for my $cat (keys %$data) {
        next unless $cat =~ /-(?:album|track|artist)$/;
        next if $keep{$cat};
        next unless $emptied{$cat} || $owned{$cat};   # ours by the ledger, or emptied just now
        delete $data->{$cat} if ref $data->{$cat} eq 'ARRAY' && !@{ $data->{$cat} };
    }

    # The delete-empties pass above only matches "*-album/-track/-artist", so the two
    # UNSUFFIXED categories we used to write — 'album' and 'playlist' — would survive as
    # empty husks once they move to the registration API (the hyphenated ones, 'album-track'
    # /'playlist-track'/'online-*', are already covered by it). Harmless in themselves (an empty
    # FILE section contributes nothing to the merged list) but they are our litter in a shared
    # file, and a stale empty 'album' is exactly the shape that has bitten before. Only-empty,
    # so another plugin's entries in the same category are never touched.
    if ($api) {
        for my $cat (keys %$positive) {
            next if $fallback{$cat};   # about to be re-written below
            delete $data->{$cat}
                if ref $data->{$cat} eq 'ARRAY' && !@{ $data->{$cat} };
        }
    }

    # Write the action set. On Material 6.4.6+ the positive entries went to Material directly
    # (_registerMaterialActions) and writing them here as well would show every "Add" TWICE —
    # the client merges the file and the plugin list. The file-only set is written on both
    # paths; on the legacy path it is simply part of the same one write. %fallback is the
    # exception on the API path: entries Material REFUSED, which live in neither place unless
    # written here (and can't double, since Material never took them).
    my %write = ( %$fileOnly, $api ? %fallback : %$positive );
    for my $cat (keys %write) {
        push @{ $data->{$cat} ||= [] }, @{ $write{$cat} };
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
    $data->{$_} = [] for _ownSurfaceSuppressorCats();

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
    # never legitimately addable. It covers browse rows only; a radio HOME-SHELF card can't be
    # hidden here — all shelves arrive in one 'material-skin' home-extra call, so the category
    # resolves through the shared "online-*" and it stays an add-time reject.
    #
    # NB a home shelf DOES have a per-command identity — it just isn't the service tag. Browsing
    # one dispatches through the home-extra id (the stock Qobuz plugin's "Qobuz" shelf is
    # 'QobuzExtrasqobuz'), which is what Material then passes as $SERVICE. That is why `svc` is
    # validated against Sources::knownSource and not by shape — see _addCtxCommand (0.1.96).

    # Everything this pass asserted: the entries themselves, the radio empties, the file-only
    # overrides, and our own suppressors. Recorded only AFTER the write LANDS, and the ordering
    # is load-bearing — see _ownedCats. Setting the ledger at all retires its one-time seed, so
    # a ledger recorded against a write that died would leave every pre-ledger husk (an empty
    # '<svc>-album' from 0.1.47-0.1.50) in neither %emptied nor %owned: the delete-empties pass
    # can never sweep it, and "Add" stays hidden on that service for good. _writeMaterialActions-
    # File has four die paths, so this is reachable on a full disk or an unwritable prefs dir.
    my $record = { map { $_ => 1 } keys %write, @radioCats, keys %$fileOnly,
        _ownSurfaceSuppressorCats() };
    _writeMaterialActionsFile($file, $data);
    _setOwnedCats($record);
    $log->warn("LL: wrote Material custom actions to $file");

    # What the API half actually DELIVERED, per category — not what we built. A failed
    # registration builds an entry and Material never gets it, so counting %positive would
    # report "streaming Add active" for a menu with nothing in it. Shares _deliveredCounts with
    # the prune: the subtraction used to be written out here and twice more, and the copies
    # drifted (see the sub). On tier 0/1 nothing registered at all, so the count stays empty.
    my %regCount = $api ? _deliveredCounts($positive) : ();

    _dumpMaterialState($file, $data, \@radioCats, \%regCount, $api) if $prefs->get('debug_log');
    return;
}

# ---------------------------------------------------------------------------
# TIER 2 — take our entries back OUT of the shared actions.json (0.1.110)
# ---------------------------------------------------------------------------
#
# On Material >= 6.4.8 every category we offer is registered, so nothing of ours belongs in the
# file any more. This is what removes what earlier builds put there. It is not a migration with
# an end date: the file is SHARED and persists across plugin updates and reinstalls, so this has
# to keep running — which is why the very first thing it does is return when the file is absent.
# After one successful prune on a box with no other custom actions, that is every subsequent
# call, at every startup, for nothing.
#
# **This never writes and never clobbers.** The write path hard-sets our own suppressor
# categories and creates radio ones with `||=`; the prune does neither. It strips, it deletes
# what is ours and now empty, and it puts back only what Material REFUSED. A hand-written
# actions.json is a real thing — LL has always MERGED into this file rather than overwriting it,
# so a user's own entries have coexisted with ours the whole time and cannot be assumed absent.
#
# **The file is deleted when the prune empties it**, which is the normal outcome on a box whose
# actions.json only ever held LL's entries. Verified safe against the served 6.4.9 bundle: the
# `axios.get` of customactions.json has a `.catch`, so a 404 leaves `customActions` undefined;
# `getCustomActions` tests `if (customActions || pluginCustomActions)` and `getSectionActions`
# tests `if (list && list[section])`. A missing file and an empty one are the same thing to
# Material. Anything foreign in the file keeps it alive, so "remove ours" and "leave theirs
# alone" never come into conflict.
#
# **The ordering that must hold: registration comes FIRST, in the same run.** The empty
# suppressors in the file are load-bearing until the equivalent sections are registered — they
# are all that holds the `online-*` pair off our own list rows, the home shelf and radio browse
# rows (the 0.1.52 rule). postinitPlugin and the deferred pass both call
# _registerMaterialActions before this, and both happen long before a client fetches either
# list, so there is no window. What this sub must NOT assume is that registration SUCCEEDED —
# hence the two fallback sets below, which are the whole reason it is not a plain delete.
sub _pruneMaterialActions {
    my ($departing, $prefOff) = @_;
    my $file = _materialActionsFile();

    # What is still ours to WRITE, because registration could not deliver it:
    #
    #   %fallback      positive entries registerCustomAction refused. Per ACTION, as ever — the
    #                  two lists are merged client-side, so writing one Material DID take would
    #                  show it twice.
    #   %emptyFallback suppressor categories whose empty-section registration failed. Deleting
    #                  one of those from the file would not remove "Add", it would ADD it where
    #                  it was suppressed — the exact regression 0.1.98 was written about.
    #
    # **%emptyFallback is gated on whether our online-* pair is live AT ALL, and that gate is
    # load-bearing in BOTH directions.** A suppressor exists to hold our own online-* pair off
    # our own rows; if nothing of ours is live there is nothing to hold back, and writing empty
    # `<cmd>-*` categories anyway would suppress ANOTHER plugin's online-* actions on every
    # radio and podcast row with nothing of ours left to clean them up. The pref-off-at-startup
    # path reaches this sub with nothing registered, and that is exactly the path that must
    # leave no trace.
    #
    # But "live" is not "$REGISTERED_N": %fallback is written to the file a few lines below, and
    # a file entry renders exactly like a registered one. Gating on the registered half alone
    # meant that when registration refused EVERY positive AND every empty section — one dead
    # $register coderef does both — the prune wrote our online-album/online-track back into the
    # file with no suppressor on either half, so "Add to Listen Later" reappeared on our own
    # list, Played and Wish List rows (using it on a Played row bounces it back to Listen
    # Later) and on radio browse rows. The legacy write path never had this hole: it writes the
    # suppressors unconditionally, right beside the positives it is writing.
    #
    # $departing (uninstall/disable, from shutdownPlugin) forces the full clean for the same
    # reason 0.1.108 gave: the whole fallback apparatus protects entries that are live IN THIS
    # RUN, and on the way out there is no next run to protect. Leaving either kind behind
    # strands it for ever.
    #
    # $prefOff (material_action turned off, from _clearMaterialActions) drops the POSITIVE
    # fallback for a reason the registrations cannot claim: a FILE entry CAN be withdrawn, and
    # on tier 0/1 the clear path withdraws exactly these, here and now. Only the registrations
    # are stuck until the restart. Dropping them also settles the suppressor question by
    # itself — with %fallback empty the gate below collapses to $REGISTERED_N, which is the
    # right answer on this path: what is still live is what REGISTERED, and only that needs
    # holding off our own rows.
    my %fallback      = ($departing || $prefOff) ? () : %UNREGISTERED;
    # Whether the API half ran AT ALL, for the diagnostics below — the same question
    # _writeMaterialActions asks, and asked the same way, so the two dumps cannot disagree.
    # NOT implied by the tier: this sub is reached with the pref off at STARTUP, where the tier
    # is 2 and registration has never run. Hardcoding it to 1 there made the dump answer
    # "plugin API", "streaming Add active" and "registered sections = ..." two lines under
    # "material_action pref = OFF" — with %UNREGISTERED empty because nothing was ever refused,
    # _deliveredCounts has no way to tell "delivered everything" from "never asked", so it must
    # not be consulted at all on that path. Same failure class as the %fallback substitution
    # above it; this was the copy that kept it.
    my $api           = $REGISTERED ? 1 : 0;
    my @radioCats     = _radioSuppressorCats();
    my @suppressors   = ( _ownSurfaceSuppressorCats(), @radioCats );
    my %emptyFallback = (!$departing && ($REGISTERED_N || %fallback))
        ? ( map { $_ => 1 } grep { !$REGISTERED_EMPTY{$_} } @suppressors )
        : ();

    # The steady state on a box whose actions.json only ever held ours: the file is gone, so
    # there is nothing to prune and this costs one stat() per startup. It is NOT an
    # unconditional early return — a registration that failed has to reach the user through the
    # file even when the file has to be created to do it, which is the same reasoning
    # _clearMaterialActions uses for re-creating a file that has gone missing.
    # The diagnostics still run: this is the state a "where did Add go" report is most likely
    # to be made from, so it must not be the one state the dump cannot describe.
    if (!-e $file && !%fallback && !%emptyFallback) {
        my ($positive) = _materialActionSet(2);
        my %regCount = $api ? _deliveredCounts($positive) : ();
        _dumpMaterialState($file, {}, \@radioCats, \%regCount, $api, 2)
            if $prefs->get('debug_log');
        return;
    }

    my $data = _readMaterialActions($file);

    # Strip our entries from every category. %emptied records the ones this took from non-empty
    # to empty — provenance, exactly as on the write path: an empty that ARRIVED empty was never
    # ours to judge.
    my %emptied;
    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY';
        my $had = scalar @{ $data->{$cat} };
        $data->{$cat} = [ grep { !_isOurAction($_) } @{ $data->{$cat} } ];
        $emptied{$cat} = 1 if $had && !@{ $data->{$cat} };
    }

    # Every category name this plugin has ever asserted, at any tier: the positive set, the
    # file-only set, both suppressor families, the pre-rebrand spellings, and whatever the
    # ownership ledger recorded. Taken from _materialActionSet at tier 0, which is the tier that
    # returns the WIDEST set — the tier we are actually on folds them together, and a prune that
    # only knew about the folded set could not remove what an older build wrote.
    my ($legacyPositive, $legacyFileOnly) = _materialActionSet(0);
    my %owned = %{ _ownedCats() };
    my %ours = map { $_ => 1 }
        keys %$legacyPositive, keys %$legacyFileOnly, @suppressors, keys %owned,
        qw(podcasts-album podcasts-track favorites-album favorites-track
           listentolater-album listentolater-track listentolater-artist
           LtLHome-album LtLHome-track LtLHome-artist);

    # Delete what is ours and now empty. Only-empty, so a category we vacated that someone else
    # also writes into keeps their entries; and never a suppressor Material did not take.
    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY' && !@{ $data->{$cat} };
        next if $emptyFallback{$cat} || $fallback{$cat};
        delete $data->{$cat} if $ours{$cat} || $emptied{$cat};
    }

    # Put back exactly what could not be delivered by registration. `||=` on the empties, for
    # the standing reason: the "<cmd>-*" namespace is not ours to reset, and any present
    # category — ours or theirs — overrides online-* and hides "Add" either way.
    for my $cat (keys %fallback) {
        push @{ $data->{$cat} ||= [] }, @{ $fallback{$cat} };
    }
    $data->{$_} ||= [] for keys %emptyFallback;

    my $record = { map { $_ => 1 } keys %fallback, keys %emptyFallback };

    # What the API half actually delivered, per category. NOT "built minus %fallback" — that is
    # the write path's formula and it only reads as "delivered" THERE, where %fallback IS
    # %UNREGISTERED. Here %fallback has been zeroed for a write-policy reason ($departing /
    # $prefOff), so the same expression counts every REFUSED entry as delivered.
    my ($positive) = _materialActionSet(2);
    my %regCount = $api ? _deliveredCounts($positive) : ();

    if (!keys %$data) {
        # Nothing of ours left and nothing of anyone else's. Remove the file rather than leave
        # an inert husk in a directory we do not own.
        unlink($file) or do {
            $log->error("LL: could not remove the now-empty $file: $!");
            return;
        };
        _setOwnedCats($record);
        $log->warn("LL: Material custom actions are fully registered — removed the now-empty $file");
        _dumpMaterialState($file, {}, \@radioCats, \%regCount, $api, 2) if $prefs->get('debug_log');
        return;
    }

    my $dir = File::Spec->catdir(Slim::Utils::Prefs::dir(), 'material-skin');
    File::Path::make_path($dir) unless -d $dir;
    _writeMaterialActionsFile($file, $data);
    # After the write lands, never before — see _ownedCats (0.1.105).
    _setOwnedCats($record);
    $log->warn('LL: Material custom actions are registered — pruned ours from ' . $file
        . (%$record ? ' (' . scalar(keys %$record) . ' section(s) kept as a file fallback)' : ''));
    _dumpMaterialState($file, $data, \@radioCats, \%regCount, $api, 2) if $prefs->get('debug_log');
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
# customactions.json — if the FILE half below is correct but the UI still lacks Add, it's a
# stale cached tab; hard-refresh Material once. See CLAUDE.md 0.1.57. On Material 6.4.6+ the
# "Add" entries no longer come from that file at all — they are fetched over the CLI, which
# is not browser-cached — so a stale tab only affects the suppressors and the podcasts
# wording. Which half of the wiring a category is on is the first line of the dump.)
sub _dumpMaterialState {
    my ($file, $data, $radioCats, $regCount, $api, $tier) = @_;
    $tier = _actionTier() unless defined $tier;

    # Accumulate every line so we can BOTH log it (server.log, tagged LL[dbg]) AND stash the
    # whole snapshot in a pref, which the Settings page renders in a copy-paste textarea — so
    # a remote user can hand over the diagnostics without touching server.log. Latest run wins.
    my @lines;
    my $emit = sub { my $m = shift; push @lines, $m; _dbg($m); };

    # Unknown version reads as "not confirmed" (the false case), exactly as before; a
    # dev/test build is assumed to carry the feature.
    my $ver = _materialVersion();
    my $online_ok = Plugins::ListenLater::Sources::materialAtLeast($ver, 6, 4, 4) ? 1 : 0;

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
    $emit->("actions.json = $file" . (-e $file ? '' : ' (ABSENT — nothing of ours is left in it)'));
    $emit->("delivery tier = $tier — "
        . ( $tier == 0 ? 'no registerCustomAction (Material < 6.4.6): the file carries everything'
          : $tier == 1 ? 'Material 6.4.6/6.4.7: the "Add" entries register, but the Now Playing '
                       . 'and queue surfaces, the podcasts override and every empty suppressor '
                       . 'still have to live in the file'
          :              'Material >= 6.4.8 (PR #1257): EVERYTHING registers, suppressors '
                       . 'included, and the file is pruned rather than written'));
    $emit->('registered empty suppressor sections = '
        . (%REGISTERED_EMPTY ? scalar(keys %REGISTERED_EMPTY) : 'none')) if $tier >= 2;
    $emit->('custom-action delivery = '
        . (!$api        ? 'actions.json (this Material has no registerCustomAction, or '
                        . 'registration has not run yet — either way the file carries everything)'
         : %$regCount   ? 'plugin API (Material 6.4.6+, registerCustomAction) — the "Add" entries are '
                        . 'served over ["material-skin","plugin-actions"], NOT from actions.json'
         :                'actions.json — registerCustomAction EXISTS but refused every entry, '
                        . 'so they were written to the file as a fallback (see server.log for why)'));

    # The Add entries must be present or NO streaming row shows Add anywhere. Count BOTH
    # halves and say which is which: reading only the file would report "WILL NOT SHOW" for a
    # perfectly working API install, and reading only the built set would report "active"
    # for entries registerCustomAction refused — the one failure this dump exists to expose.
    my $count = sub {
        my ($c) = @_;
        my $f = ref $data->{$c} eq 'ARRAY' ? scalar @{ $data->{$c} } : undef;
        my $a = $regCount->{$c};
        return (undef, undef) unless defined $f || defined $a;
        return ($f // 0, $a // 0);
    };
    my %total;
    for my $c (qw(online-album online-track)) {
        my ($f, $a) = $count->($c);
        my $n = defined $f ? $f + $a : -1;
        $total{$c} = $n;
        $emit->("category '$c' = " . ($n < 0 ? 'MISSING (!)' : "$n entr" . ($n == 1 ? 'y' : 'ies')
                . ($api ? " ($a registered, $f in actions.json)" : ''))
            . ($n > 0 ? ' — streaming Add active' : ' — streaming Add WILL NOT SHOW'));
    }
    if ($api) {
        $emit->(%$regCount
            ? 'registered sections = '
                . join(', ', map { "$_($regCount->{$_})" } sort keys %$regCount)
            : 'registered sections = NONE — registerCustomAction refused every entry; '
                . 'they were written to actions.json instead (see the counts above)');
    }

    # Radio browse commands we deliberately suppress Add on (empty <cmd>-album/-track).
    my @radios = sort keys %{ { map { my $c = $_; ($c =~ s/-(?:album|track)$//r) => 1 } @$radioCats } };
    $emit->("supported commands (Add kept) = " . join(', ', sort keys %SUPPORTED_CMD));
    $emit->("radio/unsupported commands suppressed (Add hidden on their browse rows) = "
        . (@radios ? join(', ', @radios) : '(none)'));

    # Any NON-empty per-command "<svc>-album/-track" category shadows online-* and hides
    # Add on that service. Ours are always empty (or, for 'podcasts-*', deliberately
    # POPULATED — it's what makes a podcast row say "Add to Listen Later" and route
    # kind:podcast); a populated one that ISN'T ours is foreign/leftover and is the thing to
    # look at if Add is missing on exactly one service.
    #
    # Exempt by FULL category name, read from the same source of truth the writers use —
    # never a hand-list of prefixes. Three of our own populated categories (album-track,
    # playlist-track, queue-track) are not "<svc>-<type>" shaped at all, so a prefix test
    # reads them as foreign and this diagnostic — which exists purely for remote triage —
    # reports our own entries as the fault (0.1.101). Taking the names from
    # _materialActionSet/_radioSuppressorCats also self-corrects the next time the
    # register/file split moves.
    # Tier 0 deliberately, not the running tier: it returns the WIDEST split (nothing folded),
    # so every category name this plugin can assert on ANY tier is exempted — on tier 2 the
    # folded set would still cover them, but taking the wide one means the exemption can never
    # narrow as the register/file split moves again.
    my ($posCats, $fileCats) = _materialActionSet(0);
    my %ours = map { $_ => 1 } keys %$posCats, keys %$fileCats, @$radioCats;
    my @shadow;
    for my $cat (sort keys %$data) {
        next unless $cat =~ /-(?:album|track)$/;
        next if $ours{$cat} || $cat =~ /^(?:listenlater|LLHome)-/;
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
    my $online_pop = $total{'online-album'} > 0;
    for my $menu (['apps', 'appss_loop'], ['radios', 'radioss_loop']) {
        my $loop = eval {
            my $req = Slim::Control::Request::executeRequest(undef, [$menu->[0], 0, 500]);
            $req ? ($req->getResult($menu->[1]) || []) : [];
        } || [];
        for my $a (@$loop) {
            my $cmd = $a->{cmd} or next;
            next if $seen{$cmd}++;
            my $name = $a->{name} // $cmd;
            # A per-command category decides this service on its own: populated it shows its
            # own entries, empty it hides Add entirely; otherwise the generic online-*. It
            # counts from EITHER half — Material's override test reads both lists
            # (`(appCat in customActions) || (appCat in pluginCustomActions)`, browse-resp.js)
            # — so this asks the file AND the registrations. Reading only the file was right
            # until 6.4.8 and is wrong on tier 2, where our own 'listenlater-*'/'LLHome-*' and
            # the podcasts override are REGISTERED and the file is pruned: the file-only test
            # reported "Add shown (via online-*)" for the very rows we suppress, in the one
            # dump a "where did Add go" report is made from.
            #
            # Evidence, never intent: what the file HAS, what Material TOOK. The old
            # @$radioCats fall-back said "we mean to suppress this", which reads the same in
            # the healthy case and lies in the one case worth reporting — a suppressor that
            # reached neither half. Those now show as online-* and that is the truth.
            my $filePop = ref $data->{"$cmd-album"} eq 'ARRAY' && @{ $data->{"$cmd-album"} };
            my $fileCat = exists $data->{"$cmd-album"};
            my $regPop  = ($regCount->{"$cmd-album"} // 0) > 0;
            my $regCat  = $REGISTERED_EMPTY{"$cmd-album"} ? 1 : 0;
            my $verdict = !$online_ok ? 'no Add (Material < 6.4.4)'
                        : $filePop    ? "Add shown (via its own '$cmd-album' in actions.json)"
                        : $regPop     ? "Add shown (via its own registered '$cmd-album' section)"
                        : $fileCat    ? "Add HIDDEN (empty '$cmd-album' in actions.json)"
                        : $regCat     ? "Add HIDDEN (registered empty '$cmd-album' section)"
                        : $online_pop ? 'Add shown (via online-*)'
                        :               'no Add (online-* empty)';
            $emit->("service '$cmd' ($name) [$menu->[0]]: $verdict");
        }
    }
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
    # NO TITLE FALLBACK. There used to be one — match our four titles when the entry carried no
    # `lmscommand` at all — on the theory that it caught entries an old build wrote in some other
    # shape. It cannot have: EVERY version of `_materialActionSet` back to the 0.1.25 rebrand
    # builds every action with an `lmscommand`, checked across the twelve commits that touched
    # it. So the branch was unreachable for anything LL wrote and could only ever match a THIRD
    # PARTY's entry — a `script`/`command`/`weblink` action someone titled "Add to Listen Later"
    # would be silently deleted from a shared file on every startup. Removed in 0.1.110, when the
    # tier-2 prune made this the sub that decides what LL takes OUT of a file it does not own.
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
    my ($request, $source, $album, $reason) = @_;

    # `// '?'` was not enough, and since 0.1.96 that is the COMMON case rather than an edge:
    # `svc` is believed only when it NAMES a service, so every container verb that isn't one
    # (favorites, search, bbcsounds, a home-shelf id) leaves $source an EMPTY STRING — which
    # is defined, so the line read "unsupported source ''" and named nothing whatsoever. This
    # warn is the ONLY trace a rejected add leaves (the reject is silent to the user by
    # necessity, see above), so it has to say what arrived: the container verb is what
    # identifies the surface, and it is the thing to look at when an add "does nothing".
    my $svc = $request->getParam('svc');
    $svc = undef if defined $svc && $svc =~ /^\$[A-Z]/;   # an unsubstituted Material $VAR

    # ...and for the same reason it has to name the clause that ACTUALLY failed. Most of the
    # gates test more than the source — a track add also needs a play url and a title, an
    # episode needs an enclosure — and reporting every one of those as "unsupported source
    # 'qobuz'" sends triage after the service when the real cause was an empty title. A call
    # site that knows which clause it failed passes it; the rest keep the source clause,
    # which stays the common case and the wording older logs use.
    my $src = (defined $source && length $source) ? "'$source'" : '(none identified)';
    $log->warn('LL: rejected add — '
        . ((defined $reason && length $reason) ? "$reason (source $src)"
                                               : "unsupported source $src")
        . ((defined $svc    && length $svc)    ? " via container '$svc'" : '')
        . ' (' . ((defined $album && length $album) ? $album : '?') . ')');
    $request->addResult('count', 0);
    $request->setStatusDone;
    return;
}

# Track-save: build a kind='track' record from resolved fields and store it. The play url
# + source are worked out from the given url (a streaming scheme names its own source), a
# track id (library, or a NEGATIVE remote one — see below), or — for a Material Now Playing
# add that carries neither — the
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
    elsif (defined $trackId && $trackId =~ /^-?\d+$/) {
        # A track id — take the canonical url + metadata from the object.
        #
        # A NEGATIVE id is not junk: it is LMS's own spelling of a REMOTE track. `Slim::Schema
        # ::find` tests `$_[0] < 0` and routes it to `Slim::Schema::RemoteTrack->fetchById`
        # (verified in the 9.1 source), and the ids the status query serves for a streaming
        # queue row are exactly those (verified live: `qobuz://420282127.flac` sits at
        # id=-94606967849352). Material builds a queue row's id as "track_id:"+i.id and
        # substitutes it into $TRACKID, while those rows carry NO presetParams at all — so on
        # a remote queue row the id is the only identity that arrives, and refusing it here is
        # what made every one of them unaddable. Resolve it; don't relax the gate below.
        my $t = eval { Slim::Schema->find('Track', $trackId) };
        my $turl = $t ? eval { $t->url } : undef;
        if ($t && defined $turl && length $turl) {
            # NOT hardcoded 'library' — a remote row's url names its own service, and storing
            # a qobuz:// url under source 'library' would give a row that can never replay.
            # Same file://-is-local rule as the scheme branch above: sourceFromUrl only
            # answers 'library' for a url with NO scheme, and a library track's url has one.
            my $tscheme = ($turl =~ m|^(\w+)://|) ? lc $1 : '';
            $source  = (!$tscheme || $tscheme eq 'file') ? 'library'
                     : Plugins::ListenLater::Sources::sourceFromUrl($turl);
            $url     = $turl;
            # NOT `//`. A RemoteTrack answers '' — not undef — for metadata it doesn't hold
            # (confirmed live on a qobuz:// track: ->artistName and ->albumname are both '',
            # which is why _nowPlayingFallback has to fail open on it). '' is defined, so `//`
            # KEEPS it and wipes the good title/artist Material substituted from the row. On
            # the artist that stores artist='', which then skips BOTH dedupe guards in
            # _insertTrackRow (they test `length $artist`), never matches in
            # Played::_matchRecord and renders with no artist; on the title it fails the add
            # gate below outright — the very case resolving a negative id was added to fix.
            # Take the object's value only when it HAS one (same rule as the $album lines).
            my $ttitle  = eval { $t->title };
            my $tartist = eval { $t->artistName };
            $track   = $ttitle  if defined $ttitle  && length $ttitle;
            $artist  = $tartist if defined $tartist && length $tartist;
            # A library Track's ->album is the Album ROW. A RemoteTrack's is UNDEF — NOT the
            # album name, which is what this comment used to claim. Verified against
            # Slim/Schema/RemoteTrack.pm (9.1) 2026-08-27: `album` and `albumname` are two
            # INDEPENDENT rw accessors (both in @allAttributes), and setAttributes rewrites
            # every incoming key through %localTagMapping, which maps `album => 'albumname'`
            # — so the `album` slot is declared and then never written by anything. There is
            # no `sub album`, init_accessor doesn't set it, and the base (Slim::Utils::Accessor)
            # has no AUTOLOAD. The album STRING lives only in ->albumname.
            # So `ref $alb` is the right test for "library row vs remote", and it stays — it
            # just separates a row from UNDEF rather than from a string.
            my $alb  = eval { $t->album };
            if (ref $alb) {
                $album   = (eval { $alb->title }) // $album;
                $year  ||= (eval { $alb->year })  || undef;
                $artwork = (eval { $alb && $alb->artwork ? 'music/' . $alb->artwork . '/cover' : undef }) // $artwork;
            }
            else {
                # Keep what the row sent (Material populates $ALBUMNAME on queue rows); fall
                # back to the track object only for what it didn't.
                #
                # The `//` here is deliberate and is NOT the bug it reads as — settled
                # 2026-08-27, don't re-raise it. The neighbouring lines use `defined &&
                # length` because a bare RemoteTrack answers '' and that '' would overwrite
                # a GOOD value Material sent. Neither hazard exists on this line: the
                # statement modifier means it only runs when $album is ALREADY undef or '',
                # so the value `//` could wrongly keep ('') is identical to the fallback it
                # would keep it from. The `// $alb` term was dropped with the same finding —
                # $alb is undef on every path that reaches this branch (see above), so it
                # could never contribute.
                $album = (eval { $t->albumname }) // $album
                    unless defined $album && length $album;
                $year ||= (eval { $t->year }) || undef;
            }
        }
    }
    elsif ($scheme eq 'file') {
        $source = 'library';
    }

    # Now Playing track add (Material's `track` category): no favurl, no track id — recover
    # the play url straight from the currently-playing song on this client.
    #
    # THE GATE IS WHAT MAKES THIS SAFE, because _nowPlayingTrackFallback deliberately has no
    # match guard of its own (a Now Playing track add IS the playing track, and a streaming
    # Track exposes no metadata to match against anyway). So the caller has to establish that
    # this really came from the Now Playing panel and not from a tapped ROW. Two conditions,
    # beyond the empty play url:
    #
    #   * NO container command. `svc` names the menu the row was browsed in; the Now Playing
    #     action ($trackCmd) carries no `svc:` param at all, so a populated one means a browse
    #     row. This is the same test the album path makes, for the same reason — but here it
    #     is NOT sufficient on its own, because `queue-track` uses the very same $trackCmd
    #     and therefore also arrives with no svc.
    #   * NO track id. That is what separates the queue from Now Playing: Material substitutes
    #     the tapped item's own values, and any real row carries an id, while the Now Playing
    #     panel item has neither id nor favurl to substitute (0.1.64). Testing PRESENCE, not
    #     validity, is deliberate — the id branch above resolves EITHER sign (a library id and
    #     a remote one both name a real track), so if we are still here with an id it named
    #     nothing this server could resolve, and adopting the playing song for it is exactly
    #     the bug: the user taps queue row 7 while row 1 plays and gets row 1's title and play
    #     url stored under row 7's album and artist. An unresolvable id is rejected instead.
    if ((!defined $url || !length $url)
        && !(defined $f{svc}     && length $f{svc})
        && !(defined $trackId    && length $trackId)
        && $request->client) {
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

    # Three separate ways to fail one `unless`, so say which — an add that arrived with a
    # perfectly good source and an empty title used to log "unsupported source 'qobuz'".
    if (!_isReplayableSource($source) || !(defined $url && length $url)
                                      || !(defined $track && length $track)) {
        return _rejectAdd($request, $source, $track,
            !_isReplayableSource($source)   ? undef                # the default source clause
          : !(defined $url && length $url)  ? 'no play url'
          :                                   'no track title');
    }

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
        return _rejectAdd($request, $rejectSource, undef, 'no episode title');
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
    # The tested source is 'podcast', NOT $rejectSource (which is the container the row came
    # in under) — so say so, or the line blames whatever menu was open for a server with no
    # podcast:// handler.
    return _rejectAdd($request, $rejectSource, $title, 'no podcast:// handler on this server')
        unless _isReplayableSource('podcast');

    # A show/section row (not an episode) resolves to nothing and is rejected below. The
    # per-command category can't be scoped to episodes only: Material's per-action filter
    # keys on the favurl, and these rows have none.
    $request->setStatusProcessing;

    my $done = 0;
    my $finish = sub {
        my ($ep) = @_;
        return if $done; $done = 1;

        # NOT a source problem: the row came in under whatever container it was browsed in
        # (usually 'favorites'), and what failed is that no subscribed feed yielded an
        # enclosure for it — either a show/section row rather than an episode, or a feed
        # that didn't resolve. Naming the source here is what sent triage the wrong way.
        return _rejectAdd($request, $rejectSource, $title,
            'no podcast episode resolved from the subscribed feeds') unless $ep && $ep->{url};

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

# Insert a streaming PLAYLIST row (kind='playlist'). Flat and synchronous, modelled on
# _insertTrackRow: everything needed is already on the row Material sent — the service and
# the playlist id came from Sources::playlistFromRow — so there is no service round trip and
# nothing to classify.
#
# It deliberately does NOT go through _finishAlbumAdd. That tail runs the cross-kind single
# dedupe, _verifyRelease and _backfillStreamingArtist, all three of which are RELEASE
# semantics: routing a playlist through it is precisely how one would acquire a bogus
# rel_type or track_count and start reading as an album.
sub _savePlaylistRecord {
    my ($request, $list, $p, $source, $playlistId) = @_;

    # Taken VERBATIM — no "(YYYY)"/format-qualifier stripping (see the caller).
    my $title = $p->{name};
    unless (defined $title && length $title) {
        return _rejectAdd($request, $source, undef, 'no playlist title');
    }

    # The same "don't store what we can't replay" gate every other add path runs, asked of
    # the PLAYLIST call: a service whose plugin isn't installed (or has no playlist call)
    # would give a row that only fails at play time.
    unless (_isReplayableSource($source)
            && Plugins::ListenLater::Sources::_serviceCanPlaylist($source)) {
        return _rejectAdd($request, $source, $title, 'service has no playlist call');
    }

    # The Wish List is for things you might BUY, which a curated playlist never is — the
    # same rule, and the same reason, as a podcast episode (_savePodcastEpisode).
    if ($list eq 'wishlist') {
        $log->warn('LL: playlist sent to the Wish List — saving to Listen Later instead');
        $list = 'later';
    }

    # No rel_type and no track_count, ever: a playlist is not a release, and a curated one
    # changes under you. Leaving both NULL is also what keeps it out of Played (every Played
    # lookup is filtered to kind='album'/'track'). The artist segment carries the curator
    # line when the row supplied one — it is display only, never part of the dedupe key.
    my $rec = {
        kind        => 'playlist',
        source      => $source,
        artist      => $p->{artist},
        album_title => $title,
        rel_type    => undef,
        track_count => undef,
        year        => undef,
        artwork     => $p->{image},
        ref_kind    => 'playlist_id',
        # NEVER an album_id: findBySourceAlbumId is the one finder with no kind filter and
        # it keys on ref.album_id, so an album_id here would let a playing track mark a
        # playlist as Played.
        ref         => { _svc => $source, playlist_id => $playlistId },
    };

    my ($id, $already, $existingSource) = eval { Plugins::ListenLater::DB::add($rec, $list) };
    if ($@) { $log->error("LL: playlist add failed: $@"); }
    else {
        $log->warn("LL: playlist add -> $source / $title (id=" . ($id // '?')
            . ", playlist_id=" . ($playlistId // '?')
            . ", already=" . ($already // 0) . ", list=$list)");
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
# add from Now Playing is unambiguously *this* playing track, and a streaming Track exposes
# no title/album to match against in any case (Qobuz/Tidal serve that dynamically). **That
# makes the CALLER'S gate the only protection — see _saveTrackRecord: it must establish that
# no container command and no track id arrived, or a tapped queue row adopts whatever happens
# to be playing.** Prefers a non-http url so the scheme still names the service; fills
# streaming album/artist/cover from the handler meta.
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
        # A playlist is never a Wish List item (you don't buy one) — the add path already
        # redirects "Add to Wish List" on a playlist to Listen Later, so don't offer the
        # move that would undo that.
        next if $target eq 'wishlist' && ($rec && ($rec->{kind} || '') eq 'playlist');
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

    # An unpopulated Material $VAR arrives EMPTY for every name in doReplacements'
    # ACTION_KEYS list, but as the LITERAL token for one that isn't in it — $IMAGE, the
    # only such var we send. Map the literal to undef so both spellings read as absent.
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

    # Spotify hands Material a bare Spotify URI ('spotify:album:<id>') where every other
    # service sends a scheme url, and this plugin reads a favurl as a scheme url in four
    # separate places — $favScheme below, and Sources' sourceFromUrl / favurlIsTrack /
    # playlistFromRow. Normalising it to 'spotify://album:<id>' HERE, at the one point a
    # favurl enters, means all four keep working unchanged instead of each growing a
    # Spotify case; see Sources::normaliseFavurl for the full reasoning.
    #
    # Deliberately AFTER the strip, not before: _stripPrivateParams answers a different
    # question (what did a sibling plugin pack into the query string) and should keep
    # seeing exactly what the service sent. Running second also means the addctx log line
    # just below prints the url the rest of this sub will actually work from. Every other
    # service's favurl is returned byte-for-byte unchanged.
    $p{favurl} = Plugins::ListenLater::Sources::normaliseFavurl($p{favurl});

    my $list = _wantedList($request->getParam('list'));

    $log->warn('LL: addctx params -> '
        . join(', ', map { "$_=" . (defined $p{$_} ? $p{$_} : '(undef)') } qw(name artist albumid year trackname trackid favurl image svc)));

    # Never add from one of OUR OWN surfaces. Every row there is already in the list, and
    # re-adding one bounces a Played album back to Listen Later — which is precisely what the
    # empty 'listenlater-*'/'LLHome-*' suppressor categories exist to prevent. But a written
    # category is not a gate: Material serves customactions.json from cache, so there is a
    # post-upgrade window where the old file is still in force (the documented 0.1.57
    # window), and the add COMMAND is this plugin's one reliable gate everywhere else.
    #
    # It used to be gated here too, by accident: the old `^[a-z0-9]+$` shape test made
    # svc='LLHome' the $source, and an unreplayable source was rejected two screens down.
    # knownSource (rightly, 0.1.96) leaves a non-service command EMPTY so the cover-URL sniff
    # can identify a home-shelf row — but OUR cards carry the original streaming cover, so
    # that sniff now answers 'qobuz' for a row we saved from Qobuz and the re-add succeeds.
    # Name the surfaces explicitly rather than leaning on a side effect of how svc is judged.
    #
    # Ahead of every branch below, including kind:podcast: a podcast episode in our own list
    # is no more re-addable than an album.
    if (Plugins::ListenLater::Sources::ownSurface($p{svc})) {
        return _rejectAdd($request, '', $p{name}, 'row is already in Listen Later');
    }

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
    my $favTrack      = Plugins::ListenLater::Sources::favurlIsTrack($p{favurl});

    # A streaming-service PLAYLIST (Tidal/Deezer 'playlist:' favurl, or a Qobuz editorial
    # playlist identified by its cover URL — Sources::playlistFromRow). Stored as a
    # first-class kind='playlist' row that replays through the service's own playlist call.
    #
    # Position is load-bearing at BOTH ends:
    #  • AFTER the two track tests, never before them. The Qobuz half of the detector reads
    #    the IMAGE, and a track row browsed inside a playlist can carry that playlist's
    #    cover — so testing the image first would turn a perfectly good track add into a
    #    playlist. A track-shaped favurl always wins.
    #  • BEFORE the album path below, which strips a trailing "(YYYY)" and format qualifiers
    #    off the title. A playlist called "Best of (2016)" is called exactly that; its title
    #    is stored verbatim.
    if (!$explicitTrack && !$favTrack) {
        my ($plSource, $plId) = Plugins::ListenLater::Sources::playlistFromRow($p{favurl}, $p{image});
        return _savePlaylistRecord($request, $list, \%p, $plSource, $plId) if $plSource;
    }

    if ($explicitTrack || $favTrack) {
        my $trackTitle = $p{trackname} // $p{name};
        # Only a real track-context command ($TRACKNAME present) means $ALBUMNAME is the
        # parent album; for a favurl-redirected online row `name` is the TRACK title, so the
        # parent album is unknown → leave it to the '&al=' handshake (usually undef).
        my $album = defined $p{trackname} ? ($favAlbum // $p{name}) : $favAlbum;
        return _saveTrackRecord($request, $list,
            # `svc` is only trusted when it NAMES a service (Sources::sourceFromSvc) —
            # Material's $SERVICE is the browse command, which on a home shelf is the shelf
            # id, and for Spotify is 'spotty' rather than the service's own name. Masked on
            # this path today (a track row's favurl names its own source below), but the hole
            # is identical, so it's closed in both places.
            source  => Plugins::ListenLater::Sources::sourceFromSvc($p{svc}),
            # The RAW svc as well as the source it yielded: _saveTrackRecord's now-playing
            # fallback needs to know whether a container command arrived AT ALL, and a
            # non-service one (favorites, a home-shelf id) leaves `source` empty.
            svc     => $p{svc},
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
        # playlist row: a hyphenated svc + a plugin-PNG image), so leave $source empty and
        # let the reject gate below refuse it, rather than guessing 'qobuz' and storing an
        # unplayable row.
        #
        # `svc` must NAME a service to be believed (Sources::sourceFromSvc), not merely LOOK like
        # one. Material's $SERVICE is the browse COMMAND, and on a home shelf that command is
        # the home-extra id — so the stock Qobuz plugin's own "Qobuz" shelf sends
        # svc='QobuzExtrasqobuz' for exactly the rows the Apps menu sends svc='qobuz' for.
        # The old shape test (`^[a-z0-9]+$`) accepted that, which made $svc truthy and
        # short-circuited the `||` — so the cover sniff below, which had the right answer
        # sitting in a static.qobuz.com URL, was never consulted and the add was rejected.
        # (Its hyphenated sibling shelves — QobuzExtrasnew-releases-full etc. — failed the
        # shape test and therefore worked, which is why this went unreported for so long.)
        my $svc = Plugins::ListenLater::Sources::sourceFromSvc($p{svc});
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
    #
    # It also requires that NO container command arrived. `svc` names the menu the row was
    # browsed in, and the Now Playing action ($trackCmd) does not carry a `svc:` param at
    # all — so a populated one means this add came from a browse ROW, not the Now Playing
    # panel, and the playing track is unrelated by construction. That test used to be
    # implicit in `$source`: before 0.1.96 a shape-passing svc ('favorites', 'search',
    # 'bbcsounds', a home-shelf id) BECAME the source and closed this gate. knownSource
    # (rightly) leaves those empty, which would open it — and _nowPlayingFallback FAILS
    # OPEN when the playing track exposes no album/artist to match against, which is the
    # normal case for a streaming track. A podcast episode added from Favourites while a
    # Qobuz track played would then be stored as a qobuz album (unplayable), and the
    # last-resort podcast resolve below — the whole point of 0.1.85 — would never run.
    if (!length($source // '') && !(defined $p{svc} && length $p{svc}) && $request->client) {
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

    # Reject a source we can't replay (radio, BBC Sounds, anything unadapted): don't store a record that
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

    # Tidal/Deezer/Spotify browse rows can send no $ARTISTNAME (Material doesn't map their
    # subtitle) and their cover URL has no artist/id — but the favurl gives the album id, so
    # fetch the artist in the background. Without it the row never auto-moves to
    # Played (keys on source+artist+album). Fire-and-forget; only for a fresh artist-less add.
    if ($id && !$already && ($source eq 'tidal' || $source eq 'deezer' || $source eq 'spotify')
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
# both do this, and Spotify can too** — but the favurl carries the album id, so we fetch the album's tracks
# (getAlbum → albumTracks → each rendered track's line2 = artist name) and update the
# record. Without an artist the row shows album-only and never auto-moves to Played
# (Played keys on source+artist+album). Both plugins' getAlbum share the same shape
# ($client,$cb,$args,{id=>…} → {items=>…}), so one helper covers both. Async /
# best-effort; guarded so an API hiccup can never break the add.
sub _backfillStreamingArtist {
    my ($client, $recId, $albumId, $source) = @_;
    return unless $client && $recId && defined $albumId && length $albumId;

    # Spotify goes its own way, and NOT for want of trying to share the path below. Its
    # album node (Plugins::Spotty::OPML::album) does return the same {items=>…} tracklist
    # shape, so it would slot into $getAlbum cleanly — but the artist is then read off the
    # first track's line2, and Spotty builds that as "Artist \x{2022} Album" (OPML.pm:1170),
    # not the bare artist name Tidal and Deezer put there. We'd be storing "Artist • Album"
    # as the artist, and Played matches on it.
    #
    # Asking the API directly is both simpler and exact: the normalized album object carries
    # a plain `artist` string (its cache fills it from artists[0] — API/Cache.pm normalize),
    # so there is no string surgery and nothing to get subtly wrong. Same call
    # Sources::classifyRelType makes; it only ever runs on a row that arrived artist-less.
    if ($source eq 'spotify' && Plugins::Spotty::Plugin->can('getAPIHandler')) {
        my $api = eval { Plugins::Spotty::Plugin->getAPIHandler($client) };
        return unless $api && $api->can('album');
        eval {
            $api->album(sub {
                my $album = shift;
                return unless ref $album eq 'HASH';
                # Shared with _searchService's Spotify branch — see Sources::spottyArtistName
                # for the two shapes and why this is NOT the Tidal/Deezer extraction.
                my $artist = Plugins::ListenLater::Sources::spottyArtistName($album);
                return unless length $artist;
                Plugins::ListenLater::DB::updateArtist($recId, $artist);
                $log->info("LL: backfilled spotify artist '$artist' onto rec $recId");
            }, { uri => "spotify:album:$albumId" });
            1;
        } or $log->warn("LL: spotify artist backfill failed: $@");
        return;
    }

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

    # THE UNINSTALL HOOK. Our "Add" entries live in Material's SHARED
    # prefs/material-skin/actions.json — a file we write but do not own — so removing the
    # plugin does not remove them. Before this, an uninstall stranded them in every Material
    # menu for ever, with nothing of ours left running to take them out, and the only remedy
    # was hand-editing JSON.
    #
    # Slim::Utils::PluginManager sets plugin.state to 'needs-uninstall'/'needs-disable' the
    # moment the user clicks Apply, and performs the removal at the NEXT start (its init
    # dispatches the needs-* states; _needsUninstall then rmtree's our directory). It calls
    # shutdownPlugin on every loaded module on the way down — so this is the last moment we
    # are loaded, our state pref already says we are going, and the file is still ours to
    # tidy. Keyed on __PACKAGE__ because that is exactly what plugin.state is keyed on.
    #
    # Deliberately NOT gated on the material_action pref: the user may have turned it off
    # long ago, and the entries written while it was on still need removing. $departing
    # forces the full clean (see _clearMaterialActions).
    my $state = eval { preferences('plugin.state')->get(__PACKAGE__) } || '';
    if ($state eq 'needs-uninstall' || $state eq 'needs-disable') {
        $log->warn("LL: $state — clearing our Material custom actions before we go");
        eval { _clearMaterialActions(1); 1 }
            or $log->error("LL: uninstall cleanup of Material actions failed: $@");
        # Forget the category ledger too, so a later reinstall starts from a clean sheet
        # rather than inheriting a record of categories that are no longer in the file.
        eval { $prefs->set('material_owned_cats', []); 1 };
    }
    return;
}

sub getDisplayName { 'PLUGIN_LL' }

sub playerMenu { undef }

1;
