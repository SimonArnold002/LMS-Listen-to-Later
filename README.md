# Listen Later — LMS Plugin

A plugin for **Lyrion Music Server (LMS)** that lets you save an album, an individual track, a curated playlist or a podcast episode — from your **local library**, any **streaming service** (Qobuz, Tidal, Bandcamp, Deezer, Spotify) or your **podcast subscriptions** — into a curated list, browse it like a playlist, and have things move to a **Played** section once you've heard them. A separate **Wish List** sits alongside for things you mean to buy, and items move freely between the three lists.

Tested on LMS 9.x with the **Material Skin** (the classic skin works for the basics).

---

## Features at a glance

| Feature | What it gives you | Needs |
|---|---|---|
| **Add from the "…" menu** | *Add to Listen Later* and *Add to Wish List* on any album or track | Nothing |
| **Albums, tracks, playlists or podcasts** | Save a whole release, a single track, a curated playlist, or a podcast episode | Nothing |
| **Knows what it saved** | Each row is marked *Album*, *EP*, *Single*, *Track*, *Playlist* or *Podcast* | Nothing |
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
- For **streaming** albums, the matching service plugin installed and signed in: **Qobuz**, **Tidal**, **Bandcamp**, **Deezer** and/or **Spotify** (via Spotty). Library albums need nothing extra.

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

1. Browse to any album, track or podcast episode — in your library, a streaming service (including Deezer and Spotify podcasts) or your podcast subscriptions.
2. Open its **"…"** menu and choose **Add to Listen Later** (or **Add to Wish List**).
3. Open **Apps → Listen Later** to see your lists. Tap a row to play it.
4. Play most of it and it moves itself to **Played**.

---

## Using it

### Adding things
*Add to Listen Later* and *Add to Wish List* appear in the **"…"** context menu of albums and tracks — local library and streaming alike. Adding something that's already saved (in any list) does nothing, so an accidental tap can't disturb your lists or bounce a Played item back.

The menu wording is the same everywhere, because the row you're on already tells you what you're saving: an album row saves the album, a track row saves that track. The one exception is Material's **Now Playing** screen, where there's no surrounding list to make it obvious — there the menu says **Add track to Listen Later**, and **Add album to Listen Later** sits in **"… → More"** if you want the whole release instead.

### Albums, tracks, playlists and podcasts
Each saved row is labelled with what it is on the line beneath the title, which carries a small glyph — **♫** for a multi-track release, **♪** for a single track, **≡** for a playlist, **❝** for a podcast episode — followed by the type and the source, e.g. *♫ Album · Qobuz*. The title line stays a plain *Artist – Album (Year)*:

- **Album** / **EP** / **Single** — a whole release. The wording is the one MusicBrainz or the streaming service gives it, so it's shown as they have it. It isn't always literal — a release called an *EP* can hold a single track — so the **glyph** goes by the real track listing once the release has been counted, and only falls back to the label until then.
- **Track** — one song, saved from a track row. It plays on tap rather than opening a tracklist.
- **Playlist** — a curated playlist from a streaming service, kept as a playlist rather than flattened into its tracks (see below).
- **Podcast** — one episode, marked with a quote glyph rather than a note (see below).

Saving a streaming **single** stores it as the Single release rather than a loose track, so adding "the single" and "the track" can't leave you with two rows for the same recording.

### Playlists
A **curated or service playlist** — a Qobuz or Deezer editorial list, a TIDAL or Spotify playlist — can be saved whole, from its **"…"** menu like anything else. It's stored as a playlist rather than as its tracks, so it stays live: open it later and you get whatever the playlist holds *now*, replayed through the service it came from. Needs the matching plugin installed: **Qobuz**, **TIDAL**, **Deezer** or **Spotify** (via Spotty).

Playlists end up under the same two rules as podcast episodes, for the same reason — a playlist isn't a release you buy, and it isn't a fixed thing you can finish:

- **A playlist never lands in the *Wish List*.** A playlist row can still *show* **Add to Wish List** — Material builds a menu per surface, not per row — but pressing it saves to *Listen Later*, and the confirmation tells you which list it went to. **Move to Wish List** isn't offered on a saved playlist either, and is refused if something asks for it anyway. Podcast episodes follow exactly the same three rules.
- **It never moves itself to *Played*.** A curated playlist changes under you, so "most of it heard" has no meaning. You can still move it to *Played* by hand.

**One kind that can't be saved as a playlist: a Qobuz *personal* playlist with no cover of its own.** Qobuz gives those a constituent track's album art and no identifiable link, which makes them indistinguishable from an album row — so they're saved the way they always were rather than as a playlist. Editorial Qobuz playlists, which have their own artwork, are fine.

### Podcasts
Podcast **episodes** can be saved to *Listen Later* — which is, after all, exactly what a podcast queue is for. Add one from its **"…"** menu just like anything else. Three sources can supply them, and they behave slightly differently because each identifies an episode in its own way:

| Source | How an episode is saved | Shown in your list as |
|---|---|---|
| **Podcasts app** (LMS's built-in) | Matched against the shows you subscribe to — see below | **Podcast** · *show* |
| **Deezer** | Saved directly from its own play link | **Podcast** · **Deezer** |
| **Spotify** (via Spotty) | Saved directly from its own play link | **Podcast** · **Spotify** |

A Podcasts-app episode always shows its **show name**, because the plugin reads it from the RSS feed while identifying the episode. A Deezer or Spotify episode shows one only *sometimes*: the browse row those services hand over carries just the episode title and a description, so the show has to come from the service's own metadata cache — which is filled if you reached the episode by browsing its show, and empty if you didn't. Either way the episode saves, plays and marks itself Played exactly the same; it's only the subtitle that may be shorter.

Qobuz, Tidal and Bandcamp have no podcasts, so there's nothing to save there.

A Podcasts-app episode plays back through the Podcasts plugin, so its resume position keeps working. A Deezer or Spotify episode plays through that service, exactly as it would if you'd started it from the service's own menu.

There's no *Add to Wish List* for a podcast — you don't buy podcast episodes. This holds for all three sources alike. The entry can still *appear* over an episode, because Material builds a menu per surface rather than per row: in a mixed list such as Favourites, and on a Deezer or Spotify episode browsed inside that service's own app. Pressing it saves the episode to *Listen Later* instead, and the confirmation says so; **Move to Wish List** isn't offered on the saved row either.

**Whole shows can't be saved — only episodes.** A podcast series isn't a release: it has no end, and it changes under you, so "have you finished it" has no answer. Adding a *show* rather than an episode is refused, on every source — the Podcasts app, Deezer and Spotify alike.

**Podcasts-app episodes are matched against the podcasts you subscribe to.** A row in that app carries no playable link of its own, so the plugin identifies the episode by weighing its title and its artwork together against your subscribed feeds — the title tells episodes of one show apart, and the artwork tells the shows apart. That means an episode from a show you've subscribed to can be saved from anywhere — the Podcasts app, a favourited feed, the home screen — but an episode you found through **Search feeds** on a show you *haven't* subscribed to can't be, and is refused rather than saved as something that would never play. Subscribe to the show first. **This limit is specific to that app**: a Deezer or Spotify episode carries its own play link, so it saves whether you follow the show or not.

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

- A **multi-track release** is judged on how many of its tracks you've played — see the thresholds in Settings. Streaming releases remember how many tracks they hold, measured from the release's real track listing the first time you play it (or in the background shortly after adding, where that's free), so the same *most of it* percentage applies to them as to your library albums. The fixed streaming count below is only a fallback for a release whose length couldn't be measured at all.
- The percentage **rounds down**, so a skipped track — or one that isn't available in your country — never leaves a release stuck. At the default 90%, a nine-track album needs eight of its tracks and a five-track one needs four. A two-track release always needs both, since needing only one would mark it the instant it started.
- **How long a release is comes from counting it, never from what it's called.** *Album*, *EP* and *Single* are labels from MusicBrainz or the streaming service, and they're often not literal — a release labelled *Single* can hold three tracks, and one labelled *EP* can hold a single track. Those labels are shown on the row, but they never decide when something has been heard. Only the real, playable track listing does, so a release still moves to *Played* whatever it's called and whichever of its tracks are available in your country.
- Anything that's a **single track** (a saved track, a Single, or a podcast episode) is marked Played once you've actually listened to ~90% of it. Skipping past it doesn't count, and pausing doesn't either — it goes on real playback, not elapsed time — so something you skimmed past won't quietly move to *Played* and then be tidied away.

### Material home shelf
On the Material Skin home screen you can show a horizontal **Listen Later** row of your saved albums, each playable/tappable. It uses Material's standard home-extra mechanism (no skin patching). If it isn't shown, enable it under Material's home-screen customisation.

### Sorting
A single **Default sort order** applies to all three lists: Recently added, Artist, Album, Year, or Recently played.

**A note on release years.** Albums from your own library and from **Qobuz or Spotify** carry their year, as do any added through ListenBrainz New Releases or Pitchfork Reviews. Albums added straight from **Tidal, Deezer or Bandcamp** don't: those plugins hand over a release's track listing rather than its details, so there's no date to read. Adding the same release through one of the companion plugins gets you the year. It's worth having where it's available — the year is part of how a duplicate is recognised, so two copies of an album saved with and without one aren't spotted as the same record.

---

## Settings reference

Open **Settings → Advanced → Listen Later** (also linked as **Plugin Settings** at the top of the plugin's page).

| Setting | What it does | Default |
|---|---|---|
| **Default sort order** | Ordering for all three lists | Recently added |
| **Automatically move albums to Played** | Master switch for auto-marking | On |
| **Played threshold** | Percent of an album's tracks that must play before it's Played — used whenever the number of tracks is known (your library, and any streaming release that's been looked up). Rounds down, and never below two tracks for a multi-track release | 90% |
| **Streaming track count** | Fallback for a streaming release whose length couldn't be measured: distinct tracks before it's Played | 4 |
| **Auto-remove played albums after** | Days a Played album is kept before being removed (**0 = keep forever**). Re-playing it resets the clock | 7 |
| **Add to Material context menus** | Adds the *Add to Listen Later* / *Add to Wish List* entries to Material's menus (takes effect after a restart) | On |

---

## Notes & limitations

- **Album-add from streaming** is reached from a track or album row in the service's browse view; there's no global LMS hook to inject an item into every service's own album "…" menu, so the plugin uses `Slim::Menu::TrackInfo`/`AlbumInfo` plus Material's custom-action mechanism.
- **Adding directly from a streaming service's *browse list*** (e.g. a *New Releases* row) relies on a Material Skin feature that was merged upstream ([lms-material #1235](https://github.com/CDrummond/lms-material/pull/1235)) and ships in **Material 6.4.4 and later**. On older Material that one entry just won't appear — adding from an album's or track's own "…" menu (and everything else) works regardless.
- **Outside-the-plugin Played detection** is reliable for the local library (matched by album id); for streaming it's best-effort, matched on the now-playing artist + album.
- **Material custom actions on home-shelf cards** only appear after you've opened a streaming browse page in the same session — a Material limitation in how the home shelves render menus.
- **Internet-radio stations don't show *Add*.** Radio is a live stream, not something you can save and replay, so the *Add to Listen Later* / *Add to Wish List* entries are deliberately hidden on radio browse rows (BBC Sounds, TuneIn's Music/News/Sports/… categories, etc.). This applies to radio *browse* rows; a radio card on a Material home shelf can't be suppressed the same way, but adding one there is simply ignored. *(After updating, reload Material once — Ctrl/Cmd+Shift+R — so it re-reads its custom-actions file.)*
- **Podcast episodes from the built-in Podcasts app must belong to a show you subscribe to** — that's how the plugin identifies them (see *Podcasts* above). Episodes found via *Search feeds* on an unsubscribed show are refused rather than saved unplayable. Deezer and Spotify episodes carry their own play link and are not subject to this.
- **A whole podcast show can't be saved, only an episode.** A series has no end and changes under you, so it isn't something you can finish. Adding one is refused rather than saved as a row that could never play.
- **Saving an individual track needs the Material Skin.** On the classic skin a track's "…" menu offers the *album* it belongs to, which is what that menu has always been able to reach.
- **Storage** is a SQLite database in the server cache directory, so your lists survive restarts and rescans.
