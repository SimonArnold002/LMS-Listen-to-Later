# Changelog

## 0.1.29 — Section headers fixed for newer Material

### Fixed
- **Section headers (Listen Later / Wish List / Played) render as dividers again on newer Material.** Material's development line changed how it draws *actionable* headers — because the plugin's headers carry a "re-list this section" action, newer Material was drawing them as **grid cards** mixed in with the album artwork instead of as full-width dividers. The plugin now emits the header as Material's `header-basic` type (which renders as a plain, non-actionable divider).

### Compatibility
- The new `header-basic` type only exists in **Material 6.4.3+**. The plugin detects the running Material version and uses it only there; on **older Material it keeps the previous `header` behaviour unchanged**, so nothing changes for users on older skins.

## 0.1.28 — Streaming adds use Material's `$SERVICE`

### Changed
- **The "Add to Listen Later" / "Add to Wish List" actions on a streaming service's browse list now identify the service via Material's `$SERVICE` variable** — the clean mechanism in the upstream Material change ([PR #1235](https://github.com/CDrummond/lms-material/pull/1235), now merged), replacing the earlier internal workaround.

### Compatibility
- Adding directly from a **streaming service's browse list** requires a Material build that includes the merged custom-actions-on-streaming feature (the next Material release). On Material without it, that one entry simply doesn't appear; every other way to add (the album/track "…" menu, library, etc.) is unaffected.

## 0.1.27 — "More info" points to the docs page

### Changed
- The plugin's **homepage / "More info" link** (shown in LMS *Manage Plugins* and the repository's plugin list) now points to the rendered docs page (`README.html` on GitHub Pages) instead of the bare GitHub repo.

## 0.1.26 — Code-review fixes

### Fixed
- **Settings validation actually applies now.** The clamps on Played threshold / streaming track count / retention days were being overwritten by the base settings handler (which re-saves the raw form values), so out-of-range or non-numeric entries could be stored — a bad value could make albums get marked Played far too early. The form values are now sanitised before the base handler saves them.
- **Material `actions.json` is written atomically** (temp file + rename) instead of truncating-in-place. A crash mid-write could otherwise corrupt that file, which is shared with Material and every other plugin's custom actions.
- **"Buy on Bandcamp" can no longer hang.** If the album lookup stalls (e.g. a network stall with no error), the request now completes after 15s with the Bandcamp search fallback instead of spinning forever.
- **Bandcamp albums play cleanly.** The Bandcamp plugin prepends a "Download album from …" text line + page link to its track list; those non-playable items are now kept out of the drill view and play queue (still used for the Buy link).
- Guarded the Qobuz `_albumItem` call so a future Qobuz change can't crash the album-search fallback.

## 0.1.25 — Renamed: Listen Later / Wish List

### Changed
- **Plugin renamed from "Listen to Later" to "Listen Later".**
- **The "To Buy" list is now "Wish List".**
- Both renames are thorough: plugin title, every menu item, toast and settings label, plus all internal identifiers (Perl packages `Plugins::ListenLater::*`, the plugin folder, the `listenlater` command, the `plugin.listenlater` prefs namespace, the `listenlater.db` database, the `wishlist` list status, the Material custom-action categories, and the icon filenames).

### Migration (automatic)
- **Your existing data carries over.** On first start after upgrading: the old `listentolater.db` is moved to `listenlater.db` (saved albums kept), any `tobuy` rows are converted to `wishlist`, and settings are copied from the old `plugin.listentolater` prefs. Stale "Add to Listen to Later"/"Add to To Buy" entries are cleaned from Material's `actions.json`.
- The download is now `ListenLater.zip` (the GitHub repo/Pages path is unchanged).

## 0.1.24 — Per-section icons

### Changed
- **Each list now has its own icon.** The three sections are easier to tell apart at a glance:
  - **Listen Later** — a new "music note + clock" icon (also now the plugin's own icon, on the Apps tile, home shelf and Manage Plugins).
  - **Wish List** — Material's shopping-trolley icon (the same one used by the "Add to Wish List" context-menu action).
  - **Played** — Google's "music history" icon (a clock/history ring with a note).
- Album rows without their own cover art now fall back to their section's icon instead of the generic plugin icon.

### Notes
- Wish List uses Material's own font icon via the `_MTL_icon_shopping_cart` filename convention, so it always matches the current theme. Played ships as a recolourable SVG (`_svg.png` convention) because `music_history` isn't in Material's bundled icon font; non-Material skins get a real transparent PNG fallback for every icon.

## 0.1.23 — Buy on Bandcamp

### Added
- **"Buy on Bandcamp" for Bandcamp albums.** A Bandcamp item's "… → More" menu now has a **Buy on Bandcamp** entry that opens the album's Bandcamp page in your browser (handy for Wish List items). We only store artist+album for Bandcamp, so the page URL is resolved on first use (the Bandcamp plugin emits it among the album's items) and then **cached in the DB** (`ref.buy_url`) for instant opens afterwards. If the exact page can't be matched, it falls back to a Bandcamp album search for the artist+album, so there's always a working link.

## 0.1.22 — New "Wish List" list

### Added
- **A third list, "Wish List".** Alongside Listen Later and Played, you can now keep a wishlist of albums to buy. It appears as its own section in the plugin view (between Listen Later and Played).
- **"Add to Wish List" context-menu action.** Every place that offers "Add to Listen Later" — Material's album/track/playlist menus (including streaming services) and the local library "…" menus — now also offers **Add to Wish List**, which saves the album straight into the Wish List list.
- **Move to/from Wish List.** Each album row's "… → More" menu now lists a "Move to …" entry for whichever two lists it isn't currently in (Listen Later / Wish List / Played), plus Remove.

### Notes
- **Wish List albums are never auto-removed.** The 7-day Played retention only ever deletes `status='played'` rows, and the auto-"move to Played" detector only acts on Listen Later albums — so a Wish List album (or one moved back to Listen Later) is never purged and never auto-marked Played. This state lives in the album's `status` column, so it survives restarts.
- Adding an album that's already saved anywhere remains a no-op (consistent with 0.1.21) — to put an existing album into Wish List, use the "Move to Wish List" action.

## 0.1.21 — Ignore accidental re-adds

### Changed
- **Adding an album that's already saved is now a true no-op, in any section.** Previously, clicking "Add to Listen Later" on an album already in the **Played** section silently bounced it back into the active Listen Later list — easy to trigger by accident. Now if the album exists in either section the Add is ignored (toast: *"Already in your list"*); a Played album only returns to the active list via the explicit **Move to Listen Later** action. Dedupe is per source (`source` + normalised `artist|album`).

## 0.1.20 — Fix Tidal & Bandcamp playback

### Fixed
- **Tidal albums now play.** Tidal browse rows carry the native album id in their `favorites_url` (`tidal://album:<id>`), but `addctx` was discarding it and there was no Tidal adapter — so playback fell back to an (artist-less) search that found nothing. Now the id is captured from the favurl and the album is replayed through Tidal's own `getAlbum` (passthrough key `id`); a Tidal album search is also added as a fallback. **Tidal albums added before this version need re-adding** to capture the id.
- **Bandcamp albums now play.** Resolving an album's tracks crashed with *"Not a HASH reference at Sources.pm line 195"*: Qobuz/Tidal return `{ items => [...] }` from their album coderef, but Bandcamp returns a bare arrayref of tracks — the code only handled the hashref form. Now both shapes are accepted.

## 0.1.19 — Revert Remove/Move to the "… → More" menu

### Changed
- **Reverted 0.1.18.** Putting Remove/Move at the *top* of the "…" was possible, but making them refresh the list **in place** (rather than re-listing into a new, less tidy page with an awkward back path) would have required a second Material patch (`browse-page.js`, in the main bundle). To keep the Material footprint to the single deferred-bundle patch, Remove/Move are back in the row's **"… → More"** menu, where they already refresh in place (`nextWindow => 'parent'`, since 0.1.15). "Add" stays suppressed on the plugin's own list and home shelf.

## 0.1.18 — Remove / Move at the top of the "…" menu

### Changed
- **Remove and Move now sit at the top of each album's "…" menu** (where "Add to Listen Later" appears on streaming items), instead of under "More". They work exactly like Add: a Material custom action that acts on the item's displayed info — here the row's name (`$TITLE`) — and the plugin matches it back to the saved album. Move toggles the album between Listen Later and Played. Both re-list the view so the change shows immediately. **Plugin-only** — no Material bundle change (uses the per-app `listenlater-album` category the patched bundle already renders, plus stock `$TITLE`/`lmsbrowse`).
- The home-shelf cards no longer offer "Add" either (suppressed via the shelf's own category).

### Note
- Classic (non-Material) skins have no custom actions, so per-row Remove/Move are Material-only now.

## 0.1.17 — Auto-remove old Played albums

### Added
- **Played albums are automatically removed after a retention window** (default **7 days** from when they were played), unless you move them back to Listen Later first. New setting **"Auto-remove played albums after N days"** (`played_retention_days`; set **0** to keep them forever). A daily background task (`DB::purgePlayed`, scheduled in `postinitPlugin`, first run ~60s after start) deletes `status='played'` rows whose `played_at` is older than the window; re-playing an album resets its clock.

## 0.1.16 — Material home-page shelf

### Added
- **A "Listen Later" shelf on the Material home screen** — a horizontal, scrollable row of the albums in your Listen Later list, each playable / tappable (with the same "…" Remove/Move). Registered via Material's `registerHomeExtra` (the same mechanism Qobuz/Bandcamp use), so it works on stock Material — no patched bundle needed. Enable it under Material's home-screen customisation if it isn't shown by default. New `HomeExtras.pm` (`LLHome` → `Browse::homeShelf`); the feed is a flat, quantity-stable card list so deep playback from the shelf resolves correctly.

## 0.1.15 — Remove/Move refresh the list in place

### Fixed
- **Remove/Move from a row's "…" → More no longer jump to the home screen.** They used `nextWindow => 'grandparent'` (two levels up); now `'parent'`, which on a Material "More" menu triggers an in-place list refresh (`refreshList`) so the list updates where you are. Plugin-only change — no Material reinstall needed if you already have the 0.1.14 bundle.

## 0.1.14 — Don't offer "Add" inside our own view (patched Material test)

### Changed
- **"Add to Listen Later" no longer appears on items inside the plugin's own list.** Re-adding an album already in the list is pointless and would bounce a *Played* album back to *Listen Later*. The patched Material now lets an app define a custom-action category for its **own** view (e.g. `listenlater-album`); if defined — even empty — it takes precedence over the generic `online-*` category. The plugin writes empty `listenlater-album`/`-track`/`-artist` categories, so its own rows show no "Add".
- Remove/Move stay in each row's "…" → **More** menu (that context menu is the only place that reliably carries our internal album id, which a custom action can't read).

## 0.1.13 — Streaming album rows: real capture + service from the view (patched Material test)

### Changed
- The custom action now works on **service album rows while browsing** (e.g. Qobuz New Releases) when paired with the patched Material build. Those rows carry no `favorites_url`/`metadata` — only a playable `item_id` and a two-line `title`/`subtitle` — so Material can't classify them as albums. The patched Material instead keys off **playability** and exposes the row's title/subtitle as `$ALBUMNAME`/`$ARTISTNAME`, and bakes the **browsing service id** (the Material view's `command`, e.g. `qobuz`) into the action as `svc:`.
- `addctx` now: strips a trailing `(YYYY)` from the **artist** line (streaming rows put the year there) and a trailing format qualifier (`(Hi-Res…)`, `(Explicit)`, …) from the **album**; and resolves the source from the explicit `svc` param first (no guessing), falling back to the cover host, then the default streaming service.
- Added `Sources::sourceFromImage` (cover-host → service) as a fallback only.

## 0.1.12 — Online-item custom-action categories (for patched Material test)

### Changed
- Replaced the non-working `qobuz`/`bandcamp` custom-action categories with `online-album` / `online-track` / `online-artist`, using the variables that actually populate for streaming items (`$TITLE`, `$FAVURL`, `$IMAGE`). These only do anything on a Material build that wires custom actions for online items (see `docs/material-online-custom-actions-proposal.md`); they're harmless otherwise.

## 0.1.11 — Fix local source + artwork from custom action

### Fixed
- **A local album added via the main-menu action was tagged "Qobuz" with no artwork.** Material passes the album title with the year appended (e.g. "Night Train (1963)") and leaves artist/year/cover empty, so the old title match failed and it fell through to the default streaming source. Now a numeric album id that resolves in the library is trusted as the authoritative "local" signal, and the real title / artist / year / **artwork** are taken from the library album object. The year suffix is also stripped from streaming names.
- Passes `$IMAGE` through so streaming adds keep their cover too.

### Known
- The custom action still does not appear on streaming services' per-item "…" menus (Qobuz/Bandcamp/Tidal) — Material doesn't apply custom actions to online items there. Adding a streaming album is via **Now Playing** (play it, then "…" on the track → Add album), or possibly a per-app toolbar action inside a Qobuz album.

## 0.1.10 — Working "Add" in the main menu (not buried in More)

### Fixed
- **The main-menu "Add to Listen Later" now works.** The command itself (`addctx`) was verified good; the failure was purely the leftover **0.1.7-format** entry that the de-dupe didn't catch. The writer now strips every old/legacy entry of ours from all categories before writing the correct flat-array entry, so only the working one remains.

### Changed
- Re-added the custom action to the **local** categories (album / album-track / track / playlist) — restoring the preferred placement next to "Add to Favourites" — alongside the `qobuz`/`bandcamp` categories. (The AlbumInfo/TrackInfo "More" entries still exist too; de-duplicating those is a follow-up.)

> After installing, do one Material reload so the client drops its cached copy of the old broken action.

## 0.1.9 — De-dupe custom action; scope to streaming

### Fixed
- **The duplicate/broken "Add to Listen Later" on local albums is gone.** The de-dupe now recognises the old (0.1.7) action format and the legacy entries, and strips our action from *every* category before re-writing, so the broken leftover that showed in the main menu and errored is removed. Existing user-defined custom actions are preserved.

### Changed
- The Material custom action is now scoped to the **`qobuz` / `bandcamp`** categories only. Local albums/tracks are already served by the AlbumInfo/TrackInfo providers, so the custom action no longer duplicates them there. (Material doesn't apply the library `album`/`track` categories to online items anyway.)

## 0.1.8 — Fix custom-action format; source from play URL

### Fixed
- **Tapping "Add to Listen Later" on a local album did nothing.** Material's `lmscommand` custom action must be a flat array (`["listenlater","addctx","name:$ALBUMNAME",…]`); it was written as a `{command,params}` object (that's the `lmsbrowse` shape), so an empty command was dispatched. Now a flat array — local adds work.

### Changed
- The action now passes `$FAVURL` (the item's play URL, e.g. `qobuz://…`), and `addctx` uses it to identify the source: a streaming URL → that service; `file://`/numeric library id → local library; otherwise the default streaming service. Unpopulated Material variables (which arrive as the literal `$NAME` token) are ignored.
- Added per-app `qobuz`/`bandcamp` custom-action categories as well, since Material doesn't apply the library `album`/`track` categories to online items — this is the attempt to surface the entry on Qobuz pages.

## 0.1.7 — Qobuz / streaming add via Material context menus

### Added
- **"Add to Listen Later" in Material's context menus, including Qobuz.** Streaming services own their own browse "…" menus, so the TrackInfo/AlbumInfo providers can't appear there. Instead the plugin now registers a Material **custom action** (merged safely into `prefs/material-skin/actions.json`, preserving any existing user actions) on the album / track / playlist menus. New `listenlater addctx` command receives the item's metadata, decides whether it's a local-library album (reliable id) or a streaming album (replayed via the service's search), and adds it. Toggle under Settings → Material Skin (on by default; takes effect after a restart).
- Verified live: a Qobuz album added by artist+album alone resolves back to its real tracks via Qobuz search, so streaming albums play correctly from the list.

### Note
- This build logs (at `warn`) the exact variables Material passes for each item, to confirm what's available for online items.

## 0.1.6 — Grid toggle on Material 6.4.x (header icons)

### Fixed
- **The list/grid toggle now actually appears (the 0.1.5 change wasn't enough on Material 6.4.x).** Material 6.4's grid check counts *every* item without an image as disqualifying — it has no exception for header rows (newer Material does). Our section headers had no image, so they silently disabled the toggle. Headers now carry the plugin icon, so every row has an image and the grid/thumbnail view is offered while the headers still render as dividers.

## 0.1.5 — Grid/list view toggle restored

### Fixed
- **The list/grid (thumbnail) view toggle now works while keeping the section headers.** Material disables that toggle for any page containing a `type:"text"` item; the empty-section "Nothing here yet" placeholder was that item. It's removed — an empty section just shows its "(0)" header — so albums can now be shown as a thumbnail grid with the Listen Later / Played headers as dividers, or as a list. (`type:"header"` rows don't affect the toggle.)

## 0.1.4 — Single-page album view

### Changed
- **The plugin now opens straight onto the list.** One page shows Plugin Settings at the top, then a Material **header** "Listen Later (N)" with its albums, then a "Played (N)" header with its albums — no more drilling into separate sections.
- **Albums play from the main page.** Each album is a playable row (like other LMS album views): play / play next / add to queue from its "…", and tap to open the tracklist.
- **Remove / Move moved into the "…" context menu.** They're no longer rows you tap into; they live under the album's ellipsis (More → Remove / Move) and refresh the list in place.

### Added
- `listenlater contextmenu` (the per-album Remove/Move menu) and `listenlater remove` / `listenlater move` commands.

## 0.1.3 — Real action item + placement

### Fixed
- **Clicking "Add" no longer opens a blank page.** The menu item was an OPML `url` drill; it's now a proper jive **action** that fires a registered `listenlater add` command (modelled on the built-in `playitem`), so it adds the album in place and pops back with a brief confirmation.
- **Placement:** the entry is registered with `menuMode` and positioned with the play actions (`before => 'artwork'` for tracks, `before => 'contributors'` for albums) so it's less likely to be buried under Material's "More" group.

### Added
- `listenlater add` CLI command (carries the album as flat params and rebuilds the replayable ref).

## 0.1.2 — The actual fix: provider registration

### Fixed
- **"Add album to Listen Later" now appears in the track/album "…" menus.** Root cause (present since the first build): `registerInfoProvider` takes a *flat* `($name, %details)` list, but we passed a **hashref** — so `func` was lost and LMS silently registered an inert provider that was skipped when the menu was built. No error was logged because the menu builder only skips providers whose `func` is undefined. Now registered with a flat list, matching every built-in provider. This is why none of the earlier capture fixes changed anything.

## 0.1.1 — Add-menu fixes

### Fixed
- **"Add album to Listen Later" missing from track/album menus.** The track capture path had two defects that made it die silently on local tracks (so no menu item rendered): it dereferenced `$remoteMeta` when it was `undef` (local tracks have no remote metadata), and it treated `file://` library URLs as remote/streaming. Now `$remoteMeta` is always a hashref and remote-vs-local is decided from the track's own flag.
- Hardened info-provider registration: each `registerInfoProvider` call now `require`s its menu module and is wrapped in `eval`, so a not-yet-loaded module can't abort the whole plugin.

### Added
- `warn`-level diagnostics around provider registration and the add handlers (temporary, to confirm wiring on the live server).

## 0.1.0 — Initial build

First working version of **Listen Later**, a Lyrion Music Server plugin that saves albums from any source into a curated list and tracks what you've played.

### Added
- **Add from the "…" menu** — an *Add album to Listen Later* entry appears in the track context menu (via `Slim::Menu::TrackInfo`, so it works for both local-library and streaming tracks) and in the library album context menu (via `Slim::Menu::AlbumInfo`). Works in Material and the classic skin.
- **Browsable list** with two sections, **Listen Later** and **Played**, each showing a live count. Each album drills into a small menu: *Play album*, *Remove from list*, and *Move* between sections.
- **Plays through the original source** — library albums play from your library; streaming albums replay through the originating service (Qobuz / Bandcamp). When a native album id wasn't captured, the album is re-found via the service's own search.
- **Automatic Played tracking** — once you've listened to most of a saved album (default 60% of a library album's tracks, or 4 distinct tracks for streaming) it moves to the Played section. Works whether you play it from the list or anywhere else; can be turned off.
- **Sort options** — Recently added / Artist / Album / Year / Recently played.
- **Persistent SQLite storage** (`listenlater.db` in the server cache dir) so the list survives restarts and can back future features.
- Settings page for default sort, the Played threshold, the streaming track count, and the auto-Played toggle.

### Known limitations
- Streaming album "…" coverage depends on each service routing through TrackInfo; album-level add for streaming is reached via a track ("add this track's album").
- Outside-the-plugin Played detection is reliable for the local library; for streaming it is best-effort (it matches on artist + album from the now-playing metadata).
