# Changelog

## 0.1.54 — Remove the dead "not supported" reject message

### Changed
- **The reject of an unplayable add is now silent.** Earlier versions tried to show a "Can't save — this service isn't supported" message on reject, but Material never rendered it: a server-side `showBriefly` reaches a physical player's display only, never the web UI, and Material's only feedback hook for a custom-action/menu command is a generic "'…' failed" snackbar whose text can't be set. So the message could never appear where it was needed. The reject-toast code (`showBriefly` + the `PLUGIN_LL_UNSUPPORTED` string) has been removed as dead code. The gate itself is unchanged — nothing unplayable is stored; the add is simply refused without a popup. (The pre-existing "Added" confirmation toast is kept: it still shows on hardware player displays.)

## 0.1.53 — Fix: unidentifiable items (e.g. ListenBrainz playlists) saved as empty albums

### Fixed
- **Adding something we can't identify — like a ListenBrainz "Created for You" playlist — no longer stores an empty, unplayable row.** Those rows carry no play URL, a plugin image (not a service cover), and a service id that isn't a real service, so the add code used to fall back to a default of "Qobuz" and save an empty album. It now leaves the source unset and the add is rejected with the "not supported" message, exactly like an unsupported service. A genuine streaming album with a real service cover (e.g. from a home shelf) is unaffected — it's still identified from the cover and saved normally. (Full playlist support would be a much larger feature and isn't planned; see below.)

### Note
- Any empty rows already saved this way can be removed from the list via the row's "…" → Remove.

## 0.1.52 — Fix: "Add" missing on Qobuz/Tidal/Bandcamp/ListenBrainz after the 0.1.51 cleanup

### Fixed
- **"Add to Listen Later" was gone from every supported streaming service's browse menus.** The 0.1.46–0.1.50 experiments had written per-service categories (`qobuz-album`, `tidal-album`, `bandcamp-album`, `listenbrainzfreshreleases-album`, …) into Material's shared `actions.json`. 0.1.51 stopped *writing* them but never *deleted* them — and that file survives plugin updates, so they lingered as **empty** categories. An empty `qobuz-album` takes precedence over the generic `online-album`, so it silently suppressed "Add" on exactly the services we support. Now, on every write, any stale empty per-service category we no longer use is deleted, so those services fall back to the populated `online-*` and show "Add" again. (Verified: no other plugin writes these, so the cleanup only removes our own leftovers.)

## 0.1.51 — Reject unplayable adds instead of hiding the button

### Changed
- **An album from a service we can't play back is now rejected at add time, with a clear "Can't save — this service isn't supported" message — instead of being saved and only failing later with "Could not find this album to play".** The gate is simple and reliable: we save only from the local library and services with a real replay adapter (Qobuz, Bandcamp, Tidal). Everything else — Deezer, Spotify, BBC Sounds, internet radio, anything unsupported — is refused up front. (The test is adapter support, *not* whether a link was supplied: Deezer sends a valid `deezer://album:<id>` and still can't play, because there's no Deezer adapter.)
- **Removed all the per-service "Add"-button scoping** added in 0.1.46–0.1.50 (the scheme filter, the app/radio-menu blocklist enumeration, the home-shelf suppression attempts). Those fought Material's custom-action mechanism — which is unreliable on home shelves (leftover view state) and can't be scoped per-shelf, because Material fetches all home shelves in a single call (this has always been the case). The add-time rejection makes all of that unnecessary: the "Add" button can appear anywhere, but nothing unplayable ever enters a list, so the button is a harmless no-op on unsupported services. Much simpler, and reliable.

## 0.1.50 — "Add" scoped to supported services by reading the server's own app list (removed in 0.1.51)

### Changed
- **"Add to Listen Later"/"Wish List" now appears only on services we can replay — worked out from *your* server's installed apps, not a hardcoded list.** The play-URL-scheme approach in 0.1.49 was rolled back: ListenBrainz Fresh Releases rows (and Material home-shelf cards) carry no `favorites_url`, so the scheme filter had nothing to match and showed every scheme's entry at once (the duplicate "Add" rows). Instead, on startup the plugin reads the server's own **app gallery and radio menus** and suppresses "Add" on the browse rows of every service that isn't one we support (Qobuz, Bandcamp, Tidal, ListenBrainz Fresh Releases). Because it reads the live menus, it adapts to whatever each user has installed — Deezer, Spotify, Amazon, BBC Sounds, Radio Paradise, TuneIn/internet radio, anything — with nothing to maintain. Supported services, the home-page shelves, and ListenBrainz keep "Add" (the generic `online-*` stays populated for the shelf cards, which carry no command of their own). The TrackInfo "…" menu keeps its own allowlist (library + Qobuz/Bandcamp/Tidal).

### Known gaps
- Material's **global search** puts every service's results under one `globalsearch` command, so it can't be scoped per-service — "Add" still appears there for unsupported services (blocking it would also remove it for Qobuz/Tidal). Left as-is.
- Home-shelf cards of unsupported services can still show "Add" (they carry no command or URL, so they can't be scoped) — a Material limitation.

## 0.1.49 — "Add" gated by play-URL scheme, not a service blocklist (rolled back in 0.1.50)

### Changed
- **"Add to Listen Later"/"Wish List" now shows only on services we can replay, decided by the item's play-URL scheme — no more per-service blocklist.** Blocking services one by one (Deezer, Spotify, BBC Sounds, Radio Paradise, and endless internet-radio stations) was never going to scale. Instead, the streaming `online-*` custom actions carry Material's per-action `filter`, so "Add" appears only when an item's `favorites_url` begins with a supported scheme (`qobuz://`, `bandcamp://`, `tidal://`). Everything else — Spotify, BBC Sounds, Radio Paradise, internet radio, anything new — is excluded automatically with nothing to maintain, and ListenBrainz Fresh Releases rows keep "Add" for free (their favurl *is* `qobuz://…`). Qobuz/Bandcamp/Tidal also get their own per-command category so their no-favurl "New Releases" rows still show a single "Add". The home-page shelves are unaffected (the generic `online-*` stays populated, which is what feeds the shelf cards). The TrackInfo "…" menu uses the same allowlist (library + Qobuz/Bandcamp/Tidal). Stale `deezer-*` entries from 0.1.48 are cleaned up on start. Adding a new service later is: an adapter in `Sources.pm` + its scheme in the list.

## 0.1.48 — Don't clobber other plugins' actions.json entries

### Fixed
- **Suppressing "Add" on a blocked service no longer overwrites another plugin's custom actions for that service.** `actions.json` is shared with Material and every other plugin; the 0.1.47 block wrote an *empty* `<service>-album`/`-track` category with `=`, which would wipe any entry another plugin/user had put there. Now uses `||=` — it only creates the empty category when none exists, so our Add stays hidden (a defined category, even someone else's, overrides the generic `online-*`) while their entries are preserved. Our own `listenlater-*`/`LLHome-*` namespaces still reset fully.

## 0.1.47 — Hide "Add" on unsupported services (e.g. Deezer) without breaking home shelves

### Changed
- **No "Add to Listen Later"/"Add to Wish List" on streaming services we don't support yet (e.g. Deezer).** It was offering an add there that stored a record which could never play. Suppressed on both surfaces it appears: Material's browse "…" action and the TrackInfo "…" provider. Implemented as a blocklist (`@BLOCKED_ONLINE`, seeded with `deezer`): for each blocked service we write an *empty* custom-action category that overrides Material's generic `online-*` for that service only. Deliberately a blocklist and **not** an allowlist — an allowlist has to stop populating the generic `online-*`, and the **home-page shelf cards depend on `online-*`** (they carry no per-service command), so that route made "Add" disappear from every home shelf. Keeping `online-*` populated leaves the home shelves and all supported services working, while Deezer alone is hidden.

### Note
- 0.1.46 shipped the allowlist version of this and regressed the home shelves; 0.1.47 supersedes it.

## 0.1.45 — Tidal adds get their artist (fetched from the album in the background)

### Fixed
- **An album added straight from the Tidal plugin now gets its artist.** Tidal browse rows send no artist (`$ARTISTNAME` empty — confirmed in the add log) and, unlike Qobuz, the Tidal cover URL is a random UUID with no artist/id to recover — so the saved record showed the album with no artist and never auto-moved to Played. Replay was already correct (the Tidal favurl carries `tidal://album:<id>`). Now, right after the add, the album's artist is fetched from its tracks in the background (Tidal's own `getAlbum`) and backfilled onto the record (`DB::updateArtist`, which also recomputes the dedupe key so Played's artist+album lookup matches). Fire-and-forget and fully guarded — a Tidal API hiccup can't affect the add. The artist appears on the row a moment after adding; **re-add** any Tidal album saved before this build to fill it in.
- Confirmed adds from the **ListenBrainz Fresh Releases** plugin already carry the artist (and year) — its match rows pack them into the favurl (`&a=`/`&y=`), verified end to end (`…qobuz://album:…&a=Temples&y=2026`).

## 0.1.44 — Qobuz albums replay by their exact id (recovered from the cover), no search

### Fixed
- **An album added straight from the Qobuz plugin now replays the exact album, with no search step.** Qobuz browse rows carry no `favorites_url` and no album id (confirmed: every direct-Qobuz add arrives with `favurl=` empty, `albumid=(undef)`), so replay had to search the service by artist+title — which could miss a specific same-titled edition, e.g. "American Football (LP2) (2016)" came up empty even though the album plays fine in Qobuz. But the Qobuz **cover URL embeds the album id** as its filename (`…/covers/xx/yy/<ALBUMID>_600.jpg`), so `_addCtxCommand` now recovers the id from the cover (`Sources::qobuzAlbumIdFromImage`) and stores it — replay goes straight through Qobuz's own album by id, exact, no search. The artist+title search (with the 0.1.42 year/title ranking) remains only as a fallback for records with no recoverable id. **Re-add** any Qobuz album that was saved before this build to give it the id.

## 0.1.43 — Same-titled albums from different years can both be saved

### Fixed
- **Two albums with the same artist and the same title but different release years can now both be added** — previously the second was silently dropped as a duplicate (e.g. Chanel Beads' 2024 and 2026 "Your Day Will Come", which share an identical title so nothing but the year distinguished them). The dedupe key is now `artist|album|year` (was `artist|album`). Existing saves are migrated in place (their key gains a trailing `|<year>`), so nothing already stored is affected. Albums whose titles already differed — including "(LP2)"/"(LP4)"/"(Deluxe)" editions — were never blocked and are unchanged.
- **Played detection is unaffected by the key change.** A playing streaming track can't be relied on to report the album's year, so the Played matcher now looks up the saved album by its `artist|album` prefix (year-agnostic) instead of the full key. (If two same-title different-year albums are both saved, a play attributes to the earlier-added one — streaming track metadata can't tell them apart; adding both is the point of the fix.)
- **Albums added from the ListenBrainz Fresh Releases plugin now carry their year** (plugin 0.9.59+ packs it into the favurl as `&y=`), so two same-titled LBF adds also save separately rather than one blocking the other. Older LBF builds send no year; those adds dedupe on `artist|album|` (empty year) as before.

## 0.1.42 — Right album on replay for same-titled releases; keep the artist on ListenBrainz adds

### Fixed
- **A streaming album saved directly from Qobuz/Tidal no longer replays the wrong same-titled release.** These browse rows carry no album id, so Listen Later replays them by searching the service for the artist + album and matching the title. The matcher normalises the title, which strips distinguishing qualifiers like `(LP4)` **and** the year — so "American Football (LP4) (2026)" matched (and played) the 1999 self-titled "American Football", and one of two same-named "Your Day Will Come"s resolved to the wrong year. The replay search now (1) searches the **artist only** and filters titles locally (better recall — the combined query made the service's own search rank/drop the target), and (2) ranks the candidates: an exact full-title match that **keeps** the `(LP4)` distinguisher **and** matches the saved year wins, then a year match, then a full-title match, then today's base-title match. The distinguishing title and the year are already stored on the record — they were just being discarded at match time. Applies to Qobuz and Tidal (Bandcamp already replays by its captured album id).
- **Albums added from the ListenBrainz Fresh Releases plugin now keep their artist.** Material sends those matched rows no artist (the row thumbnail is the streaming-service logo, and the subtitle isn't mapped), so the saved record had a blank artist — which meant it never auto-moved to **Played** (Played matching keys on source + artist + album). ListenBrainz Fresh Releases 0.9.58+ now packs the release artist into the favurl as a private `&a=` param (same handshake as the existing `?cover=`/`?b=`); Listen Later reads it as a fallback when the artist is empty, then strips it so the `album:<id>` logic sees a clean URL. Needs the plugin's 0.9.58 build; older saves can be removed and re-added to pick up the artist.

## 0.1.41 — Buy on Bandcamp opens in one tap when the URL is known

### Changed
- **"Buy on Bandcamp" opens the page in a single tap when the URL is already stored.** Previously the entry always drilled into a resolve query that then showed an intermediate "Open on Bandcamp" link — two taps. Now, when the album's Bandcamp page URL is known (`ref.album_url` captured at add time, or `ref.buy_url` cached from a prior open), the "… → More" entry **is** the link: one tap opens the browser, no intermediate step. Albums with no stored URL (older saves) keep the resolve drill, which finds the page, caches it, and shows the link as before — so they become one-tap on the next open.

## 0.1.40 — Buy on Bandcamp opens the stored page directly

### Changed
- **"Buy on Bandcamp" opens the album page instantly when the URL is already known.** Albums added from ListenBrainz Fresh Releases 0.9.53+ arrive with their exact Bandcamp page URL (stored as `ref.album_url`), so "Buy on Bandcamp" now links straight to it — no resolve, no search, no intermediate lookup. Albums that don't have a stored URL (older saves, or any that arrived without one) still use the previous route: resolve the page once, scan for the link, and fall back to a Bandcamp search if it can't be found.

## 0.1.39 — Use the exact Bandcamp page URL from the favurl

### Changed
- **Replay a Bandcamp album by the exact page URL passed in the favurl.** Pairs with ListenBrainz Fresh Releases 0.9.53, which packs the cover art **and** the album page URL into a single escaped `?b=<art>|<url>` favurl param. Listen Later unpacks both: the cover becomes the saved artwork, and the page URL is stored on the record (`ref.album_url`) so replay goes straight through `get_album` — exact, no lookup — and Buy-on-Bandcamp opens it directly. The `album_id`-search resolve from 0.1.38 stays as a safety net for the rare case the URL half is absent, but normal saves no longer need it.

### Fixed
- **A Bandcamp album saved from the ListenBrainz Fresh Releases plugin now plays, and keeps its cover and correct source.** Bandcamp resolves a tracklist from the album **page URL**, not the `album:<id>` carried in the favurl, so earlier saves produced no tracks. The fix carries the page URL (and the cover) across in the favurl via the `?b=<art>|<url>` blob (see "Verified: the favurl carries the full payload" below). The `(Album)`/`(Track)` suffix Bandcamp appends to titles is stripped on save for a clean name.

### Verified: the favurl carries the full payload (correcting an earlier wrong conclusion)
- An earlier theory — that Material **drops favurls longer than ~150 chars** — was **wrong**. It was reached while a stale repo-installed build was shadowing the manual dev install, so the test plugin's favurl code never actually ran and the add arrived with *no* favurl. With the correct build loaded, the full `bandcamp://album:<id>?b=<art>|<url>` favurl (~164 chars) arrives intact: the saved record shows the real Bandcamp cover *and* stores the exact page URL.
- Note for future debugging: the `addctx` log line prints the favurl **after** the `?b=`/`?cover=` payload is stripped off (`_addCtxCommand` strips, *then* logs), so it always reads as a bare `bandcamp://album:<id>` — that is **not** evidence the payload was dropped. And `image=(undef)` in that log is Material's `$IMAGE` (the service *logo*, intentionally unused); the cover rides the `?b=` blob.
- The former `docs/material-favurl-length-issue.md` (a write-up of the non-existent length limit, for the Material dev) has been **removed** — its premise was false.

## 0.1.35 – 0.1.38

Intermediate iterations of the Bandcamp page-URL interop work, all **superseded by 0.1.39** (above): the cover-only `?cover=` handling, the resolve-by-`album_id` fallback, and the early attempts to carry the page URL in the favurl. The "Material drops long favurls" conclusion drawn during these turned out to be a stale-install artifact (see 0.1.39). Consolidated rather than listed individually — no action needed if you ran one of these dev builds.

## 0.1.34 — No "Add to Listen Later" on the Now Playing screen

### Changed
- **The "Add to Listen Later" / "Add to Wish List" entries no longer appear in Material's Now Playing context menu.** They're still on every browse surface — album and playlist track lists, the queue, and streaming service "…" menus — just not on the now-playing track itself, where they didn't belong. Plugin-only change; no Material update required.

## 0.1.33 — Don't save the same album twice from different services

### Changed
- **Adding an album you've already saved — even from a different service — no longer creates a second copy.** Duplicate detection used to be per-service, so the same album from, say, Qobuz and Bandcamp ended up as two entries. It's now matched across every source (and the library), so a repeat "Add" is a no-op and shows a toast naming where it's already saved, e.g. *"Already saved from Qobuz"*. This applies on every add path, including the "Add" action on a streaming service's browse list.

### Notes
- Albums already saved twice (one per service) before this update are left as-is — this prevents new duplicates rather than merging existing ones; remove one of the pair manually if you have any.

## 0.1.32 — Code-review fixes

### Fixed
- **"Add" no longer appears on streaming *artist* rows.** The plugin saves albums, not artists; offering "Add" on an artist row stored a junk entry (the artist's name as an album title) that could never play. Artist rows now show no "Add" action — album and track rows are unchanged.
- **Hardened the private `?cover=` favurl handling** (the ListenBrainz Fresh Releases cover hand-off): the param is now stripped with its own leading delimiter so the remaining favurl is always well-formed, regardless of where the param sits.

### Internal
- "Buy on Bandcamp" cancels its 15-second fallback timer as soon as the page resolves, instead of letting it linger.
- Removed a duplicated library-track lookup and an unused icon constant; added comments documenting why the two `_norm` helpers (dedupe key vs. fuzzy match) deliberately differ. No behaviour change.

## 0.1.31 — Settings entry uses a cog icon

### Changed
- **The top-level "Plugin Settings" entry now shows a cog icon** instead of the plugin's own logo, matching the sibling ListenBrainz Fresh Releases plugin. It uses Material's own themed `settings` font icon (the `_MTL_icon_settings` filename convention, same approach as the Wish List trolley), so it recolours with your theme; non-Material skins get a plain cog PNG fallback.

## 0.1.30 — Cover artwork from the ListenBrainz Fresh Releases detail page

### Added
- **Adding a streaming album from the sibling ListenBrainz Fresh Releases detail page now keeps its real cover.** Those rows show the streaming **service logo** as their thumbnail (so you can see which service the match is on), which meant the image handed to "Add" was the logo, not the album art. The plugin now reads an album-art URL that ListenBrainz Fresh Releases tucks onto the favurl as a private `?cover=<url-encoded>` param: it uses that as the stored cover (preferred over the row image), then strips it so the source / `album:<id>` replay logic sees a clean `<service>://album:<id>`. Together with the favurl those rows now carry, an added match gets the **correct service**, a **directly-replayable album**, and the **right artwork**.

### Compatibility
- The `?cover=` param is only emitted by **ListenBrainz Fresh Releases 0.9.42+**. Native streaming-plugin "Add" (Qobuz/Tidal/Bandcamp browse rows) is **completely unaffected** — those favurls never carry the param, so the extraction never fires and the favurl is left byte-for-byte unchanged.

## 0.1.29 — Section headers fixed for newer Material

### Fixed
- **Section headers (Listen Later / Wish List / Played) render as dividers again on newer Material.** Material's development line changed how it draws *actionable* headers — because the plugin's headers carry a "re-list this section" action, newer Material was drawing them as **grid cards** mixed in with the album artwork instead of as full-width dividers. The plugin now emits the header as Material's `header-basic` type (which renders as a plain, non-actionable divider).

### Compatibility
- The new `header-basic` type only exists in **Material 6.4.3+**. The plugin detects the running Material version and uses it only there; on **older Material it keeps the previous `header` behaviour unchanged**, so nothing changes for users on older skins.

## 0.1.28 — Streaming adds use Material's `$SERVICE`

### Changed
- **The "Add to Listen Later" / "Add to Wish List" actions on a streaming service's browse list now identify the service via Material's `$SERVICE` variable** — the clean mechanism in the upstream Material change ([PR #1235](https://github.com/CDrummond/lms-material/pull/1235), now merged), replacing the earlier internal workaround.

### Compatibility
- Adding directly from a **streaming service's browse list** requires the merged custom-actions-on-streaming feature, which ships in **Material 6.4.4 and later**. On older Material that one entry simply doesn't appear; every other way to add (the album/track "…" menu, library, etc.) is unaffected.

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
