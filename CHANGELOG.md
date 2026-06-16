# Changelog

## 0.1.6 — Grid toggle on Material 6.4.x (header icons)

### Fixed
- **The list/grid toggle now actually appears (the 0.1.5 change wasn't enough on Material 6.4.x).** Material 6.4's grid check counts *every* item without an image as disqualifying — it has no exception for header rows (newer Material does). Our section headers had no image, so they silently disabled the toggle. Headers now carry the plugin icon, so every row has an image and the grid/thumbnail view is offered while the headers still render as dividers.

## 0.1.5 — Grid/list view toggle restored

### Fixed
- **The list/grid (thumbnail) view toggle now works while keeping the section headers.** Material disables that toggle for any page containing a `type:"text"` item; the empty-section "Nothing here yet" placeholder was that item. It's removed — an empty section just shows its "(0)" header — so albums can now be shown as a thumbnail grid with the Listen to Later / Played headers as dividers, or as a list. (`type:"header"` rows don't affect the toggle.)

## 0.1.4 — Single-page album view

### Changed
- **The plugin now opens straight onto the list.** One page shows Plugin Settings at the top, then a Material **header** "Listen to Later (N)" with its albums, then a "Played (N)" header with its albums — no more drilling into separate sections.
- **Albums play from the main page.** Each album is a playable row (like other LMS album views): play / play next / add to queue from its "…", and tap to open the tracklist.
- **Remove / Move moved into the "…" context menu.** They're no longer rows you tap into; they live under the album's ellipsis (More → Remove / Move) and refresh the list in place.

### Added
- `listentolater contextmenu` (the per-album Remove/Move menu) and `listentolater remove` / `listentolater move` commands.

## 0.1.3 — Real action item + placement

### Fixed
- **Clicking "Add" no longer opens a blank page.** The menu item was an OPML `url` drill; it's now a proper jive **action** that fires a registered `listentolater add` command (modelled on the built-in `playitem`), so it adds the album in place and pops back with a brief confirmation.
- **Placement:** the entry is registered with `menuMode` and positioned with the play actions (`before => 'artwork'` for tracks, `before => 'contributors'` for albums) so it's less likely to be buried under Material's "More" group.

### Added
- `listentolater add` CLI command (carries the album as flat params and rebuilds the replayable ref).

## 0.1.2 — The actual fix: provider registration

### Fixed
- **"Add album to Listen to Later" now appears in the track/album "…" menus.** Root cause (present since the first build): `registerInfoProvider` takes a *flat* `($name, %details)` list, but we passed a **hashref** — so `func` was lost and LMS silently registered an inert provider that was skipped when the menu was built. No error was logged because the menu builder only skips providers whose `func` is undefined. Now registered with a flat list, matching every built-in provider. This is why none of the earlier capture fixes changed anything.

## 0.1.1 — Add-menu fixes

### Fixed
- **"Add album to Listen to Later" missing from track/album menus.** The track capture path had two defects that made it die silently on local tracks (so no menu item rendered): it dereferenced `$remoteMeta` when it was `undef` (local tracks have no remote metadata), and it treated `file://` library URLs as remote/streaming. Now `$remoteMeta` is always a hashref and remote-vs-local is decided from the track's own flag.
- Hardened info-provider registration: each `registerInfoProvider` call now `require`s its menu module and is wrapped in `eval`, so a not-yet-loaded module can't abort the whole plugin.

### Added
- `warn`-level diagnostics around provider registration and the add handlers (temporary, to confirm wiring on the live server).

## 0.1.0 — Initial build

First working version of **Listen to Later**, a Lyrion Music Server plugin that saves albums from any source into a curated list and tracks what you've played.

### Added
- **Add from the "…" menu** — an *Add album to Listen to Later* entry appears in the track context menu (via `Slim::Menu::TrackInfo`, so it works for both local-library and streaming tracks) and in the library album context menu (via `Slim::Menu::AlbumInfo`). Works in Material and the classic skin.
- **Browsable list** with two sections, **Listen to Later** and **Played**, each showing a live count. Each album drills into a small menu: *Play album*, *Remove from list*, and *Move* between sections.
- **Plays through the original source** — library albums play from your library; streaming albums replay through the originating service (Qobuz / Bandcamp). When a native album id wasn't captured, the album is re-found via the service's own search.
- **Automatic Played tracking** — once you've listened to most of a saved album (default 60% of a library album's tracks, or 4 distinct tracks for streaming) it moves to the Played section. Works whether you play it from the list or anywhere else; can be turned off.
- **Sort options** — Recently added / Artist / Album / Year / Recently played.
- **Persistent SQLite storage** (`listentolater.db` in the server cache dir) so the list survives restarts and can back future features.
- Settings page for default sort, the Played threshold, the streaming track count, and the auto-Played toggle.

### Known limitations
- Streaming album "…" coverage depends on each service routing through TrackInfo; album-level add for streaming is reached via a track ("add this track's album").
- Outside-the-plugin Played detection is reliable for the local library; for streaming it is best-effort (it matches on artist + album from the now-playing metadata).
