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
