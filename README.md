# Listen Later — LMS Plugin

A plugin for **Lyrion Music Server (LMS)** that lets you save an album, an individual track or a podcast episode — from your **local library**, any **streaming service** (Qobuz, Tidal, Bandcamp, Deezer) or your **podcast subscriptions** — into a curated list, browse it like a playlist, and have things move to a **Played** section once you've heard them. A separate **Wish List** sits alongside for things you mean to buy, and items move freely between the three lists.

Tested on LMS 9.x with the **Material Skin** (the classic skin works for the basics).

---

## Features at a glance

| Feature | What it gives you | Needs |
|---|---|---|
| **Add from the "…" menu** | *Add to Listen Later* and *Add to Wish List* on any album or track | Nothing |
| **Albums, tracks or podcasts** | Save a whole release, a single track, or a podcast episode | Nothing |
| **Knows what it saved** | Each row is marked *Album*, *EP*, *Single*, *Track* or *Podcast* | Nothing |
| **Three lists** | *Listen Later*, *Wish List* and *Played*, each with a live count and icon | Nothing |
| **Plays from the original source** | Library albums play locally; streaming albums replay through their service | The matching service plugin |
| **Automatic Played tracking** | A saved item moves to *Played* once you've heard most of it — from the list or anywhere | Nothing |
| **Move & remove** | Move an album between any two lists, or remove it, from the row's "…" menu | Material Skin |
| **Buy on Bandcamp** | Opens a Bandcamp album's purchase page in your browser | Bandcamp plugin |
| **Auto-tidy Played** | Played albums clear themselves after a set number of days | Nothing |
| **Material home shelf** | A scrollable *Listen Later* row on the home screen | Material Skin |
| **Sorting** | Recently added / Artist / Album / Year / Recently played | Nothing |

---

## Requirements

- **Lyrion Music Server 9.0.0+** (tested with the Material Skin; classic skin covers add/browse/play).
- For **streaming** albums, the matching service plugin installed and signed in: **Qobuz**, **Tidal**, **Bandcamp** and/or **Deezer**. Library albums need nothing extra.

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

1. Browse to any album, track or podcast episode — in your library, a streaming service or your podcast subscriptions.
2. Open its **"…"** menu and choose **Add to Listen Later** (or **Add to Wish List**).
3. Open **Apps → Listen Later** to see your lists. Tap a row to play it.
4. Play most of it and it moves itself to **Played**.

---

## Using it

### Adding things
*Add to Listen Later* and *Add to Wish List* appear in the **"…"** context menu of albums and tracks — local library and streaming alike. Adding something that's already saved (in any list) does nothing, so an accidental tap can't disturb your lists or bounce a Played item back.

The menu wording is the same everywhere, because the row you're on already tells you what you're saving: an album row saves the album, a track row saves that track. The one exception is Material's **Now Playing** screen, where there's no surrounding list to make it obvious — there the menu says **Add track to Listen Later**, and **Add album to Listen Later** sits in **"… → More"** if you want the whole release instead.

### Albums, tracks and podcasts
Each saved row is labelled with what it is, and carries a small glyph — **♫** for a multi-track release, **♪** for a single track, **❝** for a podcast episode:

- **Album** / **EP** / **Single** — a whole release. Streaming releases are classified when you add them, so the label is right straight away rather than changing later.
- **Track** — one song, saved from a track row. It plays on tap rather than opening a tracklist.
- **Podcast** — one episode, marked with a quote glyph rather than a note (see below).

Saving a streaming **single** stores it as the Single release rather than a loose track, so adding "the single" and "the track" can't leave you with two rows for the same recording.

### Podcasts
Episodes from LMS's built-in **Podcasts** app can be saved to *Listen Later* — which is, after all, exactly what a podcast queue is for. Add one from its **"…"** menu just like anything else; it appears in your list as **Podcast · &lt;show&gt;** and plays back through the Podcasts plugin, so its resume position keeps working.

There's no *Add to Wish List* for a podcast — you don't buy podcast episodes. (In a mixed list such as Favourites the entry can still appear, because the menu is built per list rather than per row; saving from it puts the episode in *Listen Later* anyway.)

**Episodes are matched against the podcasts you subscribe to.** A podcast browse row carries no playable link of its own, so the plugin identifies the episode by its artwork and title in your subscribed feeds. That means an episode from a show you've subscribed to can be saved from anywhere — the Podcasts app, a favourited feed, the home screen — but an episode you found through **Search feeds** on a show you *haven't* subscribed to can't be, and is refused rather than saved as something that would never play. Subscribe to the show first.

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
With **Automatically move albums to Played** on (the default), a **Listen Later** item moves to **Played** once you've heard most of it — whether you started playback from the list or anywhere else (Material, the app, a streaming page). Only *Listen Later* items are watched; *Wish List* items are left alone.

- A **multi-track release** is judged on how many of its tracks you've played — see the thresholds in Settings.
- Anything that's a **single track** (a saved track, a Single, or a podcast episode) is marked Played once you've actually listened to ~90% of it. Skipping past it doesn't count, and pausing doesn't either — it goes on real playback, not elapsed time — so something you skimmed past won't quietly move to *Played* and then be tidied away.

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
| **Streaming track count** | Distinct *streaming* tracks before a streaming album is Played (no reliable track total exists). Capped for an EP, which may have fewer tracks than this | 4 |
| **Auto-remove played albums after** | Days a Played album is kept before being removed (**0 = keep forever**). Re-playing it resets the clock | 7 |
| **Add to Material context menus** | Adds the *Add to Listen Later* / *Add to Wish List* entries to Material's menus (takes effect after a restart) | On |

---

## Notes & limitations

- **Album-add from streaming** is reached from a track or album row in the service's browse view; there's no global LMS hook to inject an item into every service's own album "…" menu, so the plugin uses `Slim::Menu::TrackInfo`/`AlbumInfo` plus Material's custom-action mechanism.
- **Adding directly from a streaming service's *browse list*** (e.g. a *New Releases* row) relies on a Material Skin feature that was merged upstream ([lms-material #1235](https://github.com/CDrummond/lms-material/pull/1235)) and ships in **Material 6.4.4 and later**. On older Material that one entry just won't appear — adding from an album's or track's own "…" menu (and everything else) works regardless.
- **Outside-the-plugin Played detection** is reliable for the local library (matched by album id); for streaming it's best-effort, matched on the now-playing artist + album.
- **Material custom actions on home-shelf cards** only appear after you've opened a streaming browse page in the same session — a Material limitation in how the home shelves render menus.
- **Internet-radio stations don't show *Add*.** Radio is a live stream, not something you can save and replay, so the *Add to Listen Later* / *Add to Wish List* entries are deliberately hidden on radio browse rows (BBC Sounds, TuneIn's Music/News/Sports/… categories, etc.). This applies to radio *browse* rows; a radio card on a Material home shelf can't be suppressed the same way, but adding one there is simply ignored. *(After updating, reload Material once — Ctrl/Cmd+Shift+R — so it re-reads its custom-actions file.)*
- **Podcast episodes must belong to a show you subscribe to** — that's how the plugin identifies them (see *Podcasts* above). Episodes found via *Search feeds* on an unsubscribed show are refused rather than saved unplayable.
- **Saving an individual track needs the Material Skin.** On the classic skin a track's "…" menu offers the *album* it belongs to, which is what that menu has always been able to reach.
- **Storage** is a SQLite database in the server cache directory, so your lists survive restarts and rescans.
