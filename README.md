# Listen Later — Lyrion Music Server plugin

Save an album — from your **local library** or any **streaming service** (Qobuz, Bandcamp, Tidal) — into a *Listen Later* list, browse it like a playlist *of albums*, and have albums move to a **Played** section once you've heard them. A separate **Wish List** wishlist sits alongside, and albums can be moved freely between the three lists.

## Features
- **Add from the "…" menu.** *Add album to Listen Later* and *Add to Wish List* entries appear in the track context menu (local and streaming) and in the library album context menu. Material skin preferred; also works in the classic skin.
- **Three sections:** *Listen Later*, *Wish List* and *Played*, each with a live count and its own icon.
- **Per-album actions:** Play album, Remove from list, Move between any of the three sections.
- **Buy on Bandcamp.** Bandcamp albums get a *Buy on Bandcamp* entry in the "… → More" menu that opens the album's page in your browser (handy for *Wish List* items).
- **Plays through the original source.** Library albums play from the library; streaming albums replay through the service they came from (falling back to the service's own search when needed).
- **Automatic Played tracking.** A saved album moves to *Played* once you've listened to most of it — whether you played it from the list or anywhere else. Configurable, and can be turned off.
- **Sort:** Recently added / Artist / Album / Year / Recently played.
- **Material home shelf.** A *Listen Later* row on the Material Skin home screen — a horizontal, scrollable strip of your saved albums, each playable/tappable. Uses Material's standard home-extra mechanism (no skin patching). Enable it in Material's home-screen customisation if it isn't shown by default.
- **Auto-tidy the Played section.** Played albums are removed automatically after a configurable window (default 7 days), unless you move them back to *Listen Later* (or *Wish List*) first. Set the window to 0 to keep them forever. *Wish List* albums are never auto-marked Played nor auto-removed.
- **Durable storage.** A SQLite database in the server cache directory, ready to back future features.

## Requirements
- Lyrion Music Server 9.0+.
- For streaming albums: the relevant service plugin installed (Qobuz, Bandcamp and/or Tidal).

## Install (manual)
```bash
sudo rm -rf /var/lib/squeezeboxserver/Plugins/ListenLater
sudo unzip ListenLater.zip -d /var/lib/squeezeboxserver/Plugins/
sudo chown -R squeezeboxserver:nogroup /var/lib/squeezeboxserver/Plugins/ListenLater
sudo systemctl restart lyrionmusicserver
```

## Settings
- **Default sort order** for all three lists.
- **Automatically move albums to Played** (master toggle for auto-marking).
- **Played threshold** — percent of a library album's tracks that must play (default 60).
- **Streaming track count** — distinct streaming tracks before a streaming album is marked played (default 4; streaming albums have no reliable track total).
- **Auto-remove played albums after N days** — retention window for the Played section (default 7; 0 = keep forever).

## Notes & limitations
- For streaming, album-level add is reached from a track ("add this track's album"), because there is no global hook to inject an item into every service's own album "…" menu — `Slim::Menu::TrackInfo` is the cross-service path.
- Outside-the-plugin Played detection is reliable for the local library; for streaming it is best-effort (matched on artist + album from the now-playing metadata).
