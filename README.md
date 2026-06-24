# Listen Later — LMS Plugin

A plugin for **Lyrion Music Server (LMS)** that lets you save an album — from your **local library** or any **streaming service** (Qobuz, Tidal, Bandcamp) — into a curated list, browse it like a playlist *of albums*, and have albums move to a **Played** section once you've heard them. A separate **Wish List** sits alongside for things you mean to buy, and albums move freely between the three lists.

Tested on LMS 9.x with the **Material Skin** (the classic skin works for the basics).

---

## Features at a glance

| Feature | What it gives you | Needs |
|---|---|---|
| **Add from the "…" menu** | *Add to Listen Later* and *Add to Wish List* on any album or track | Nothing |
| **Three lists** | *Listen Later*, *Wish List* and *Played*, each with a live count and icon | Nothing |
| **Plays from the original source** | Library albums play locally; streaming albums replay through their service | The matching service plugin |
| **Automatic Played tracking** | A saved album moves to *Played* once you've heard most of it — from the list or anywhere | Nothing |
| **Move & remove** | Move an album between any two lists, or remove it, from the row's "…" menu | Material Skin |
| **Buy on Bandcamp** | Opens a Bandcamp album's purchase page in your browser | Bandcamp plugin |
| **Auto-tidy Played** | Played albums clear themselves after a set number of days | Nothing |
| **Material home shelf** | A scrollable *Listen Later* row on the home screen | Material Skin |
| **Sorting** | Recently added / Artist / Album / Year / Recently played | Nothing |

---

## Requirements

- **Lyrion Music Server 9.0.0+** (tested with the Material Skin; classic skin covers add/browse/play).
- For **streaming** albums, the matching service plugin installed and signed in: **Qobuz**, **Tidal** and/or **Bandcamp**. Library albums need nothing extra.

Every streaming integration is optional and degrades gracefully — if a service plugin isn't present, albums from it simply can't be replayed.

---

## Installation

**Via repository (recommended).** In LMS go to **Settings → Plugins → Additional Repositories** and add:

```
https://simonarnold002.github.io/LMS-Listen-to-Later/repo.xml
```

Then install **Listen Later** from the plugin list and restart.

**Manual.** Download `ListenLater.zip` from the [repository](https://github.com/SimonArnold002/LMS-Listen-to-Later), unzip it into your LMS `Plugins/` directory so it sits as `Plugins/ListenLater/`, and restart:

```bash
sudo rm -rf /var/lib/squeezeboxserver/Plugins/ListenLater
sudo unzip ListenLater.zip -d /var/lib/squeezeboxserver/Plugins/
sudo chown -R squeezeboxserver:nogroup /var/lib/squeezeboxserver/Plugins/ListenLater
sudo systemctl restart lyrionmusicserver
```

---

## Quick start

1. Browse to any album or track — in your library or a streaming service.
2. Open its **"…"** menu and choose **Add to Listen Later** (or **Add to Wish List**).
3. Open **Apps → Listen Later** to see your lists. Tap an album to play it.
4. Play most of an album and it moves itself to **Played**.

---

## Using it

### Adding albums
*Add to Listen Later* and *Add to Wish List* appear in the **"…"** context menu of albums and tracks — local library and streaming alike. Adding an album that's already saved (in any list) does nothing, so an accidental tap can't disturb your lists or bounce a Played album back.

### The three lists
Open **Apps → Listen Later** and you'll see one page with three headed sections, each showing a live count:

- **Listen Later** — your main queue of things to hear.
- **Wish List** — albums you intend to buy. Never auto-played and never auto-removed.
- **Played** — albums you've already heard (auto-tidied; see below).

### Moving & removing
Each album row's **"… → More"** menu offers **Move to …** for the two lists it isn't in, plus **Remove from list**. The list refreshes in place.

### Playing
Tap an album to play it. Library albums play from your library; streaming albums replay through the service they came from (falling back to that service's own search if the original reference is gone).

### Buy on Bandcamp
For a Bandcamp album, the **"… → More"** menu has **Buy on Bandcamp**, which opens the album's Bandcamp page in your browser. The page link is found on first use and cached; if the exact page can't be matched it falls back to a Bandcamp search.

### Automatic Played tracking
With **Automatically move albums to Played** on (the default), a **Listen Later** album moves to **Played** once you've heard most of it — whether you started playback from the list or anywhere else (Material, the app, a streaming page). Only *Listen Later* albums are watched; *Wish List* albums are left alone. See the thresholds in Settings.

### Material home shelf
On the Material Skin home screen you can show a horizontal **Listen Later** row of your saved albums, each playable/tappable. It uses Material's standard home-extra mechanism (no skin patching). If it isn't shown, enable it under Material's home-screen customisation.

### Sorting
A single **Default sort order** applies to all three lists: Recently added, Artist, Album, Year, or Recently played.

---

## Settings reference

Open **Settings → Advanced → Listen Later** (also linked as **Plugin Settings** at the top of the plugin's page).

| Setting | What it does | Default |
|---|---|---|
| **Default sort order** | Ordering for all three lists | Recently added |
| **Automatically move albums to Played** | Master switch for auto-marking | On |
| **Played threshold** | Percent of a *library* album's tracks that must play before it's Played | 60% |
| **Streaming track count** | Distinct *streaming* tracks before a streaming album is Played (no reliable track total exists) | 4 |
| **Auto-remove played albums after** | Days a Played album is kept before being removed (**0 = keep forever**). Re-playing it resets the clock | 7 |
| **Add to Material context menus** | Adds the *Add to Listen Later* / *Add to Wish List* entries to Material's menus (takes effect after a restart) | On |

---

## Notes & limitations

- **Album-add from streaming** is reached from a track or album row in the service's browse view; there's no global LMS hook to inject an item into every service's own album "…" menu, so the plugin uses `Slim::Menu::TrackInfo`/`AlbumInfo` plus Material's custom-action mechanism.
- **Adding directly from a streaming service's *browse list*** (e.g. a *New Releases* row) relies on a Material Skin feature that was merged upstream ([lms-material #1235](https://github.com/CDrummond/lms-material/pull/1235)) and ships in **Material's next release**. Until your Material includes it, that one entry just won't appear — adding from an album's or track's own "…" menu (and everything else) works regardless.
- **Outside-the-plugin Played detection** is reliable for the local library (matched by album id); for streaming it's best-effort, matched on the now-playing artist + album.
- **Material custom actions on home-shelf cards** only appear after you've opened a streaming browse page in the same session — a Material limitation in how the home shelves render menus.
- **Storage** is a SQLite database in the server cache directory, so your lists survive restarts and rescans.
