# Listen Later — LMS Plugin

## Project Overview
A plugin for Lyrion Music Server (LMS) that lets you save an album — from the local library or any streaming service (Qobuz, Bandcamp, Tidal, Deezer) — into a curated **Listen Later** list, browse it like a playlist *of albums*, and have albums move to a **Played** section once most of the album has been heard. A separate **Wish List** wishlist (0.1.22) sits alongside, and albums can be moved freely between the three lists. It also adds a **Material home-page shelf** for the list. Targets LMS v9.x, Material Skin preferred (classic best-effort). Storage is a plugin-owned SQLite database so the list is sortable, deduped, history-bearing, and ready for future features.

## Server Details
- **LMS Server**: 192.168.1.234:9000
- **OS**: DietPi (Debian Bookworm)
- **Service**: `lyrionmusicserver`
- **Plugin location (manual install)**: `/var/lib/squeezeboxserver/Plugins/ListenLater/`
- **Log**: `/var/log/squeezeboxserver/server.log`
- **Plugin DB**: `<server cachedir>/listenlater.db`

## Testing the live server WITHOUT SSH (important)
SSH to the box prompts for a password from this environment and is not reliable. Use **HTTP** instead (same channel the ListenBrainz project uses):
- **Log**: `curl -s http://192.168.1.234:9000/log.txt`
- **JSON-RPC**: `POST http://192.168.1.234:9000/jsonrpc.js`, body `{"id":1,"method":"slim.request","params":["<playerMAC>",[<cmd>...]]}`. Menu/feed queries **need a real player MAC** as the first param — an empty string returns instant HTTP 000 (not a hang). Known player: `dc:a6:32:77:ea:e0`.
- Handy probes:
  - feed: `["<mac>",["listenlater","items","0","10"]]`
  - context menus: `["<mac>",["trackinfo","items","0","100","track_id:<id>","menu:1"]]`, `[…,"albuminfo",…,"album_id:<id>","menu:1"]`
  - exists: `["","can","listenlater","items","?"]` (bogus tag → `_can:0`, so it's a genuine signal)
  - apps list: `["","apps","0","100"]`; plugin state: `["","pref","plugin.state:ListenLater","?"]`
- INFO logs from a plugin only appear in `log.txt` if its category is at INFO; while debugging, log at **WARN** to guarantee visibility.

Installing still needs filesystem access (the user runs the unzip+chown+restart); all verification is done over HTTP afterwards.

## Install Commands
```bash
sudo rm -rf /var/lib/squeezeboxserver/Plugins/ListenLater
sudo unzip -o ListenLater.zip -d /var/lib/squeezeboxserver/Plugins/
sudo chown -R squeezeboxserver:nogroup /var/lib/squeezeboxserver/Plugins/ListenLater
sudo systemctl restart lyrionmusicserver
```
File ownership must be `squeezeboxserver:nogroup` (DietPi), and the zip must extract directly as `ListenLater/` (no extra `Plugins/` wrapper).

## File Structure
```
ListenLater/
├── Plugin.pm     # OPMLBased init; registers TrackInfo + AlbumInfo "Add" providers; opens DB; starts play-detector
├── Browse.pm     # top-level (Listen Later / Wish List / Played / Settings); album rows; per-album submenu (Play / Move to … / Remove)
├── DB.pm         # SQLite (DBI/DBD::SQLite) connect + migrate + CRUD; dedupe by normalised source|artist|album
├── HomeExtras.pm # Material home-page shelf (HomeExtraBase subclass LLHome -> Browse::homeShelf)
├── Sources.pm    # per-source adapters: capture a record from a track/album, rebuild a playable node, match helpers
├── Played.pm     # subscribes to playlist newsong/stop/clear; threshold logic to auto-move albums to Played
├── Settings.pm   # default sort, played threshold %, streaming track count, auto-Played toggle
├── install.xml   # <extension> singular; <icon> = …Icon_svg.png; <optionsURL>; <homepageURL>
├── strings.txt   # PLUGIN_LL_* strings (EN)
└── HTML/EN/plugins/ListenLater/{settings.html, html/images/*Icon*.svg|_svg.png|.png}
```
Section/app icons (see "Icon system"): `ListenLaterIcon.{svg,_svg.png,.png}` (app icon + Listen Later section, the music-note+clock design), `PlayedIcon.{svg,_svg.png,.png}` (Google `music_history`, recoloured), `WishListIcon_MTL_icon_shopping_cart.png` (Material font trolley, single PNG fallback).

## Key Technical Decisions
- **Base class**: `Slim::Plugin::OPMLBased`, `is_app => 1` (Apps section), `menu => 'radios'`. Feed is `Browse::topLevel`.
- **Add path**: there is **no global hook** into every streaming plugin's own album "…" menu. The universal path is `Slim::Menu::TrackInfo->registerInfoProvider` (fires for local **and** remote tracks); `Slim::Menu::AlbumInfo` adds a direct entry for library albums. Both return an OPML drill item (`type=>'link'`, `url=>coderef`) that performs the add and shows a brief confirmation — renders in Material and classic. Custom providers are confirmed to show in `trackinfo`/`albuminfo menu:1` (alongside "Save to Favourites", "On Qobuz").
- **Register defensively**: `require Slim::Menu::TrackInfo`/`AlbumInfo` and wrap each `registerInfoProvider` in `eval` — an unguarded call dies and aborts the whole plugin if the module isn't loaded yet.
- **Storage**: SQLite over prefs (prefs give no query/sort/dedupe). One `albums` table; display metadata denormalised so the list renders without re-hitting any service; `ref_json` carries only what's needed to replay (album_id / passthrough / `_svc`). `UNIQUE(source, dedupe_key)` prevents duplicate adds; re-adding an album already saved in **any** section is a no-op (0.1.21) — it is not moved. `status` is `later` | `played` | `wishlist`; `add($rec,$status)` sets the target list for a new album (`later` default, or `wishlist`).
- **Replay**: library → load album tracks by `album.id`. Streaming → if a native album id was captured, rebuild the service's own album node (reattach `Qobuz…QobuzGetTracks` / `Bandcamp…get_album`, the same coderef round-trip the sibling uses); otherwise **search the originating service** by "artist album" and keep the title+artist match (resilient — no hard dependence on capturing the album id).
- **Played detection**: subscribe to `[['playlist'],['newsong','stop','clear']]`; per player, count distinct tracks of the currently-playing saved album. A release with a MEASURED length (library live count, or a stored streaming `track_count`) uses `Played::tracksNeeded` = `played_threshold`% of it, **rounded DOWN**, floored at 2 for a multi-track release (default 90 — see "The Played threshold"); only a release whose length can't be measured falls back to `streaming_min_tracks` distinct tracks (default 4, best-effort). Same path for inside- and outside-plugin plays; `watch_outside` is the master toggle.
- **Remote vs local detection gotcha**: trust `$track->remote`; do **not** treat a `file://` URL as remote (`$url =~ m|://|` matches `file://`). And `$remoteMeta` is **undef** for local tracks — dereferencing it under `use strict` dies and the menu wrapper swallows the error → no item appears. Always `$remoteMeta = {} unless ref $remoteMeta eq 'HASH'`.
- **install.xml**: `<extension>` singular (manual installs). `<icon>` → `…Icon_svg.png` (Material `_svg.png` convention loads the sibling `.svg` and recolours it; the SVG must use `#000`, not `#000000`). PNGs are real transparent RGBA (Pillow), not JPEGs misnamed `.png`.

## Icon system (0.1.24)
Three section icons, set in `Browse.pm` (`_iconFor($status)` → `_header`/`_albumRow`); the app icon (install.xml/home shelf) is `ListenLaterIcon`.
- **Two Material conventions, picked per icon** (authoritative rules mirrored from the sibling ListenBrainz plugin's "Icon System"):
  - **`_svg.png` recolour**: Material loads the sibling `.svg` and theme-recolours it (string-replaces the literal `#000` → theme colour, so the SVG MUST use `#000`, never `#000000`). Used by **Listen Later** (`ListenLaterIcon`, music-note+clock) and **Played** (`PlayedIcon`, Google `music_history`). Ship 3 files: `.svg` (source, `#000`), `_svg.png` (install.xml ref + non-Material fallback), `.png` (generic fallback).
  - **`_MTL_icon_<name>.png` font icon**: Material's `mapIcon`/`icon-mapping.js` parses `<name>` out of the filename and renders its own themed **font** glyph; the PNG itself is only a minimal non-Material fallback (single file, no `.svg`). Used by **Wish List** (`WishListIcon_MTL_icon_shopping_cart.png`) so it exactly matches the "Add to Wish List" context-menu trolley.
- **Why Wish List uses the font but Played can't**: Material's bundled icon font (Release 6.4.3, matching the box) **has** `shopping_cart` but **not** `music_history` (verified via the font's GSUB ligatures with fontTools) — an `_MTL_icon_music_history` would render blank. So Played's `music_history` had to be shipped as a recoloured `.svg` instead. (Confirm new font icons exist in `test-artifacts/lms-material/.../font/MaterialIcons.ttf` before using `_MTL_icon_`.)
- **No SVG rasteriser on this Mac** (no cairo/rsvg/inkscape; svglib's renderPM needs cairo). The PNGs are generated **qlmanage → Pillow** (the documented sibling-plugin path): `qlmanage -t -s 512` renders the `.svg` onto white, then Pillow does luminance→alpha (black art, transparent bg), trims to content bbox, and centres on a 256² canvas with 8% pad. Black-on-transparent so both the recolour and classic fallbacks look right.

## Material custom actions on streaming "…" menus (the hard problem — solved, released in Material 6.4.4)
Goal: an **"Add to Listen Later"** entry on a streaming **album row while browsing** (Qobuz New Releases, etc.), where the service plugin owns the "…" menu so TrackInfo/AlbumInfo providers can't reach it. Material's **custom actions** (`prefs/material-skin/actions.json`, served at `/material/customactions.json`) are the only hook — but out of the box they appear on **library** items only.

**STATUS (2026-07): MERGED upstream AND RELEASED in Material 6.4.4** — [PR #1235](https://github.com/CDrummond/lms-material/pull/1235) landed on `dev` (`b631754`), merged to `master` (`519b03a`), and shipped in the **Material 6.4.4** release (tag `6.4.4`, master `9be80db`). So there is **no more local bundle patching** — the feature ships in stock Material. Verified live on the box: it runs the stock 6.4.4 deferred bundle (561 KB, i.e. the un-patched size — the old patched build was 889 KB) and the streaming online actions are served and functional. The released code does exactly what the patch did — sets `i.service`=browse command (exposed as **`$SERVICE`**), sets `i.album=i.title`/`i.artist=i.subtitle`, and resolves the per-app `<command>-<type>` category with `online-<type>` fallback. The `$SERVICE` streaming feature is **6.4.4+**; `header-basic` (below) predates it (**6.4.3+**). On Material older than 6.4.4 the streaming-browse "Add" degrades to *entry absent* (the online browse path doesn't exist there) — every other add path is unaffected. No Perl-side `registerAction` API was added upstream, so the plugin's direct `actions.json` write (`_writeMaterialActions`) remains the correct mechanism. The original full trace, kept for context:

- **Bundles**: Material ships two minified JS bundles. `material.min.js` (**main**) contains `customactions.js` (`getCustomActions`, `doReplacements`, `doCustomAction`) and `browse-page.js` (renders the menu). `material-deferred.min.js` (**deferred**) contains `browse-resp.js`, `browse-functions.js`, `standarditems.js`. The deferred build list is the `addJsToDocument("html/js/",[…])` array in `index.html`.
- **Why library-only**: per-item custom actions are added in `browse-functions.js` only when `item.stdItem < STD_ITEMS.length` **and** `STD_ITEMS[item.stdItem].actionMenu` contains the `CUSTOM_ACTIONS` (`-2`) marker. Online items have `stdItem` **300/301** (`STD_ITEM_ONLINE_ARTIST/ALBUM`), far beyond `STD_ITEMS.length` (~16) — so they **bypass that whole path**. (And `standarditems.js` has `CUSTOM_ACTIONS` commented out on the online-album entry anyway.)
- **How online/app items get their menu**: library content comes via `*_loop` branches (`albums_loop`, `titles_loop`, …); **app/streaming content comes via the SlimBrowse `item_loop` branch**, which builds each item's own `i.menu` array directly. The context menu renders `menu.itemMenu = item.menu`, and the `CUSTOM_ACTIONS` template (`browse-page.js`) iterates the **view-level** `itemCustomActions`. So showing a custom action on an online item needs BOTH: push `CUSTOM_ACTIONS` into that item's `i.menu`, **and** set `resp.itemCustomActions` (wired to the view via `browse-functions.js:676`). Setting only `resp.itemCustomActions` (my first patch) does nothing.
- **The real blocker — Qobuz album rows have no identity**: verified over JSON-RPC, a New Releases album row is only `{type:"playlist", text:"Album (Hi-Res)\nArtist (YYYY)", params:{item_id:"6.0"}, icon:…}` — **no `favorites_url`, no `metadata`** (even with `wantMetadata:1`; LMS is 9.1 so the server supports it — the Qobuz plugin just doesn't emit it). Title/artist/year are only in the 2-line `text`; play works via `base.actions.play` + the positional `item_id` (non-durable). **Track** rows inside an album *do* carry `presetParams.favorites_url: qobuz://<trackid>.flac` + `favorites_type:audio`. So Material can't classify album rows as online albums — and neither can a classification-based patch.
- **Working fix** (in `browse-resp.js`, the `item_loop` per-item section, after the play-action block): key off **playability** not classification — `addedPlayAction && undefined==i.stdItem && !isFavorites && !isAppsTop` (these are app/online rows; library albums never reach `item_loop`). For such rows, set `i.album=i.title` / `i.artist=i.subtitle` so `$ALBUMNAME`/`$ARTISTNAME` resolve, push `CUSTOM_ACTIONS` into `i.menu`, and set `resp.itemCustomActions=getCustomActions("online-album")`. Service identity = the browse **`command`** (`data.params[1][0]`, e.g. `"qobuz"`), set on `i.service`. The merged Material exposes it as the **`$SERVICE`** replacement variable, so the plugin's `online-*` commands carry `svc:$SERVICE` (0.1.28). (The pre-merge local patch *baked* a literal `svc:<command>` into each `lmscommand` instead — that workaround is gone now that `$SERVICE` exists.)
- **Variable map** (`doReplacements`): `$ALBUMNAME`←`item.album`, `$ARTISTNAME`←`item.artist`, `$TITLE`←`item.title`, `$FAVURL`←`item.presetParams.favorites_url`, `$IMAGE`←`item.image`, `$ALBUMID`←`item.album_id`. Online album rows populate none of these by default — hence setting `item.album`/`item.artist` in `browse-resp.js`.
- **Plugin side** (`addctx`): reads `svc` as the authoritative source (no guessing); strips a trailing `(YYYY)` off the **artist** line → year, and a format qualifier (`(Hi-Res…)`/`(Explicit)`/…) off the **album**. `Sources::sourceFromImage` (cover host → service) is a fallback only. `_writeMaterialActions` strips every prior LL entry from all categories, then writes the active set with the flat-array `lmscommand` shape (NOT the `{command,params}` `lmsbrowse` shape): library `album`/`album-track`/`playlist`/`playlist-track`; streaming `online-album`/`online-track` as a single Add/Wish-List pair; and the own-view suppressors `listenlater-*`/`LLHome-*` = []. **We do NOT scope "Add" per streaming service anymore** (0.1.51 removed the 0.1.46–0.1.50 experiments — scheme filter, app/radio blocklist, home-shelf suppression). Instead the **add commands reject any source we can't replay** (`_isReplayableSource` = library or `Sources::_serviceCan`): an unsupported service's "Add" button is a harmless no-op with a "not supported" toast, never a stored-but-unplayable row. This is the one reliable gate (runs on every add path, unlike the flaky/unscopeable Material button). **Deliberately NOT written:** `online-artist` (dropped 0.1.32 — we save albums, not artists) and the plain **`track`** category (dropped 0.1.34 — its sole consumer is Material's Now Playing screen, `nowplaying-page.js` `getCustomActions("track")`; browse track lists use `album-track`/`playlist-track`, so omitting `track` suppresses "Add" on Now Playing only, plugin-side, no Material change). The strip pass also clears any `track`/`online-artist` entries an older version left behind.
- **Building/testing a dev Material (the feature is now released in 6.4.4 — this is only for future Material work)**: the clone is `test-artifacts/lms-material` (gitignored; remotes `origin`=CDrummond, `mine`=fork). The streaming feature no longer needs any local build/patch — stock Material 6.4.4+ carries it. To test *further* Material changes, build a real minified Material plugin from `origin/master`: `python3 mkrel.py test` → `lms-material-test.zip` (its contents = a `MaterialSkin/` plugin: install by replacing the box's MaterialSkin dir, chown `squeezeboxserver:nogroup`, restart; test in an **incognito** window — Material caches the bundle at app start). `mkrel.py` needs **Java 17** (runs the bundled Closure jar) + python **`requests`** (both installed on this Mac); CSS minify is pure-Python, no LESS step. Verify a build with e.g. `unzip -p lms-material-test.zip HTML/material/html/js/material.min.js | grep -c '\$SERVICE'`. *(Historical: before the merge, with no JDK on this Mac, the deferred bundle was hand-**concatenated** from the raw 6.4.3 sources and dropped onto the box. No longer needed.)* Proposal draft (now historical): `docs/material-online-custom-actions-proposal.md`.
- **Suppressing the action inside our OWN view (the per-app override)**: our plugin is itself an app, so its list rows are playable `item_loop` items → `isAppItem` matched and "Add to Listen Later" showed on albums already in the list (re-adding would bounce a *Played* album back to *Later*). Fix: the patched Material resolves the category for app items as `getCustomActions(command+"-"+btype)` **if** `command+"-"+btype in customActions` (the in-check is needed because `getCustomActions` returns `undefined` for an empty category), else falls back to `online-<btype>`. The plugin writes empty `listenlater-album`/`-track`/`-artist` categories, so its own rows show no "Add" while streaming services still do. This is also a general feature (any app can customise or suppress actions on its own view).
- **Remove/Move placement — kept in "… → More" (0.1.18 reverted in 0.1.19)**: they live in each row's `itemActions.info` → `listenlater contextmenu` query, and refresh the list **in place** via `nextWindow => 'parent'` (0.1.15). Putting them at the *top* of the "…" is possible as Material custom actions matched by the stock `$TITLE` variable (no db-id needed — identify the row by its displayed name, like Add) — but a top-level custom action can only refresh by `lmsbrowse` re-list (new page + awkward back path), and **in-place** refresh would need a second Material patch (`browse-page.js` `itemCustomAction` → `refreshList()` on a `refresh` flag) in the **main** bundle. To keep the Material footprint to the single deferred-bundle patch, we stayed with the More menu. (The would-be inline approach: `listenlater-album` holds `lmsbrowse` Remove/Move using `ltlremove:$TITLE`/`ltlmove:$TITLE`, handled in `topLevel` by matching a lowercased-alphanumeric key of the display name.) The empty `listenlater-*` and `LLHome-*` categories remain — they suppress "Add" on the plugin's own list and home shelf via the per-app override.
- **Context-menu actions: refresh in place, don't go home**: a "More"-menu `do` action's `nextWindow` governs navigation. `'grandparent'` jumps two levels (→ home); use **`'parent'`** — Material's rule `isMoreMenu && nextWindow=="parent"` calls `view.refreshList()`, updating the list where you are. (Path: `itemMoreAction` → `doTextClick(item, true)` sets `isMoreMenu`.) Remove/Move use `nextWindow => 'parent'`. Plugin-only — no Material change.
- **Diagnosing a streaming feed over JSON-RPC**: `["<mac>",["qobuz","items","0","5","item_id:<id>","menu:1","useContextMenu:1","wantMetadata:1"]]` returns the SlimBrowse `item_loop` Material parses — inspect each item's `presetParams`/`metadata`/`params` to see exactly what identity (if any) a row carries.

## Verification checklist (over HTTP)
1. App present: `apps 0 100` shows "Listen Later"; feed returns the three rows.
2. `trackinfo …menu:1` and `albuminfo …menu:1` include "Add album to Listen Later".
3. Add → `listenlater items` count increments; dedupe works.
4. Play album from the list; play ≥ threshold → moves to Played.
5. Remove / Move between sections; persists across `systemctl restart`.

## Prefs Namespace
`plugin.listenlater` — sort, played_threshold, streaming_min_tracks, watch_outside, material_action, played_retention_days, debug_log, threshold_90_migrated.

## The Played threshold: 90%, rounded DOWN (0.1.93)

`played_threshold` defaults to **90** (was 60) and the arithmetic lives in **`Played::tracksNeeded($total)`**,
split out of `_maybeMark` so it is directly testable — see the note below, it matters.

**Why 90.** 60% was a hedge from when a release's length was half-inferred from its TYPE. Since 0.1.90
a length is only ever MEASURED, so there is nothing left to hedge against and 60% moved an album to
Played well before it had been heard.

**Why rounded DOWN, and why that isn't a detail.** `ceil` is fine at 60% and punishing at 90%:
`0.9*N > N-1` for every `N < 10`, so ceil lands back on `N` and "90%" becomes arithmetically identical
to "100%" for any release under ten tracks. A skipped track — or one not licensed in the user's
region — would leave such a release permanently unmarkable. `floor` always leaves a track of slack:

| tracks | 2 | 3 | 5 | 9 | 10 | 12 |
|---|---|---|---|---|---|---|
| need | 2 | 2 | 4 | 8 | 9 | 10 |

**The 2-track guard is load-bearing.** `floor(0.9*2) = 1`, and "1 of 2 seen" is true on the very first
newsong — so a 2-track release would be marked the instant it started and auto-purged days later,
which is **0.1.83's bug arriving by a new route**. `tracksNeeded` never returns below 2 for
`$total > 1`, at ANY threshold (pinned at 90/60/10). A genuine 1-track release never reaches this
path — `_onChange` routes `total == 1` to `_armDeferredMark`'s played-through check.

**Existing installs are migrated once.** `$prefs->init` only fills an ABSENT pref, so every existing
user would have kept 60 silently and the change would have looked like it hadn't worked. `Plugin.pm`
bumps it unconditionally, gated on its own `threshold_90_migrated` flag so it runs once and can never
fight a user who then chooses their own value. Deliberately not "only if it's still 60" — this is a
change of default for everyone, not a repair of one setting.

**`tracksNeeded` exists because the test used to MIRROR the formula.** `t_played.pl` restated
`_maybeMark`'s arithmetic alongside it (on the grounds that `_maybeMark` needs `%tracking` and writes
to the DB), and a copied formula passes just as happily when the original is wrong — the exact hazard
that file exists to catch. It earned itself immediately: the first 90% assertion written was
`12 tracks -> 11`, carried over from the ceil table; the suite said 10 and the suite was right. Under
the old mirror that error would have been copied into both sides and passed. **Rule: pin the sum by
CALLING the code, never by restating it.**

## Played auto-retention (0.1.17)
Played albums are auto-removed after `played_retention_days` (default 7; **0 = keep forever**). `DB::purgePlayed($days)` deletes `status='played'` rows with `played_at < now - days*86400` (items moved back to Listen Later (`status='later'`) or to Wish List (`status='wishlist'`) are never purged). `played_at` is set when the album is first marked Played and is **not** refreshed by replaying an already-Played album (Played detection only tracks `status='later'` rows), so the clock runs from that first mark; to restart it, Move the album back to Listen Later and replay it. Scheduled in `Plugin::postinitPlugin` via `Slim::Utils::Timers` — first run ~60s after start, re-armed every 24h (`_purgeTick`). Settings field validates 0–3650.

## Streaming replay per service (Sources.pm) — the differences that bite
Browse rows differ by service, which is why each needs handling (all confirmed from the live `addctx` log + the Tidal/Bandcamp plugin source):
- **Qobuz** New Releases rows carry **no** `favorites_url` and no metadata — only a positional `item_id` + title/subtitle. So Qobuz replays by **search** (`getAPIHandler->search(cb, query, 'albums')` → `{albums}{items}` → `_albumItem`). Works.
- **Tidal** rows **do** carry the album id in `favorites_url` (`tidal://album:<id>`). `addctx` extracts it (`m{(?:[:/])album:([\w.-]+)}`) into `ref.album_id`; `_streamingAlbumNode` replays via `Plugins::TIDAL::Plugin::getAlbum` with **passthrough key `id`** (not `album_id`!) — `getAlbum` reads `$params->{id}` and returns `{items=>...}`. `_searchTidal` (`search(cb,{type=>'albums',search=>..,limit=>20})` → arrayref of album hashes → `_renderAlbum`) is the no-id fallback. Tidal capture often has an **empty artist** (online-classified items don't fill `$ARTISTNAME`), which is fine because the id path needs no artist — but the search fallback is then title-only.
- **Bandcamp** rows carry no id (like Qobuz) → **search** (`Plugins::Bandcamp::Search::search`, keep items with `passthrough[0]{album_id}`). **Gotcha:** Bandcamp's album coderef (`get_album`) calls back with a **bare arrayref** of tracks, while Qobuz/Tidal pass `{items=>[...]}` — `resolveTracks` must accept both (the 0.1.20 `Sources.pm:195` "Not a HASH reference" crash).
- `resolveTracks` finds the playable node (`type=>playlist`, `url=>CODE`) from `buildPlayableItems`, then calls `node->{url}->($client,$cb,{},$pt)` where `$pt = passthrough[0]`. Source tag from `favorites_url` scheme via `sourceFromUrl`; `sourceFromImage` (cover host) is a fallback when there's no favurl.

## Drag-and-drop to move between sections — NOT feasible (Material limitation)
Material only enables list drag-drop for **Favourites, editable local playlists, and the queue**: in the SlimBrowse `item_loop` branch `resp.canDrop = isFavorites` (hardcoded), and `dragStart`/`dragOver` gate on `this.canDrop`. A third-party OPML feed can't opt in (no response field enables it), and the `drop` handler issues favourites/playlist-specific reorder commands, not a generic "moved item → section" callback. So drag-to-move between the Listen Later / Played sections would need a separate upstream Material change.

## Custom actions on Material HOME shelves — only after a streaming browse (main-bundle limitation, left unpatched)
The "Add to Listen Later"/"Add to Wish List" custom actions appear on streaming **browse** pages but on **home-page shelf cards only after you've opened a Qobuz/Bandcamp/Tidal browse area in the same session**. Cause: `itemCustomActions` is a single **view-level** property. Browsing a service runs `view.itemCustomActions = resp.itemCustomActions` (`browse-functions.js:640`, deferred bundle) and that value **persists** on the home view; but the home shelves are built by `handleHomeExtra` (`browse-page.js`, **main** bundle `material.min.js`), which takes only `resp.items` and never sets `itemCustomActions`. Our patch *does* push the `CUSTOM_ACTIONS` marker into each home-shelf card's menu, but the marker only expands when `view.itemCustomActions` is already populated (i.e. leftover from a prior browse). There is **no plugin-only fix** — the plugin can't influence `view.itemCustomActions`. The one-line fix is in the main bundle: in `handleHomeExtra`, after `this.topExtra = resp.items;`, add `if (undefined!=resp.itemCustomActions) { this.itemCustomActions = resp.itemCustomActions; }`. **Decision: left unpatched** — we keep the Material footprint to the single deferred-bundle patch (same reason 0.1.18's main-bundle patch was reverted). A candidate addition to upstream PR #1235 if revisited.

## GitHub Pages docs (README.html / index.html)
`README.html` and the `index.html` redirect are **generated** from `README.md` by `tools/make_readme_html.py` (zero-dependency Markdown→HTML; ported from the sibling ListenBrainz plugin). The version badge is read **live from `ListenLater/install.xml`** — never hardcode it. The first `## ` section onward becomes the body; the "Features at a glance" table renders as cards, other tables as styled tables; the intro paragraph becomes the hero tagline. **Re-run `python3 tools/make_readme_html.py` after editing `README.md` or bumping the version** (these are docs only, not in the plugin zip). GitHub Pages serves the repo root, so `index.html` → `README.html` and the `ListenLater.zip`/`repo.xml` links resolve at the Pages URL.

## Version History
- **0.1.0** — Initial build: add from track/album "…" menu, browsable Listen Later / Played lists with per-album Play/Remove/Move, SQLite storage, automatic Played tracking, sort options, settings page. (See CHANGELOG.md.)
- **0.1.13** — Streaming **album rows while browsing** now get "Add to Listen Later" (confirmed working on Qobuz), paired with the patched Material deferred bundle: Material keys off playability and exposes title/subtitle as `$ALBUMNAME`/`$ARTISTNAME`, and passes the view's service id as `svc:`; `addctx` reads `svc` and cleans the year-off-artist / qualifier-off-album. (Full trace in "Material custom actions on streaming …" above; intermediate 0.1.7–0.1.12 were the dead-end classification attempts. See CHANGELOG.md.)
- **0.1.14** — "Add" no longer offered inside the plugin's own view (patched Material per-app category override; plugin writes empty `listenlater-*` categories). Needs the 0.1.14+ deferred bundle.
- **0.1.15** — Remove/Move from a row's "…" → More refresh the list in place (`nextWindow => 'parent'`) instead of jumping to the home screen. Plugin-only.
- **0.1.16** — Material home-page shelf for the Listen Later list, via `Plugins::MaterialSkin::HomeExtraBase` (`HomeExtras.pm`, tag `LLHome` → `Browse::homeShelf`), registered in `postinitPlugin` guarded on `registerHomeExtra`. Works on stock Material (no patched bundle). `homeShelf` returns a flat list of `_albumRow`s — **must stay quantity-stable** (carousel and "show all" click-in are the same feed at different quantities; a structure/quantity-dependent result shifts item_ids and breaks deep playback — the sibling plugin's 0.6.11 rule). Pattern copied from `LMS-ListenBrainz-New-Releases` `HomeExtras.pm`.
- **0.1.17** — Auto-remove Played albums after `played_retention_days` (default 7; 0 = forever) via a daily `DB::purgePlayed` timer. See "Played auto-retention".
- **0.1.18** — Remove/Move moved to the top of the "…" menu (Material custom actions matched by `$TITLE`, plugin-only). **Reverted in 0.1.19.**
- **0.1.19** — Reverted 0.1.18: Remove/Move back in "… → More" (in-place refresh, single-patch footprint), since a top-level + in-place-refresh combo needs a second Material (main-bundle) patch we chose not to add. See "Remove/Move placement".
- **0.1.20** — Fixed Tidal playback (capture album id from `tidal://album:<id>` favurl → replay via Tidal `getAlbum`, passthrough key `id`; + `_searchTidal` fallback) and Bandcamp playback (its album coderef returns a bare arrayref, not `{items=>...}` — `resolveTracks` now accepts both). See "Streaming replay per service". Tidal items added before 0.1.20 need re-adding.
- **0.1.21** — Accidental re-adds are a true no-op in **any** section. `DB::add` no longer bounces a Played album back to Listen Later when re-added (the old behaviour); an existing album is left where it is. Toast reworded to "Already in your list".
- **0.1.23** — **Buy on Bandcamp**: Bandcamp items get a "Buy on Bandcamp" entry in the "… → More" menu (a `go` drill into the async `listenlater buy` query). Bandcamp items store only artist+album, so the page URL is resolved on demand — `Sources::bandcampBuyUrl` runs `resolveTracks` and `_findBandcampUrl` scans the returned items for the `http(s)://…bandcamp.com/album|track/…` link the plugin emits ("Download album from the following address: …"), then caches it via `DB::setRefValue($id,'buy_url',…)` for instant re-opens. Returned as a jive `weblink` item (opens in browser). Fallback when no exact page: `https://bandcamp.com/search?item_type=a&q=artist+album`. `_buyCommand` uses `setStatusProcessing`/`setStatusDone` (async CLI query).
- **0.1.22** — New **Wish List** list (`status='wishlist'`). Third browse section (Listen Later / Wish List / Played); a second "Add to Wish List" entry in every context menu (Material custom actions get a paired action with `list:wishlist`; local info-providers return two items via `_addItemFor`); `add($rec,$status)` takes the target list (`later`|`wishlist`); the "… → More" menu offers a "Move to …" for each of the two lists the row isn't in, plus Remove (`_moveCommand` accepts `wishlist`). **Wish List is inherently purge-safe**: auto-Played detection only fires on `status='later'` (Played.pm) and `purgePlayed` only deletes `status='played'`, so a Wish List album is never auto-marked Played nor auto-removed.
- **0.1.24** — **Per-section icons** (`Browse::_iconFor`): Listen Later = new music-note+clock icon (also the app icon), Wish List = Material's `shopping_cart` font icon (`_MTL_icon_` convention, matches the context-menu action), Played = Google's `music_history` shipped as a recoloured SVG (not in Material's bundled font). Album rows fall back to their section icon. See "Icon system".
- **0.1.25** — **Renamed "Listen to Later" → "Listen Later"** and **"To Buy" → "Wish List"** throughout (title, menus, Perl packages `Plugins::ListenLater::*`, folder, `listenlater` command, `plugin.listenlater` prefs, `listenlater.db`, Material categories, icon filenames). Automatic data migration on first start (old db moved, `tobuy`→`wishlist`, prefs copied, stale Material actions cleaned). Download is now `ListenLater.zip`.
- **0.1.26** — Code-review fixes: settings clamps applied *before* the base handler saves (out-of-range values could mark albums Played too early); `actions.json` written atomically; "Buy on Bandcamp" can't hang (15s fallback); Bandcamp's "Download album from…" text lines kept out of the drill/queue; guarded the Qobuz `_albumItem` fallback.
- **0.1.27** — Homepage / "More info" link points to the rendered docs page (`README.html`) instead of the bare repo.
- **0.1.28** — Streaming-browse "Add" actions identify the service via Material's **`$SERVICE`** variable (`online-*` commands carry `svc:$SERVICE`), the clean upstream mechanism now that [PR #1235](https://github.com/CDrummond/lms-material/pull/1235) is **merged and released in Material 6.4.4** — replaces the old baked-`svc:` workaround. Needs Material **6.4.4+**; degrades to "entry absent" on older Material. See "Material custom actions on streaming …".
- **0.1.29** — **Section headers render as dividers again on newer Material.** Newer Material draws an *actionable* header (the plugin's headers carry a re-list `url`) as a grid **card**; the plugin now emits `type => 'header-basic'` (clears actions → plain divider). Gated by Material version: `Browse::_headerType` reads `Plugins::MaterialSkin::Plugin->getPluginVersion()` and uses `header-basic` only on Material **>= 6.4.3** (or dev/`test` builds), else the long-standing `header` — so older skins are unchanged. (`header-basic` first appears in Material 6.4.3.) Same one-liner is needed in sibling header-using plugins (ListenBrainz New Releases "Week of XXX").
- **0.1.30** — **Album cover from the ListenBrainz Fresh Releases detail page.** Those
  matched streaming rows show the **service logo** as their thumbnail (the detail-page
  service indicator), so `$IMAGE` is the logo, not the art. ListenBrainz Fresh Releases
  0.9.42+ instead tucks the album art onto the favurl as a private
  `?cover=<URI::Escape-d>` param. `_addCtxCommand` now, right after building `%p`, does
  `if ($p{favurl} && $p{favurl} =~ s{[?&]cover=([^&]+)}{}) { $favCover = uri_unescape($1) }`
  — extracting the cover **and stripping it in place**, so all the downstream source /
  `album:<id>` logic sees a clean `<scheme>://album:<id>` (and the stored favurl stays
  clean). `$artwork` becomes `$favCover // $p{image}`. **Scoped strictly to our own
  convention:** the substitution only matches the literal `cover=` token, so a native
  Qobuz/Tidal/Bandcamp browse favurl (no `?cover=`) never triggers it and is byte-for-byte
  unchanged — no effect on the normal streaming-plugin Add path. Pairs with LBF's
  `_attachFavUrl`; a private handshake between the two plugins, opaque to Material.
- **0.1.31** — **Settings entry uses a cog icon.** The top-level "Plugin Settings" row now
  uses `ICON_SETTINGS` (`SettingsIcon_MTL_icon_settings.png`, Material's `settings` font icon
  via the `_MTL_icon_<name>` convention — same mechanism as the Wish List trolley and the
  sibling ListenBrainz plugin's `MENU_COG`) instead of the app `ICON`. PNG copied from the
  sibling plugin's `lbf-cog_MTL_icon_settings.png`; it's only the non-Material fallback.
- **0.1.32** — **Code-review fixes (no user-facing feature change).**
  (1) Dropped the `online-artist` Material category — we save albums, not artists, and an
  artist row's `$TITLE` is the artist name with no album/favurl, so "Add" there stored a junk
  record that never replays. Stale `online-artist` entries self-clean on the next
  `_writeMaterialActions` (the strip-our-entries pass) — only our entries, never a user's.
  (2) The private `?cover=` strip in `_addCtxCommand` now matches `[?&]cover=([^&]*)` (param
  with its own leading delimiter, empty value tolerated, no trailing `&` consumed) so the
  residual favurl is always well-formed. (3) `_buyCommand` keeps the fallback timer in a
  lexical and `killTimers` it once the resolve callback wins. (4) `_libraryAlbumTracks` reuses
  `_libraryTrackItems` (one Schema query); the unused `ICON` constant left Plugin.pm and
  `HomeExtras::ICON` now aliases `Browse::ICON`; both `_norm`s carry a "deliberately differs —
  don't unify" comment (DB keeps `(…)` for the dedupe key, Sources strips it for fuzzy match).
- **0.1.33** — **Cross-service de-duplication.** Saving an album already in the list — even from
  a *different* service — is a no-op instead of a second row. `DB::add` now matches on
  `dedupe_key` across **all** sources via the new `DB::findAnyByKey` (was the per-source
  `findByKey`), and returns `($id, $already, $existingSource)`. `Plugin::_addedMsg` takes the
  existing + new source and, when they differ, toasts `PLUGIN_LL_ALREADY_FROM` ("Already saved
  from %s", via `sprintf(cstring(...))` — the sibling's idiom); same-source re-adds keep
  "Already in your list". Applies on both add paths (`_addCommand`, `_addCtxCommand` incl. the
  Material streaming action — chosen as block+toast because that fire-and-forget action can't
  show a Replace/Ignore prompt). Pre-existing duplicate rows are NOT auto-merged. (Note:
  Played auto-detection still matches per-source in `Played::_matchRecord`, so a Qobuz-saved
  album played from the library won't auto-move to Played — pre-existing, left as-is.)
- **0.1.34** — **No "Add to Listen Later"/"Add to Wish List" on Material's Now Playing screen.**
  `_writeMaterialActions` no longer writes the plain **`track`** custom-action category.
  Material's Now Playing context menu is the **only** consumer of `track`
  (`nowplaying-page.js` → `getCustomActions("track")`); every other surface uses a different
  category — browse track lists `album-track`, playlist tracks `playlist-track`, the queue
  `queue-track`, streaming rows `online-track` — so omitting `track` removes the pair from
  Now Playing **only**, with no effect on any browse/queue/streaming "…" menu. Plugin-only,
  **no Material change** (not even a PR'd one): the existing strip-our-entries pass clears any
  `track` entry a previous version wrote, so it disappears on the next `postinitPlugin` run.
  See "Material custom actions on streaming …" (the per-section category table).
- **0.1.39** — **Bandcamp albums from ListenBrainz Fresh Releases replay by their exact page
  URL, carried in the favurl.** Bandcamp's `get_album` resolves a tracklist from the album
  **page URL**, not the `album:<id>` in the favurl, so these saves used to produce no tracks.
  LBF 0.9.53+ packs the cover art **and** the page URL into one escaped `?b=<art>|<url>`
  favurl param; `_addCtxCommand` unpacks both (`$favCover` → saved artwork, `$favBandcampUrl`
  → `ref.album_url`), so replay goes straight through `get_album` and Buy-on-Bandcamp opens
  the page directly. The `?b=` strip mirrors the 0.1.30 `?cover=` handshake and runs in the
  same spot. **Corrected a wrong conclusion:** an earlier belief that "Material drops favurls
  longer than ~150 chars" (0.1.35–0.1.38 worked around it by re-deriving the URL via an
  `album_id` search) was an artifact of a **stale repo-installed build shadowing the manual
  dev install** (see memory `plugin-repo-shadows-manual-install`) — the new favurl code never
  ran, so the add arrived with no favurl. With the correct build loaded, the full ~164-char
  favurl arrives intact. The `album_id`-search resolve in `Sources::buildPlayableItems` is kept
  only as a safety net. The discarded `docs/material-favurl-length-issue.md` (written for the
  Material dev about the non-existent limit) was removed. **Debugging gotcha:** the `addctx`
  log line prints the favurl *after* the `?b=`/`?cover=` payload is stripped, so it always
  reads as a bare `bandcamp://album:<id>` — not proof the payload was dropped; and
  `image=(undef)` there is Material's `$IMAGE` (the service logo, intentionally unused).
- **0.1.40** — **"Buy on Bandcamp" opens a stored page URL directly.** `_buyCommand` now
  short-circuits on `ref.album_url` (the exact page URL captured at add time from the 0.1.39
  `?b=` favurl) as well as `ref.buy_url` (resolved on a prior open) — the album page *is* the
  buy page, so a newly-added Bandcamp album opens instantly with no resolve/search. Records
  with neither URL still take the resolve route (`bandcampBuyUrl` → `resolveTracks` →
  `_findBandcampUrl`, with the 15s search-URL fallback). Note `bandcampBuyUrl` in `Sources.pm`
  already preferred `ref.album_url`; this change moves the short-circuit up into `_buyCommand`
  so it skips `setStatusProcessing`/the fallback timer entirely.
- **0.1.41** — **"Buy on Bandcamp" is a one-tap link when the URL is known.** 0.1.40 removed the
  resolve *delay* but the entry was still a `go` drill into the `buy` query, which returns an
  intermediate "Open on Bandcamp" weblink — a second tap. Now the "… → More" builder
  (`_contextMenuQuery`) checks `ref.buy_url || ref.album_url` at menu-build time:
  if a page URL is known it emits the entry **as a `weblink` item itself** (handled in the
  render loop before the `go`/`do` branches), so one tap opens the browser. Only records with
  no stored URL still drill into `buy` (resolve once → cache → show link → one-tap thereafter).
  This is the actual fix for "Buy on Bandcamp doesn't resolve in one go" — 0.1.40 alone didn't
  remove the extra tap. (Reminder: only Bandcamp albums **added after LBF 0.9.53 / LL 0.1.39**
  carry `ref.album_url`; pre-0.1.39 saves resolve+cache `buy_url` on first buy, then one-tap.)
  **Known limitation (decided: leave as-is):** the weblink opens the page but does NOT return
  to the Listen Later list afterwards — Move/Remove do (they're `do` actions that flow through
  `browseDoClick` → `browseHandleNextWindow`, which honours `nextWindow:'parent'`), but a
  `weblink` is intercepted earlier in Material's `browseClick` (`else if (item.weblink) {
  openWebLink(item); }`) and that branch never checks `nextWindow`. There is **no plugin-only**
  way to both open the URL and pop back: the command path can't open a browser, the weblink
  path can't navigate. The only fix is a one-line Material change (call `browseGoBack`/honour
  `nextWindow` after `openWebLink`) + the entry setting `nextWindow:'parent'` — declined here to
  avoid a Material dependency (2026-06-27).
  **Two upstream Material options were explored (PR text drafted, neither submitted — kept 0.1.41
  as-is):** (1) *honour `nextWindow` on weblink clicks* — one-line change in `browseClick`'s
  weblink branch (`if (item.nextWindow) browseGoBack(view, true);`), so a weblink can open + return.
  (2) *make the browse-list service emblem clickable* like Now Playing's — Material already renders
  `emblem: getEmblem(i.extid)` on browse rows but it's decorative (no `@click`), whereas the Now
  Playing emblem (`emblemClicked` → `openWindow(playerStatus.current.source.url)`) opens the service
  page. A browse `@click.stop` handler preferring an explicit `item.emblemUrl` then falling back to
  `getTrackSource(item)` would open the page from the row, no context menu / no go-back at all.
  Caveat found: `track-sources.json` has **no URL template for Bandcamp** (only `{name,extid}`), so
  `getTrackSource` yields no URL for it — hence the explicit `emblemUrl` (which our stored
  `ref.album_url` would supply). Also note: for a **currently-playing** Bandcamp album the Now
  Playing emblem already opens the page for free, so the Buy entry is partly redundant once playing.
- **0.1.42** — **Right album on replay for same-titled releases + keep the artist on ListenBrainz adds.**
  Two independent fixes, both diagnosed live over JSON-RPC (saved records replayed the wrong tracklist:
  "American Football (LP4) (2026)" → the 1999 LP1's *Never Meant…*; one of two "Your Day Will Come"s →
  the wrong year).
  (1) **`_searchService` disambiguation (`Sources.pm`).** A Qobuz/Tidal browse row carries **no album
  id**, so replay searches the service and title-matches — but `_norm` strips the `(LP4)` distinguisher
  AND the year, so `_albumMatches` took the first same-base-title hit. Now the search sends the **raw
  artist only** and filters titles locally (recall — mirrors the sibling plugin's 0.9.34 lesson), and a
  new `_bestMatches` ranks the base-matched candidates: exact full title (kept via `_normStrict`, which
  strips only quality qualifiers, not `(LP4)`) **and** matching year > year > full title > base. Year
  comes from the raw service date field, else the year the renderer already shows on the item (`_yearOf`,
  a boundary-anchored 19xx/20xx match that ignores an epoch `released_at`). Bandcamp unchanged (replays
  by captured album id). The distinguishing title + year were already on the record — just discarded at
  match time.
  (2) **Artist packed in the favurl.** LBF match rows arrive with an empty `$ARTISTNAME` (Material
  doesn't map their subtitle — confirmed in the `addctx` log: `artist=` empty, `favurl=qobuz://album:…`
  present), so LBF-saved records had no artist and never auto-moved to Played. LBF 0.9.58+ packs
  `&a=<artist>` into the favurl; `_addCtxCommand` reads `[?&]a=`/`[?&]y=` as fallbacks for artist/year
  (after the `?cover=`/`?b=` strip, before the log so the logged favurl stays clean) and strips them.
  Native favurls (no query) never trigger it. Needs LBF 0.9.58; existing artist-less records can be
  removed + re-added.
- **0.1.43** — **Same-titled albums from different years can both be saved.** The dedupe key became
  `artist|album|year` (was `artist|album`), so e.g. Chanel Beads' 2024 and 2026 "Your Day Will Come"
  (identical titles, only the year differs) no longer block each other — the second used to be dropped
  as a duplicate. `DB::dedupeKey` takes the year; `add` passes `$rec->{year}`; a one-off idempotent
  migration in `_migrate` appends `|<year>` to existing 1-pipe keys (`WHERE dedupe_key NOT LIKE
  '%|%|%'`). **Played detection** must NOT gain the year (a playing streaming track can't be trusted to
  report it), so `Played::_matchRecord` now calls the new `DB::findByArtistAlbum($source,$artist,$album)`
  — a year-agnostic `dedupe_key LIKE 'artist|album|%'` prefix lookup (normalised parts carry no LIKE
  metacharacters) — replacing the removed `findByKey`. Two same-title different-year albums both saved:
  a play attributes to the lower id (streaming metadata can't disambiguate; accepted). Differently-titled
  editions ("(LP2)"/"(Deluxe)") were already distinct via `DB::_norm` (keeps parens) and are unchanged.
  Pairs with LBF 0.9.59, which packs the year into the favurl as `&y=` (`_addCtxCommand` reads
  `[?&]a=`/`[?&]y=`) so LBF adds carry a year too; older LBF builds send none → those dedupe on
  `artist|album|` as before.
- **0.1.44** — **Qobuz albums replay by their exact id, recovered from the cover URL — no search.**
  Diagnosed live: every direct-Qobuz add arrives with `favurl=` empty and `albumid=(undef)` (Qobuz
  browse rows carry no identity), so replay fell back to `Sources::_searchService` (artist-only search
  + 0.1.42 year/title tiering) — which for "American Football (LP2) (2016)" returned nothing (Qobuz's
  artist search didn't surface that specific edition), giving "Could not find this album to play" while
  LP3/LP4 happened to resolve. Root fix: the Qobuz **cover URL filename IS the album id**
  (`…/static.qobuz.com/images/covers/<xx>/<yy>/<ALBUMID>_<size>.jpg`; the xx/yy path is derived from the
  id's last chars — verified against the known-good favurl id `y89n6mtoxfa4k` and LP3/LP4's covers).
  New `Sources::qobuzAlbumIdFromImage` uri-unescapes the proxied cover and extracts the id;
  `_addCtxCommand`'s no-favurl branch, when `$source eq 'qobuz'`, sets `ref.album_id` from it (uses the
  raw `$p{image}`, not `$artwork`). `buildPlayableItems` then replays via `_streamingAlbumNode` by id —
  exact, no search — for ALL direct-Qobuz adds (also makes Chanel Beads etc. exact, not year-tiered).
  `_searchService` stays as the fallback for records with no recoverable id (older saves, non-Qobuz-cover
  images). Existing artist-less/id-less Qobuz records need a re-add to gain the id. Tidal already carried
  `tidal://album:<id>` in its favurl, so this is Qobuz-specific.
- **0.1.45** — **Tidal direct adds backfill the artist from the album (async); LBF adds confirmed carrying artist.**
  Tidal browse rows arrive with `favurl=tidal://album:<id>` (replay by id works) but `artist=` EMPTY
  (Material doesn't map their subtitle) and `year=(undef)`, and the Tidal cover URL is a random
  `resources.tidal.com/images/<uuid>/…` with no artist/id to recover (unlike Qobuz — see
  [[qobuz-album-id-from-cover-url]]). So `_addCtxCommand` now, for a fresh artist-less Tidal add with an
  album id, calls `_backfillTidalArtist` fire-and-forget: `Plugins::TIDAL::Plugin::getAlbum` (→
  `albumTracks(id)` → each `_renderTrack` sets `line2 => artist->{name}`) → take the first track's line2
  → `DB::updateArtist($id,$artist)`, which sets the artist column AND recomputes `dedupe_key` (year still
  unknown/empty) so Played's `findByArtistAlbum` prefix lookup matches. Guarded; a Tidal hiccup can't
  break the add. Artist shows on the row a moment after adding (async); pre-0.1.45 Tidal saves need a
  re-add. Tidal year is not exposed by albumTracks — left empty (only matters for same-title different-year
  Tidal dedupe, an edge case; AF editions have distinct titles). **Verified LBF adds already carry the
  artist**: a live LBF detail page streaming row's `favorites_url` was
  `qobuz://album:dmuizydvpcxsy?cover=…&a=Temples&y=2026` (0.9.59 `_attachFavUrl` + 0.1.44 `[?&]a=` receiver).
  Tidal plugin source: github.com/michaelherger/lms-plugin-tidal (`getAlbum`/`albumTracks`/`_renderTrack`).
- **0.1.46** — *(superseded by 0.1.47)* Tried an **allowlist** for the "Add restricted to supported services"
  feature: stopped writing the generic `online-*` and instead wrote `<command>-album`/`-track` per supported
  service. **Regressed the Material home-page shelves** — a shelf card has no per-service browse `command`, so
  it resolves custom actions via the generic `online-*` fallback (`browse-resp.js` ~L693); emptying `online-*`
  made "Add" disappear from every home shelf. Reverted in 0.1.47.
- **0.1.47** — **"Add" hidden on unsupported streaming services (Deezer, …) — as a BLOCKLIST.** The Add entry
  is suppressed on services we can't save/replay, while library + Qobuz/Bandcamp/Tidal + the ListenBrainz
  Fresh Releases feed keep it. Chosen as a **blocklist** (`@BLOCKED_ONLINE`, seeded `deezer`), not an
  allowlist, because it's the only design that keeps Material's generic `online-album`/`online-track`
  **populated** — the **home-page shelf cards depend on `online-*`** (they carry no per-service `command`, so
  they fall back to it); an allowlist empties `online-*` and kills Add on all home shelves (the 0.1.46
  regression). Mechanism: keep `online-*` = our Add/Wish-List pair, and for each blocked command write an
  **empty** `"<command>-album"`/`"-track"` category — Material's resolver (`browse-resp.js` ~L693) prefers a
  present app category (even empty) over `online-<btype>`, so the empty category hides Add on that service's
  browse rows only (same trick as our own-view `listenlater-*`/`LLHome-*` empties). Two surfaces, keyed on
  DIFFERENT identifiers: (1) **Material browse action** — blocked by browse COMMAND (`$SERVICE`); (2)
  **TrackInfo "…" provider** — `_trackInfoHandler` returns no item when `$rec->{source}` (play-url scheme) is
  blocked. The command and the scheme can DIFFER for one service (Spotty **browses** as `spotty` but **plays**
  `spotify://…`), so a fully-blocked service needs BOTH spellings in `@BLOCKED_ONLINE`. Tradeoff (accepted):
  open by default — a new unsupported plugin shows Add until added (a one-word change). Empty blocked
  categories linger in `actions.json` if a service is later removed from the list / becomes supported — clear
  them then (not auto-cleaned, unlike the rebrand strip).
- **0.1.48** — **Blocked-service suppression uses `||=`, not `=`, on the shared `actions.json`.** The 0.1.47
  block wrote `$data->{"<svc>-album"} = []`, which would overwrite another plugin's/user's custom actions for
  that service (unlike our own `listenlater-*`/`LLHome-*` namespaces, `<svc>-*` isn't ours to reset). `||= []`
  only creates the empty category when absent — our Add stays hidden (any defined category, even someone
  else's, overrides `online-*`) while their entries survive. Code-review fix, no user-facing change.
- **0.1.49** — **"Add" gated by play-URL SCHEME via Material's per-action `filter`, replacing the 0.1.47/0.1.48
  service blocklist.** The blocklist couldn't scale — too many unsupported services (Spotify, BBC Sounds,
  Radio Paradise, endless internet radio). Material's `filter` field (customactions.js `getSectionActions`:
  an action shows only when the passed filter `startsWith(sect[i].filter)`; the filter passed for online rows
  is `i.presetParams.favorites_url`, `browse-resp.js` ~L686/695) lets us allow by **scheme** instead. Now
  `_writeMaterialActions` writes: (a) `online-album`/`online-track` = one Add + one Wish List **per supported
  scheme** (`@SUPPORTED_SCHEMES` = `qobuz://`/`bandcamp://`/`tidal://`), each with `filter => <scheme>` — so
  only those play-urls get Add, everything else is excluded with nothing to enumerate, and ListenBrainz Fresh
  Releases rows qualify automatically (their favurl IS `qobuz://…`); (b) an **unfiltered** per-command
  `qobuz-`/`bandcamp-`/`tidal-`album`/`track` (`@NATIVE_SERVICES`) because those services' "New Releases" rows
  carry NO `favorites_url`, so the scheme filter can't see them (a filter is bypassed when the favurl is
  undefined → on a no-favurl row ALL scheme copies would show; the per-command category gives a single Add and
  Material prefers it over `online-*`). **Home shelves keep working** because `online-*` stays POPULATED (the
  shelf cards go through `parseBrowseResp` → per-card `CUSTOM_ACTIONS` marker, but only when `online-*` is
  non-empty — the 0.1.46 allowlist emptied it and broke them). Non-clobbering: entries are PUSHED, so another
  plugin's `qobuz-album`/etc. survive (verified). The TrackInfo "…" provider uses the source allowlist
  `%SUPPORTED_SOURCE` = `library qobuz bandcamp tidal`. Stale `deezer-*` (0.1.48) are deleted on write
  (`@STALE_CATEGORIES`). **Known edge:** a NO-favurl row on an UNsupported service bypasses the filter and
  would show all scheme copies — but such services (Deezer/Spotify/radio) carry favurls, and native no-favurl
  services are the supported ones; if one ever appears, give it an empty per-command category (the old
  blocklist trick, now a targeted escape hatch). Add a service: adapter in `Sources.pm` + scheme in
  `@SUPPORTED_SCHEMES` (+ command in `@NATIVE_SERVICES` if its browse rows can lack a favurl; + scheme in
  `%SUPPORTED_SOURCE` for the TrackInfo menu).
- **0.1.50** — **"Add" scoped by a DYNAMIC command blocklist read from the server's own menus — replaces the
  0.1.49 scheme filter (rolled back).** Verified over JSON-RPC why the scheme filter failed: ListenBrainz
  Fresh Releases rows AND Material home-shelf cards carry `favorites_url = None` / empty `presetParams` (they're
  `type=link` drills, or home cards whose menu resolves via `online-*` with an *undefined* command — a per-
  command category like `LBFForYou-album` is NOT consulted for them). With no favurl, Material's `filter` is
  bypassed (`undefined==filter` short-circuits `getSectionActions`), so all 3 scheme copies showed → the 6-way
  duplicate "Add" on LBF. There is no per-item identity to filter on; the only axis LBF/home rows expose is the
  browse COMMAND (home cards: none → `online-*`). So: keep `online-album`/`online-track` a single populated pair
  (home shelves + LBF keep Add, no dup), and suppress "Add" on unsupported services' BROWSE rows via empty
  `<command>-album`/`-track`. The blocklist is **not hardcoded** (every user installs different services):
  `_unsupportedAppCommands` runs `Slim::Control::Request::executeRequest(undef, ['apps'|'radios', 0, 500])`
  (both work with no player), reads each entry's `cmd` from `appss_loop`/`radioss_loop`, and blocks every
  command NOT in `%SUPPORTED_APP` (`qobuz bandcamp tidal listenbrainzfreshreleases listenlater`). Enumerating
  BOTH menus matters: streaming apps are under `apps`, internet radio (TuneIn categories `music`/`news`/`search`/
  … + `bbcsounds` + `podcast`/`presets`) is under `radios`, and a service can be in both (Qobuz) — unioned by
  command, and `qobuz` is supported so it's never blocked whichever menu it came from. Verified the generic
  TuneIn command names don't collide: `search` returns TuneIn radio (not Qobuz — Qobuz's own search runs under
  cmd `qobuz`). `||=` keeps the non-clobber property. **Known gaps (documented, left as-is):** (1) Material
  **global search** puts every service under one `globalsearch` command (verified: Qobuz/Tidal/BBC all drill as
  `['globalsearch','items']`), so it can't be scoped — Add shows there for unsupported too; blocking it would
  also kill it for Qobuz/Tidal. (2) Home-shelf cards of unsupported services can still show Add (no command/URL
  to scope). Add a service now = adapter in `Sources.pm` + its command in `%SUPPORTED_APP` (+ scheme in
  `%SUPPORTED_SOURCE` for the TrackInfo menu). See [[lms-server-http-testing]] for the JSON-RPC probes used.
- **0.1.51** — **Dropped ALL the 0.1.46–0.1.50 per-service "Add"-button scoping; reject unplayable adds at add
  time instead.** The whole scoping saga (blocklist → allowlist → scheme filter → dynamic app/radio
  enumeration) was fighting Material's custom-action mechanism, which is fundamentally unfit for this: on
  home-page shelves it's driven by leftover view state (`handleHomeExtra` never sets `itemCustomActions`, so a
  card only shows "Add" if a *prior* browse populated it — the user's "use it on a library shelf and it starts
  working on Qobuz shelves" symptom) AND unscopeable: ALL home shelves are fetched in ONE
  `["material-skin","home-extra",…]` call (browse-page.js L1146), so the custom-action `command` is always
  `material-skin` (L91) and `LLHome-album=[]` is never consulted. **CORRECTION (per CDrummond, the Material
  author):** this one-call design is NOT new to 6.4.3 — "Material always got all scrollable lists with one
  call." An earlier note here claimed 6.4.3 introduced it; that was wrong, from a `git log -S` on the SHALLOW
  test-artifacts clone (history only reaches the 6.4.3 tag, so the search reported the oldest visible commit,
  not the real origin). So `LLHome-album` never worked on the carousel — home-shelf "Add" has always been
  governed by `online-*` + leftover view state (i.e. always "hit and miss"), never a regression. So we
  stopped trying to hide the button and moved the gate to the one path that always runs: the **add commands**.
  `_addCommand`/`_addCtxCommand` now call `_rejectAdd` (no DB row, **silent** — see below) unless
  `_isReplayableSource($source)` — library, or `Sources::_serviceCan` (an installed Qobuz/Bandcamp/Tidal
  adapter). Verified over JSON-RPC that **Deezer sends a valid `deezer://album:<id>` favurl and still can't
  play** (no adapter → `_searchService` has no deezer branch → `_noMatch`), which is why the gate keys on
  ADAPTER support, not favurl presence. `_writeMaterialActions` reverts to the pre-0.1.46 shape (library +
  `online-*` single pair + `listenlater-*`/`LLHome-*` suppressors); the TrackInfo provider's source gate was
  removed too (rejection covers it). Net: "Add" may appear on unsupported services / home shelves, but it's a
  harmless no-op — nothing unplayable is ever stored. **The reject is silent by necessity:** Material renders
  no toast for a custom-action/menu command (server-side `showBriefly` reaches physical player displays only,
  never the web UI — verified: no `showBriefly` handler anywhere in Material's JS), and its only feedback hook
  is a generic `'…' failed` snackbar whose text we can't set. So there's no way to show a descriptive "not
  supported" message from this path; the `showBriefly`/`PLUGIN_LL_UNSUPPORTED` reject-toast was removed as dead
  code (0.1.54). The pre-existing "Added" confirmation `showBriefly` stays — it still shows on hardware player
  displays. Known-gap docs from 0.1.50
  (globalsearch, home-shelf leakage) are now moot — they were only about hiding the button.
- **0.1.52** — **Fix: 0.1.51 hid "Add" on Qobuz/Tidal/Bandcamp/ListenBrainz.** `actions.json` is SHARED and
  persists across plugin updates. The scoping experiments (0.1.46–0.1.50) wrote per-command categories
  (`qobuz-album`, `tidal-album`, `bandcamp-album`, `listenbrainzfreshreleases-album`, the LBF tags, and the
  dynamic blocklist ones); 0.1.51 stopped writing them but the STRIP pass only removes our *entries*, leaving
  the categories as EMPTY arrays — and an empty `<cmd>-album` overrides the generic `online-album`
  (browse-resp.js ~L693), so it suppressed "Add" on the very services we support. Verified live over the
  served `customactions.json` (qobuz-album=0, tidal-album=0, …) and that LBF writes NO custom actions of its
  own (so every stale empty is ours). Fix: after the strip pass, delete every empty `*-album`/`*-track`/
  `*-artist` category EXCEPT the ones we actively write (the `%cats` keys) and our own suppressors
  (`listenlater-*`/`LLHome-*`); only-empty so another plugin's real entries are never touched. Supported
  services then fall through to the populated `online-*` again. **Lesson:** when you STOP writing a custom-
  action category, you must DELETE it — leaving it empty is not neutral, it actively suppresses.
- **0.1.53** — **Reject unidentifiable adds instead of defaulting them to Qobuz.** An LB "Created for You"
  playlist added as an empty `qobuz` album (log: `name=W/C 22 June 2026 … favurl= image=plugins/ListenBrainz…
  playlist-weekly-jams-prev.png svc=material-skin-client → addctx -> qobuz / … (id=113)`). Root cause: in
  `_addCtxCommand`'s no-favurl `else` branch, `svc` = `material-skin-client` fails the `^[a-z0-9]+$` test
  (hyphens), the image is a plugin PNG (not a service cover, so `sourceFromImage`→''), and the old
  `_defaultStreamingSource()` then forced `source='qobuz'` — which passed the reject gate and stored an
  album-less row. Fix: dropped `_defaultStreamingSource` (source is now `$svc || sourceFromImage || ''`), and
  `_isReplayableSource('')` now returns FALSE (was defaulting empty→library→true). So an unidentifiable item
  is rejected; a real streaming album with a service cover (e.g. Qobuz on a home shelf — same `svc=
  material-skin-client`, but a `static.qobuz.com` cover → `sourceFromImage`→qobuz → id recovered) is
  unaffected. NB the add commands still pass an explicit `'library'` for real library items, so empty source
  never legitimately means library. (Full playlist SUPPORT was assessed as too much work — LB playlists are
  ListenBrainz recommendation lists resolved track-by-track by LBF, with no service playlist id to replay.)
- **0.1.55** — **"Add" hidden on internet-radio BROWSE rows — a narrow, deliberate exception to the 0.1.51
  "don't scope the button" stance.** Radio stations are live streams, never a valid Listen Later item, and —
  unlike the general per-service scoping that 0.1.51 abandoned — radios ARE cleanly command-scoped in the
  browse menu, so this one case is worth doing. `_unsupportedRadioCommands` runs
  `executeRequest(undef, ['radios', 0, 500])` (works with no player), reads each `radioss_loop` entry's `cmd`,
  and drops any in `%SUPPORTED_CMD` (`qobuz bandcamp tidal listenbrainzfreshreleases listenlater`) — so a
  service also listed under radios (Qobuz) keeps Add, while a dual-listed but unsupported one (BBC Sounds,
  under both `apps` and `radios`) is blocked wherever it shows. For each remaining command `_writeMaterialActions`
  writes an **empty** `<cmd>-album`/`-track` with `||=` (0.1.48 non-clobber — the `<cmd>-*` namespace isn't
  ours; another plugin's real entries survive and still override `online-*` → Add hidden either way), and adds
  those keys to `%keep` so the 0.1.52 delete-empties pass leaves them — the one place we WANT an empty category
  to persist (empty overrides `online-*`, which is exactly the suppression we want; cf. 0.1.52's lesson used in
  reverse). **Browse rows only.** A radio HOME-SHELF card has no per-command identity (all shelves arrive in one
  `material-skin` home-extra call → resolves via shared `online-*`), so its Add can't be hidden here — it stays
  a harmless add-time reject (0.1.51). This does NOT resurrect the full 0.1.46–0.1.50 saga (apps blocklist,
  scheme filter, home-shelf scoping) — only the radios slice, which is legitimate and self-contained.
- **0.1.56** — **Fix: 0.1.55 only blocked BBC Sounds, not TuneIn.** The `radios` enumeration runs at
  `postinitPlugin`, but **TuneIn's radio directory (Music/News/Sports/… categories) is fetched ASYNC from
  mysqueezebox.com** and isn't ready that early — so the init write only saw the locally-registered BBC Sounds
  plugin (verified live: served `customactions.json` had `bbcsounds-album`=0 but no `music-album`/`news-album`/…,
  while a later `['radios',0,500]` JSON-RPC returned all 11 TuneIn cmds). Added a **deferred re-write**:
  `_writeMaterialActionsDeferred` fires on a `Slim::Utils::Timers` timer +60s after postinit (killTimers-guarded,
  same pattern as `_purgeTick`), by which time the directory has loaded, so the TuneIn commands get their empty
  suppressor categories. `_writeMaterialActions` is fully idempotent so the re-run is safe. **Residual race:** on
  a very slow network the directory can take >60s to load → TuneIn shows "Add" until the next add/restart's write;
  acceptable (and the add is still a harmless reject). Confirmed radio-row suppression itself works — BBC Sounds
  was correctly hidden by 0.1.55, proving the empty-`<cmd>-album` override reaches radio browse rows.
- **0.1.59** — **`debug_log` pref — diagnostics for "Add missing on a streaming service" reports we can't
  reproduce on our own box.** A checkbox in Settings → Material Skin (`PLUGIN_LL_DEBUG_LOG`, pref
  `debug_log`, default off); `_dbg` logs at **WARN** (so it shows regardless of the category's level — INFO
  is invisible unless the category is at INFO). At the end of every `_writeMaterialActions` (when the pref is
  on) `_dumpMaterialState` dumps the whole decision surface for the online "Add": the detected Material
  version via `_materialVersion` (`Plugins::MaterialSkin::Plugin->getPluginVersion`) and whether it's **>=
  6.4.4** (online custom actions exist — below that, streaming rows get NO Add and only local works, the
  reported symptom); `online-album`/`online-track` entry counts (empty → no streaming Add anywhere); any
  **NON-empty `<svc>-album`/`-track`** category, which SHADOWS `online-*` and hides Add on that one service
  (ours are always empty, so a populated one is foreign/leftover — the thing to look at); the radio/
  unsupported commands we suppress; and a per-enabled-app verdict (`apps 0 500`) of "Add shown via online-* /
  HIDDEN by a per-command category / no Add (Material < 6.4.4)". Prime suspects for another user, both
  invisible from our box: (1) Material older than 6.4.4; (2) a stale app-start-cached `customactions.json`
  (the file is correct but an open tab shows the old one — hard-refresh once, see 0.1.57). No behaviour
  change when off. **The report is also surfaced in the Settings page itself** (not just server.log): the
  accumulated lines are stashed in the `material_debug_snapshot` pref and rendered in a readonly select-all
  textarea (`PLUGIN_LL_DEBUG_SNAPSHOT`, shown only when `debug_log` is on) so a remote user can copy-paste it
  without touching the log. `Settings::handler` persists the two Material toggles from the form and re-runs
  `_writeMaterialActions` on save (guarded on material_action + MaterialSkin, like postinit) so the snapshot
  reflects the just-saved state, then passes it to the template before SUPER renders.
- **0.1.57** — **Fix: 0.1.56's deferred write hid TuneIn "Add" in the FILE but not in the live UI — a Material
  load-time cache issue, not a file issue.** Traced end-to-end over HTTP: (1) the served `customactions.json`
  correctly had `music-album`/`news-album`/… = 0 after the +60s deferred pass; (2) `browse-resp.js` L91/685/692
  resolves a TuneIn station to `command="music"` (from `data.params[1][0]`, confirmed via menu-mode
  `['radios',…,'menu:radios']` → each item's `actions.go.cmd=['music','items']`; the plain `radios` query's
  `cmd` field happens to match) and `btype="album"` (stations are `type:audio` app items → the `:"album"` else),
  so it checks `"music-album" in customActions` → empty → no Add. The logic is correct. BUT
  `customactions.js:25` fetches the file **once at Material app start** via `axios.get(".../customactions.json?r="
  + LMS_MATERIAL_REVISION)` — `?r=` is the Material VERSION, not our writes — so it's browser-cached and never
  re-fetched in-session. `bbcsounds-album` (written at INIT, before Material loads) was always present;
  `music-album` (written +60s) was missed by already-loaded/cached tabs → fell back to populated `online-album`
  → Add showed. **Verified**: in a fresh incognito window (cache-bypassed) TuneIn Add was correctly gone. **Fix:**
  seed a hardcoded `@KNOWN_RADIO_CMDS` (`music news sports talk location language podcast search presets local` —
  TuneIn's stable top-level categories) at INIT, unioned with `_unsupportedRadioCommands()` (minus
  `%SUPPORTED_CMD`), so the empties exist before Material ever loads the file. The +60s deferred write stays
  (catches other late radio plugins). One-time: after updating, hard-refresh Material once to drop the stale
  cached `customactions.json`; correct on every restart thereafter. **Lesson:** Material caches
  `customactions.json` at app start keyed on its own revision — a category MUST be on disk before Material loads
  or an open/cached tab won't see it; deferred/async writes are invisible until a hard refresh.
- **0.1.60** — **Deezer is a supported streaming source.** Deezer joins Qobuz/Bandcamp/Tidal in
  `Sources.pm`: `%SCHEME`/`sourceFromImage` (dzcdn.net host) recognise it, `_serviceCan` returns true when
  `Plugins::Deezer::Plugin->can('getAlbum')`, `_streamingAlbumNode` replays a captured id via
  `Plugins::Deezer::Plugin::getAlbum` with passthrough key **`id`** (same as Tidal — confirmed
  `getAlbum` reads `$params->{id}` → `albumTracks`), and `_searchService` gains a Deezer branch (API-handler
  `->search(cb,{search,type=>'album',strict=>'off'})` → bare arrayref of raw album hashes → `_renderAlbum`,
  which already returns `type=>playlist, url=>\&getAlbum, passthrough=>[{id}]`). No add-gate list changed
  because since 0.1.51 the sole gate is `_isReplayableSource` → `_serviceCan`; adding the branch is enough,
  so Deezer adds (its browse rows carry a clean `deezer://album:<id>` favurl — the generic
  `m{(?:[:/])album:([A-Za-z0-9._-]+)}` capture already extracts it) are now accepted and replay by id.
  The prior "Deezer sends a valid favurl and still can't play" reject (0.1.51) is exactly what this closes.
  Pairs with ListenBrainz Fresh Releases 0.9.69 (Deezer matching). Deezer plugin surface confirmed against
  michaelherger/lms-deezer.
- **0.1.61** — **Deezer adds backfill the artist (like Tidal, 0.1.45).** Verified live: a Deezer album added
  from browsing stored **and replayed** (id=119 Revolver → 14 `deezer://…flc` tracks), but the `addctx` log
  showed `artist=` EMPTY — Deezer browse rows carry no `$ARTISTNAME` (Material doesn't map the subtitle) and
  the `e-cdns-images.dzcdn.net` cover URL has nothing to recover it from (same as Tidal). So the artist-less
  record showed album-only and would never auto-move to Played (keys on source+artist+album). Generalised
  `_backfillTidalArtist` → **`_backfillStreamingArtist($client,$recId,$albumId,$source)`**, which picks the
  right plugin's `getAlbum` (Tidal or Deezer — both share `($client,$cb,$args,{id})→{items}`, tracks with
  `line2`=artist) and updates the record async/guarded; the call site now fires for `tidal` OR `deezer`. Also
  added `deezer` to `%SUPPORTED_CMD`. **The reported "failed to add from browsing albums" was NOT a failure**
  — the add stored (`setStatusDone` called) and the album plays; Material just shows no success toast on the
  web UI (`showBriefly` reaches hardware players only — the 0.1.51/0.1.54 limitation), so a successful add
  looks like nothing happened. Pre-0.1.61 Deezer saves can be removed + re-added to gain the artist.
- **0.1.62** — **"Add to Listen Later"/"Add to Wish List" restored on Material's Now Playing screen (reverses
  0.1.34).** `_writeMaterialActions` now writes the plain **`track`** category again (added to `%cats`, so it's
  also in `%keep` and survives the delete-empties pass). Material's Now Playing menu is the ONLY consumer of
  `track` (`nowplaying-page.js getCustomActions("track")`), so this puts Add there and nowhere else — the
  queue uses `queue-track`, browse lists `album-track`/`playlist-track`. It uses the existing `$trackCmd`
  (`name:$ALBUMNAME`), so it adds the **currently-playing ALBUM**, not the track (the `trackname`/`trackid`
  params are logged only — `_addCtxCommand` always stores `$album`). Behaviour by source: a streaming
  now-playing track's `$FAVURL` is the TRACK url (e.g. `deezer://<id>.flc`, no `album:<id>`), so the source is
  read from the scheme and the album is resolved by artist+title search (`Sources::_searchService`); a library
  track carries `$ALBUMID` and adds directly. Same end result the user already gets from the play queue's
  "… → More". (0.1.34 had omitted `track` as a deliberate design choice — Now Playing is track-oriented, the
  plugin saves albums — but it's wanted back.)
- **0.1.63** — **Top-level "Add" restored on PLAY-QUEUE tracks (`queue-track` category).** The queue's track "…"
  menu only showed Add under "… → More" (the TrackInfo info-provider), never at the top. Confirmed against the
  SERVED main bundle: the queue component does `this.queueCustomActions = getCustomActions("queue-track", false)`
  — so Material DOES support custom actions on queue items (the 0.1.34 note was right; a WebFetch of
  `nowplaying-page.js` wrongly claimed queue items get none — the string `queue-track` is present twice in
  `material.min.js`, so trust the served bundle over a summarised fetch). We just weren't writing the category.
  Added `'queue-track' => $trackCmd` to `%cats` (so it's in `%keep` and gets the Add/Wish-List pair). Same
  `$trackCmd` → adds the track's ALBUM. Surfaces confirmed distinct: `track` = Now Playing info panel,
  `queue-track` = the play-queue list, `album-track`/`playlist-track` = browse lists, `online-track` = streaming
  rows. **Method to identify a surface's category: grep the SERVED bundle (`curl …/material/html/js/material.min.js`
  + `material-deferred.min.js`) for `getCustomActions(` — literal args are the category; the queue/nowplaying ones
  are set via `bus.$on("customActions", …)` handlers.** Needs a Material hard-refresh after install (customactions
  cache, 0.1.57).
- **0.1.64** — **Now Playing "Add" now actually stores the album (the `track` category from 0.1.62 was inert).**
  Diagnosed from the live log: a Now Playing Add arrived as `name=special, artist=Richard Orofino, albumid=,
  favurl=, trackid=, svc=(undef)` → `rejected add — unsupported source ''`. Root cause confirmed by extracting
  Material's `doReplacements` var map from the SERVED bundle: the Now Playing `track` action's substitution
  object `c` = the now-playing item, which has `c.album`/`c.artist`/`c.title` but **no
  `c.presetParams.favorites_url` and no `c.album_id`** — so `$FAVURL`/`$ALBUMID`/`$SERVICE` are all empty and
  `$source` came up '' → the 0.1.53 reject fired. (So `track`/`queue-track` differ: a QUEUE item carries a real
  favurl, a NOW-PLAYING panel item does not.) Fix: **`_nowPlayingFallback($client,$album,$artist)`** — when
  `$source` is empty and there's a client, recover source + album from the player's **currently-playing track**
  (`$client->playingSong->currentTrack->url` → scheme = source; `->album->id` for a library track), guarded by
  matching the playing track's album (+artist when both known) to the params so a stray empty-favurl Add can't
  adopt an unrelated playing track. A streaming NP track's url is a TRACK url (no `album:<id>`) → replay by
  artist+title search; a library NP track adds by album id. Reuses `Sources::_norm`/`_artistMatch`. Unsupported
  services still reject (the scheme feeds `_serviceCan`). NB: relies on `$request->client` being the playing
  player — Material sends the current player with the custom action, so it is.
- **0.1.70** — **Matcher: self-titled-album exact rule (fleet sync from Discography 0.11.1).** `_albumMatches`
  (`Sources.pm`) now, when the album title normalises to the ARTIST name ("The Beatles", "Weezer"), requires an
  EXACT title before the lenient "starts-with" rule — so a saved self-titled album stops matching "The Beatles
  1962-1966" etc. `_norm` still strips brackets, so "(White Album)"/"(Remastered)" match. Fires ONLY when the
  artist is present AND == the album; **LL's deliberate lenient empty-artist replay path is untouched** (the
  self-titled block sits above the `return 1 unless length $artistNorm` line). Applied across the fleet
  (LBF 0.9.90, PFR 0.7.5, DSC already had it); LL's pinned `_albumMatches` variant re-pinned
  `5d270440af5a→2bf38f346e0f` in `matcher_sync_check.py` (exits 0). No cache (LL matches live). `perl -c`
  clean; validated by the shared self-titled matcher test incl. the LL empty-artist leniency preserved. (0.1.65–0.1.69 detail is in CHANGELOG.md.)
- **0.1.71** — **Clean album title on adds from a sibling plugin that labels rows "Artist - Album"
  (Pitchfork Reviews) — fixes those albums never auto-moving to Played.** A Pitchfork row's `name`/`line1`
  is `"Artist - Album"`, and Material forces `$ALBUMNAME`/`$TITLE` to that whole label for online items, so
  `_addCtxCommand` stored the album title with the artist prefixed ("Will Sheff - Extra Mile"). That showed
  DOUBLED in the list ("Will Sheff – Will Sheff - Extra Mile") AND broke **Played auto-detection**: its
  dedupe-key album segment then included the artist, so the playing Qobuz track's clean album ("Extra Mile")
  never matched via `Played::_matchRecord` → `DB::findByArtistAlbum` (nor the `findByAlbum` fallback). Fixed as
  the symmetric partner of the existing `&a=` artist handshake, NOT an LL-side strip of bad input: **PFR
  (0.7.6) packs the CLEAN album into the favurl as `&al=`** (`Browse::_attachFavUrl`), and `_addCtxCommand`
  reads `[?&]al=` and prefers it over `$TITLE` (`[?&]a=` can't match `&al=` — it needs `=` right after `a`).
  Already-saved polluted rows are cleaned by a one-off idempotent DB migration `DB::_migrateArtistPrefix`
  (strip a leading `"<artist> - "`/en/em-dash from the title + recompute the dedupe_key; **streaming rows
  only** — a local album can legitimately be titled "Artist - Title"; per-row guarded against a
  UNIQUE(source,dedupe_key) collision with a clean twin). No matcher change (`_attachFavUrl` is outside the
  shared engine). `perl -c` clean. NB the fix needs BOTH plugins updated; an older PFR sends no `&al=` and new
  adds from it stay polluted until it's updated (existing rows are still cleaned by the migration).
- **0.1.72** — **Code-review hardening of the 0.1.71 `_migrateArtistPrefix` cleanup** (behaviour of the add-path
  `&al=` fix unchanged). Three fixes, all verified against a real in-memory SQLite DB
  (`scratchpad/verify_migration.pl`, all pass): **(1) run ONCE** — the migration was called from `_migrate` on
  every server start (a full non-library `SELECT` + per-row Perl loop each boot, and a row that can't be cleaned
  — a `UNIQUE(source,dedupe_key)` collision with a clean twin — re-logged its skip WARN forever). Now gated on
  the SQLite `PRAGMA user_version` (0 ⇒ run + stamp `1`), so it's genuinely one-off; still idempotent so a
  re-run after a partial upgrade is safe. **(2) narrower prefix match** — the strip now requires the
  SPACE-PADDED `"<artist> <dash> <album>"` shape Material actually renders (`\s+[dash]\s+`, was `\s*[dash]\s*`),
  so a hyphenated single-token title (`Jay-Z`, `Sunn O)))-Monoliths`) can no longer be misread as an artist
  prefix and corrupted. Residual (accepted, now bounded to the single run): a streaming album whose REAL title
  genuinely is `"<own artist> - <rest>"` with spaces is indistinguishable from the pollution by stored content
  alone and is still stripped — vanishingly rare, and library rows (where it's most plausible) are excluded.
  **(3) full dash family** — separator class broadened from hyphen/en/em to also cover figure dash (U+2012),
  horizontal bar (U+2015) and minus (U+2212), so sibling labels using any dash variant are cleaned. `perl -c`
  clean (logic validated standalone — Slim modules absent on the Mac). No matcher change.
- **0.1.74–0.1.78** — **Individual TRACK + single/EP support** (the plugin previously saved albums only).
  New `kind` column (`album`|`track`) with a `user_version < 2` migration; a track gets a 4-segment dedupe key
  (`artist|album|year|t:<track>`) so a track and its parent album never collide. Distinguish album vs track by
  **context** (album vs track menus differ) rather than a chooser. Visual distinction is **glyph + type word in
  the subtitle** (Material can't badge artwork, and the no-image-libs rule bars server compositing): `♫` (U+266B)
  = multi-track release (Album/EP), `♪` (U+266A) = single track (Single release OR individual Track); subtitle
  reads Album/EP/Single/Track. **Release-type classification is "service type, count fallback"** — prefer Qobuz's
  authoritative `getAlbum→release_type`, else a resolved-track-count heuristic (1=Single, 2–6=EP, 7+=Album) — and
  is done **before** the row is inserted (`_classifyThenAdd`, async + `setStatusProcessing`) so the list never
  shows a wrong "Album" that flips to EP/Single on refresh. **AMENDED 2026-07-29 — this classify-before-insert
  rule now applies ONLY to an UNKNOWN type; a type a SOURCE ASSERTS inserts immediately and is corrected in the
  background. See "Release type: why an asserted type is not classified before insert" below. Do not re-argue
  it from this paragraph.** Track/album Played states are independent (a saved
  track marks Played on newsong via `findTrackByUrl`/`findSavedTrack`). **Streaming-track detection is favurl-based,
  not category-based**: Material collapses a Qobuz album-drill track row onto `online-album` (its `wa` is-track flag
  is false), so `Sources::favurlIsTrack` (a `.flac`/`/track/` play url with no `album:`) is the reliable tiebreaker.
  **Now Playing** (Material can't drill from a top-level custom action — `getSectionActions` renders a FLAT list):
  top-level default = **Add track** (the `track` category, `[$trackBase]`); **Add album** lives in the TrackInfo
  "… → More" (`_trackInfoHandler`, album-only). Classic skin therefore reaches only Add album from a track row.
- **0.1.79** — **A streaming track whose release is a SINGLE is stored AS the Single, and track↔single never
  duplicate.** Two coupled fixes to "adding a single from Now Playing gave two rows (a Track, then a Single) that
  didn't reconcile". **(1) Track-add classification** — `_saveTrackRecord` now, for a Qobuz/Tidal/Deezer track with
  a recoverable album id, classifies the release and, if `single`, stores it in the **album (Single) form** instead
  of `kind='track'` (`_saveTrackClassify`, async + `setStatusProcessing` + 6s timeout). The album id comes
  SYNCHRONOUSLY from the service's cached playing-track metadata via `Sources::trackAlbumId`
  (`ProtocolHandlers->handlerForURL->getMetadataFor` → `albumId`/`album_id`); Qobuz uses the authoritative
  `release_type`, Tidal the resolved-track count. **Deezer** (its `getMetadataFor` flattens the album object to a
  bare title, dropping the id) and **Bandcamp** (no native album id) can't classify from Now Playing, so they
  degrade to storing a plain Track. Because the Single form shares the album 3-segment dedupe key, a later "Add
  album" of the same single is a natural no-op. **(2) Cross-kind single reconcile (all services, no extra API
  calls)** — for the degraded/reverse cases: `_finishAlbumAdd`, when inserting a `single`, no-ops if a matching
  track already exists (`DB::findTrackByArtistTitle`, a `artist|%|t:title` LIKE), and `_insertTrackRow` no-ops if a
  matching `single` album already exists (`DB::findByArtistAlbum` + `rel_type eq 'single'`); both guarded on a
  known artist so a bare-title match across artists can't misfire. So a single and its lone track are treated as
  the same recording and never both stored; a genuine multi-track album's track still coexists with its album (an
  accepted edge: a 2-track single's A-side track + the single release are treated as the same release). Per-service
  album-id + release-type signals verified from plugin source — see memory
  `streaming-track-album-id-signatures`. `perl -c` clean; no matcher change (matcher_sync_check LL variants still
  pass; the DSC-vs-others drift it reports is pre-existing and unrelated).
- **0.1.80** — **Fix: 0.1.79 skipped classification for STREAMING BROWSE-track singles (reported: "Tidal singles
  add purely as tracks").** A browse track row carries no `$ALBUMNAME` (and a browse add has no Now-Playing
  fallback), so the 0.1.79 classify gate `defined $album && length $album` was false → it stored a plain Track,
  never detecting the single. The album NAME was never needed to classify (that needs only the album ID, recovered
  inside `_saveTrackClassify` from the service's cached metadata); it's only needed to LABEL the stored Single, and
  a single's release title is the track title. Fix: gate on `_canClassifyTrack($source) && $request->client` only,
  and default the Single record's `album_title` to the track title when no album name arrived. Affected Tidal AND
  Qobuz browse-track adds equally (the earlier Qobuz confirmation was via LBF Now Playing, which DID carry an album
  name). Added a WARN diagnostic (`LL: track-classify source=… url=… albumId=…`) so a live add can be traced via
  `curl http://plex:9000/log.txt`.
- **0.1.81** — **Code-review fixes on the 0.1.74–0.1.80 track work** (no new feature). **(1) The same track saved
  from two SURFACES no longer makes two rows.** The track dedupe key carries the PARENT ALBUM, and the album name
  depends on where the add came from: a queue / Now Playing row sends `$ALBUMNAME`, a streaming BROWSE track row
  sends none (`online-track` has no `name:` param), so the same track landed as `artist|the album||t:x` one way and
  `artist|||t:x` the other — different keys, which `DB::add`'s exact-key `findAnyByKey` can't reconcile.
  `_insertTrackRow`'s existing cross-kind single guard now also runs **`DB::findTrackByArtistTitle`** (`artist|%|t:title`
  — album segment wild), catching it in either order. Same class of hole on the YEAR segment for singles:
  `_finishAlbumAdd` now also checks `DB::findByArtistAlbum` (year-agnostic) and no-ops when that row is **also**
  `rel_type='single'` — the rel_type gate is what keeps 0.1.43 (two same-titled ALBUMS from different years still
  coexist). Verified against real in-memory SQLite (`scratchpad/verify_track_dedupe.pl`, 10/10: both orderings
  caught, no false positive on a sibling track or a same-titled track by another artist, 0.1.43 preserved).
  **(2) A saved track is no longer marked Played the instant it starts.** `Played::_markPlayedTrack` marked on
  `newsong` with no threshold (unlike albums), so merely SKIPPING PAST a saved track marked it Played — and
  `purgePlayed` (which filters on `status='played'` alone, no `kind`) then deleted it `played_retention_days`
  later. The record is still LOOKED UP at newsong (metadata is freshest there) but the mark is deferred by
  **`_armTrackMark`**: a `Slim::Utils::Timers` timer at `played_threshold`% of `$song->duration` (the same pref the
  album path uses), falling back to 60s when the song reports no duration, floor 5s. At fire time it re-checks that
  the same url is still playing, that `watch_outside` is still on, and re-reads the row's status. One pending mark
  per player, cancelled on new song / stop / clear / `shutdown`. **(3) Dead code removed:** the info-provider track
  path was fully written but never wired — `Sources::captureTrackFromTrack` had no callers, so nothing ever
  produced a `kind='track'` record, making `_addItemFor`'s kind block and `_addCommand`'s `kind:track` branch
  unreachable and `PLUGIN_LL_ADD_TRACK`/`_WISHLIST` unused. All deleted; the `_saveTrackRecord` header (which
  claimed two callers) corrected to say the Material `addctx` action is the only entry point — **so Classic skin
  has no individual-track add**, as 0.1.74–0.1.78 already documents. **(4) `Sources::favurlIsTrack` hardened:** the
  decisive-negative test now covers `playlist:`/`artist:`/`mix:` as well as `album:`, and the fail-open `return 1`
  logs a WARN naming the url — nothing enforces the "an album favurl is empty or carries `album:`" invariant, so if
  a SUPPORTED service ever emits an album favurl in an unrecognised shape its albums would be stored as
  `kind='track'` rows pointing a `type => 'audio'` item at a non-audio url (rows that can't play); now that shows
  up in `log.txt` as a named suspect instead of silently. `perl -c` clean on all five modules. No matcher change
  (`matcher_sync_check.py` reports `LL variant OK`; its non-zero exit is the pre-existing DSC-vs-PFR
  `_albumMatches` drift noted in 0.1.79).
- **0.1.82** — **Fix: a streaming SINGLE (or short EP) could NEVER auto-move to Played.** Reported as "played a
  track through and it's still in my LL list"; diagnosed from `curl http://plex:9000/log.txt` — the row logged as
  `_finishAlbumAdd … rel=single`, i.e. `kind='album'`, so the individual-track Played path was never involved.
  **Root cause, opened by 0.1.79:** that release stores a streaming single in ALBUM form, so it goes down the album
  Played path — where `_totalTracks` returns undef for anything not `library`, and `_maybeMark` therefore falls to
  the `streaming_min_tracks` floor (default **4** distinct tracks). A single has ONE track, so `$seen` maxes at 1
  and `1 >= 4` is never true. EPs with fewer than `streaming_min_tracks` tracks were broken identically. The
  `rel_type` column added in 0.1.74–0.1.80 was exactly the missing signal but Played never read it. **Fix:**
  `_totalTracks` returns **1** for a `rel_type='single'` record (that is what the classification means — Qobuz's
  authoritative `release_type` or a resolved count of 1), so it takes the known-total branch and needs
  `ceil(60% × 1) = 1` track; and `_maybeMark` caps the streaming floor at **2** for `rel_type='ep'` so a 2-track EP
  can still complete. `%tracking` now carries `rel_type`. Streaming ALBUMS and legacy `rel_type IS NULL` rows keep
  the 4-track floor unchanged; library albums are untouched. **Also: the Played marking log lines are WARN, not
  INFO** — INFO is invisible in `log.txt` unless the category is raised, which is precisely what made this
  undiagnosable from a log dump (see the CLAUDE.md testing note). Existing rows need no re-add: the fix reads
  `rel_type` at play time. Verified with `scratchpad/verify_played_threshold.pl` (12/12 across single / EP /
  album / unknown-type / library).
- **0.1.83** — **A one-track release moves to Played when it has actually been PLAYED THROUGH, not when it
  starts.** 0.1.82 gave a Single a real total of 1, which made the counter say "1 of 1 seen" on the very first
  `newsong` — so a Single was marked the instant it started, the same "skip past it and purgePlayed deletes it"
  flaw 0.1.81 removed from individual tracks. **Unified:** anything whose Played status rests on ONE track — a
  saved `kind='track'` row, a Single, or a 1-track library release (`_totalTracks == 1`) — now bypasses the
  distinct-track counter entirely and takes the deferred played-through check. `_onChange` routes it to
  **`_armDeferredMark`** (the generalised `_armTrackMark`), which fires at **`TRACK_MARK_FRACTION` = 90%** of
  `$song->duration` — NOT the actual end, because the last seconds are usually fade/silence and with crossfade or
  gapless the next song's `newsong` (which cancels the pending mark) arrives BEFORE the current track's audio
  truly ends; 90% always lands before that hand-off. Was `played_threshold`%, which is documented as a % of an
  album's TRACK COUNT — a conflation. **Pause-correct:** the timer body **`_deferredMarkTick`** re-reads
  `$client->songElapsedSeconds` and, if actual playback is short of the target (paused, or seeked back), re-arms
  for the shortfall instead of marking — so the wall clock coming round is never mistaken for listening. It's a
  NAMED sub, not a closure, so `setTimer`/`killTimers` pair on the coderef and a re-arm can't build a
  self-referencing closure chain. Still guarded on `watch_outside` and the same-url check at fire time, still one
  pending mark per player, cancelled on new song / stop / clear / shutdown. Streams reporting no duration keep the
  flat `TRACK_MARK_FALLBACK_SECS` (60s) wait. **EPs and albums are untouched** — they keep the distinct-track
  counter (EP floor capped at 2 per 0.1.82). Verified with `scratchpad/verify_played_flow.pl` (19/19: routing per
  release type, skip-after-2s and halfway both held, 90% and end-of-track both marked, pause re-arms, and the
  counter path unchanged).
- **0.1.84** — **Podcast episodes.** An episode from the built-in **Podcasts app** can be saved from its browse
  row, storing as an ordinary `kind='track'` record — so replay, dedupe and the 0.1.83 played-through Played
  check all come from the existing track machinery unchanged. The menu entry reads **"Add podcast to Listen
  Later" / "… to Wish List"**. See "Podcast episodes" below for the measured constraints.
  New `Podcast.pm` (feed fetch/parse/resolve), `kind:podcast` add path (`_savePodcastEpisode`),
  `Sources::_serviceCan('podcast')`, "Podcast" type word in the row subtitle (source segment dropped so it
  doesn't read "Podcast · <show> · Podcast"). Verified against the live server + the real Darko.Audio feed:
  parser returns **129 episodes, exactly matching the 129 the browse query reports**; the row's `$IMAGE`
  unwraps to the RSS `itunes:image` byte-for-byte; the title key matches too; duration 3485s == the row's
  "(58:05)".
- **0.1.85** — **Podcast episodes save from ANY container, not just the Podcasts app** (reported: "context
  still says add album and it doesn't add it" — the add was coming from a favourited FEED, `svc=favorites`).
  Last-resort resolve before `_addCtxCommand` rejects; type-neutral wording on `favorites-*`; and **no Wish
  List entry for podcasts** (you don't buy podcasts) with a generic-container wishlist add redirected to
  Listen Later. Detail in "0.1.85 — episodes reached through OTHER containers" below.
- **0.1.87** — **Podcast rows use ❝ (U+275D) instead of the ♪ note**, so speech is distinguishable from music at a glance; `GLYPH_PODCAST` in `Browse::_glyphFor`, keyed on `source eq "podcast"`. No plain-text microphone exists — see "Glyph" in the Podcast section below for why. *(Glyph PLACEMENT changed in 0.1.93: it now leads `line2` beside the type word, not the title.)*
- **0.1.86** — **One plain wording for every row: "Add to Listen Later" / "Add to Wish List".** A browse ROW
  already tells you what it is (you're looking at an album, a track, a podcast episode), so naming the type in
  the menu is noise — and Material can only name it per CONTAINER, which gets it wrong on any mixed list. The
  ONE exception is Material's **Now Playing** panel: there you're outside any listing, so "this track" and
  "the album it's from" are both plausible and the entry has to say which — it keeps **"Add track to Listen
  Later" / "Add track to Wish List"**, with the album option qualified alongside it in "… → More"
  (`PLUGIN_LL_ADD`/`_WISHLIST`, the TrackInfo provider, which can drill). Roles collapse to
  **plain / nowplaying / podcast**. Podcasts use the plain wording with **no Wish List entry** (0.1.85).
  **`favorites-*` is dropped again**: it existed in 0.1.85 solely to get neutral wording there, and now that
  every row-level entry is neutral, favourites inherit exactly the right wording from the `online-*` fallback
  (the last-resort podcast resolve supplies the behaviour). A leftover empty from the 0.1.85 build is cleared
  by the strip pass and then removed by the delete-empties pass, so it can't linger and SUPPRESS `online-*`
  (the 0.1.52 rule). Wording map verified by extracting `%roleTitle` + `%cats` from the source and printing
  every category's entries.

- **0.1.88** — **A claimed 'single' is verified, and every streaming release remembers its track
  count.** Two failure modes of the same root cause: LL reads `rel_type='single'` as "this release
  has exactly ONE track" (`Played::_totalTracks` returns 1 → 0.1.83's played-through mark), but the
  sources that ASSERT a type don't mean it that way. MusicBrainz (via LBF's `&rt=` handshake, LBF
  0.9.141) types a release group Single however many B-sides/remixes/radio edits it carries, and
  **Qobuz's `release_type` does the same** — so a 3-track single was marked Played after track one.
  Mirror case: a release MB correctly calls an Album that holds ONE track fell on the
  `streaming_min_tracks` floor of 4, which it can never reach, so it could never be marked at all.
  **Fix, in three parts.** (1) `Sources::singleIsWrong($type,$count)` — a claimed single with a
  count > 1 isn't one; `relTypeFor` applies it (library adds settle synchronously, the count is
  free) and `_settle` applies it to every async classify. Demotion goes to the COUNT's verdict
  (2-6 = ep, 7+ = album), NOT unconditionally to 'ep' — calling a 9-track release an EP just
  re-runs the same early-mark bug against the EP's 2-track floor. A claim with NO resolvable count
  stands (unchanged behaviour beats a guess). (2) New **`track_count`** column (`user_version < 3`
  migration, `DB::updateTrackCount`, which OVERWRITES — unlike `updateRelType` — since it's a
  re-measurement). `Played::_totalTracks` now reads library live → stored count → the `single`⇒1
  fallback, so a resolved streaming release gets the same `played_threshold`% rule as a library
  album and the flat floor applies only to unresolved ones. (3) `Browse::_albumTracks` refreshes
  the count on every resolve and force-corrects a stored single that resolves to >1 track — this is
  what repairs rows saved before 0.1.88, free, from a resolve that was happening anyway.
  **Performance shape (the point that was iterated on):** the add must NOT wait on a service. A
  known type (library or `&rt=`) inserts immediately as before; `_verifyRelease` then chases the
  count fire-and-forget AFTER the insert (same pattern as `_backfillStreamingArtist`), gated on the
  row having a native album ID — without one the lookup would fall back to `_searchService`, and
  the SEARCH is the expensive half, so those rows just wait for their first play. Only an UNKNOWN
  streaming type still blocks (pre-existing `_classifyThenAdd`; a row that flips label on refresh
  is worse). **Qobuz costs zero extra calls**: its album object carries `tracks_count` alongside
  `release_type`, so `Sources::albumTrackCount` reads both off the one fetch and NO tracklist is
  resolved (verified: 0 tracklist fetches on every Qobuz path with a count). Tidal/Deezer/Bandcamp
  have no album-object surface on their ID path — `getAlbum` returns the TRACKLIST — so they cost
  one background call, which is the same call the first play would have made anyway. **This is
  settled, not assumed**: per `streaming-track-album-id-signatures` (verified 2026-07-25 from each
  plugin's source), Tidal album objects DO carry `type`+`numberOfTracks` and Deezer's carry
  `record_type`+`nb_tracks`, but only on the raw `albums/<id>` / `album/<id>` endpoints the plugins
  don't surface — and **reaching into those private internals was DECLINED (Simon, 2026-07-25:
  breaks on plugin updates), so catalogue-side single/EP detection is Qobuz-only BY DECISION.
  Don't re-attempt it.** What is legitimately reachable is those plugins' own public SEARCH
  results, whose raw album hashes carry the counts (`_searchService`'s Tidal/Deezer branches) —
  unused here only because the search is the expense being avoided. Hence those two field names in
  `albumTrackCount` are inert today, kept because they're verified and reachable without going
  private. **Catalogue vs
  playable — CORRECTED 2026-07-30, this was a real bug:** Qobuz's `tracks_count` is the catalogue
  count and can exceed what's playable in a region. 0.1.88 stored it as the total and called it
  "provisional, overwritten by the first drill/play" — but that overwrite only happens on a
  drill/play **from the LL list**, so a release heard from Qobuz's own pages (i.e. what
  `watch_outside` exists for) kept the inflated total indefinitely, needing 60% of tracks that don't
  exist for that user — **strictly worse than the 4-track floor it replaced.** Now
  `classifyRelType` returns a THIRD value marking a catalogue count PROVISIONAL; it settles the
  type (what the fetch is for, and the `singleIsWrong` demotion still works) but is never stored as
  the total. A total now comes only from a resolved TRACKLIST, which the service has already
  region-filtered. Provisional counts are still passed back so `_verifyRelease` can tell "the
  service answered" from "unreachable" — otherwise every Qobuz add would spend a pointless retry
  and log a failure that never happened. `_finishAlbumAdd` also skips the background verify when a
  classify already saw a provisional count (`_provisionalCount` on the rec, not a DB column), since
  re-fetching the same album object would return the same number. Residual, accepted: a release
  Qobuz explicitly asserts is an `album` while holding 2-6 tracks now waits on the floor until its
  first play — narrow, because a small count classifies itself (1 → single → total 1; 2-6 unasserted
  → ep → floor capped at 2). If it bites, the fix is to let a provisional total only ever LOWER the
  bar (`need = min(pct of it, floor)`), never raise it — sound because a catalogue count can only
  exceed the playable one. Covered by `t_reltype.pl` (producer) and `t_verify_retry.pl` (consumer);
  both were checked against the unflagged code and fail there.
  Podcasts are untouched (episodes insert as `kind='track'`, never the album path). Verified by
  four scratch suites (61 checks): `relTypeFor`/`singleIsWrong` truth table, the full
  `classifyRelType` decision table against a stubbed service, the Qobuz zero-tracklist path, and
  real-SQLite migration/persistence + every `_totalTracks` branch. No matcher change
  (`matcher_sync_check.py` still reports LL variant OK on all three pinned subs).

- **0.1.89** — **`&tc=` handshake: the sibling sends the release's TRACK COUNT, so 0.1.88's
  background lookup disappears for LBF adds.** Completes what LBF 0.9.141's `&rt=` should have
  carried: LBF already reads a count off the streaming service's own album hash while matching
  (`_candReleaseType`, since 0.9.89), on the same items, ~11 lines before `_attachFavUrl` builds the
  favurl — so the number was in hand and unused, and `&rt=`'s bare MusicBrainz "Single" is exactly
  what needed checking against it. **Receiver ships FIRST** (this release): an updated LBF must
  never meet an LL that can't strip `tc=`, or the param is left in the favurl. With no sender
  present this release is behaviourally identical to 0.1.88. Reader sits with the other private
  params in `_addCtxCommand`: `s{[?&]tc=([^&]*)}{}` — strips ANY value so nothing is left behind,
  THEN validates `^\d{1,3}$ && > 0` (a bogus/huge count would set an unreachable Played threshold
  at 60% of nonsense; junk → undef → falls back to resolving). Feeds `relTypeFor(service => rt,
  count => tc)`, so `singleIsWrong` fires at INSERT time with **zero service calls**; stored as
  `track_count` (streaming only — library counts live), which automatically suppresses
  `_verifyRelease` via its existing `!$rec->{track_count}` gate (no new logic). Bonus: the type is
  correct BEFORE `_finishAlbumAdd`'s single-dedupe block, so a mislabelled single can no longer
  be wrongly no-op'd against a saved track of the same name. `DB::add`'s `_sane()` is a second
  guard. **The receiver did NOT work as shipped** — it discarded every count; see the `&tc=` lesson
  in the regression-tests section, including why the 24-check `verify_favurl_params.pl` (since lost
  to a scratchpad) could not have caught it. Fixed 2026-07-30, and the extraction now lives in
  `_stripPrivateParams` with `tools/t_favurl.pl` calling it: real LBF Qobuz/Bandcamp/`&al=` favurl
  shapes, tc first/last/alone, `a=` still not eating `al=`, junk values stripped-then-rejected, and
  native Qobuz/Tidal/Deezer favurls byte-for-byte untouched. **Bandcamp gets no `&tc=`** (no count
  until its page is fetched) and falls back to the background resolve. **Catalogue-vs-playable —
  CLOSED 2026-07-30, `&tc=` no longer fills `track_count`.** LBF reads its count off a service
  ALBUM HASH, so it is a catalogue count — exactly what the Qobuz path now refuses — and it arrives
  as a bare integer with no provenance, so LL can't tell a resolved count from a catalogue one and
  must assume the unsafe case. The rule is now uniform: **only a count resolved from a real
  TRACKLIST ever becomes Played's total, whichever door it came in by.** `&tc=` is still read and
  still fed to `relTypeFor`, because disproving a claimed 'single' AT INSERT is the one job only an
  add-time count can do — a 'single' still standing at insert can be swallowed by `_finishAlbumAdd`'s
  cross-kind dedupe against an already-saved track of the same name, and no background correction
  repairs a row that was never inserted. Consequence, accepted: `&tc=` no longer suppresses the
  background `_verifyRelease`, so it stops being a saved service call — on Tidal/Deezer that verify
  now yields a REAL total, on Qobuz it returns a provisional one it won't store and the total waits
  for the first play. That is the same call an add without `&tc=` always made, so nothing regressed.
  Mostly moot in practice anyway: per `streaming-search-no-track-count` the SEARCH payloads LBF
  matches against carry no count at all, so `&tc=` rarely arrives. **No LBF change is needed or
  wanted** — don't ask the sibling to start sending counts for Played; if it ever sends one it is
  used for the type check and nothing else. Covered by `t_addpath.pl`.

- **0.1.90** — **A failed release-verify is retried once, and never fails silently.** 0.1.88's
  `_verifyRelease` is fire-and-forget; its callback did nothing AND logged nothing when no count came
  back, so a service briefly unreachable at add time left the unverified `single` claim standing →
  `Played::_totalTracks` reads it as a real total of 1 → marked Played after ONE track → purged days
  later. That is 0.1.88's own bug, reachable through its own failure path. **Fix:** both failure
  routes (a callback with no count, and a synchronous die — the latter previously didn't retry at
  all) go through `_armVerifyRetry`, which arms ONE retry at `VERIFY_RETRY_SECS` (60s) via
  `_verifyRetryTick` and logs whichever it does. `VERIFY_MAX_ATTEMPTS` = 2 caps it: an unbounded
  retry hammering a service would be worse than the bug. `_verifyRetryTick` is a **NAMED sub** (the
  0.1.83 `_deferredMarkTick` lesson) and RE-READS the row, so a removed row or one already resolved
  by a drill/play is left alone; no live client → give up rather than pretend.
  **The corroboration alternative was REJECTED, do not build it:** gating the single fast-path on
  `rel_type='single' AND track_count=1` would put every pre-0.1.88 single (no stored count) back on
  the 4-track floor, re-opening **0.1.82**. Heal the row; don't punish rows that predate the check.
  Covered by `tools/t_verify_retry.pl`. **Not covered offline:** the timer actually FIRING — that
  needs the server.

  **0.1.90 also carries a full code review of the 0.1.88–0.1.90 work (2026-07-30). Five findings,
  all fixed before release — none of this ever shipped:**
  1. **The `&tc=` receiver was completely inert.** `$1 =~ /^\d{1,3}$/ && $1 > 0` — the validation
     match is capture-less, and a SUCCESSFUL match resets `$1` to undef, so every count was
     discarded. Silent, because `Plugin.pm` has no `use warnings`. Fixed by copying the capture out
     first; the extraction moved to `_stripPrivateParams` so it is testable at all. See the lesson
     in the regression-tests section — it shipped "verified" by a suite that could not fail.
  2. **A FAILED resolve stamped `track_count=1`** (`Browse::_albumTracks`): the display fallback put
     the "no match" text row back and it was counted as a playable track, so a 10-track album whose
     resolve merely failed was marked Played after one track, and a real stored count was clobbered.
     Now counted before the fallback can restore anything.
  3. **Qobuz's CATALOGUE count became Played's total** — see the corrected "Catalogue vs playable"
     note in the 0.1.88 entry. Now flagged provisional and never stored; the same rule was then
     applied to `&tc=`, which is the same kind of number arriving by a different door.
  4. **A resolved type was thrown away** unless it demoted a wrong 'single', so a row inserted NULL
     by `_classifyThenAdd`'s timeout showed "Album" for good. Now fills a NULL, unforced.
  5. **The verify gate asked "is there an album id"**, which is the wrong question for Bandcamp
     (`get_album` scrapes the album PAGE url) — an id-only Bandcamp row spent the full service
     SEARCH the gate exists to refuse. Predicate unified into `Sources::hasDirectAlbumRef`.

  **A SECOND review pass then found three more, all fixed (2026-07-30). All three came from
  the same mistake in the first fix — a rule applied to one consumer of a number and not the
  other:**
  6. **`$prov` gated `updateTrackCount` but not the single→ep demotion**, so a claimed single
     contradicted by a CATALOGUE count became `rel_type='ep'` with `track_count` NULL → the EP
     floor of 2 → a release with one playable track could never be marked, where **0.1.87
     marked it**. (The demotion itself arrived with 0.1.88, which failed the same case by the
     other route — `ceil(60% × 3)`; the provisional fix moved the failure, it didn't cause it.)
  7. **Same inconsistency at add time** (`&tc=`): the comment refuses to store the count as a
     total because it "can only ever be >= the playable count", then hands it to `relTypeFor`
     anyway.
  8. **`_verifyRelease` had a third failure route**: a callback that never ARRIVES fired
     neither the no-count branch nor the die branch, so no retry and no log — the silent
     give-up 0.1.90 claims to have removed. Now guarded by a `VERIFY_TIMEOUT_SECS` (6s) timer,
     the shape `_classifyThenAdd` already used, with a `$done` flag so a late answer can't act
     after the timeout has.

  **The fix for 6 and 7 is one line, at the source rather than at the two call sites**, and it
  rests on a rule worth keeping: **a provisional count may LOWER the Played bar, never RAISE
  it.** Deriving a type from a count only ever lowers it (1 → single needs 1, 2-6 → ep needs 2,
  both below the 4-track floor); the ONE exception is demoting a claimed single, which goes
  1 → 2. So `classifyRelType` short-circuits on a catalogue count *except* when it would
  demote a single, where it resolves the real tracklist instead — one extra call, only in the
  ambiguous case, and it returns a REAL count (storable) plus a type settled from it.
  **The rejected alternative:** gating `singleIsWrong` on `$prov` (i.e. never demote on a
  catalogue count) re-opens 0.1.88's bug for the COMMON case — most MB "singles" of 2-3 tracks
  are fully playable, and they would all mark Played after one track and be purged. Don't.

  **The test that defended the bug.** `t_reltype.pl` asserted `a 3-track "single" is still
  demoted → 'ep'` — the buggy behaviour, pinned as correct. Rewritten. A suite that encodes the
  wrong invariant is worse than no suite, because it argues for the defect.

  **The tests are the other half of this release.** The repo went from 5 suites / 128 checks to
  **8 / 267**, adding `t_favurl.pl`, `t_resolve_count.pl` and `t_addpath.pl` — the last covering the
  ADD PATH end to end, which had no coverage at all and is the route finding 1 walked through. Every
  new suite was run against the bug it claims to catch before being called done; that check is now a
  documented rule, because two of these bugs shipped past tests that could not fail.

- **0.1.92** — **The SERVICE's own label is kept beside the clean title, so Played can still
  find the row (`ref.svc_title`).** The hole `&al=` opened, found while code-reviewing LBF
  0.9.144 and confirmed against Simon's live list before building.
  **The premise `&al=` rests on is only half true.** It hands us the MusicBrainz release name
  as the authoritative title, which is right for DISPLAY and for the dedupe key. But MB
  deliberately keeps a release's distinguisher **outside** the title: all four American
  Football LPs are titled exactly `American Football`, and `LP2`/`LP3`/`LP4` live in MB's
  `disambiguation` field — verified against the MB API and against the live mirror. Qobuz
  prints `American Football (LP2)`. So the stored title and the PLAYING title genuinely differ.
  **Why that breaks Played and nothing else.** `Played::_matchRecord`'s streaming branch has no
  album-id anchor — it matches on artist + album TITLE only — and `DB::_norm` deliberately KEEPS
  `(LP2)` (that is what lets the dedupe key tell editions apart). Bare name stored + qualified
  name playing = never marked, **silently**: the album plays perfectly and just never leaves the
  list. Replay is NOT affected — `buildPlayableItems` prefers the captured album id
  (`hasDirectAlbumRef`) and LBF/PFR rows always carry one, so `_bestMatches`' `(LP4)`-preserving
  ranking never even runs for them. Display degrades (three rows reading "American Football",
  separated only by the year) — accepted, see below.
  **Fix: keep both.** `_addCtxCommand` stores Material's raw row label as `ref.svc_title` when
  it differs from the title actually saved (JSON, no migration, no schema change — and NOT an
  input to `dedupeKey`, so the whole point of `&al=` is undisturbed). `Played::_matchRecord`
  gains a THIRD and LAST pass over `DB::findBySourceRefTitle`, with the same `_artistMatch`
  guard the existing fallback uses. Being last, it can only ever rescue a miss — it cannot
  change which record an already-matching play resolves to.
  **APPENDING MB'S `disambiguation` WAS THE FIRST PLAN AND IT IS WRONG — do not build it.**
  Sampling **120 release-groups straight from a live LB fresh-releases feed** against the mirror:
  exactly **1** carries a disambiguation, and it is `The Vampire Lestat OST` — editorial PROSE,
  not a service-style qualifier. Appending it yields `The Failures (The Vampire Lestat OST)`,
  which matches nothing on any service and breaks the key it was meant to fix. It is also not
  free: the LB feed carries no such field (confirmed — 12 keys, none of them disambiguation), so
  it needs one MB lookup per release-group, and the trending path resolves in bulk. American
  Football's `LP2` happening to be exactly Qobuz's spelling is a COINCIDENCE, and generalising
  from it was the error the sample caught.
  **Accepted limits:** future adds only (nothing exists to repair older rows from — the
  population was zero at ship time); and Bandcamp coverage is unverified, since its search rows
  read `Title (Album)` but what a PLAYING Bandcamp track reports as its album wasn't checked.
  Neither is a correctness risk — the new pass is an OR, so it can only add matches.
  Covered by `t_addpath.pl`, which drives the real add path into SQLite and then the real
  `_matchRecord` over it; **anti-tested both ways** (sender removed → 2 failures, receiver
  removed → 1), with the decisive assertion failing `NO MATCH` in both.

- **0.1.93** — **The Played threshold moves to 90% rounded DOWN; the length measure can no
  longer get permanently stuck; the row glyph moves off the title.**
  (1) **Threshold 60 → 90**, arithmetic extracted to `Played::tracksNeeded`, rounded with
  `floor` and never below 2 for a multi-track release, plus a one-off `threshold_90_migrated`
  bump so existing installs actually move. Full reasoning in "The Played threshold" above —
  **read it before changing either the percentage or the rounding**, the two interact and
  `ceil` at 90% silently means 100% for anything under ten tracks.
  (2) **`Played::_learnTrackCount`'s in-flight guard is a TIMESTAMP, not a flag**
  (`COUNT_STALE_SECS` = 60). Found by code review and CONFIRMED by probe: a request the
  service accepts and never answers runs none of our code, so the boolean was never cleared
  and that release could never be measured again for the life of the server — it sat on the
  flat `streaming_min_tracks` floor permanently, so anything shorter than the floor could
  never reach Played. **That is 0.1.90's own bug returning through 0.1.90's own failure
  route.** Deliberately NOT a timer: nothing has to HAPPEN on expiry and it is read in one
  place, so a lazy check at the single read site avoids the arm/kill/pair machinery and the
  ordering-bug class that 0.1.83's re-arm chain and 0.1.90's `$done` flag both had to fix. It
  also covers a failure no `$cb`-based guard can see — a die inside the SERVICE's own async
  handler, where nothing of ours runs. 60s because it must exceed the services' own HTTP
  timeout (Qobuz's `SimpleAsyncHTTP` uses 15s) or a slow-but-live request gets duplicated.
  Covered by `t_learn_count.pl`, anti-tested (2 failures against the boolean guard).
  (3) **The ♫/♪/❝ glyph moved from the NAME line to `line2`**, ahead of the type word and
  source (`♫ Album · Qobuz`); the title is a plain `Artist – Album (Year)` again. 0.1.86 had
  put it on the name line. Beyond reading wrong, it was a live hazard: an LL home-shelf card's
  `$ALBUMNAME` is the row's DISPLAYED name and the `LLHome-album` suppressor never worked on
  the carousel, so an add from there would have stored the glyph verbatim in `album_title` —
  the 0.1.71 pollution shape. Checked live before changing: no stored title carried a glyph
  (each of 49 rows rendered exactly one, and the renderer always prepends exactly one), so
  nothing needs repairing. Pinned in `t_resolve_count.pl` on BOTH lines, in both directions.
  (4) **Both siblings now send the SERVICE's album title in `&al=`** — see the fleet rule
  above — and `tools/add_naming_check.py` is the harness for verifying it.
  (5) `tools/t_stubs.pl` gains **`TestClock`**, a `CORE::GLOBAL::time` override, so
  elapsed-time behaviour is testable without sleeping. The override must be installed before
  any plugin module compiles; the existing `require`-then-`ll_require()` order guarantees it,
  **so don't move `ll_require()` above the stub require**. `Slim::Schema` also gains
  `find('Album')`, defaulting to NOT FOUND so a year test can't pass vacuously.
  (6) **Years on native and library adds** — `Sources::serviceYear` (hash-wide, epoch-aware,
  ported from PFR) and `Sources::libraryAlbumYear` (local DB, because Material has no `$YEAR`
  variable). See "Year backfill" for the per-source table and why Tidal/Deezer/Bandcamp
  natives stay yearless BY DECISION.

## Regression tests — RUN THESE BEFORE ANY BUILD (added 2026-07-29)

    sh tools/t_all.sh          # one line per suite, non-zero exit on any failure
    sh tools/t_all.sh -v       # every case, for when one fails

Needs only perl + DBD::SQLite. **No LMS install and no server** — `tools/t_stubs.pl` fakes just
enough of the `Slim::*` tree to load the plugin's real modules, and `ll_require()` in there works
around the fact that the package names (`Plugins::ListenLater::*`) match the INSTALLED layout while
a checkout has no `Plugins/` parent.

**Why this exists.** Until 0.1.90 this repo had no committed tests at all. The invariants lived only
as prose in this file, every round of work re-derived them by hand, and 0.1.88 broke one that had
been settled in 0.1.74–0.1.80. Verification scripts WERE written in earlier rounds
(`verify_played_flow.pl`, `verify_track_dedupe.pl`, `verify_played_threshold.pl`) but lived in
session scratchpads and are gone — so nothing carried forward. Anything worth verifying belongs in
`tools/`, committed, named after the behaviour it protects.

| suite | protects |
|---|---|
| `t_db.pl` | dedupe keys and migrations against real SQLite: 0.1.43 (same title, different year), 0.1.33 (cross-source), 0.1.74+ (track vs album keys), 0.1.81 (same track from two surfaces), 0.1.88 (`track_count`, forced `rel_type`), and an old schema file upgrading with its rows intact |
| `t_played.pl` | the thresholds that keep regressing in both directions: 0.1.82 (a single/short EP CAN reach Played), 0.1.83 (a one-track release does NOT mark when it starts), 0.1.88 (a real total beats the 4-track floor), plus the live-library-count rule |
| `t_reltype.pl` | 0.1.88's classification: `singleIsWrong`, the full `relTypeFor` table, `classifyRelType` end to end, that the Qobuz album-object path fetches **no** tracklist, and that a CATALOGUE count comes back flagged provisional while a resolved one doesn't (the flag is the only thing stopping an inflated Played total) |
| `t_verify_retry.pl` | 0.1.90's retry: that it retries, retries EXACTLY once (an unbounded retry would be worse than the bug), never gives up silently, and re-reads the row first — plus the three distinct answers `_verifyRelease` must keep apart (real count → store; provisional → neither store nor retry; no count → retry) |
| `t_learn_count.pl` | 0.1.93's in-flight guard on `Played::_learnTrackCount` and specifically its EXPIRY: that a lost request stops blocking after `COUNT_STALE_SECS`, that it is logged rather than swallowed, that an answered request stays immediately re-askable, that records don't block each other, and that a library release is never asked at all. Uses `TestClock::advance()` |
| `t_favurl.pl` | the private favurl handshake (`Plugin::_stripPrivateParams`): `?cover=`/`?b=`/`&a=`/`&y=`/`&al=`/`&rt=`/`&tc=` — what each yields, that junk is stripped-but-rejected, that `&a=` can't eat `&al=`, that `&rt=`+`&tc=` really do reach `singleIsWrong`, and that a NATIVE favurl comes back byte-for-byte unchanged with no field set. Calls the real sub — see the `&tc=` lesson below |
| `t_addpath.pl` | the ADD PATH end to end — a Material action into `_addCtxCommand`, out as a row in SQLite. Also 0.1.92's `ref.svc_title`: that the service label is kept when it differs and not when it doesn't, that a play of the QUALIFIED title finds the row while a different artist's doesn't, and that the dedupe key still ignores the label. What the handshake params become on the stored row, that `&tc=` settles the type but never fills `track_count`, that the cross-kind single dedupe eats a REAL single but not a disproved one, that an UNKNOWN type defers instead of inserting a guess, and that unreplayable/unidentifiable adds are refused. Needs no service: the whole path asks only `client`/`getParam`/`setStatusDone`/`setStatusProcessing`/`addResult`/`addResultLoop`, and `client => undef` makes the background jobs no-op. **The service plugins must be declared** (`_serviceCan`) or the gate rejects everything and every assertion passes against an empty DB |
| `t_resolve_count.pl` | what a resolve writes BACK to the row (`Browse::_albumTracks`): a FAILED resolve records nothing and never clobbers a real `track_count`/`rel_type`, Bandcamp helper-only rows count as a failure too, and 0.1.88's successful-resolve refresh + forced single-correction still work. Plus `Sources::hasDirectAlbumRef` — whether a row's tracklist costs one album call or a whole service SEARCH (the Bandcamp page-url case), which is what gates background work |
| `t_load.pl` | every shipped module compiles AND loads, plus a called-vs-defined sweep — `perl -c` passes on a call to a sub that doesn't exist, which nearly shipped a runtime crash in 0.1.83 |

Two rules that follow from how this suite is built:

- **Assertions must not be able to pass vacuously.** The stubs are deliberately dumb; anything a
  test depends on (a library track count, a pref, a tracklist) is set IN the test. The `&tc=`
  episode in the sibling ListenBrainz plugin is the cautionary case: every test for it SUPPLIED the
  field it was meant to be checking for, so all of them passed while the feature was inert.
  **This side of the same handshake then did it too** — see below.
- **A test of extraction must CALL the extraction.** 0.1.89's `&tc=` receiver shipped with
  `$favTracks = $1 + 0 if $1 =~ /^\d{1,3}$/ && $1 > 0`. The strip works and `$1` holds the count,
  but the validation match has no capture group of its own and **a successful match still resets
  `$1` to undef** — so every count was discarded and the whole handshake was inert on this side as
  well. It shipped "verified by 24 checks": that script pulled the seven strip regexes out of
  Plugin.pm *by grep* and applied them standalone, which sounds like the strongest possible test and
  was in fact incapable of failing, because the bug was in the four lines of validation NEXT to the
  regexes. `Plugin.pm` has `use strict` but **not** `use warnings` (unlike Browse/DB/Played/
  Sources), so the "uninitialized value $1" warning was never emitted either — completely silent on
  the server. Fixed by copying the capture into a lexical first; the extraction now lives in its own
  sub (`_stripPrivateParams`) purely so a test can call it, and `t_favurl.pl` does. Both new suites
  were checked against the pre-fix code and fail there (11 and 7 failures) — **a new suite is not
  done until it has been run against the bug it claims to catch.**
  *(Adding `use warnings` to Plugin.pm/Podcast.pm/Settings.pm/HomeExtras.pm would have caught this
  on the first add. Not done here — it's a change to a 2000-line module that could surface a pile of
  pre-existing benign warnings in `server.log`, so it wants its own pass.)*
- **A test that needs the server says so.** The retry's timer FIRING, and anything touching a real
  service, is not covered here — `tools/t_all.sh` proves logic, not integration. Live checks go
  through `curl http://plex:9000/log.txt` (see the testing note above) and their results belong in
  this file.

## `&al=` carries the SERVICE's album title — FLEET RULE (SETTLED 2026-07-30)

**Whatever a sibling plugin packs into `&al=`, it must be the title the STREAMING SERVICE uses, not
the one the sibling prefers.** This was got wrong independently in both senders and cost a whole
debugging session; it is the single most important thing on this page about plugin interop.

**Why the service's name and nothing else.** `Played::_matchRecord`'s streaming branch has **no
album-id anchor** — it matches on artist + album TITLE, because a playing track's metadata is all
there is to go on. So the stored title has to be the string the service will report at playback.
Store anything else and the release **plays perfectly and silently never leaves the list**: no
tracking, no measure, no mark, and *nothing in the log*, because `_matchRecord` returning undef is
not an error. It is the hardest failure mode in this plugin to notice.

**How each sender got it wrong, and what each now sends:**

| sender | row label Material sends as `$ALBUMNAME` | was in `&al=` | now in `&al=` |
|---|---|---|---|
| **LBF** | the album name | MusicBrainz's release name | the service's own title |
| **PFR** | `"Artist - Album"` | Pitchfork's album title | the matched service item's title |

- **LBF** sent MB's name because it is the better name for DISPLAY and for the dedupe key. But MB
  keeps a release's distinguisher OUTSIDE the title (all four American Football LPs are titled
  `American Football`), and its name can differ outright: MB `Radio: Fourth Space (Original Music
  from Big Walk)` vs Qobuz `Radio: Fourth Space (Original Music from the Game "Big Walk")` — verified
  live, rec 205. **PFR** legitimately NEEDS `&al=` (its label really is `"Artist - Album"`, so
  `$ALBUMNAME` is polluted) — it just has to put the right title in it: the service item's title was
  sitting right there next to `_albumid` in the match loop and was being discarded.
- **An intermediate LBF fix over-corrected** and sent the service's ROW LABEL, which carries the
  artist — Qobuz labels artist-first (`aksfx - Radio: …`, rec 207), Bandcamp artist-last
  (`Radio: … - aksfx`, rec 208). Both unmatchable. The target is the album TITLE alone.

**Why the matcher can't be loosened to paper over this.** The shared matcher's `_norm` strips
brackets so it CAN match across an edition qualifier; `DB::_norm` deliberately KEEPS them so the
dedupe key can tell editions apart. Both are right. The consequence is that precisely the cases where
the matcher's leniency does useful work (`Extra Mile` matched against `Extra Mile (Deluxe Edition)`)
are the cases where a sibling's own title can never match at playback. **Fix it at the SENDER.**

**Checking it: `tools/add_naming_check.py`.** Every add logs both halves — Material's label and the
title actually stored — so the whole matrix is checkable from one log fetch, no DB access:

    python3 tools/add_naming_check.py            # non-zero exit if anything mismatches

Three verdicts: `OK` (identical), `strip(...)` (stored == label minus something `_addCtxCommand`
removes on purpose — a trailing `(YYYY)`, a format qualifier like `(Album)`/`(Hi-Res)`, a sibling's
`Artist - ` prefix), and `** MISMATCH` (a genuinely different title — the bug). It pairs each
`addctx` with the NEXT `add ->` in log order rather than zipping the two streams, because a rejected
add and an `already=1` re-add both break a positional zip silently.

**Its one blind spot, and it is not small: for PFR the check is VACUOUS.** On every other surface
Material's label IS the service title, so label-vs-stored is a valid proxy. PFR's label is
Pitchfork's own string, so `strip(artist-prefix)` proves only that the prefix came off — it says
nothing about whether the remainder is what the service calls the release. Post-fix LBF is partly the
same. **The only non-proxy test is playback**: play a track and read the log — a match logs
`measured on first play` / `marked album rec`; a miss logs nothing at all, and that silence IS the
diagnosis.

**Verified live 2026-07-30**, after both senders were fixed: Qobuz/Tidal/Deezer native `OK`, Bandcamp
via LBF `strip(qualifier)`, Qobuz via PFR `strip(artist-prefix)`. Rows saved before the fixes (205,
207, 208, 212, 215) are unrepairable — `svc_title` is captured at add time from a label that is gone —
and need a re-add.

**Two things the check surfaced that are worth knowing.** (1) `svc=` is EMPTY on some sibling adds
(rec 205, 207) and `listenbrainzfreshreleases` on others, so the `via` column tells you which Material
CATEGORY fired, not which plugin sent it — `$SERVICE` doesn't populate on every surface. (2) Bandcamp
appends `(Album)` to its browse titles and `_addCtxCommand` strips it.

**SETTLED by playback 2026-07-30: stripping `(Album)` is correct.** A Bandcamp release added via LBF
was played and moved to Played, so the stripped title DOES match what Bandcamp reports while playing —
i.e. `(Album)` is a browse-row decoration, not part of the album name. Nothing offline could have
predicted this; only playing it could.

**Status of `ref.svc_title` (0.1.92) after that.** Its two candidate justifications are now both gone:
the senders were the real bug and are fixed, and the qualifier-strip case turns out not to need
rescuing. **It has no known live case.** Keeping it anyway, deliberately: it is the LAST pass in
`_matchRecord`, guarded by the same `_artistMatch` as the pass above, so it can only ever rescue a
miss and never redirect a play that already matches — and the failure it guards against is the silent
one (a release that plays perfectly and never leaves the list). Cheap insurance against a future
sender regression or a service that starts decorating titles. Don't spend effort removing it; equally,
don't cite it as load-bearing.

**Played status is believed COMPLETE as of 2026-07-30** — verified end to end across native
Qobuz/Tidal/Deezer, Bandcamp via LBF, Qobuz via PFR, and Now Playing (both the counter path and
`_armDeferredMark`'s played-through path, including correctly NOT marking a track that was skipped
partway).

## Played length: MEASURE it, never infer it from the release type (DECIDED 2026-07-30)

**The rule: a release's length is only ever a COUNT of its real playable tracks. The release
TYPE never decides anything about Played.** Reported by Simon and rebuilt the same day, after
a saved release (adieu — *Wanna me*) was played through and refused to move to Played.

**Why the type can't be trusted, ever.** `rel_type` comes from MusicBrainz (via LBF's `&rt=`)
or a service catalogue. It is a BIBLIOGRAPHIC LABEL, not a count — MB calls a lead track plus
B-sides a *Single*, and calls a 1-track release an *EP*. **LBF cannot fix this**: it passes on
what ListenBrainz/MusicBrainz give it. Every threshold derived from the label was a guess
dressed as a fact, and it was wrong in both directions — a "single" of 3 tracks marked Played
after one (0.1.88's bug), and an "EP" of 1 track that could never be marked because the EP
floor asked for 2 tracks it doesn't have (the reported bug). Both were patched repeatedly;
the patches were the problem.

**The counting bug underneath it, VERIFIED LIVE 2026-07-30.** The resolved item list was
filtered with a DENY-list — not `type => 'text'`, no `weblink` — so anything a service invents
fails it OPEN. Qobuz returns 5-6 info rows with every album (`Artist: …`, `Add Release … to
Qobuz favourites`, `Credits`, `Description`, `Music Label: …`, `Copyright`, and one `Artist:`
row PER credited artist), and **none of them carries a `type` key at all** — confirmed over
`jsonrpc.js` against four releases, and against `Slim::Control::XMLBrowser`, which emits
`type` verbatim when present. So every one was counted as a track:

| release | rows | counted | real |
|---|---|---|---|
| adieu — Wanna me | 6 | **6** | 1 |
| 3OH!3 — MY FRIENDS | 8 | **8** | 3 |
| Cola — Cost Of Living Adjustment | 17 | **17** | 11 |
| Will Sheff — Extra Mile | 15 | **15** | 9 |

Wanna me therefore needed `ceil(60% × 6)` = 4 of its 1 track — impossible — and Cola needed
all 11 instead of 7.

**The four parts, all shipped in 0.1.90:**
1. **`Sources::isPlayableTrack`** — a port of LMS's own `hasAudio` (`Slim/Control/
   XMLBrowser.pm`), the predicate the server itself sets `isaudio` with. An ALLOW-list, so an
   unanticipated row fails CLOSED. **Note it accepts `playlist` as well as `audio`, plus
   `play` and audio `enclosure` — filtering on `type eq 'audio'` alone would be wrong.**
   Counting and DISPLAY are now separate: the drill view still shows the info rows.
2. **`Played::_totalTracks` returns only a MEASURED length** — library live count, or a stored
   resolved count. The `single ⇒ 1` inference is gone, and so is `_maybeMark`'s EP floor cap
   (dropping the floor to 2 for an "EP" still asks for a track a 1-track release lacks).
3. **`Played::_learnTrackCount`** — on the first play of a saved streaming release with no
   measured length, resolve the tracklist, count it and store it. Fired only in the branch
   that STARTS tracking, plus an in-flight guard, so an album asks once. If the answer arrives
   mid-play it updates the live `%tracking` total; **if it comes back 1 it cancels the counter
   and hands over to `_armDeferredMark`**, or the release would be marked the instant it
   started (0.1.83's bug).
4. **`user_version < 4` migration** — clears `track_count` on every non-library row. Wrong
   counts CANNOT heal on their own (Played only measures a length it doesn't have), so without
   this nothing already saved gets better. Library rows are untouched.

**The safety principle that falls out, and should govern anything similar: when the length is
unknown, fail towards NOT marking.** Failing to mark is recoverable and merely annoying;
marking wrongly moves the row to Played and auto-tidy then DELETES it. Uncertainty must never
destroy a saved row. That is why an unmeasurable release sits on the flat floor rather than
getting a smaller, friendlier guess.

**Consequence, accepted:** a release whose length can never be measured (service permanently
unreachable) and which holds fewer tracks than `streaming_min_tracks` won't auto-mark. Before,
the label rescued some of those — at the cost of wrongly marking others. Measuring is right;
guessing was not.

## Year backfill from the Qobuz album object (0.1.91)

A streaming BROWSE row carries no year. The only add-time sources are the siblings' `&y=`
handshake, an explicit `year` param, and Material's Now Playing `"Album (YYYY)"` label — so
measured on the live list, **14 of 45 rows had no year** (9 Qobuz, 4 Bandcamp, 1 other).

**It is not cosmetic.** The year is a segment of the dedupe key (`artist|album|year`), so a
yearless row keys as `artist|album|` and the SAME album added later from a source that does
supply one keys differently → a second row that dedupe cannot see. Same class as the
year-in-title pollution, from the opposite direction.

**Free on Qobuz, unavailable on Tidal/Deezer/Bandcamp.** Qobuz is the one service whose ID
call returns an album OBJECT rather than a tracklist, and that object states the date.
`classifyRelType` fetches that object anyway (for `release_type` + `tracks_count`), so the
year rides back as a FOURTH callback value at no extra cost, on both the short-circuit and
the resolve-fallback paths.

### WHICH SOURCES CAN SUPPLY A YEAR — the whole picture (0.1.93)

| source | year? | from where |
|---|---|---|
| **library** | ✅ always | `Sources::libraryAlbumYear` — the local DB, free |
| **Qobuz** (native or sibling) | ✅ | the album object, via `Sources::serviceYear` |
| **LBF / PFR** (any service) | ✅ when they have one | the `&y=` handshake |
| **Now Playing** | ✅ only if the label reads `"Album (YYYY)"` | Material's label, stripped by `_addCtxCommand` |
| **Tidal native** | ❌ | `getAlbum` returns a TRACKLIST, no album hash to read |
| **Deezer native** | ❌ | same |
| **Bandcamp native** | ❌ | same, and no date at all without scraping the page |

**The three ❌ rows are a DECISION, not an oversight.** Those plugins' raw `albums/<id>` /
`album/<id>` endpoints DO carry dates, but surfacing them means reaching into private plugin
internals, which was **DECLINED 2026-07-25** (breaks on plugin updates) — the same ruling that
makes catalogue-side single/EP detection Qobuz-only. The one legitimate route left is those
plugins' public SEARCH results, whose raw album hashes carry dates (`_searchService` already
reads them for `_bestMatches` ranking) — unused here because a search is far too expensive to
spend on a cosmetic-plus-dedupe field. **Don't re-attempt the private-endpoint route.**

**`Sources::serviceYear` is the reader, and it takes the HASH.** Ported from PFR's `_svcYear`
(0.1.93) after native adds were seen losing years that PFR kept. The earlier version asked for
three Qobuz fields by name, so anything spelled differently produced nothing. Key order is
PRECEDENCE: `release_date_original` (the original release — a reissue keeps the year it was
made) → `release_date_stream` → `release_date` → `releaseDate` → `date` → `streamStartDate` →
`released_at` (Qobuz's EPOCH, converted through `localtime` and range-checked) → `year`.
**`release_date_stream` is not in PFR's list — don't drop it when syncing, this plugin reads
it** (the regression suite caught exactly that).

**The epoch changed behaviour deliberately.** `_yearOf` (string input) still refuses
`released_at`, and must: there is no word boundary inside a digit run, so mining it would turn
`1767225600` into "1767". But refusing it *outright* meant an album object stating only the
epoch yielded no year at all — which is what PFR was getting right. `serviceYear` converts it,
because there it is known to be an epoch rather than guessed at.

**Material has NO `$YEAR` variable.** Its map is `$ALBUMNAME`/`$ARTISTNAME`/`$TITLE`/`$FAVURL`/
`$IMAGE`/`$ALBUMID` — so a **library** album added from a Material menu arrived yearless while
the same album added from the info-provider menu (`_addItemFor`, which always sent one) got its
year, and the two then keyed differently and could not dedupe. `_addCtxCommand` now reads it
from `Slim::Schema` off the `$ALBUMID` it is already given. Note LMS stores `year = 0` for
"unknown", which is not a year — `libraryAlbumYear` rejects it.

- **`DB::updateYear`** mirrors `updateArtist`: fills a MISSING year and RECOMPUTES the dedupe
  key. It never overwrites a year we already hold — that one came from the add, closer to the
  user's own view of the release, and a service date can be a reissue's.
- **`_classifyThenAdd` sets it BEFORE the insert**, so it reaches the key (`DB::add` builds
  the key at insert; a year arriving later would leave the key yearless).
- **`_verifyRelease` backfills it too**, ahead of the count check, so it lands even when the
  count is provisional or never arrives — that is what heals rows already saved.
- **An epoch `released_at` is deliberately NOT read.** `_yearOf` anchors on `\b`, and a run of
  digits has no internal word boundary, so `1767225600` yields nothing rather than a nonsense
  year. Pinned by a test.

## Release type: why an asserted type is not classified before insert (DECIDED 2026-07-29)

**Settled. Do not re-open — it was re-litigated once already, at length, and this is where that ended.**

The tension is genuine and has no third option: for a release type we cannot corroborate at insert
time, **"never show a type that changes" and "never delay the add" are mutually exclusive.** One of
them has to give. Both have now been chosen, in that order, for different reasons:

- **0.1.74–0.1.80 chose "never changes", accepting the wait.** Correct for what existed then: the
  only types available were an unknown one (nothing to show but a guessed "Album") and a resolved
  one, and the correction it was avoiding waited for a **first drill or play** — potentially days
  later, in front of the user, on the list itself.
- **0.9.141 created a third category that decision never considered: an ASSERTED type.** MusicBrainz
  (via LBF's `&rt=`) and Qobuz's `release_type` both state one — and both are wrong in exactly one
  way that matters, calling a multi-track release a Single (see 0.1.88). So it is neither "unknown"
  (there IS a label, and a good one for album-vs-EP) nor "known" (it can't be trusted on the one
  axis Played depends on).
- **DECISION (Simon, 2026-07-29): the add must not wait on a service.** An asserted type inserts
  IMMEDIATELY; `_verifyRelease` corrects it fire-and-forget afterwards. The first cut of 0.1.88
  blocked instead, and was rejected on exactly this ground: *"I dont want a delay to adding
  material."*

**What makes the flip acceptable here, where it wasn't in 0.1.74–0.1.80** — the two situations differ
in more than preference:

1. **Milliseconds, not days.** Measured live on the real server, 3-track MB Single, per service:
   Qobuz **1.5 ms**, Deezer **2–277 ms**, Tidal **150 ms** between the insert line and the
   `reclassified as ep` line. The old flip waited for a first play.
2. **Nobody is looking at the list.** An add happens from a streaming browse page or Now Playing —
   the LL list isn't rendered, and by the time it is, the correction has long landed. Simon's own
   report of the shipped behaviour: *"it did show up straight away in my test no delay."*
3. **An UNKNOWN type still blocks.** `_classifyThenAdd` is unchanged for it, because there the label
   would be a pure guess with nothing behind it. That half of 0.1.74–0.1.80 stands.

**If this is ever revisited, the only lever is going back to blocking** — there is no arrangement that
avoids both the delay and the correction. Storing NULL until verified was considered and rejected: it
still flips visually (NULL renders as "Album", `_typeLabel`), and it breaks 0.1.79's cross-kind
single↔track dedupe, which keys on `rel_type eq 'single'` at insert.

**Two further `_verifyRelease` holes, both fixed 2026-07-30 (code review):**

1. **It threw away a type it had just been handed.** It only ever wrote a type to DEMOTE a
   wrong 'single', so a row inserted with a NULL type — the shape `_classifyThenAdd`'s safety
   timeout leaves behind — kept showing `_typeLabel`'s neutral "Album" default for good, even
   though the callback had just returned 'ep'. Now a missing type is filled in, UNFORCED
   (`updateRelType`'s `WHERE rel_type IS NULL`), so it can't race over a type a drill/play
   stored meanwhile. A standing claim is still left alone.
2. **The gate asked the wrong question for Bandcamp.** It ran whenever the row had an album
   ID, but Bandcamp's `get_album` scrapes the album PAGE url — an id-only Bandcamp row
   resolves via a full service SEARCH, exactly the cost the gate exists to refuse.
   `buildPlayableItems` already got this right, so the predicate is now ONE sub,
   `Sources::hasDirectAlbumRef`, used by both — they had drifted, which is the same way
   `_albumTracks` drifted from `_resolveCount`. **Rule: anything deciding whether to do
   optional background work asks `hasDirectAlbumRef`, never "is there an album id".**

**Related item — MITIGATED in 0.1.90, not eliminated.** A failed verify leaves the unverified `single`
claim standing, and `Played::_totalTracks` reads it as a real total of 1 → marked Played after one
track → auto-purged days later. 0.1.90 retries once after 60s (`_armVerifyRetry` /
`_verifyRetryTick`) and, crucially, LOGS both failure routes — before that a service that answered
with nothing was completely silent, which is why this could have sat unnoticed indefinitely. A
sustained outage across both attempts still leaves the claim; the row is then corrected on first
play/drill from the list (`Browse::_albumTracks`), so what remains needs the service down for a
minute AND the release played only from outside LL.

**The corroboration fix was considered and REJECTED — do not build it.** Gating the single fast-path
on `rel_type='single' AND track_count=1` would put every pre-0.1.88 single (no stored count) back on
the 4-track floor, re-opening **0.1.82**. Trading a narrow new hole for a documented old one is the
wrong direction; heal the row, don't punish rows that predate the check.

## Podcast episodes (0.1.84) — what a browse row actually carries, and why resolution works this way

Measured over JSON-RPC (`["podcasts","items",0,2,"item_id:<feed>","menu:1","useContextMenu:1","wantMetadata:1"]`),
for BOTH a search result and a SUBSCRIBED feed — they are identical:

- An episode row has **no `presetParams`, no `favorites_url`, no `metadata`** — only a positional
  `item_id` ("3.0"). So `$FAVURL` and `$ALBUMID` are both empty on a custom action.
- That `item_id` is **not durable**: it's an index into the feed, so today's `3.0` becomes `3.1` when the next
  episode drops. An upstream Material change exposing it would therefore NOT help — this was checked before
  being ruled out.
- Its "… → More" is the Podcast plugin's **own OPML info window** (Description / Duration), NOT a `trackinfo`
  menu — so `Slim::Menu::TrackInfo` providers can't appear there either. On a browse row the plugin has no
  other reach.
- So an add arrives with only: `$TITLE` (episode title), `$ARTISTNAME` (= the row subtitle, e.g.
  "Monday, July 6, 2026 (58:05)"), `$SERVICE`="podcasts", `$IMAGE` (episode artwork).

**Resolution.** The Podcast plugin keeps subscriptions — with their real RSS urls — in its own prefs
(`plugin.podcast:feeds` → `[{name, value}]`). `Podcast.pm` fetches those feeds (SimpleAsyncHTTP +
`Slim::Utils::Cache`, 1h TTL / 7d fallback, the PFR API.pm idiom) and finds the episode. **The artwork url is
the primary key** — it appears verbatim in the RSS as `<itunes:image href>` and is unique per episode; the
Material `$IMAGE` is the LMS image proxy wrapping it (`/imageproxy/<escaped>/image.png`), so `_realImageUrl`
unwraps it back. Normalised title is the fallback. The matched `<enclosure url>` is stored **podcast://-
prefixed**, so the Podcast plugin's own protocol handler plays it AND keeps its resume-position tracking. RSS
is parsed with a tolerant regex scan, not an XML parser — podcast feeds are machine-generated, only four
fields per item are needed, and a strict parser would die on the malformed-but-common ones.

**Category.** Confirmed from the SERVED bundle, not inferred: `ba = fb?"artist":wa?"track":"album"`, and `wa`
is only set when the parent view is an online ALBUM and the item has `metadata.type=="track"`. Podcast rows
have no metadata, so `wa` is false → `ba`="album" → the category is **`podcasts-album`** (`k` = the browse
command). Material prefers a PRESENT per-command category over `online-*`, so writing a POPULATED
`podcasts-album` is what swaps the generic "Add album …" for "Add podcast …" there and nowhere else — the same
per-app override used EMPTY for suppression elsewhere (0.1.55); populated, it can only add, never hide.
`podcasts-track` is written with the same pair as insurance if a future Material reclassifies these rows.

**Limits (accepted, by measurement not choice):**
- **Only SUBSCRIBED feeds resolve.** An episode found via "Search feeds" on an unsubscribed show has nothing
  to match against and is rejected (no row) rather than stored as something that could never play.
- The categories are written **only when `plugin.podcast:feeds` is non-empty** — with no subscriptions the
  generic "Add album" stays and keeps rejecting as before, rather than offering a podcast add we can't honour.
  If the user later unsubscribes from everything, `podcasts-*` leaves `%cats`, so the 0.1.52 delete-empties
  pass removes it and the `online-*` fallback is restored (an empty category would otherwise SUPPRESS).
- The override applies to **everything under the `podcasts` command** — show rows, Search feeds, New episodes,
  Recently played — so "Add podcast" appears there too and rejects on anything that isn't an episode. It can't
  be scoped finer: Material's per-action `filter` keys on the favurl, and these rows have none (0.1.50).
- **Now Playing / queue adds were deliberately NOT pursued** — a podcast is saved to hear it later, so the
  moment that matters is the browse list, not playback. (They should nonetheless WORK for free: a queued /
  playing episode's track url IS the `podcast://` enclosure, so the ordinary track path handles it with no
  feed resolution — and would therefore even cover an unsubscribed show. Untested.)
- **You cannot favourite an individual EPISODE, only the feed** — an episode row has no `favorites_url`,
  which is exactly what favouriting requires. An earlier note here speculated the opposite; it was wrong.

**Glyph (0.1.87).** A podcast row uses **❝** (U+275D) rather than the ♪ music note, so speech reads as
distinct from music in a mixed list. There is **no plain-text microphone** to use: the only ones (U+1F3A4,
U+1F399) are emoji-plane characters, and although U+1F399 defaults to text presentation, virtually no font
ships a monochrome glyph for it — so it resolves from the colour emoji font, or renders as a missing-glyph
box where there is no emoji font. These glyphs are drawn by the VIEWER'S browser, not the server, so anything
emoji-backed varies per device. U+275D is Dingbats, BMP, no emoji variant — same coverage class as ♪/♫.

### 0.1.85 — episodes reached through OTHER containers (the route users actually take)

0.1.84 only covered the Podcasts app. Diagnosed live: the add logged `svc=favorites, favurl=` and
`rejected add — unsupported source 'favorites'`. Material picks the custom action from the **container's**
browse command, so a favourited FEED (verified: `favorites items item_id:<id>` lists its episodes, rows
identical in shape — no favurl, no metadata, positional item_id, same artwork key) is browsed under
`favorites` and never reaches the kind:podcast action. Home-shelf cards and search hits behave the same.

Fix is one **last-resort resolve** in `_addCtxCommand`, immediately before `_rejectAdd`: if the source isn't
replayable AND there's no favurl/albumid AND there are subscribed feeds, try `_savePodcastEpisode`. That
catches every such container at once instead of chasing them one category at a time, and costs nothing on a
working add — it only runs on one already destined to be rejected, against cached feeds. A rejection from
this path reports the ORIGINAL source, not 'podcast'.

**Wording.** `favorites-album`/`-track` are now written with a type-NEUTRAL "Add to Listen Later" / "Add to
Wish List" (same `$onlineCmd`, so behaviour is identical). A favourites list is heterogeneous — albums,
tracks, podcasts, radio — so "Add album" was already the wrong word there, podcasts aside. It cannot be made
per-item: the category comes from the container's command, and the per-action `filter` that could
discriminate is bypassed on a favurl-less row (0.1.50) — which is exactly what these are. So in the Podcasts
app the entry reads "Add podcast"; elsewhere it reads the neutral "Add to Listen Later".

**No Wish List for podcasts.** The Wish List is for things you might BUY. The `podcast` role has no wishlist
title, and the writer loop only emits the Wish List entry when the role defines one — so the Podcasts app
shows a single "Add podcast to Listen Later". An episode arriving through a GENERIC container's "Add to Wish
List" (where the menu can't know it's a podcast) is saved to Listen Later instead, with a WARN, rather than
dropped into a list where it's meaningless.

## Shared Matching Engine — FLEET SYNC RULE (2026-07-10)

The artist/album/track matcher (`_norm`, `%FOLD`, `_artistMatch`, `_albumMatches`,
fallback helpers `_stripFmt`/`_asciiNorm`/`_punctNorm`/`_stripArtistPrefix`; LBF also
`_trackMatches`) is ONE engine with a copy in each of these four repos:

- `LMS-ListenBrainz-New-Releases/ListenBrainzFreshReleases/Browse.pm` (origin, canonical)
- `LMS-Pitchfork-Reviews/PitchforkReviews/Browse.pm`
- `LMS-Discography/Discography/Sources.pm`
- `LMS-Listen-to-Later/ListenLater/Sources.pm` (hash-pinned LENIENT variant — empty-artist
  saved-item replay must still match; do NOT blindly align it)

**THE RULE: a matching fix in ANY of these repos must be applied to ALL repos carrying the
affected sub, in the SAME work session.** Enforcement — this must exit 0 before any matcher
change is called done:

    python3 LMS-ListenBrainz-New-Releases/tools/matcher_sync_check.py

It diffs the comment-stripped CODE of every copy across all four repos. Deliberate variants
are sha1-pinned inside the script with a reason, and FAIL the check if they change without a
conscious re-pin (`--print-hashes` prints current hashes). After aligning: bump every touched
repo's plugin version AND its match/decision cache versions (LBF: `lbf:stream` + `lbf:track` +
`lbf:pl:resolved` — ALL layers; PFR: `pfr:stream`; DSC: `dsc:cand` only if the cached candidate
shape changed — matching runs live there; LL: none — matching is live), rebuild zips + repo.xml
sha. Never leave a matcher fix in one repo "to port later" — that is exactly how the 2026-07
drift happened (LBF missed the P!nk/EP/ascii rules for months).

