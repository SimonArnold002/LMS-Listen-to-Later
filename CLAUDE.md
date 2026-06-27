# Listen Later — LMS Plugin

## Project Overview
A plugin for Lyrion Music Server (LMS) that lets you save an album — from the local library or any streaming service (Qobuz, Bandcamp, Tidal) — into a curated **Listen Later** list, browse it like a playlist *of albums*, and have albums move to a **Played** section once most of the album has been heard. A separate **Wish List** wishlist (0.1.22) sits alongside, and albums can be moved freely between the three lists. It also adds a **Material home-page shelf** for the list. Targets LMS v9.x, Material Skin preferred (classic best-effort). Storage is a plugin-owned SQLite database so the list is sortable, deduped, history-bearing, and ready for future features.

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
- **Played detection**: subscribe to `[['playlist'],['newsong','stop','clear']]`; per player, count distinct tracks of the currently-playing saved album. Library uses real track count × `played_threshold`% (default 60); streaming has no reliable total so falls back to `streaming_min_tracks` distinct tracks (default 4, best-effort). Same path for inside- and outside-plugin plays; `watch_outside` is the master toggle.
- **Remote vs local detection gotcha**: trust `$track->remote`; do **not** treat a `file://` URL as remote (`$url =~ m|://|` matches `file://`). And `$remoteMeta` is **undef** for local tracks — dereferencing it under `use strict` dies and the menu wrapper swallows the error → no item appears. Always `$remoteMeta = {} unless ref $remoteMeta eq 'HASH'`.
- **install.xml**: `<extension>` singular (manual installs). `<icon>` → `…Icon_svg.png` (Material `_svg.png` convention loads the sibling `.svg` and recolours it; the SVG must use `#000`, not `#000000`). PNGs are real transparent RGBA (Pillow), not JPEGs misnamed `.png`.

## Icon system (0.1.24)
Three section icons, set in `Browse.pm` (`_iconFor($status)` → `_header`/`_albumRow`); the app icon (install.xml/home shelf) is `ListenLaterIcon`.
- **Two Material conventions, picked per icon** (authoritative rules mirrored from the sibling ListenBrainz plugin's "Icon System"):
  - **`_svg.png` recolour**: Material loads the sibling `.svg` and theme-recolours it (string-replaces the literal `#000` → theme colour, so the SVG MUST use `#000`, never `#000000`). Used by **Listen Later** (`ListenLaterIcon`, music-note+clock) and **Played** (`PlayedIcon`, Google `music_history`). Ship 3 files: `.svg` (source, `#000`), `_svg.png` (install.xml ref + non-Material fallback), `.png` (generic fallback).
  - **`_MTL_icon_<name>.png` font icon**: Material's `mapIcon`/`icon-mapping.js` parses `<name>` out of the filename and renders its own themed **font** glyph; the PNG itself is only a minimal non-Material fallback (single file, no `.svg`). Used by **Wish List** (`WishListIcon_MTL_icon_shopping_cart.png`) so it exactly matches the "Add to Wish List" context-menu trolley.
- **Why Wish List uses the font but Played can't**: Material's bundled icon font (Release 6.4.3, matching the box) **has** `shopping_cart` but **not** `music_history` (verified via the font's GSUB ligatures with fontTools) — an `_MTL_icon_music_history` would render blank. So Played's `music_history` had to be shipped as a recoloured `.svg` instead. (Confirm new font icons exist in `test-artifacts/lms-material/.../font/MaterialIcons.ttf` before using `_MTL_icon_`.)
- **No SVG rasteriser on this Mac** (no cairo/rsvg/inkscape; svglib's renderPM needs cairo). The PNGs are generated **qlmanage → Pillow** (the documented sibling-plugin path): `qlmanage -t -s 512` renders the `.svg` onto white, then Pillow does luminance→alpha (black art, transparent bg), trims to content bbox, and centres on a 256² canvas with 8% pad. Black-on-transparent so both the recolour and classic fallbacks look right.

## Material custom actions on streaming "…" menus (the hard problem — solved, now upstream)
Goal: an **"Add to Listen Later"** entry on a streaming **album row while browsing** (Qobuz New Releases, etc.), where the service plugin owns the "…" menu so TrackInfo/AlbumInfo providers can't reach it. Material's **custom actions** (`prefs/material-skin/actions.json`, served at `/material/customactions.json`) are the only hook — but out of the box they appear on **library** items only.

**STATUS (2026-06): the Material side is MERGED upstream** — [PR #1235](https://github.com/CDrummond/lms-material/pull/1235) landed on `dev` (`b631754`) and was merged on to `master` (`519b03a`). So there is **no more local bundle patching**: the feature ships in Material itself. The merged code does exactly what the patch did — sets `i.service`=browse command (exposed as **`$SERVICE`**), sets `i.album=i.title`/`i.artist=i.subtitle`, and resolves the per-app `<command>-<type>` category with `online-<type>` fallback. NOT YET in a *released* Material (latest release `6.4.3` lacks it; only on `master`/`DEVELOPMENT`) — the streaming-browse "Add" lights up once the next Material is released. The original full trace, kept for context:

- **Bundles**: Material ships two minified JS bundles. `material.min.js` (**main**) contains `customactions.js` (`getCustomActions`, `doReplacements`, `doCustomAction`) and `browse-page.js` (renders the menu). `material-deferred.min.js` (**deferred**) contains `browse-resp.js`, `browse-functions.js`, `standarditems.js`. The deferred build list is the `addJsToDocument("html/js/",[…])` array in `index.html`.
- **Why library-only**: per-item custom actions are added in `browse-functions.js` only when `item.stdItem < STD_ITEMS.length` **and** `STD_ITEMS[item.stdItem].actionMenu` contains the `CUSTOM_ACTIONS` (`-2`) marker. Online items have `stdItem` **300/301** (`STD_ITEM_ONLINE_ARTIST/ALBUM`), far beyond `STD_ITEMS.length` (~16) — so they **bypass that whole path**. (And `standarditems.js` has `CUSTOM_ACTIONS` commented out on the online-album entry anyway.)
- **How online/app items get their menu**: library content comes via `*_loop` branches (`albums_loop`, `titles_loop`, …); **app/streaming content comes via the SlimBrowse `item_loop` branch**, which builds each item's own `i.menu` array directly. The context menu renders `menu.itemMenu = item.menu`, and the `CUSTOM_ACTIONS` template (`browse-page.js`) iterates the **view-level** `itemCustomActions`. So showing a custom action on an online item needs BOTH: push `CUSTOM_ACTIONS` into that item's `i.menu`, **and** set `resp.itemCustomActions` (wired to the view via `browse-functions.js:676`). Setting only `resp.itemCustomActions` (my first patch) does nothing.
- **The real blocker — Qobuz album rows have no identity**: verified over JSON-RPC, a New Releases album row is only `{type:"playlist", text:"Album (Hi-Res)\nArtist (YYYY)", params:{item_id:"6.0"}, icon:…}` — **no `favorites_url`, no `metadata`** (even with `wantMetadata:1`; LMS is 9.1 so the server supports it — the Qobuz plugin just doesn't emit it). Title/artist/year are only in the 2-line `text`; play works via `base.actions.play` + the positional `item_id` (non-durable). **Track** rows inside an album *do* carry `presetParams.favorites_url: qobuz://<trackid>.flac` + `favorites_type:audio`. So Material can't classify album rows as online albums — and neither can a classification-based patch.
- **Working fix** (in `browse-resp.js`, the `item_loop` per-item section, after the play-action block): key off **playability** not classification — `addedPlayAction && undefined==i.stdItem && !isFavorites && !isAppsTop` (these are app/online rows; library albums never reach `item_loop`). For such rows, set `i.album=i.title` / `i.artist=i.subtitle` so `$ALBUMNAME`/`$ARTISTNAME` resolve, push `CUSTOM_ACTIONS` into `i.menu`, and set `resp.itemCustomActions=getCustomActions("online-album")`. Service identity = the browse **`command`** (`data.params[1][0]`, e.g. `"qobuz"`), set on `i.service`. The merged Material exposes it as the **`$SERVICE`** replacement variable, so the plugin's `online-*` commands carry `svc:$SERVICE` (0.1.28). (The pre-merge local patch *baked* a literal `svc:<command>` into each `lmscommand` instead — that workaround is gone now that `$SERVICE` exists.)
- **Variable map** (`doReplacements`): `$ALBUMNAME`←`item.album`, `$ARTISTNAME`←`item.artist`, `$TITLE`←`item.title`, `$FAVURL`←`item.presetParams.favorites_url`, `$IMAGE`←`item.image`, `$ALBUMID`←`item.album_id`. Online album rows populate none of these by default — hence setting `item.album`/`item.artist` in `browse-resp.js`.
- **Plugin side** (`addctx`): reads `svc` as the authoritative source (no guessing); strips a trailing `(YYYY)` off the **artist** line → year, and a format qualifier (`(Hi-Res…)`/`(Explicit)`/…) off the **album**. `Sources::sourceFromImage` (cover host → service) is a fallback only. `_writeMaterialActions` strips every prior LL entry from all categories, then writes the active set with the flat-array `lmscommand` shape (NOT the `{command,params}` `lmsbrowse` shape): library `album`/`album-track`/`playlist`/`playlist-track` and streaming `online-album`/`online-track`. **Deliberately NOT written:** `online-artist` (dropped 0.1.32 — we save albums, not artists) and the plain **`track`** category (dropped 0.1.34 — its sole consumer is Material's Now Playing screen, `nowplaying-page.js` `getCustomActions("track")`; browse track lists use `album-track`/`playlist-track`, so omitting `track` suppresses "Add" on Now Playing only, plugin-side, no Material change). The strip pass also clears any `track`/`online-artist` entries an older version left behind.
- **Building/testing a dev Material (now that the feature is upstream)**: the clone is `test-artifacts/lms-material` (gitignored; remotes `origin`=CDrummond, `mine`=fork). To test the merged feature before it's released, build a real minified Material plugin from `origin/master`: `python3 mkrel.py test` → `lms-material-test.zip` (its contents = a `MaterialSkin/` plugin: install by replacing the box's MaterialSkin dir, chown `squeezeboxserver:nogroup`, restart; test in an **incognito** window — Material caches the bundle at app start). `mkrel.py` needs **Java 17** (runs the bundled Closure jar) + python **`requests`** (both installed on this Mac); CSS minify is pure-Python, no LESS step. Verify a build with e.g. `unzip -p lms-material-test.zip HTML/material/html/js/material.min.js | grep -c '\$SERVICE'`. *(Historical: before the merge, with no JDK on this Mac, the deferred bundle was hand-**concatenated** from the raw 6.4.3 sources and dropped onto the box. No longer needed.)* Proposal draft (now historical): `docs/material-online-custom-actions-proposal.md`.
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
`plugin.listenlater` — sort, played_threshold, streaming_min_tracks, watch_outside, material_action, played_retention_days.

## Played auto-retention (0.1.17)
Played albums are auto-removed after `played_retention_days` (default 7; **0 = keep forever**). `DB::purgePlayed($days)` deletes `status='played'` rows with `played_at < now - days*86400` (items moved back to Listen Later (`status='later'`) or to Wish List (`status='wishlist'`) are never purged; re-playing resets `played_at`). Scheduled in `Plugin::postinitPlugin` via `Slim::Utils::Timers` — first run ~60s after start, re-armed every 24h (`_purgeTick`). Settings field validates 0–3650.

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
- **0.1.28** — Streaming-browse "Add" actions identify the service via Material's **`$SERVICE`** variable (`online-*` commands carry `svc:$SERVICE`), the clean upstream mechanism now that [PR #1235](https://github.com/CDrummond/lms-material/pull/1235) is **merged** — replaces the old baked-`svc:` workaround. Needs a Material build with the merged feature (next release); degrades to "entry absent" without it. See "Material custom actions on streaming …".
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
