# Listen to Later — LMS Plugin

## Project Overview
A plugin for Lyrion Music Server (LMS) that lets you save an album — from the local library or any streaming service (Qobuz, Bandcamp) — into a curated **Listen to Later** list, browse it like a playlist *of albums*, and have albums move to a **Played** section once most of the album has been heard. Targets LMS v9.x, Material Skin preferred (classic best-effort). Storage is a plugin-owned SQLite database so the list is sortable, deduped, history-bearing, and ready for future features.

## Server Details
- **LMS Server**: 192.168.1.234:9000
- **OS**: DietPi (Debian Bookworm)
- **Service**: `lyrionmusicserver`
- **Plugin location (manual install)**: `/var/lib/squeezeboxserver/Plugins/ListenToLater/`
- **Log**: `/var/log/squeezeboxserver/server.log`
- **Plugin DB**: `<server cachedir>/listentolater.db`

## Testing the live server WITHOUT SSH (important)
SSH to the box prompts for a password from this environment and is not reliable. Use **HTTP** instead (same channel the ListenBrainz project uses):
- **Log**: `curl -s http://192.168.1.234:9000/log.txt`
- **JSON-RPC**: `POST http://192.168.1.234:9000/jsonrpc.js`, body `{"id":1,"method":"slim.request","params":["<playerMAC>",[<cmd>...]]}`. Menu/feed queries **need a real player MAC** as the first param — an empty string returns instant HTTP 000 (not a hang). Known player: `dc:a6:32:77:ea:e0`.
- Handy probes:
  - feed: `["<mac>",["listentolater","items","0","10"]]`
  - context menus: `["<mac>",["trackinfo","items","0","100","track_id:<id>","menu:1"]]`, `[…,"albuminfo",…,"album_id:<id>","menu:1"]`
  - exists: `["","can","listentolater","items","?"]` (bogus tag → `_can:0`, so it's a genuine signal)
  - apps list: `["","apps","0","100"]`; plugin state: `["","pref","plugin.state:ListenToLater","?"]`
- INFO logs from a plugin only appear in `log.txt` if its category is at INFO; while debugging, log at **WARN** to guarantee visibility.

Installing still needs filesystem access (the user runs the unzip+chown+restart); all verification is done over HTTP afterwards.

## Install Commands
```bash
sudo rm -rf /var/lib/squeezeboxserver/Plugins/ListenToLater
sudo unzip -o ListenToLater.zip -d /var/lib/squeezeboxserver/Plugins/
sudo chown -R squeezeboxserver:nogroup /var/lib/squeezeboxserver/Plugins/ListenToLater
sudo systemctl restart lyrionmusicserver
```
File ownership must be `squeezeboxserver:nogroup` (DietPi), and the zip must extract directly as `ListenToLater/` (no extra `Plugins/` wrapper).

## File Structure
```
ListenToLater/
├── Plugin.pm     # OPMLBased init; registers TrackInfo + AlbumInfo "Add" providers; opens DB; starts play-detector
├── Browse.pm     # top-level (Listen to Later / Played / Settings); album rows; per-album submenu (Play / Remove / Move)
├── DB.pm         # SQLite (DBI/DBD::SQLite) connect + migrate + CRUD; dedupe by normalised source|artist|album
├── Sources.pm    # per-source adapters: capture a record from a track/album, rebuild a playable node, match helpers
├── Played.pm     # subscribes to playlist newsong/stop/clear; threshold logic to auto-move albums to Played
├── Settings.pm   # default sort, played threshold %, streaming track count, auto-Played toggle
├── install.xml   # <extension> singular; <icon> = …Icon_svg.png; <optionsURL>; <homepageURL>
├── strings.txt   # PLUGIN_LTL_* strings (EN)
└── HTML/EN/plugins/ListenToLater/{settings.html, html/images/*Icon.svg|_svg.png|.png}
```

## Key Technical Decisions
- **Base class**: `Slim::Plugin::OPMLBased`, `is_app => 1` (Apps section), `menu => 'radios'`. Feed is `Browse::topLevel`.
- **Add path**: there is **no global hook** into every streaming plugin's own album "…" menu. The universal path is `Slim::Menu::TrackInfo->registerInfoProvider` (fires for local **and** remote tracks); `Slim::Menu::AlbumInfo` adds a direct entry for library albums. Both return an OPML drill item (`type=>'link'`, `url=>coderef`) that performs the add and shows a brief confirmation — renders in Material and classic. Custom providers are confirmed to show in `trackinfo`/`albuminfo menu:1` (alongside "Save to Favourites", "On Qobuz").
- **Register defensively**: `require Slim::Menu::TrackInfo`/`AlbumInfo` and wrap each `registerInfoProvider` in `eval` — an unguarded call dies and aborts the whole plugin if the module isn't loaded yet.
- **Storage**: SQLite over prefs (prefs give no query/sort/dedupe). One `albums` table; display metadata denormalised so the list renders without re-hitting any service; `ref_json` carries only what's needed to replay (album_id / passthrough / `_svc`). `UNIQUE(source, dedupe_key)` prevents duplicate adds; re-adding a Played album returns it to Listen to Later.
- **Replay**: library → load album tracks by `album.id`. Streaming → if a native album id was captured, rebuild the service's own album node (reattach `Qobuz…QobuzGetTracks` / `Bandcamp…get_album`, the same coderef round-trip the sibling uses); otherwise **search the originating service** by "artist album" and keep the title+artist match (resilient — no hard dependence on capturing the album id).
- **Played detection**: subscribe to `[['playlist'],['newsong','stop','clear']]`; per player, count distinct tracks of the currently-playing saved album. Library uses real track count × `played_threshold`% (default 60); streaming has no reliable total so falls back to `streaming_min_tracks` distinct tracks (default 4, best-effort). Same path for inside- and outside-plugin plays; `watch_outside` is the master toggle.
- **Remote vs local detection gotcha**: trust `$track->remote`; do **not** treat a `file://` URL as remote (`$url =~ m|://|` matches `file://`). And `$remoteMeta` is **undef** for local tracks — dereferencing it under `use strict` dies and the menu wrapper swallows the error → no item appears. Always `$remoteMeta = {} unless ref $remoteMeta eq 'HASH'`.
- **install.xml**: `<extension>` singular (manual installs). `<icon>` → `…Icon_svg.png` (Material `_svg.png` convention loads the sibling `.svg` and recolours it; the SVG must use `#000`, not `#000000`). PNGs are real transparent RGBA (Pillow), not JPEGs misnamed `.png`.

## Material custom actions on streaming "…" menus (the hard problem — solved)
Goal: an **"Add to Listen to Later"** entry on a streaming **album row while browsing** (Qobuz New Releases, etc.), where the service plugin owns the "…" menu so TrackInfo/AlbumInfo providers can't reach it. Material's **custom actions** (`prefs/material-skin/actions.json`, served at `/material/customactions.json`) are the only hook — but out of the box they appear on **library** items only. Full trace and the working fix:

- **Bundles**: Material ships two minified JS bundles. `material.min.js` (**main**) contains `customactions.js` (`getCustomActions`, `doReplacements`, `doCustomAction`) and `browse-page.js` (renders the menu). `material-deferred.min.js` (**deferred**) contains `browse-resp.js`, `browse-functions.js`, `standarditems.js`. The deferred build list is the `addJsToDocument("html/js/",[…])` array in `index.html`.
- **Why library-only**: per-item custom actions are added in `browse-functions.js` only when `item.stdItem < STD_ITEMS.length` **and** `STD_ITEMS[item.stdItem].actionMenu` contains the `CUSTOM_ACTIONS` (`-2`) marker. Online items have `stdItem` **300/301** (`STD_ITEM_ONLINE_ARTIST/ALBUM`), far beyond `STD_ITEMS.length` (~16) — so they **bypass that whole path**. (And `standarditems.js` has `CUSTOM_ACTIONS` commented out on the online-album entry anyway.)
- **How online/app items get their menu**: library content comes via `*_loop` branches (`albums_loop`, `titles_loop`, …); **app/streaming content comes via the SlimBrowse `item_loop` branch**, which builds each item's own `i.menu` array directly. The context menu renders `menu.itemMenu = item.menu`, and the `CUSTOM_ACTIONS` template (`browse-page.js`) iterates the **view-level** `itemCustomActions`. So showing a custom action on an online item needs BOTH: push `CUSTOM_ACTIONS` into that item's `i.menu`, **and** set `resp.itemCustomActions` (wired to the view via `browse-functions.js:676`). Setting only `resp.itemCustomActions` (my first patch) does nothing.
- **The real blocker — Qobuz album rows have no identity**: verified over JSON-RPC, a New Releases album row is only `{type:"playlist", text:"Album (Hi-Res)\nArtist (YYYY)", params:{item_id:"6.0"}, icon:…}` — **no `favorites_url`, no `metadata`** (even with `wantMetadata:1`; LMS is 9.1 so the server supports it — the Qobuz plugin just doesn't emit it). Title/artist/year are only in the 2-line `text`; play works via `base.actions.play` + the positional `item_id` (non-durable). **Track** rows inside an album *do* carry `presetParams.favorites_url: qobuz://<trackid>.flac` + `favorites_type:audio`. So Material can't classify album rows as online albums — and neither can a classification-based patch.
- **Working fix** (in `browse-resp.js`, the `item_loop` per-item section, after the play-action block): key off **playability** not classification — `addedPlayAction && undefined==i.stdItem && !isFavorites && !isAppsTop` (these are app/online rows; library albums never reach `item_loop`). For such rows, set `i.album=i.title` / `i.artist=i.subtitle` so `$ALBUMNAME`/`$ARTISTNAME` resolve, push `CUSTOM_ACTIONS` into `i.menu`, and set `resp.itemCustomActions=getCustomActions("online-album")`. Service identity = the browse **`command`** (`data.params[1][0]`, e.g. `"qobuz"`) — a known constant for the whole view — baked into each `lmscommand` as a literal `svc:<command>` (passes through `doReplacements` untouched since it has no `$`). For the PR this becomes a clean `$SERVICE` variable instead of baking.
- **Variable map** (`doReplacements`): `$ALBUMNAME`←`item.album`, `$ARTISTNAME`←`item.artist`, `$TITLE`←`item.title`, `$FAVURL`←`item.presetParams.favorites_url`, `$IMAGE`←`item.image`, `$ALBUMID`←`item.album_id`. Online album rows populate none of these by default — hence setting `item.album`/`item.artist` in `browse-resp.js`.
- **Plugin side** (`addctx`): reads `svc` as the authoritative source (no guessing); strips a trailing `(YYYY)` off the **artist** line → year, and a format qualifier (`(Hi-Res…)`/`(Explicit)`/…) off the **album**. `Sources::sourceFromImage` (cover host → service) is a fallback only. `_writeMaterialActions` strips every prior LTL entry from all categories, then writes `online-album`/`online-track`/`online-artist` (+ library `album`/`track`/…) with the flat-array `lmscommand` shape (NOT the `{command,params}` `lmsbrowse` shape).
- **Local Material build without Java**: no JDK/Homebrew on this Mac, so Closure can't run. Instead **concatenate the raw 6.4.3 deferred sources** (in `index.html` order) into `material-deferred.min.js` — functionally identical because cross-bundle references are globals (SIMPLE minification doesn't rename them; confirmed `CUSTOM_ACTIONS=-2`, `STD_ITEM_ONLINE_ALBUM=301`, `getCustomActions` all survive as globals in the served `material.min.js`). Syntax-check with JavaScriptCore: `osascript -l JavaScript` + `new Function(src)` (parses without executing). The cloned `CDrummond/lms-material` master HEAD is `Release 6.4.3` — matches the box, so no version skew. Patched bundle + original live in `test-artifacts/` (gitignored); install by overwriting `…/MaterialSkin/HTML/material/html/js/material-deferred.min.js` (back up to `.bak`, chown `squeezeboxserver:nogroup`, restart) and testing in an **incognito** window (Material caches the bundle in `customActions` at app start). Proposal draft: `docs/material-online-custom-actions-proposal.md` (NOTE: still describes the earlier, wrong fix — rewrite before any PR).
- **Suppressing the action inside our OWN view (the per-app override)**: our plugin is itself an app, so its list rows are playable `item_loop` items → `isAppItem` matched and "Add to Listen to Later" showed on albums already in the list (re-adding would bounce a *Played* album back to *Later*). Fix: the patched Material resolves the category for app items as `getCustomActions(command+"-"+btype)` **if** `command+"-"+btype in customActions` (the in-check is needed because `getCustomActions` returns `undefined` for an empty category), else falls back to `online-<btype>`. The plugin writes empty `listentolater-album`/`-track`/`-artist` categories, so its own rows show no "Add" while streaming services still do. This is also a general feature (any app can customise or suppress actions on its own view).
- **Remove/Move can't be inline custom actions — the id problem**: Material sets our rows' `i.id = "item_id:<positional path>"` (browse-resp.js, e.g. `"item_id:2"`), NOT our db id. Our real db id only lives in the row's own `actions.more.params.id`, which a custom action can't read (`$ITEMID` resolves to the positional path). So Remove/Move stay in each row's "…" → **More** context menu (our `listentolater contextmenu` query), the only place the db id is passed reliably. (A forced-inline route exists — encode the db id into a synthetic `favorites_url` like `ltl://<id>` so `$FAVURL` carries it — but setting `favorites_url` can make Material also offer Add-to-Favourites/pin on the rows.)
- **Context-menu actions: refresh in place, don't go home**: a "More"-menu `do` action's `nextWindow` governs navigation. `'grandparent'` jumps two levels (→ home); use **`'parent'`** — Material's rule `isMoreMenu && nextWindow=="parent"` calls `view.refreshList()`, updating the list where you are. (Path: `itemMoreAction` → `doTextClick(item, true)` sets `isMoreMenu`.) Remove/Move use `nextWindow => 'parent'`. Plugin-only — no Material change.
- **Diagnosing a streaming feed over JSON-RPC**: `["<mac>",["qobuz","items","0","5","item_id:<id>","menu:1","useContextMenu:1","wantMetadata:1"]]` returns the SlimBrowse `item_loop` Material parses — inspect each item's `presetParams`/`metadata`/`params` to see exactly what identity (if any) a row carries.

## Verification checklist (over HTTP)
1. App present: `apps 0 100` shows "Listen to Later"; feed returns the three rows.
2. `trackinfo …menu:1` and `albuminfo …menu:1` include "Add album to Listen to Later".
3. Add → `listentolater items` count increments; dedupe works.
4. Play album from the list; play ≥ threshold → moves to Played.
5. Remove / Move between sections; persists across `systemctl restart`.

## Prefs Namespace
`plugin.listentolater` — sort, played_threshold, streaming_min_tracks, watch_outside.

## Version History
- **0.1.0** — Initial build: add from track/album "…" menu, browsable Listen to Later / Played lists with per-album Play/Remove/Move, SQLite storage, automatic Played tracking, sort options, settings page. (See CHANGELOG.md.)
- **0.1.13** — Streaming **album rows while browsing** now get "Add to Listen to Later" (confirmed working on Qobuz), paired with the patched Material deferred bundle: Material keys off playability and exposes title/subtitle as `$ALBUMNAME`/`$ARTISTNAME`, and passes the view's service id as `svc:`; `addctx` reads `svc` and cleans the year-off-artist / qualifier-off-album. (Full trace in "Material custom actions on streaming …" above; intermediate 0.1.7–0.1.12 were the dead-end classification attempts. See CHANGELOG.md.)
- **0.1.14** — "Add" no longer offered inside the plugin's own view (patched Material per-app category override; plugin writes empty `listentolater-*` categories). Needs the 0.1.14+ deferred bundle.
- **0.1.15** — Remove/Move from a row's "…" → More refresh the list in place (`nextWindow => 'parent'`) instead of jumping to the home screen. Plugin-only.
