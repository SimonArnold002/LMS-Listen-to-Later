# Changelog

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
