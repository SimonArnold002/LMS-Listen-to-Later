# Listen Later — Version History

Split out of `CLAUDE.md` (2026-09-10) so the Review Ledger is not buried behind 3,111 lines
of changelog. Nothing reads this file automatically; it is the narrative record per version.
Per-release user-facing notes live in `CHANGELOG.md`. Append new entries at the END.

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
- **0.1.28** — Streaming-browse "Add" actions identify the service via Material's **`$SERVICE`** variable (`online-*` commands carry `svc:$SERVICE`), the clean upstream mechanism now that [PR #1235](https://github.com/CDrummond/lms-material/pull/1235) is **merged and released in Material 6.4.4** — replaces the old baked-`svc:` workaround. Needs Material **6.4.4+**; degrades to "entry absent" on older Material. See "Material custom actions on streaming …".
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
  **REVERSED IN 0.1.62 — read that entry before quoting this one.** `track` is written (and,
  on 6.4.6+, registered) again, so Now Playing carries the pair today; everything below is the
  reasoning for the removal, not current behaviour.
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
- **0.1.42** — **Right album on replay for same-titled releases + keep the artist on ListenBrainz adds.**
  Two independent fixes, both diagnosed live over JSON-RPC (saved records replayed the wrong tracklist:
  "American Football (LP4) (2026)" → the 1999 LP1's *Never Meant…*; one of two "Your Day Will Come"s →
  the wrong year).
  (1) **`_searchService` disambiguation (`Sources.pm`).** A Qobuz/Tidal browse row carries **no album
  id**, so replay searches the service and title-matches — but `_norm` strips the `(LP4)` distinguisher
  AND the year, so `_albumMatches` took the first same-base-title hit. Now the search sends the **raw
  artist only** and filters titles locally (recall — mirrors the sibling plugin's 0.9.34 lesson), and a
  new `_bestMatches` ranks the base-matched candidates: exact full title (kept via `_normStrict`, which
  strips only quality qualifiers, not `(LP4)`) **and** matching year > year > full title > base. Year
  comes from the raw service date field, else the year the renderer already shows on the item (`_yearOf`,
  a boundary-anchored 19xx/20xx match that ignores an epoch `released_at`). Bandcamp unchanged (replays
  by captured album id). The distinguishing title + year were already on the record — just discarded at
  match time.
  (2) **Artist packed in the favurl.** LBF match rows arrive with an empty `$ARTISTNAME` (Material
  doesn't map their subtitle — confirmed in the `addctx` log: `artist=` empty, `favurl=qobuz://album:…`
  present), so LBF-saved records had no artist and never auto-moved to Played. LBF 0.9.58+ packs
  `&a=<artist>` into the favurl; `_addCtxCommand` reads `[?&]a=`/`[?&]y=` as fallbacks for artist/year
  (after the `?cover=`/`?b=` strip, before the log so the logged favurl stays clean) and strips them.
  Native favurls (no query) never trigger it. Needs LBF 0.9.58; existing artist-less records can be
  removed + re-added.
- **0.1.43** — **Same-titled albums from different years can both be saved.** The dedupe key became
  `artist|album|year` (was `artist|album`), so e.g. Chanel Beads' 2024 and 2026 "Your Day Will Come"
  (identical titles, only the year differs) no longer block each other — the second used to be dropped
  as a duplicate. `DB::dedupeKey` takes the year; `add` passes `$rec->{year}`; a one-off idempotent
  migration in `_migrate` appends `|<year>` to existing 1-pipe keys (`WHERE dedupe_key NOT LIKE
  '%|%|%'`). **Played detection** must NOT gain the year (a playing streaming track can't be trusted to
  report it), so `Played::_matchRecord` now calls the new `DB::findByArtistAlbum($source,$artist,$album)`
  — a year-agnostic `dedupe_key LIKE 'artist|album|%'` prefix lookup (normalised parts carry no LIKE
  metacharacters) — replacing the removed `findByKey`. Two same-title different-year albums both saved:
  a play attributes to the lower id (streaming metadata can't disambiguate; accepted). Differently-titled
  editions ("(LP2)"/"(Deluxe)") were already distinct via `DB::_norm` (keeps parens) and are unchanged.
  Pairs with LBF 0.9.59, which packs the year into the favurl as `&y=` (`_addCtxCommand` reads
  `[?&]a=`/`[?&]y=`) so LBF adds carry a year too; older LBF builds send none → those dedupe on
  `artist|album|` as before.
- **0.1.44** — **Qobuz albums replay by their exact id, recovered from the cover URL — no search.**
  Diagnosed live: every direct-Qobuz add arrives with `favurl=` empty and `albumid=(undef)` (Qobuz
  browse rows carry no identity), so replay fell back to `Sources::_searchService` (artist-only search
  + 0.1.42 year/title tiering) — which for "American Football (LP2) (2016)" returned nothing (Qobuz's
  artist search didn't surface that specific edition), giving "Could not find this album to play" while
  LP3/LP4 happened to resolve. Root fix: the Qobuz **cover URL filename IS the album id**
  (`…/static.qobuz.com/images/covers/<xx>/<yy>/<ALBUMID>_<size>.jpg`; the xx/yy path is derived from the
  id's last chars — verified against the known-good favurl id `y89n6mtoxfa4k` and LP3/LP4's covers).
  New `Sources::qobuzAlbumIdFromImage` uri-unescapes the proxied cover and extracts the id;
  `_addCtxCommand`'s no-favurl branch, when `$source eq 'qobuz'`, sets `ref.album_id` from it (uses the
  raw `$p{image}`, not `$artwork`). `buildPlayableItems` then replays via `_streamingAlbumNode` by id —
  exact, no search — for ALL direct-Qobuz adds (also makes Chanel Beads etc. exact, not year-tiered).
  `_searchService` stays as the fallback for records with no recoverable id (older saves, non-Qobuz-cover
  images). Existing artist-less/id-less Qobuz records need a re-add to gain the id. Tidal already carried
  `tidal://album:<id>` in its favurl, so this is Qobuz-specific.
- **0.1.45** — **Tidal direct adds backfill the artist from the album (async); LBF adds confirmed carrying artist.**
  Tidal browse rows arrive with `favurl=tidal://album:<id>` (replay by id works) but `artist=` EMPTY
  (Material doesn't map their subtitle) and `year=(undef)`, and the Tidal cover URL is a random
  `resources.tidal.com/images/<uuid>/…` with no artist/id to recover (unlike Qobuz — see
  [[qobuz-album-id-from-cover-url]]). So `_addCtxCommand` now, for a fresh artist-less Tidal add with an
  album id, calls `_backfillTidalArtist` fire-and-forget: `Plugins::TIDAL::Plugin::getAlbum` (→
  `albumTracks(id)` → each `_renderTrack` sets `line2 => artist->{name}`) → take the first track's line2
  → `DB::updateArtist($id,$artist)`, which sets the artist column AND recomputes `dedupe_key` (year still
  unknown/empty) so Played's `findByArtistAlbum` prefix lookup matches. Guarded; a Tidal hiccup can't
  break the add. Artist shows on the row a moment after adding (async); pre-0.1.45 Tidal saves need a
  re-add. Tidal year is not exposed by albumTracks — left empty (only matters for same-title different-year
  Tidal dedupe, an edge case; AF editions have distinct titles). **Verified LBF adds already carry the
  artist**: a live LBF detail page streaming row's `favorites_url` was
  `qobuz://album:dmuizydvpcxsy?cover=…&a=Temples&y=2026` (0.9.59 `_attachFavUrl` + 0.1.44 `[?&]a=` receiver).
  Tidal plugin source: github.com/michaelherger/lms-plugin-tidal (`getAlbum`/`albumTracks`/`_renderTrack`).
- **0.1.46** — *(superseded by 0.1.47)* Tried an **allowlist** for the "Add restricted to supported services"
  feature: stopped writing the generic `online-*` and instead wrote `<command>-album`/`-track` per supported
  service. **Regressed the Material home-page shelves** — a shelf card has no per-service browse `command`, so
  it resolves custom actions via the generic `online-*` fallback (`browse-resp.js` ~L693); emptying `online-*`
  made "Add" disappear from every home shelf. Reverted in 0.1.47.
- **0.1.47** — **"Add" hidden on unsupported streaming services (Deezer, …) — as a BLOCKLIST.** The Add entry
  is suppressed on services we can't save/replay, while library + Qobuz/Bandcamp/Tidal + the ListenBrainz
  Fresh Releases feed keep it. Chosen as a **blocklist** (`@BLOCKED_ONLINE`, seeded `deezer`), not an
  allowlist, because it's the only design that keeps Material's generic `online-album`/`online-track`
  **populated** — the **home-page shelf cards depend on `online-*`** (they carry no per-service `command`, so
  they fall back to it); an allowlist empties `online-*` and kills Add on all home shelves (the 0.1.46
  regression). Mechanism: keep `online-*` = our Add/Wish-List pair, and for each blocked command write an
  **empty** `"<command>-album"`/`"-track"` category — Material's resolver (`browse-resp.js` ~L693) prefers a
  present app category (even empty) over `online-<btype>`, so the empty category hides Add on that service's
  browse rows only (same trick as our own-view `listenlater-*`/`LLHome-*` empties). Two surfaces, keyed on
  DIFFERENT identifiers: (1) **Material browse action** — blocked by browse COMMAND (`$SERVICE`); (2)
  **TrackInfo "…" provider** — `_trackInfoHandler` returns no item when `$rec->{source}` (play-url scheme) is
  blocked. The command and the scheme can DIFFER for one service (Spotty **browses** as `spotty` but **plays**
  `spotify://…`), so a fully-blocked service needs BOTH spellings in `@BLOCKED_ONLINE`. Tradeoff (accepted):
  open by default — a new unsupported plugin shows Add until added (a one-word change). Empty blocked
  categories linger in `actions.json` if a service is later removed from the list / becomes supported — clear
  them then (not auto-cleaned, unlike the rebrand strip).
- **0.1.48** — **Blocked-service suppression uses `||=`, not `=`, on the shared `actions.json`.** The 0.1.47
  block wrote `$data->{"<svc>-album"} = []`, which would overwrite another plugin's/user's custom actions for
  that service (unlike our own `listenlater-*`/`LLHome-*` namespaces, `<svc>-*` isn't ours to reset). `||= []`
  only creates the empty category when absent — our Add stays hidden (any defined category, even someone
  else's, overrides `online-*`) while their entries survive. Code-review fix, no user-facing change.
- **0.1.49** — **"Add" gated by play-URL SCHEME via Material's per-action `filter`, replacing the 0.1.47/0.1.48
  service blocklist.** The blocklist couldn't scale — too many unsupported services (Spotify, BBC Sounds,
  Radio Paradise, endless internet radio). Material's `filter` field (customactions.js `getSectionActions`:
  an action shows only when the passed filter `startsWith(sect[i].filter)`; the filter passed for online rows
  is `i.presetParams.favorites_url`, `browse-resp.js` ~L686/695) lets us allow by **scheme** instead. Now
  `_writeMaterialActions` writes: (a) `online-album`/`online-track` = one Add + one Wish List **per supported
  scheme** (`@SUPPORTED_SCHEMES` = `qobuz://`/`bandcamp://`/`tidal://`), each with `filter => <scheme>` — so
  only those play-urls get Add, everything else is excluded with nothing to enumerate, and ListenBrainz Fresh
  Releases rows qualify automatically (their favurl IS `qobuz://…`); (b) an **unfiltered** per-command
  `qobuz-`/`bandcamp-`/`tidal-`album`/`track` (`@NATIVE_SERVICES`) because those services' "New Releases" rows
  carry NO `favorites_url`, so the scheme filter can't see them (a filter is bypassed when the favurl is
  undefined → on a no-favurl row ALL scheme copies would show; the per-command category gives a single Add and
  Material prefers it over `online-*`). **Home shelves keep working** because `online-*` stays POPULATED (the
  shelf cards go through `parseBrowseResp` → per-card `CUSTOM_ACTIONS` marker, but only when `online-*` is
  non-empty — the 0.1.46 allowlist emptied it and broke them). Non-clobbering: entries are PUSHED, so another
  plugin's `qobuz-album`/etc. survive (verified). The TrackInfo "…" provider uses the source allowlist
  `%SUPPORTED_SOURCE` = `library qobuz bandcamp tidal`. Stale `deezer-*` (0.1.48) are deleted on write
  (`@STALE_CATEGORIES`). **Known edge:** a NO-favurl row on an UNsupported service bypasses the filter and
  would show all scheme copies — but such services (Deezer/Spotify/radio) carry favurls, and native no-favurl
  services are the supported ones; if one ever appears, give it an empty per-command category (the old
  blocklist trick, now a targeted escape hatch). Add a service: adapter in `Sources.pm` + scheme in
  `@SUPPORTED_SCHEMES` (+ command in `@NATIVE_SERVICES` if its browse rows can lack a favurl; + scheme in
  `%SUPPORTED_SOURCE` for the TrackInfo menu).
- **0.1.50** — **"Add" scoped by a DYNAMIC command blocklist read from the server's own menus — replaces the
  0.1.49 scheme filter (rolled back).** Verified over JSON-RPC why the scheme filter failed: ListenBrainz
  Fresh Releases rows AND Material home-shelf cards carry `favorites_url = None` / empty `presetParams` (they're
  `type=link` drills, or home cards whose menu resolves via `online-*` with an *undefined* command — a per-
  command category like `LBFForYou-album` is NOT consulted for them). With no favurl, Material's `filter` is
  bypassed (`undefined==filter` short-circuits `getSectionActions`), so all 3 scheme copies showed → the 6-way
  duplicate "Add" on LBF. There is no per-item identity to filter on; the only axis LBF/home rows expose is the
  browse COMMAND (home cards: none → `online-*`). So: keep `online-album`/`online-track` a single populated pair
  (home shelves + LBF keep Add, no dup), and suppress "Add" on unsupported services' BROWSE rows via empty
  `<command>-album`/`-track`. The blocklist is **not hardcoded** (every user installs different services):
  `_unsupportedAppCommands` runs `Slim::Control::Request::executeRequest(undef, ['apps'|'radios', 0, 500])`
  (both work with no player), reads each entry's `cmd` from `appss_loop`/`radioss_loop`, and blocks every
  command NOT in `%SUPPORTED_APP` (`qobuz bandcamp tidal listenbrainzfreshreleases listenlater`). Enumerating
  BOTH menus matters: streaming apps are under `apps`, internet radio (TuneIn categories `music`/`news`/`search`/
  … + `bbcsounds` + `podcast`/`presets`) is under `radios`, and a service can be in both (Qobuz) — unioned by
  command, and `qobuz` is supported so it's never blocked whichever menu it came from. Verified the generic
  TuneIn command names don't collide: `search` returns TuneIn radio (not Qobuz — Qobuz's own search runs under
  cmd `qobuz`). `||=` keeps the non-clobber property. **Known gaps (documented, left as-is):** (1) Material
  **global search** puts every service under one `globalsearch` command (verified: Qobuz/Tidal/BBC all drill as
  `['globalsearch','items']`), so it can't be scoped — Add shows there for unsupported too; blocking it would
  also kill it for Qobuz/Tidal. (2) Home-shelf cards of unsupported services can still show Add (no command/URL
  to scope). Add a service now = adapter in `Sources.pm` + its command in `%SUPPORTED_APP` (+ scheme in
  `%SUPPORTED_SOURCE` for the TrackInfo menu). See [[lms-server-http-testing]] for the JSON-RPC probes used.
- **0.1.51** — **Dropped ALL the 0.1.46–0.1.50 per-service "Add"-button scoping; reject unplayable adds at add
  time instead.** The whole scoping saga (blocklist → allowlist → scheme filter → dynamic app/radio
  enumeration) was fighting Material's custom-action mechanism, which is fundamentally unfit for this: on
  home-page shelves it's driven by leftover view state (`handleHomeExtra` never sets `itemCustomActions`, so a
  card only shows "Add" if a *prior* browse populated it — the user's "use it on a library shelf and it starts
  working on Qobuz shelves" symptom) AND unscopeable: ALL home shelves are fetched in ONE
  `["material-skin","home-extra",…]` call (browse-page.js L1146), so the custom-action `command` is always
  `material-skin` (L91) and `LLHome-album=[]` is never consulted. **CORRECTION (per CDrummond, the Material
  author):** this one-call design is NOT new to 6.4.3 — "Material always got all scrollable lists with one
  call." An earlier note here claimed 6.4.3 introduced it; that was wrong, from a `git log -S` on the SHALLOW
  test-artifacts clone (history only reaches the 6.4.3 tag, so the search reported the oldest visible commit,
  not the real origin). So `LLHome-album` never worked on the carousel — home-shelf "Add" has always been
  governed by `online-*` + leftover view state (i.e. always "hit and miss"), never a regression. So we
  stopped trying to hide the button and moved the gate to the one path that always runs: the **add commands**.
  `_addCommand`/`_addCtxCommand` now call `_rejectAdd` (no DB row, **silent** — see below) unless
  `_isReplayableSource($source)` — library, or `Sources::_serviceCan` (an installed Qobuz/Bandcamp/Tidal
  adapter). Verified over JSON-RPC that **Deezer sends a valid `deezer://album:<id>` favurl and still can't
  play** (no adapter → `_searchService` has no deezer branch → `_noMatch`), which is why the gate keys on
  ADAPTER support, not favurl presence. `_writeMaterialActions` reverts to the pre-0.1.46 shape (library +
  `online-*` single pair + `listenlater-*`/`LLHome-*` suppressors); the TrackInfo provider's source gate was
  removed too (rejection covers it). Net: "Add" may appear on unsupported services / home shelves, but it's a
  harmless no-op — nothing unplayable is ever stored. **The reject is silent by necessity:** Material renders
  no toast for a custom-action/menu command (server-side `showBriefly` reaches physical player displays only,
  never the web UI — verified: no `showBriefly` handler anywhere in Material's JS), and its only feedback hook
  is a generic `'…' failed` snackbar whose text we can't set. So there's no way to show a descriptive "not
  supported" message from this path; the `showBriefly`/`PLUGIN_LL_UNSUPPORTED` reject-toast was removed as dead
  code (0.1.54). The pre-existing "Added" confirmation `showBriefly` stays — it still shows on hardware player
  displays. Known-gap docs from 0.1.50
  (globalsearch, home-shelf leakage) are now moot — they were only about hiding the button.
- **0.1.52** — **Fix: 0.1.51 hid "Add" on Qobuz/Tidal/Bandcamp/ListenBrainz.** `actions.json` is SHARED and
  persists across plugin updates. The scoping experiments (0.1.46–0.1.50) wrote per-command categories
  (`qobuz-album`, `tidal-album`, `bandcamp-album`, `listenbrainzfreshreleases-album`, the LBF tags, and the
  dynamic blocklist ones); 0.1.51 stopped writing them but the STRIP pass only removes our *entries*, leaving
  the categories as EMPTY arrays — and an empty `<cmd>-album` overrides the generic `online-album`
  (browse-resp.js ~L693), so it suppressed "Add" on the very services we support. Verified live over the
  served `customactions.json` (qobuz-album=0, tidal-album=0, …) and that LBF writes NO custom actions of its
  own (so every stale empty is ours). Fix: after the strip pass, delete every empty `*-album`/`*-track`/
  `*-artist` category EXCEPT the ones we actively write (the `%cats` keys) and our own suppressors
  (`listenlater-*`/`LLHome-*`); only-empty so another plugin's real entries are never touched. Supported
  services then fall through to the populated `online-*` again. **Lesson:** when you STOP writing a custom-
  action category, you must DELETE it — leaving it empty is not neutral, it actively suppresses.
- **0.1.53** — **Reject unidentifiable adds instead of defaulting them to Qobuz.** An LB "Created for You"
  playlist added as an empty `qobuz` album (log: `name=W/C 22 June 2026 … favurl= image=plugins/ListenBrainz…
  playlist-weekly-jams-prev.png svc=material-skin-client → addctx -> qobuz / … (id=113)`). Root cause: in
  `_addCtxCommand`'s no-favurl `else` branch, `svc` = `material-skin-client` fails the `^[a-z0-9]+$` test
  (hyphens), the image is a plugin PNG (not a service cover, so `sourceFromImage`→''), and the old
  `_defaultStreamingSource()` then forced `source='qobuz'` — which passed the reject gate and stored an
  album-less row. Fix: dropped `_defaultStreamingSource` (source is now `$svc || sourceFromImage || ''`), and
  `_isReplayableSource('')` now returns FALSE (was defaulting empty→library→true). So an unidentifiable item
  is rejected; a real streaming album with a service cover (e.g. Qobuz on a home shelf — same `svc=
  material-skin-client`, but a `static.qobuz.com` cover → `sourceFromImage`→qobuz → id recovered) is
  unaffected. NB the add commands still pass an explicit `'library'` for real library items, so empty source
  never legitimately means library. (Full playlist SUPPORT was assessed as too much work — LB playlists are
  ListenBrainz recommendation lists resolved track-by-track by LBF, with no service playlist id to replay.)
- **0.1.55** — **"Add" hidden on internet-radio BROWSE rows — a narrow, deliberate exception to the 0.1.51
  "don't scope the button" stance.** Radio stations are live streams, never a valid Listen Later item, and —
  unlike the general per-service scoping that 0.1.51 abandoned — radios ARE cleanly command-scoped in the
  browse menu, so this one case is worth doing. `_unsupportedRadioCommands` runs
  `executeRequest(undef, ['radios', 0, 500])` (works with no player), reads each `radioss_loop` entry's `cmd`,
  and drops any in `%SUPPORTED_CMD` (`qobuz bandcamp tidal listenbrainzfreshreleases listenlater`) — so a
  service also listed under radios (Qobuz) keeps Add, while a dual-listed but unsupported one (BBC Sounds,
  under both `apps` and `radios`) is blocked wherever it shows. For each remaining command `_writeMaterialActions`
  writes an **empty** `<cmd>-album`/`-track` with `||=` (0.1.48 non-clobber — the `<cmd>-*` namespace isn't
  ours; another plugin's real entries survive and still override `online-*` → Add hidden either way), and adds
  those keys to `%keep` so the 0.1.52 delete-empties pass leaves them — the one place we WANT an empty category
  to persist (empty overrides `online-*`, which is exactly the suppression we want; cf. 0.1.52's lesson used in
  reverse). **Browse rows only.** A radio HOME-SHELF card can't be hidden here (all shelves arrive in one
  `material-skin` home-extra call → resolves via shared `online-*`) — it stays
  a harmless add-time reject (0.1.51). This does NOT resurrect the full 0.1.46–0.1.50 saga (apps blocklist,
  scheme filter, home-shelf scoping) — only the radios slice, which is legitimate and self-contained.
- **0.1.56** — **Fix: 0.1.55 only blocked BBC Sounds, not TuneIn.** The `radios` enumeration runs at
  `postinitPlugin`, but **TuneIn's radio directory (Music/News/Sports/… categories) is fetched ASYNC from
  mysqueezebox.com** and isn't ready that early — so the init write only saw the locally-registered BBC Sounds
  plugin (verified live: served `customactions.json` had `bbcsounds-album`=0 but no `music-album`/`news-album`/…,
  while a later `['radios',0,500]` JSON-RPC returned all 11 TuneIn cmds). Added a **deferred re-write**:
  `_writeMaterialActionsDeferred` fires on a `Slim::Utils::Timers` timer +60s after postinit (killTimers-guarded,
  same pattern as `_purgeTick`), by which time the directory has loaded, so the TuneIn commands get their empty
  suppressor categories. `_writeMaterialActions` is fully idempotent so the re-run is safe. **Residual race:** on
  a very slow network the directory can take >60s to load → TuneIn shows "Add" until the next add/restart's write;
  acceptable (and the add is still a harmless reject). Confirmed radio-row suppression itself works — BBC Sounds
  was correctly hidden by 0.1.55, proving the empty-`<cmd>-album` override reaches radio browse rows.
- **0.1.59** — **`debug_log` pref — diagnostics for "Add missing on a streaming service" reports we can't
  reproduce on our own box.** A checkbox in Settings → Material Skin (`PLUGIN_LL_DEBUG_LOG`, pref
  `debug_log`, default off); `_dbg` logs at **WARN** (so it shows regardless of the category's level — INFO
  is invisible unless the category is at INFO). At the end of every `_writeMaterialActions` (when the pref is
  on) `_dumpMaterialState` dumps the whole decision surface for the online "Add": the detected Material
  version via `_materialVersion` (`Plugins::MaterialSkin::Plugin->getPluginVersion`) and whether it's **>=
  6.4.4** (online custom actions exist — below that, streaming rows get NO Add and only local works, the
  reported symptom); `online-album`/`online-track` entry counts (empty → no streaming Add anywhere); any
  **NON-empty `<svc>-album`/`-track`** category, which SHADOWS `online-*` and hides Add on that one service
  (ours are always empty, so a populated one is foreign/leftover — the thing to look at); the radio/
  unsupported commands we suppress; and a per-enabled-app verdict (`apps 0 500`) of "Add shown via online-* /
  HIDDEN by a per-command category / no Add (Material < 6.4.4)". Prime suspects for another user, both
  invisible from our box: (1) Material older than 6.4.4; (2) a stale app-start-cached `customactions.json`
  (the file is correct but an open tab shows the old one — hard-refresh once, see 0.1.57). No behaviour
  change when off. **The report is also surfaced in the Settings page itself** (not just server.log): the
  accumulated lines are stashed in the `material_debug_snapshot` pref and rendered in a readonly select-all
  textarea (`PLUGIN_LL_DEBUG_SNAPSHOT`, shown only when `debug_log` is on) so a remote user can copy-paste it
  without touching the log. `Settings::handler` persists the two Material toggles from the form and re-runs
  `_writeMaterialActions` on save (guarded on material_action + MaterialSkin, like postinit) so the snapshot
  reflects the just-saved state, then passes it to the template before SUPER renders.
- **0.1.57** — **Fix: 0.1.56's deferred write hid TuneIn "Add" in the FILE but not in the live UI — a Material
  load-time cache issue, not a file issue.** Traced end-to-end over HTTP: (1) the served `customactions.json`
  correctly had `music-album`/`news-album`/… = 0 after the +60s deferred pass; (2) `browse-resp.js` L91/685/692
  resolves a TuneIn station to `command="music"` (from `data.params[1][0]`, confirmed via menu-mode
  `['radios',…,'menu:radios']` → each item's `actions.go.cmd=['music','items']`; the plain `radios` query's
  `cmd` field happens to match) and `btype="album"` (stations are `type:audio` app items → the `:"album"` else),
  so it checks `"music-album" in customActions` → empty → no Add. The logic is correct. BUT
  `customactions.js:25` fetches the file **once at Material app start** via `axios.get(".../customactions.json?r="
  + LMS_MATERIAL_REVISION)` — `?r=` is the Material VERSION, not our writes — so it's browser-cached and never
  re-fetched in-session. `bbcsounds-album` (written at INIT, before Material loads) was always present;
  `music-album` (written +60s) was missed by already-loaded/cached tabs → fell back to populated `online-album`
  → Add showed. **Verified**: in a fresh incognito window (cache-bypassed) TuneIn Add was correctly gone. **Fix:**
  seed a hardcoded `@KNOWN_RADIO_CMDS` (`music news sports talk location language podcast search presets local` —
  TuneIn's stable top-level categories) at INIT, unioned with `_unsupportedRadioCommands()` (minus
  `%SUPPORTED_CMD`), so the empties exist before Material ever loads the file. The +60s deferred write stays
  (catches other late radio plugins). One-time: after updating, hard-refresh Material once to drop the stale
  cached `customactions.json`; correct on every restart thereafter. **Lesson:** Material caches
  `customactions.json` at app start keyed on its own revision — a category MUST be on disk before Material loads
  or an open/cached tab won't see it; deferred/async writes are invisible until a hard refresh.
- **0.1.60** — **Deezer is a supported streaming source.** Deezer joins Qobuz/Bandcamp/Tidal in
  `Sources.pm`: `%SCHEME`/`sourceFromImage` (dzcdn.net host) recognise it, `_serviceCan` returns true when
  `Plugins::Deezer::Plugin->can('getAlbum')`, `_streamingAlbumNode` replays a captured id via
  `Plugins::Deezer::Plugin::getAlbum` with passthrough key **`id`** (same as Tidal — confirmed
  `getAlbum` reads `$params->{id}` → `albumTracks`), and `_searchService` gains a Deezer branch (API-handler
  `->search(cb,{search,type=>'album',strict=>'off'})` → bare arrayref of raw album hashes → `_renderAlbum`,
  which already returns `type=>playlist, url=>\&getAlbum, passthrough=>[{id}]`). No add-gate list changed
  because since 0.1.51 the sole gate is `_isReplayableSource` → `_serviceCan`; adding the branch is enough,
  so Deezer adds (its browse rows carry a clean `deezer://album:<id>` favurl — the generic
  `m{(?:[:/])album:([A-Za-z0-9._-]+)}` capture already extracts it) are now accepted and replay by id.
  The prior "Deezer sends a valid favurl and still can't play" reject (0.1.51) is exactly what this closes.
  Pairs with ListenBrainz Fresh Releases 0.9.69 (Deezer matching). Deezer plugin surface confirmed against
  michaelherger/lms-deezer.
- **0.1.61** — **Deezer adds backfill the artist (like Tidal, 0.1.45).** Verified live: a Deezer album added
  from browsing stored **and replayed** (id=119 Revolver → 14 `deezer://…flc` tracks), but the `addctx` log
  showed `artist=` EMPTY — Deezer browse rows carry no `$ARTISTNAME` (Material doesn't map the subtitle) and
  the `e-cdns-images.dzcdn.net` cover URL has nothing to recover it from (same as Tidal). So the artist-less
  record showed album-only and would never auto-move to Played (keys on source+artist+album). Generalised
  `_backfillTidalArtist` → **`_backfillStreamingArtist($client,$recId,$albumId,$source)`**, which picks the
  right plugin's `getAlbum` (Tidal or Deezer — both share `($client,$cb,$args,{id})→{items}`, tracks with
  `line2`=artist) and updates the record async/guarded; the call site now fires for `tidal` OR `deezer`. Also
  added `deezer` to `%SUPPORTED_CMD`. **The reported "failed to add from browsing albums" was NOT a failure**
  — the add stored (`setStatusDone` called) and the album plays; Material just shows no success toast on the
  web UI (`showBriefly` reaches hardware players only — the 0.1.51/0.1.54 limitation), so a successful add
  looks like nothing happened. Pre-0.1.61 Deezer saves can be removed + re-added to gain the artist.
- **0.1.62** — **"Add to Listen Later"/"Add to Wish List" restored on Material's Now Playing screen (reverses
  0.1.34).** `_writeMaterialActions` now writes the plain **`track`** category again (added to `%cats`, so it's
  also in `%keep` and survives the delete-empties pass). Material's Now Playing menu is the ONLY consumer of
  `track` (`nowplaying-page.js getCustomActions("track")`), so this puts Add there and nowhere else — the
  queue uses `queue-track`, browse lists `album-track`/`playlist-track`. It uses the existing `$trackCmd`
  (`name:$ALBUMNAME`), so it adds the **currently-playing ALBUM**, not the track (the `trackname`/`trackid`
  params are logged only — `_addCtxCommand` always stores `$album`). Behaviour by source: a streaming
  now-playing track's `$FAVURL` is the TRACK url (e.g. `deezer://<id>.flc`, no `album:<id>`), so the source is
  read from the scheme and the album is resolved by artist+title search (`Sources::_searchService`); a library
  track carries `$ALBUMID` and adds directly. Same end result the user already gets from the play queue's
  "… → More". (0.1.34 had omitted `track` as a deliberate design choice — Now Playing is track-oriented, the
  plugin saves albums — but it's wanted back.)
- **0.1.63** — **Top-level "Add" restored on PLAY-QUEUE tracks (`queue-track` category).** The queue's track "…"
  menu only showed Add under "… → More" (the TrackInfo info-provider), never at the top. Confirmed against the
  SERVED main bundle: the queue component does `this.queueCustomActions = getCustomActions("queue-track", false)`
  — so Material DOES support custom actions on queue items (the 0.1.34 note was right; a WebFetch of
  `nowplaying-page.js` wrongly claimed queue items get none — the string `queue-track` is present twice in
  `material.min.js`, so trust the served bundle over a summarised fetch). We just weren't writing the category.
  Added `'queue-track' => $trackCmd` to `%cats` (so it's in `%keep` and gets the Add/Wish-List pair). Same
  `$trackCmd` → adds the track's ALBUM. Surfaces confirmed distinct: `track` = Now Playing info panel,
  `queue-track` = the play-queue list, `album-track`/`playlist-track` = browse lists, `online-track` = streaming
  rows. **Method to identify a surface's category: grep the SERVED bundle (`curl …/material/html/js/material.min.js`
  + `material-deferred.min.js`) for `getCustomActions(` — literal args are the category; the queue/nowplaying ones
  are set via `bus.$on("customActions", …)` handlers.** Needs a Material hard-refresh after install (customactions
  cache, 0.1.57).
- **0.1.64** — **Now Playing "Add" now actually stores the album (the `track` category from 0.1.62 was inert).**
  Diagnosed from the live log: a Now Playing Add arrived as `name=special, artist=Richard Orofino, albumid=,
  favurl=, trackid=, svc=(undef)` → `rejected add — unsupported source ''`. Root cause confirmed by extracting
  Material's `doReplacements` var map from the SERVED bundle: the Now Playing `track` action's substitution
  object `c` = the now-playing item, which has `c.album`/`c.artist`/`c.title` but **no
  `c.presetParams.favorites_url` and no `c.album_id`** — so `$FAVURL`/`$ALBUMID`/`$SERVICE` are all empty and
  `$source` came up '' → the 0.1.53 reject fired. (So `track`/`queue-track` differ: a QUEUE item carries a real
  favurl, a NOW-PLAYING panel item does not.) Fix: **`_nowPlayingFallback($client,$album,$artist)`** — when
  `$source` is empty and there's a client, recover source + album from the player's **currently-playing track**
  (`$client->playingSong->currentTrack->url` → scheme = source; `->album->id` for a library track), guarded by
  matching the playing track's album (+artist when both known) to the params so a stray empty-favurl Add can't
  adopt an unrelated playing track. A streaming NP track's url is a TRACK url (no `album:<id>`) → replay by
  artist+title search; a library NP track adds by album id. Reuses `Sources::_norm`/`_artistMatch`. Unsupported
  services still reject (the scheme feeds `_serviceCan`). NB: relies on `$request->client` being the playing
  player — Material sends the current player with the custom action, so it is.
- **0.1.70** — **Matcher: self-titled-album exact rule (fleet sync from Discography 0.11.1).** `_albumMatches`
  (`Sources.pm`) now, when the album title normalises to the ARTIST name ("The Beatles", "Weezer"), requires an
  EXACT title before the lenient "starts-with" rule — so a saved self-titled album stops matching "The Beatles
  1962-1966" etc. `_norm` still strips brackets, so "(White Album)"/"(Remastered)" match. Fires ONLY when the
  artist is present AND == the album; **LL's deliberate lenient empty-artist replay path is untouched** (the
  self-titled block sits above the `return 1 unless length $artistNorm` line). Applied across the fleet
  (LBF 0.9.90, PFR 0.7.5, DSC already had it); LL's pinned `_albumMatches` variant re-pinned
  `5d270440af5a→2bf38f346e0f` in `matcher_sync_check.py` (exits 0). No cache (LL matches live). `perl -c`
  clean; validated by the shared self-titled matcher test incl. the LL empty-artist leniency preserved. (0.1.65–0.1.69 detail is in CHANGELOG.md.)
- **0.1.71** — **Clean album title on adds from a sibling plugin that labels rows "Artist - Album"
  (Pitchfork Reviews) — fixes those albums never auto-moving to Played.** A Pitchfork row's `name`/`line1`
  is `"Artist - Album"`, and Material forces `$ALBUMNAME`/`$TITLE` to that whole label for online items, so
  `_addCtxCommand` stored the album title with the artist prefixed ("Will Sheff - Extra Mile"). That showed
  DOUBLED in the list ("Will Sheff – Will Sheff - Extra Mile") AND broke **Played auto-detection**: its
  dedupe-key album segment then included the artist, so the playing Qobuz track's clean album ("Extra Mile")
  never matched via `Played::_matchRecord` → `DB::findByArtistAlbum` (nor the `findByAlbum` fallback). Fixed as
  the symmetric partner of the existing `&a=` artist handshake, NOT an LL-side strip of bad input: **PFR
  (0.7.6) packs the CLEAN album into the favurl as `&al=`** (`Browse::_attachFavUrl`), and `_addCtxCommand`
  reads `[?&]al=` and prefers it over `$TITLE` (`[?&]a=` can't match `&al=` — it needs `=` right after `a`).
  Already-saved polluted rows are cleaned by a one-off idempotent DB migration `DB::_migrateArtistPrefix`
  (strip a leading `"<artist> - "`/en/em-dash from the title + recompute the dedupe_key; **streaming rows
  only** — a local album can legitimately be titled "Artist - Title"; per-row guarded against a
  UNIQUE(source,dedupe_key) collision with a clean twin). No matcher change (`_attachFavUrl` is outside the
  shared engine). `perl -c` clean. NB the fix needs BOTH plugins updated; an older PFR sends no `&al=` and new
  adds from it stay polluted until it's updated (existing rows are still cleaned by the migration).
- **0.1.72** — **Code-review hardening of the 0.1.71 `_migrateArtistPrefix` cleanup** (behaviour of the add-path
  `&al=` fix unchanged). Three fixes, all verified against a real in-memory SQLite DB
  (`scratchpad/verify_migration.pl`, all pass): **(1) run ONCE** — the migration was called from `_migrate` on
  every server start (a full non-library `SELECT` + per-row Perl loop each boot, and a row that can't be cleaned
  — a `UNIQUE(source,dedupe_key)` collision with a clean twin — re-logged its skip WARN forever). Now gated on
  the SQLite `PRAGMA user_version` (0 ⇒ run + stamp `1`), so it's genuinely one-off; still idempotent so a
  re-run after a partial upgrade is safe. **(2) narrower prefix match** — the strip now requires the
  SPACE-PADDED `"<artist> <dash> <album>"` shape Material actually renders (`\s+[dash]\s+`, was `\s*[dash]\s*`),
  so a hyphenated single-token title (`Jay-Z`, `Sunn O)))-Monoliths`) can no longer be misread as an artist
  prefix and corrupted. Residual (accepted, now bounded to the single run): a streaming album whose REAL title
  genuinely is `"<own artist> - <rest>"` with spaces is indistinguishable from the pollution by stored content
  alone and is still stripped — vanishingly rare, and library rows (where it's most plausible) are excluded.
  **(3) full dash family** — separator class broadened from hyphen/en/em to also cover figure dash (U+2012),
  horizontal bar (U+2015) and minus (U+2212), so sibling labels using any dash variant are cleaned. `perl -c`
  clean (logic validated standalone — Slim modules absent on the Mac). No matcher change.
- **0.1.74–0.1.78** — **Individual TRACK + single/EP support** (the plugin previously saved albums only).
  New `kind` column (`album`|`track`) with a `user_version < 2` migration; a track gets a 4-segment dedupe key
  (`artist|album|year|t:<track>`) so a track and its parent album never collide. Distinguish album vs track by
  **context** (album vs track menus differ) rather than a chooser. Visual distinction is **glyph + type word in
  the subtitle** (Material can't badge artwork, and the no-image-libs rule bars server compositing): `♫` (U+266B)
  = multi-track release (Album/EP), `♪` (U+266A) = single track (Single release OR individual Track); subtitle
  reads Album/EP/Single/Track. **Release-type classification is "service type, count fallback"** — prefer Qobuz's
  authoritative `getAlbum→release_type`, else a resolved-track-count heuristic (1=Single, 2–6=EP, 7+=Album) — and
  is done **before** the row is inserted (`_classifyThenAdd`, async + `setStatusProcessing`) so the list never
  shows a wrong "Album" that flips to EP/Single on refresh. **AMENDED 2026-07-29 — this classify-before-insert
  rule now applies ONLY to an UNKNOWN type; a type a SOURCE ASSERTS inserts immediately and is corrected in the
  background. See "Release type: why an asserted type is not classified before insert" below. Do not re-argue
  it from this paragraph.** Track/album Played states are independent (a saved
  track marks Played on newsong via `findTrackByUrl`/`findSavedTrack`). **Streaming-track detection is favurl-based,
  not category-based**: Material collapses a Qobuz album-drill track row onto `online-album` (its `wa` is-track flag
  is false), so `Sources::favurlIsTrack` (a `.flac`/`/track/` play url with no `album:`) is the reliable tiebreaker.
  **Now Playing** (Material can't drill from a top-level custom action — `getSectionActions` renders a FLAT list):
  top-level default = **Add track** (the `track` category, `[$trackBase]`); **Add album** lives in the TrackInfo
  "… → More" (`_trackInfoHandler`, album-only). Classic skin therefore reaches only Add album from a track row.
- **0.1.79** — **A streaming track whose release is a SINGLE is stored AS the Single, and track↔single never
  duplicate.** Two coupled fixes to "adding a single from Now Playing gave two rows (a Track, then a Single) that
  didn't reconcile". **(1) Track-add classification** — `_saveTrackRecord` now, for a Qobuz/Tidal/Deezer track with
  a recoverable album id, classifies the release and, if `single`, stores it in the **album (Single) form** instead
  of `kind='track'` (`_saveTrackClassify`, async + `setStatusProcessing` + 6s timeout). The album id comes
  SYNCHRONOUSLY from the service's cached playing-track metadata via `Sources::trackAlbumId`
  (`ProtocolHandlers->handlerForURL->getMetadataFor` → `albumId`/`album_id`); Qobuz uses the authoritative
  `release_type`, Tidal the resolved-track count. **Deezer** (its `getMetadataFor` flattens the album object to a
  bare title, dropping the id) and **Bandcamp** (no native album id) can't classify from Now Playing, so they
  degrade to storing a plain Track. Because the Single form shares the album 3-segment dedupe key, a later "Add
  album" of the same single is a natural no-op. **(2) Cross-kind single reconcile (all services, no extra API
  calls)** — for the degraded/reverse cases: `_finishAlbumAdd`, when inserting a `single`, no-ops if a matching
  track already exists (`DB::findTrackByArtistTitle`, a `artist|%|t:title` LIKE), and `_insertTrackRow` no-ops if a
  matching `single` album already exists (`DB::findByArtistAlbum` + `rel_type eq 'single'`); both guarded on a
  known artist so a bare-title match across artists can't misfire. So a single and its lone track are treated as
  the same recording and never both stored; a genuine multi-track album's track still coexists with its album (an
  accepted edge: a 2-track single's A-side track + the single release are treated as the same release). Per-service
  album-id + release-type signals verified from plugin source — see memory
  `streaming-track-album-id-signatures`. `perl -c` clean; no matcher change (matcher_sync_check LL variants still
  pass; the DSC-vs-others drift it reports is pre-existing and unrelated).
- **0.1.80** — **Fix: 0.1.79 skipped classification for STREAMING BROWSE-track singles (reported: "Tidal singles
  add purely as tracks").** A browse track row carries no `$ALBUMNAME` (and a browse add has no Now-Playing
  fallback), so the 0.1.79 classify gate `defined $album && length $album` was false → it stored a plain Track,
  never detecting the single. The album NAME was never needed to classify (that needs only the album ID, recovered
  inside `_saveTrackClassify` from the service's cached metadata); it's only needed to LABEL the stored Single, and
  a single's release title is the track title. Fix: gate on `_canClassifyTrack($source) && $request->client` only,
  and default the Single record's `album_title` to the track title when no album name arrived. Affected Tidal AND
  Qobuz browse-track adds equally (the earlier Qobuz confirmation was via LBF Now Playing, which DID carry an album
  name). Added a WARN diagnostic (`LL: track-classify source=… url=… albumId=…`) so a live add can be traced via
  `curl http://plex:9000/log.txt`.
- **0.1.81** — **Code-review fixes on the 0.1.74–0.1.80 track work** (no new feature). **(1) The same track saved
  from two SURFACES no longer makes two rows.** The track dedupe key carries the PARENT ALBUM, and the album name
  depends on where the add came from: a queue / Now Playing row sends `$ALBUMNAME`, a streaming BROWSE track row
  sends none (`online-track` has no `name:` param), so the same track landed as `artist|the album||t:x` one way and
  `artist|||t:x` the other — different keys, which `DB::add`'s exact-key `findAnyByKey` can't reconcile.
  `_insertTrackRow`'s existing cross-kind single guard now also runs **`DB::findTrackByArtistTitle`** (`artist|%|t:title`
  — album segment wild), catching it in either order. Same class of hole on the YEAR segment for singles:
  `_finishAlbumAdd` now also checks `DB::findByArtistAlbum` (year-agnostic) and no-ops when that row is **also**
  `rel_type='single'` — the rel_type gate is what keeps 0.1.43 (two same-titled ALBUMS from different years still
  coexist). Verified against real in-memory SQLite (`scratchpad/verify_track_dedupe.pl`, 10/10: both orderings
  caught, no false positive on a sibling track or a same-titled track by another artist, 0.1.43 preserved).
  **(2) A saved track is no longer marked Played the instant it starts.** `Played::_markPlayedTrack` marked on
  `newsong` with no threshold (unlike albums), so merely SKIPPING PAST a saved track marked it Played — and
  `purgePlayed` (which filters on `status='played'` alone, no `kind`) then deleted it `played_retention_days`
  later. The record is still LOOKED UP at newsong (metadata is freshest there) but the mark is deferred by
  **`_armTrackMark`**: a `Slim::Utils::Timers` timer at `played_threshold`% of `$song->duration` (the same pref the
  album path uses), falling back to 60s when the song reports no duration, floor 5s. At fire time it re-checks that
  the same url is still playing, that `watch_outside` is still on, and re-reads the row's status. One pending mark
  per player, cancelled on new song / stop / clear / `shutdown`. **(3) Dead code removed:** the info-provider track
  path was fully written but never wired — `Sources::captureTrackFromTrack` had no callers, so nothing ever
  produced a `kind='track'` record, making `_addItemFor`'s kind block and `_addCommand`'s `kind:track` branch
  unreachable and `PLUGIN_LL_ADD_TRACK`/`_WISHLIST` unused. All deleted; the `_saveTrackRecord` header (which
  claimed two callers) corrected to say the Material `addctx` action is the only entry point — **so Classic skin
  has no individual-track add**, as 0.1.74–0.1.78 already documents. **(4) `Sources::favurlIsTrack` hardened:** the
  decisive-negative test now covers `playlist:`/`artist:`/`mix:` as well as `album:`, and the fail-open `return 1`
  logs a WARN naming the url — nothing enforces the "an album favurl is empty or carries `album:`" invariant, so if
  a SUPPORTED service ever emits an album favurl in an unrecognised shape its albums would be stored as
  `kind='track'` rows pointing a `type => 'audio'` item at a non-audio url (rows that can't play); now that shows
  up in `log.txt` as a named suspect instead of silently. `perl -c` clean on all five modules. No matcher change
  (`matcher_sync_check.py` reports `LL variant OK`; its non-zero exit is the pre-existing DSC-vs-PFR
  `_albumMatches` drift noted in 0.1.79).
- **0.1.82** — **Fix: a streaming SINGLE (or short EP) could NEVER auto-move to Played.** Reported as "played a
  track through and it's still in my LL list"; diagnosed from `curl http://plex:9000/log.txt` — the row logged as
  `_finishAlbumAdd … rel=single`, i.e. `kind='album'`, so the individual-track Played path was never involved.
  **Root cause, opened by 0.1.79:** that release stores a streaming single in ALBUM form, so it goes down the album
  Played path — where `_totalTracks` returns undef for anything not `library`, and `_maybeMark` therefore falls to
  the `streaming_min_tracks` floor (default **4** distinct tracks). A single has ONE track, so `$seen` maxes at 1
  and `1 >= 4` is never true. EPs with fewer than `streaming_min_tracks` tracks were broken identically. The
  `rel_type` column added in 0.1.74–0.1.80 was exactly the missing signal but Played never read it. **Fix:**
  `_totalTracks` returns **1** for a `rel_type='single'` record (that is what the classification means — Qobuz's
  authoritative `release_type` or a resolved count of 1), so it takes the known-total branch and needs
  `ceil(60% × 1) = 1` track; and `_maybeMark` caps the streaming floor at **2** for `rel_type='ep'` so a 2-track EP
  can still complete. `%tracking` now carries `rel_type`. Streaming ALBUMS and legacy `rel_type IS NULL` rows keep
  the 4-track floor unchanged; library albums are untouched. **Also: the Played marking log lines are WARN, not
  INFO** — INFO is invisible in `log.txt` unless the category is raised, which is precisely what made this
  undiagnosable from a log dump (see the CLAUDE.md testing note). Existing rows need no re-add: the fix reads
  `rel_type` at play time. Verified with `scratchpad/verify_played_threshold.pl` (12/12 across single / EP /
  album / unknown-type / library).
- **0.1.83** — **A one-track release moves to Played when it has actually been PLAYED THROUGH, not when it
  starts.** 0.1.82 gave a Single a real total of 1, which made the counter say "1 of 1 seen" on the very first
  `newsong` — so a Single was marked the instant it started, the same "skip past it and purgePlayed deletes it"
  flaw 0.1.81 removed from individual tracks. **Unified:** anything whose Played status rests on ONE track — a
  saved `kind='track'` row, a Single, or a 1-track library release (`_totalTracks == 1`) — now bypasses the
  distinct-track counter entirely and takes the deferred played-through check. `_onChange` routes it to
  **`_armDeferredMark`** (the generalised `_armTrackMark`), which fires at **`TRACK_MARK_FRACTION` = 90%** of
  `$song->duration` — NOT the actual end, because the last seconds are usually fade/silence and with crossfade or
  gapless the next song's `newsong` (which cancels the pending mark) arrives BEFORE the current track's audio
  truly ends; 90% always lands before that hand-off. Was `played_threshold`%, which is documented as a % of an
  album's TRACK COUNT — a conflation. **Pause-correct:** the timer body **`_deferredMarkTick`** re-reads
  `$client->songElapsedSeconds` and, if actual playback is short of the target (paused, or seeked back), re-arms
  for the shortfall instead of marking — so the wall clock coming round is never mistaken for listening. It's a
  NAMED sub, not a closure, so `setTimer`/`killTimers` pair on the coderef and a re-arm can't build a
  self-referencing closure chain. Still guarded on `watch_outside` and the same-url check at fire time, still one
  pending mark per player, cancelled on new song / stop / clear / shutdown. Streams reporting no duration keep the
  flat `TRACK_MARK_FALLBACK_SECS` (60s) wait. **EPs and albums are untouched** — they keep the distinct-track
  counter (EP floor capped at 2 per 0.1.82). Verified with `scratchpad/verify_played_flow.pl` (19/19: routing per
  release type, skip-after-2s and halfway both held, 90% and end-of-track both marked, pause re-arms, and the
  counter path unchanged).
- **0.1.84** — **Podcast episodes.** An episode from the built-in **Podcasts app** can be saved from its browse
  row, storing as an ordinary `kind='track'` record — so replay, dedupe and the 0.1.83 played-through Played
  check all come from the existing track machinery unchanged. The menu entry reads **"Add podcast to Listen
  Later" / "… to Wish List"**. See "Podcast episodes" below for the measured constraints.
  New `Podcast.pm` (feed fetch/parse/resolve), `kind:podcast` add path (`_savePodcastEpisode`),
  `Sources::_serviceCan('podcast')`, "Podcast" type word in the row subtitle (source segment dropped so it
  doesn't read "Podcast · <show> · Podcast"). Verified against the live server + the real Darko.Audio feed:
  parser returns **129 episodes, exactly matching the 129 the browse query reports**; the row's `$IMAGE`
  unwraps to the RSS `itunes:image` byte-for-byte; the title key matches too; duration 3485s == the row's
  "(58:05)".
- **0.1.85** — **Podcast episodes save from ANY container, not just the Podcasts app** (reported: "context
  still says add album and it doesn't add it" — the add was coming from a favourited FEED, `svc=favorites`).
  Last-resort resolve before `_addCtxCommand` rejects; type-neutral wording on `favorites-*`; and **no Wish
  List entry for podcasts** (you don't buy podcasts) with a generic-container wishlist add redirected to
  Listen Later. Detail in "0.1.85 — episodes reached through OTHER containers" below.
- **0.1.87** — **Podcast rows use ❝ (U+275D) instead of the ♪ note**, so speech is distinguishable from music at a glance; `GLYPH_PODCAST` in `Browse::_glyphFor`, keyed on `source eq "podcast"`. No plain-text microphone exists — see "Glyph" in the Podcast section below for why. *(Glyph PLACEMENT changed in 0.1.93: it now leads `line2` beside the type word, not the title.)*
- **0.1.86** — **One plain wording for every row: "Add to Listen Later" / "Add to Wish List".** A browse ROW
  already tells you what it is (you're looking at an album, a track, a podcast episode), so naming the type in
  the menu is noise — and Material can only name it per CONTAINER, which gets it wrong on any mixed list. The
  ONE exception is Material's **Now Playing** panel: there you're outside any listing, so "this track" and
  "the album it's from" are both plausible and the entry has to say which — it keeps **"Add track to Listen
  Later" / "Add track to Wish List"**, with the album option qualified alongside it in "… → More"
  (`PLUGIN_LL_ADD`/`_WISHLIST`, the TrackInfo provider, which can drill). Roles collapse to
  **plain / nowplaying / podcast**. Podcasts use the plain wording with **no Wish List entry** (0.1.85).
  **`favorites-*` is dropped again**: it existed in 0.1.85 solely to get neutral wording there, and now that
  every row-level entry is neutral, favourites inherit exactly the right wording from the `online-*` fallback
  (the last-resort podcast resolve supplies the behaviour). A leftover empty from the 0.1.85 build is cleared
  by the strip pass and then removed by the delete-empties pass, so it can't linger and SUPPRESS `online-*`
  (the 0.1.52 rule). Wording map verified by extracting `%roleTitle` + `%cats` from the source and printing
  every category's entries.

- **0.1.88** — **A claimed 'single' is verified, and every streaming release remembers its track
  count.** Two failure modes of the same root cause: LL reads `rel_type='single'` as "this release
  has exactly ONE track" (`Played::_totalTracks` returns 1 → 0.1.83's played-through mark), but the
  sources that ASSERT a type don't mean it that way. MusicBrainz (via LBF's `&rt=` handshake, LBF
  0.9.141) types a release group Single however many B-sides/remixes/radio edits it carries, and
  **Qobuz's `release_type` does the same** — so a 3-track single was marked Played after track one.
  Mirror case: a release MB correctly calls an Album that holds ONE track fell on the
  `streaming_min_tracks` floor of 4, which it can never reach, so it could never be marked at all.
  **Fix, in three parts.** (1) `Sources::singleIsWrong($type,$count)` — a claimed single with a
  count > 1 isn't one; `relTypeFor` applies it (library adds settle synchronously, the count is
  free) and `_settle` applies it to every async classify. Demotion goes to the COUNT's verdict
  (2-6 = ep, 7+ = album), NOT unconditionally to 'ep' — calling a 9-track release an EP just
  re-runs the same early-mark bug against the EP's 2-track floor. A claim with NO resolvable count
  stands (unchanged behaviour beats a guess). (2) New **`track_count`** column (`user_version < 3`
  migration, `DB::updateTrackCount`, which OVERWRITES — unlike `updateRelType` — since it's a
  re-measurement). `Played::_totalTracks` now reads library live → stored count → the `single`⇒1
  fallback, so a resolved streaming release gets the same `played_threshold`% rule as a library
  album and the flat floor applies only to unresolved ones. (3) `Browse::_albumTracks` refreshes
  the count on every resolve and force-corrects a stored single that resolves to >1 track — this is
  what repairs rows saved before 0.1.88, free, from a resolve that was happening anyway.
  **Performance shape (the point that was iterated on):** the add must NOT wait on a service. A
  known type (library or `&rt=`) inserts immediately as before; `_verifyRelease` then chases the
  count fire-and-forget AFTER the insert (same pattern as `_backfillStreamingArtist`), gated on the
  row having a native album ID — without one the lookup would fall back to `_searchService`, and
  the SEARCH is the expensive half, so those rows just wait for their first play. Only an UNKNOWN
  streaming type still blocks (pre-existing `_classifyThenAdd`; a row that flips label on refresh
  is worse). **Qobuz costs zero extra calls**: its album object carries `tracks_count` alongside
  `release_type`, so `Sources::albumTrackCount` reads both off the one fetch and NO tracklist is
  resolved (verified: 0 tracklist fetches on every Qobuz path with a count). Tidal/Deezer/Bandcamp
  have no album-object surface on their ID path — `getAlbum` returns the TRACKLIST — so they cost
  one background call, which is the same call the first play would have made anyway. **This is
  settled, not assumed**: per `streaming-track-album-id-signatures` (verified 2026-07-25 from each
  plugin's source), Tidal album objects DO carry `type`+`numberOfTracks` and Deezer's carry
  `record_type`+`nb_tracks`, but only on the raw `albums/<id>` / `album/<id>` endpoints the plugins
  don't surface — and **reaching into those private internals was DECLINED (Simon, 2026-07-25:
  breaks on plugin updates), so catalogue-side single/EP detection is Qobuz-only BY DECISION.
  Don't re-attempt it.** What is legitimately reachable is those plugins' own public SEARCH
  results, whose raw album hashes carry the counts (`_searchService`'s Tidal/Deezer branches) —
  unused here only because the search is the expense being avoided. Hence those two field names in
  `albumTrackCount` are inert today, kept because they're verified and reachable without going
  private. **Catalogue vs
  playable — CORRECTED 2026-07-30, this was a real bug:** Qobuz's `tracks_count` is the catalogue
  count and can exceed what's playable in a region. 0.1.88 stored it as the total and called it
  "provisional, overwritten by the first drill/play" — but that overwrite only happens on a
  drill/play **from the LL list**, so a release heard from Qobuz's own pages (i.e. what
  `watch_outside` exists for) kept the inflated total indefinitely, needing 60% of tracks that don't
  exist for that user — **strictly worse than the 4-track floor it replaced.** Now
  `classifyRelType` returns a THIRD value marking a catalogue count PROVISIONAL; it settles the
  type (what the fetch is for, and the `singleIsWrong` demotion still works) but is never stored as
  the total. A total now comes only from a resolved TRACKLIST, which the service has already
  region-filtered. Provisional counts are still passed back so `_verifyRelease` can tell "the
  service answered" from "unreachable" — otherwise every Qobuz add would spend a pointless retry
  and log a failure that never happened. `_finishAlbumAdd` also skips the background verify when a
  classify already saw a provisional count (`_provisionalCount` on the rec, not a DB column), since
  re-fetching the same album object would return the same number. Residual, accepted: a release
  Qobuz explicitly asserts is an `album` while holding 2-6 tracks now waits on the floor until its
  first play — narrow, because a small count classifies itself (1 → single → total 1; 2-6 unasserted
  → ep → floor capped at 2). If it bites, the fix is to let a provisional total only ever LOWER the
  bar (`need = min(pct of it, floor)`), never raise it — sound because a catalogue count can only
  exceed the playable one. Covered by `t_reltype.pl` (producer) and `t_verify_retry.pl` (consumer);
  both were checked against the unflagged code and fail there.
  Podcasts are untouched (episodes insert as `kind='track'`, never the album path). Verified by
  four scratch suites (61 checks): `relTypeFor`/`singleIsWrong` truth table, the full
  `classifyRelType` decision table against a stubbed service, the Qobuz zero-tracklist path, and
  real-SQLite migration/persistence + every `_totalTracks` branch. No matcher change
  (`matcher_sync_check.py` still reports LL variant OK on all three pinned subs).

- **0.1.89** — **`&tc=` handshake: the sibling sends the release's TRACK COUNT, so 0.1.88's
  background lookup disappears for LBF adds.** Completes what LBF 0.9.141's `&rt=` should have
  carried: LBF already reads a count off the streaming service's own album hash while matching
  (`_candReleaseType`, since 0.9.89), on the same items, ~11 lines before `_attachFavUrl` builds the
  favurl — so the number was in hand and unused, and `&rt=`'s bare MusicBrainz "Single" is exactly
  what needed checking against it. **Receiver ships FIRST** (this release): an updated LBF must
  never meet an LL that can't strip `tc=`, or the param is left in the favurl. With no sender
  present this release is behaviourally identical to 0.1.88. Reader sits with the other private
  params in `_addCtxCommand`: `s{[?&]tc=([^&]*)}{}` — strips ANY value so nothing is left behind,
  THEN validates `^\d{1,3}$ && > 0` (a bogus/huge count would set an unreachable Played threshold
  at 60% of nonsense; junk → undef → falls back to resolving). Feeds `relTypeFor(service => rt,
  count => tc)`, so `singleIsWrong` fires at INSERT time with **zero service calls**; stored as
  `track_count` (streaming only — library counts live), which automatically suppresses
  `_verifyRelease` via its existing `!$rec->{track_count}` gate (no new logic). Bonus: the type is
  correct BEFORE `_finishAlbumAdd`'s single-dedupe block, so a mislabelled single can no longer
  be wrongly no-op'd against a saved track of the same name. `DB::add`'s `_sane()` is a second
  guard. **The receiver did NOT work as shipped** — it discarded every count; see the `&tc=` lesson
  in the regression-tests section, including why the 24-check `verify_favurl_params.pl` (since lost
  to a scratchpad) could not have caught it. Fixed 2026-07-30, and the extraction now lives in
  `_stripPrivateParams` with `tools/t_favurl.pl` calling it: real LBF Qobuz/Bandcamp/`&al=` favurl
  shapes, tc first/last/alone, `a=` still not eating `al=`, junk values stripped-then-rejected, and
  native Qobuz/Tidal/Deezer favurls byte-for-byte untouched. **Bandcamp gets no `&tc=`** (no count
  until its page is fetched) and falls back to the background resolve. **Catalogue-vs-playable —
  CLOSED 2026-07-30, `&tc=` no longer fills `track_count`.** LBF reads its count off a service
  ALBUM HASH, so it is a catalogue count — exactly what the Qobuz path now refuses — and it arrives
  as a bare integer with no provenance, so LL can't tell a resolved count from a catalogue one and
  must assume the unsafe case. The rule is now uniform: **only a count resolved from a real
  TRACKLIST ever becomes Played's total, whichever door it came in by.** `&tc=` is still read and
  still fed to `relTypeFor`, because disproving a claimed 'single' AT INSERT is the one job only an
  add-time count can do — a 'single' still standing at insert can be swallowed by `_finishAlbumAdd`'s
  cross-kind dedupe against an already-saved track of the same name, and no background correction
  repairs a row that was never inserted. Consequence, accepted: `&tc=` no longer suppresses the
  background `_verifyRelease`, so it stops being a saved service call — on Tidal/Deezer that verify
  now yields a REAL total, on Qobuz it returns a provisional one it won't store and the total waits
  for the first play. That is the same call an add without `&tc=` always made, so nothing regressed.
  Mostly moot in practice anyway: per `streaming-search-no-track-count` the SEARCH payloads LBF
  matches against carry no count at all, so `&tc=` rarely arrives. **No LBF change is needed or
  wanted** — don't ask the sibling to start sending counts for Played; if it ever sends one it is
  used for the type check and nothing else. Covered by `t_addpath.pl`.

- **0.1.90** — **A failed release-verify is retried once, and never fails silently.** 0.1.88's
  `_verifyRelease` is fire-and-forget; its callback did nothing AND logged nothing when no count came
  back, so a service briefly unreachable at add time left the unverified `single` claim standing →
  `Played::_totalTracks` reads it as a real total of 1 → marked Played after ONE track → purged days
  later. That is 0.1.88's own bug, reachable through its own failure path. **Fix:** both failure
  routes (a callback with no count, and a synchronous die — the latter previously didn't retry at
  all) go through `_armVerifyRetry`, which arms ONE retry at `VERIFY_RETRY_SECS` (60s) via
  `_verifyRetryTick` and logs whichever it does. `VERIFY_MAX_ATTEMPTS` = 2 caps it: an unbounded
  retry hammering a service would be worse than the bug. `_verifyRetryTick` is a **NAMED sub** (the
  0.1.83 `_deferredMarkTick` lesson) and RE-READS the row, so a removed row or one already resolved
  by a drill/play is left alone; no live client → give up rather than pretend.
  **The corroboration alternative was REJECTED, do not build it:** gating the single fast-path on
  `rel_type='single' AND track_count=1` would put every pre-0.1.88 single (no stored count) back on
  the 4-track floor, re-opening **0.1.82**. Heal the row; don't punish rows that predate the check.
  Covered by `tools/t_verify_retry.pl`. **Not covered offline:** the timer actually FIRING — that
  needs the server.

  **0.1.90 also carries a full code review of the 0.1.88–0.1.90 work (2026-07-30). Five findings,
  all fixed before release — none of this ever shipped:**
  1. **The `&tc=` receiver was completely inert.** `$1 =~ /^\d{1,3}$/ && $1 > 0` — the validation
     match is capture-less, and a SUCCESSFUL match resets `$1` to undef, so every count was
     discarded. Silent, because `Plugin.pm` has no `use warnings`. Fixed by copying the capture out
     first; the extraction moved to `_stripPrivateParams` so it is testable at all. See the lesson
     in the regression-tests section — it shipped "verified" by a suite that could not fail.
  2. **A FAILED resolve stamped `track_count=1`** (`Browse::_albumTracks`): the display fallback put
     the "no match" text row back and it was counted as a playable track, so a 10-track album whose
     resolve merely failed was marked Played after one track, and a real stored count was clobbered.
     Now counted before the fallback can restore anything.
  3. **Qobuz's CATALOGUE count became Played's total** — see the corrected "Catalogue vs playable"
     note in the 0.1.88 entry. Now flagged provisional and never stored; the same rule was then
     applied to `&tc=`, which is the same kind of number arriving by a different door.
  4. **A resolved type was thrown away** unless it demoted a wrong 'single', so a row inserted NULL
     by `_classifyThenAdd`'s timeout showed "Album" for good. Now fills a NULL, unforced.
  5. **The verify gate asked "is there an album id"**, which is the wrong question for Bandcamp
     (`get_album` scrapes the album PAGE url) — an id-only Bandcamp row spent the full service
     SEARCH the gate exists to refuse. Predicate unified into `Sources::hasDirectAlbumRef`.

  **A SECOND review pass then found three more, all fixed (2026-07-30). All three came from
  the same mistake in the first fix — a rule applied to one consumer of a number and not the
  other:**
  6. **`$prov` gated `updateTrackCount` but not the single→ep demotion**, so a claimed single
     contradicted by a CATALOGUE count became `rel_type='ep'` with `track_count` NULL → the EP
     floor of 2 → a release with one playable track could never be marked, where **0.1.87
     marked it**. (The demotion itself arrived with 0.1.88, which failed the same case by the
     other route — `ceil(60% × 3)`; the provisional fix moved the failure, it didn't cause it.)
  7. **Same inconsistency at add time** (`&tc=`): the comment refuses to store the count as a
     total because it "can only ever be >= the playable count", then hands it to `relTypeFor`
     anyway.
  8. **`_verifyRelease` had a third failure route**: a callback that never ARRIVES fired
     neither the no-count branch nor the die branch, so no retry and no log — the silent
     give-up 0.1.90 claims to have removed. Now guarded by a `VERIFY_TIMEOUT_SECS` (6s) timer,
     the shape `_classifyThenAdd` already used, with a `$done` flag so a late answer can't act
     after the timeout has.

  **The fix for 6 and 7 is one line, at the source rather than at the two call sites**, and it
  rests on a rule worth keeping: **a provisional count may LOWER the Played bar, never RAISE
  it.** Deriving a type from a count only ever lowers it (1 → single needs 1, 2-6 → ep needs 2,
  both below the 4-track floor); the ONE exception is demoting a claimed single, which goes
  1 → 2. So `classifyRelType` short-circuits on a catalogue count *except* when it would
  demote a single, where it resolves the real tracklist instead — one extra call, only in the
  ambiguous case, and it returns a REAL count (storable) plus a type settled from it.
  **The rejected alternative:** gating `singleIsWrong` on `$prov` (i.e. never demote on a
  catalogue count) re-opens 0.1.88's bug for the COMMON case — most MB "singles" of 2-3 tracks
  are fully playable, and they would all mark Played after one track and be purged. Don't.

  **The test that defended the bug.** `t_reltype.pl` asserted `a 3-track "single" is still
  demoted → 'ep'` — the buggy behaviour, pinned as correct. Rewritten. A suite that encodes the
  wrong invariant is worse than no suite, because it argues for the defect.

  **The tests are the other half of this release.** The repo went from 5 suites / 128 checks to
  **8 / 267**, adding `t_favurl.pl`, `t_resolve_count.pl` and `t_addpath.pl` — the last covering the
  ADD PATH end to end, which had no coverage at all and is the route finding 1 walked through. Every
  new suite was run against the bug it claims to catch before being called done; that check is now a
  documented rule, because two of these bugs shipped past tests that could not fail.

- **0.1.92** — **The SERVICE's own label is kept beside the clean title, so Played can still
  find the row (`ref.svc_title`).** The hole `&al=` opened, found while code-reviewing LBF
  0.9.144 and confirmed against Simon's live list before building.
  **The premise `&al=` rests on is only half true.** It hands us the MusicBrainz release name
  as the authoritative title, which is right for DISPLAY and for the dedupe key. But MB
  deliberately keeps a release's distinguisher **outside** the title: all four American
  Football LPs are titled exactly `American Football`, and `LP2`/`LP3`/`LP4` live in MB's
  `disambiguation` field — verified against the MB API and against the live mirror. Qobuz
  prints `American Football (LP2)`. So the stored title and the PLAYING title genuinely differ.
  **Why that breaks Played and nothing else.** `Played::_matchRecord`'s streaming branch has no
  album-id anchor — it matches on artist + album TITLE only — and `DB::_norm` deliberately KEEPS
  `(LP2)` (that is what lets the dedupe key tell editions apart). Bare name stored + qualified
  name playing = never marked, **silently**: the album plays perfectly and just never leaves the
  list. Replay is NOT affected — `buildPlayableItems` prefers the captured album id
  (`hasDirectAlbumRef`) and LBF/PFR rows always carry one, so `_bestMatches`' `(LP4)`-preserving
  ranking never even runs for them. Display degrades (three rows reading "American Football",
  separated only by the year) — accepted, see below.
  **Fix: keep both.** `_addCtxCommand` stores Material's raw row label as `ref.svc_title` when
  it differs from the title actually saved (JSON, no migration, no schema change — and NOT an
  input to `dedupeKey`, so the whole point of `&al=` is undisturbed). `Played::_matchRecord`
  gains a THIRD and LAST pass over `DB::findBySourceRefTitle`, with the same `_artistMatch`
  guard the existing fallback uses. Being last, it can only ever rescue a miss — it cannot
  change which record an already-matching play resolves to.
  **APPENDING MB'S `disambiguation` WAS THE FIRST PLAN AND IT IS WRONG — do not build it.**
  Sampling **120 release-groups straight from a live LB fresh-releases feed** against the mirror:
  exactly **1** carries a disambiguation, and it is `The Vampire Lestat OST` — editorial PROSE,
  not a service-style qualifier. Appending it yields `The Failures (The Vampire Lestat OST)`,
  which matches nothing on any service and breaks the key it was meant to fix. It is also not
  free: the LB feed carries no such field (confirmed — 12 keys, none of them disambiguation), so
  it needs one MB lookup per release-group, and the trending path resolves in bulk. American
  Football's `LP2` happening to be exactly Qobuz's spelling is a COINCIDENCE, and generalising
  from it was the error the sample caught.
  **Accepted limits:** future adds only (nothing exists to repair older rows from — the
  population was zero at ship time); and Bandcamp coverage is unverified, since its search rows
  read `Title (Album)` but what a PLAYING Bandcamp track reports as its album wasn't checked.
  Neither is a correctness risk — the new pass is an OR, so it can only add matches.
  Covered by `t_addpath.pl`, which drives the real add path into SQLite and then the real
  `_matchRecord` over it; **anti-tested both ways** (sender removed → 2 failures, receiver
  removed → 1), with the decisive assertion failing `NO MATCH` in both.

- **0.1.93** — **The Played threshold moves to 90% rounded DOWN; the length measure can no
  longer get permanently stuck; the row glyph moves off the title.**
  (1) **Threshold 60 → 90**, arithmetic extracted to `Played::tracksNeeded`, rounded with
  `floor` and never below 2 for a multi-track release, plus a one-off `threshold_90_migrated`
  bump so existing installs actually move. Full reasoning in "The Played threshold" above —
  **read it before changing either the percentage or the rounding**, the two interact and
  `ceil` at 90% silently means 100% for anything under ten tracks.
  (2) **`Played::_learnTrackCount`'s in-flight guard is a TIMESTAMP, not a flag**
  (`COUNT_STALE_SECS` = 60). Found by code review and CONFIRMED by probe: a request the
  service accepts and never answers runs none of our code, so the boolean was never cleared
  and that release could never be measured again for the life of the server — it sat on the
  flat `streaming_min_tracks` floor permanently, so anything shorter than the floor could
  never reach Played. **That is 0.1.90's own bug returning through 0.1.90's own failure
  route.** Deliberately NOT a timer: nothing has to HAPPEN on expiry and it is read in one
  place, so a lazy check at the single read site avoids the arm/kill/pair machinery and the
  ordering-bug class that 0.1.83's re-arm chain and 0.1.90's `$done` flag both had to fix. It
  also covers a failure no `$cb`-based guard can see — a die inside the SERVICE's own async
  handler, where nothing of ours runs. 60s because it must exceed the services' own HTTP
  timeout (Qobuz's `SimpleAsyncHTTP` uses 15s) or a slow-but-live request gets duplicated.
  Covered by `t_learn_count.pl`, anti-tested (2 failures against the boolean guard).
  (3) **The ♫/♪/❝ glyph moved from the NAME line to `line2`**, ahead of the type word and
  source (`♫ Album · Qobuz`); the title is a plain `Artist – Album (Year)` again. 0.1.86 had
  put it on the name line. Beyond reading wrong, it was a live hazard: an LL home-shelf card's
  `$ALBUMNAME` is the row's DISPLAYED name and the `LLHome-album` suppressor never worked on
  the carousel, so an add from there would have stored the glyph verbatim in `album_title` —
  the 0.1.71 pollution shape. Checked live before changing: no stored title carried a glyph
  (each of 49 rows rendered exactly one, and the renderer always prepends exactly one), so
  nothing needs repairing. Pinned in `t_resolve_count.pl` on BOTH lines, in both directions.
  (4) **Both siblings now send the SERVICE's album title in `&al=`** — see the fleet rule
  above — and `tools/add_naming_check.py` is the harness for verifying it.
  (5) `tools/t_stubs.pl` gains **`TestClock`**, a `CORE::GLOBAL::time` override, so
  elapsed-time behaviour is testable without sleeping. The override must be installed before
  any plugin module compiles; the existing `require`-then-`ll_require()` order guarantees it,
  **so don't move `ll_require()` above the stub require**. `Slim::Schema` also gains
  `find('Album')`, defaulting to NOT FOUND so a year test can't pass vacuously.
  (6) **Years on native and library adds** — `Sources::serviceYear` (hash-wide, epoch-aware,
  ported from PFR) and `Sources::libraryAlbumYear` (local DB, because Material has no `$YEAR`
  variable). See "Year backfill" for the per-source table and why Tidal/Deezer/Bandcamp
  natives stay yearless BY DECISION.

- **0.1.94** — **The rebrand pref copy ran at EVERY server start, reverting the user's settings —
  including 0.1.93's 90% threshold, seconds after the bump set it.** Reported as "albums move to
  Played too early, still the old 60% behaviour"; diagnosed live in one query
  (`played_threshold`=60 sitting next to `threshold_90_migrated`=1 — the migration had run AND its
  result was gone), confirmed by rec 229: `is 10 track(s)` then `marked … (6 tracks, total=10)`.
  **Cause:** `Slim::Utils::Prefs::Base::set` discards any pref matching `/^_/`, so the 0.1.25 flag
  `_rebrand_migrated` never persisted and `_migrateRebrandPrefs` re-imported `plugin.listentolater`
  on every start. Full rule, and why it stayed invisible for six weeks, under "Prefs Namespace"
  above — **read that before adding any pref or migration flag.**
  **Fix, three parts.** (1) The flag is `rebrand_migrated`, underscore-free, so the copy is genuinely
  one-shot. (2) Existing installs are SEEDED as already-copied, gated on `threshold_90_migrated` as
  the "not a new install" proxy — otherwise the newly-working copy would run one final time and
  re-import the very 60 this release removes; a fresh install is deliberately NOT seeded, so a
  genuine pre-0.1.25 upgrader still gets their settings. (3) `threshold_90_migrated` becomes a
  VERSION (`THRESHOLD_MIGRATION` = 2) so the bump re-applies once for every install whose version-1
  run was undone, while a value chosen after that is left alone. Both migrations moved into
  `Plugin::_migratePrefs`.
  **`t_stubs.pl`'s prefs stub now mirrors the server on the two points that produce this bug** — the
  underscore discard, and namespaces as SEPARATE stores (a stub that conflates them makes the copy
  between them look like a no-op, hiding the thing worth testing). Consequence for existing suites:
  `cachedir` must be set with `set_test_pref_ns('server', …)`, since `DB::_path` reads it from the
  `server` namespace. Covered by `t_prefs_migration.pl`, anti-tested (8 failures against the old
  code, the decisive one reproducing the live symptom exactly: `90 survives the copy that used to
  undo it → got '60'`).

- **0.1.95** — **The Material "Add" entries are REGISTERED with Material instead of written
  into its shared actions.json.** Material 6.4.6 added `registerCustomAction($section,
  $action)`; LL now hands over its eight menu categories on 6.4.6+ and keeps the file write
  only for what the API cannot express — the empty suppressors (own list, home shelf, radio
  browse rows) and the `podcasts-*` override, because Material resolves an app's own
  `<command>-<type>` category from the FILE object alone (`appCat in customActions`, verified
  in the served 6.4.7 bundle). Older Material is untouched: `_useActionApi` is a `->can` test,
  and without the API the file gets everything exactly as before, byte for byte.
  **The one dangerous property is that the two lists are MERGED** — file first, then
  plugin-registered — so registering while our old entries are still in the file shows every
  "Add" TWICE. That is why `_writeMaterialActions` still runs on the API path: its strip pass
  is the upgrade. `_materialActionSet` builds both sets from one definition, so the registered
  and written entries can't drift. **`registerCustomAction` pushes, with no de-dupe and no
  unregister**, so registration is once per server run (`$REGISTERED` — `our`, so a test can
  re-arm it) and turning the pref off takes effect at the next restart, which the pref
  description now says. Also **new for free from 6.4.6: "Add" on library SEARCH results**, from
  the categories LL already defines — no plugin change, just a check. Covered by
  `tools/t_material_actions.pl`, anti-tested against three injected bugs (write the positives to
  the file as well → 4 failures; drop the once-only guard → 3; keep the emptied categories → 1).
  The upstream fix that would let the last three categories move too is drafted in
  `docs/material-plugin-action-sections.patch`.

- **0.1.96** — **A Material HOME SHELF's browse verb is not a service name — Qobuz adds from the
  home screen were silently refused.** Reported as "can't add from Qobuz New Releases, but a
  playlist works"; unreproducible on the dev box for weeks because it depends on WHICH DOOR you
  enter Qobuz by, not on any version.
  **What `$SERVICE` actually is.** Material takes it verbatim from `data.params[1][0]` — the
  browse COMMAND of the menu the row came from. From **Apps → Qobuz** that is `qobuz`. From the
  Material **home screen's "Qobuz" shelf** it is the home-extra id: the stock Qobuz plugin
  registers `3rdparty_QobuzExtrasqobuz` ("Qobuz"), `QobuzExtrasnew-releases-full`,
  `QobuzExtrasbest-sellers`, `QobuzExtraspress-awards`. Verified live on the dev server with no
  third-party plugin involved: `["QobuzExtrasqobuz","items",0,11,"menu:QobuzExtrasqobuz"]` returns
  the **identical 11-item Qobuz app menu**, New Releases included. So the user was right that he
  was browsing the main Qobuz plugin's New Releases — same content, different dispatch.
  **The defect was ours.** `_addCtxCommand` validated `svc` by SHAPE (`^[a-z0-9]+$`, written only
  to reject Material's unpopulated literal `"$SERVICE"` and hyphenated non-services). An
  all-alphanumeric shelf id passes it, so `$svc` was truthy, the `||` short-circuited, and
  `sourceFromImage` — which had the right answer sitting in the row's `static.qobuz.com` cover —
  was never consulted. `$source` became `'qobuzextrasqobuz'`, `_isReplayableSource` said no, and
  `_rejectAdd` dropped it **silently** (`count:0`, no toast by design since 0.1.51).
  **Why it went unreported for so long, which is the useful half:** the hyphenated shelves
  (`…new-releases-full`, `…best-sellers`) FAIL the shape test and therefore fell through to the
  cover sniff and worked. Only the one shelf whose id happens to be all letters broke. So the
  Qobuz **"New Releases" shelf** worked while the Qobuz **"Qobuz" shelf** — which contains New
  Releases — did not.
  **Fix:** `Sources::knownSource` — `svc` is believed only when it NAMES a service, never when it
  merely looks like one; otherwise fall through to the cover sniff. Applied at BOTH call sites
  (the album path, and the track path where the same hole is masked by a favurl naming its own
  source). Deliberately an EXACT match, never a substring: `QobuzExtrasqobuz` contains `qobuz`,
  and so would a hypothetical `tidalqobuz`. `deezer`/`spotify` stay IN the known list even though
  they can't be replayed, so an add naming them is still refused under its own name rather than
  re-sniffed from a cover — behaviour there is unchanged.
  **Blast radius beyond Qobuz** (from the live `LMS_3RDPARTY_HOME_EXTRA`): `TIDALExtrastidal`,
  `Bandcampweekly`, `Bandcampdaily`, `BBCSoundsExtras*` are all the same shape. In practice it
  bit only Qobuz, because a favurl takes the `$streaming` branch and never consults `svc` at all —
  and Qobuz album rows are the ones with no `presetParams` whatsoever.
  **Corrects a standing assumption in this file**: the note beside the radio suppressors said a
  home-shelf card "has no per-command identity". It has one — it just isn't the service tag.
  Covered by `t_addpath.pl`, anti-tested: reverting the album-path line reproduces the live
  symptom exactly (home-shelf verb REJECTED, while the Apps verb and the hyphenated shelf both
  keep working). Podcast `CACHE_VER` bumped with the build per the dev-build cache rule; nothing
  in this change touches feed parsing.

  **Two code-review findings on the 0.1.95–0.1.96 work, both fixed before release
  (2026-08-23). Neither shipped.**

  1. **`knownSource` widened the NOW-PLAYING FALLBACK, and that fallback fails open.** The
     fallback (0.1.64) recovers the source from the PLAYING track when an add arrives with
     nothing to identify it, and it deliberately **fails open on its own match guard** — a
     streaming Track exposes no `albumname`/`artistName` to match against (Qobuz/Tidal serve
     that dynamically), so refusing there would reject every legitimate Now Playing add. What
     actually kept it out of browse adds was `$source` being non-empty, and *that* is what
     0.1.96 changed: every container command that isn't a service name (`favorites`, `search`,
     `bbcsounds`, any home-shelf id) now leaves `$source` empty and opens the gate. Reproduced
     against this tree — a podcast episode added from **Favourites** while a Qobuz track played
     was stored as `source=qobuz` (an unplayable row), and the 0.1.85 last-resort podcast
     resolve never ran, because the row now looked replayable. **Fix:** the gate also requires
     that no `svc` arrived at all. Material's Now Playing action (`$trackCmd`) carries no
     `svc:` param, so a populated one means a browse ROW and the playing track is unrelated by
     construction. Strictly tighter than both the old shape test and the new one. Covered by
     `t_addpath.pl`, anti-tested (reverting the gate stores the podcast as a qobuz album while
     the genuine Now Playing add keeps working, so neither assertion can pass by the fallback
     simply being off).
  2. **A refused `registerCustomAction` left the entries in NEITHER place.** `$REGISTERED` was
     latched even when every call died, and `_writeMaterialActions` chose its path with the
     CAPABILITY test (`_useActionApi`) rather than with what registration actually achieved —
     so a failure stripped our entries from `actions.json` and registered nothing. The
     diagnostics couldn't show it either: on the API path the dump counted `%positive`, i.e.
     what was *built*, so `online-*` always read "Add active". **Fix:** `%UNREGISTERED` records
     what the API refused, **per action** (the two lists are merged client-side, so
     file-writing something Material took would double it), the write path is chosen by
     `$REGISTERED && _useActionApi()`, and those refused entries are written to the file. The
     dump now counts both halves separately (`2 registered, 0 in actions.json`) and says so on
     the delivery line. `$REGISTERED_N` (how many Material actually took) replaces `$REGISTERED`
     as the condition for the "…go at the next restart" warning in `_clearMaterialActions` —
     if nothing registered, there is nothing to wait for. **A side benefit worth knowing:**
     the same gate fixes turning `material_action` ON from Settings mid-run. That re-runs the
     FILE write but must not register (no de-dupe, no unregister outside postinit), and the old
     capability gate wrote nothing — so the toggle did nothing until a restart. Covered by
     `t_material_actions.pl` (total failure, partial failure, and the pref-turned-on case),
     anti-tested → 6 failures against the capability gate.

  Nit from the same review, also fixed: the comment above `$onlineCmd` still described the
  `^[a-z0-9]+$` test that 0.1.96 removed.

- **0.1.97** — **0.1.95 moved Now Playing and the play queue to the registration API, and
  Material's client-side snapshot silently dropped both.** Found by review of 0.1.96, verified
  against the SERVED 6.4.7 bundle and the live server. **Six of our eight categories are
  RE-RESOLVED per browse response, so it never matters when the plugin list
  arrives. `track` (Now Playing) and `queue-track` are the exceptions — Material resolves those
  two ONCE, off a bus event:**

      bus.$on("customActions", () => getCustomActions("track"|"queue-track", false))

  and the **only** `$emit("customActions")` in the bundle is inside the `.then` of the axios GET
  of `customactions.json`. `initCustomActions` fires that GET and the `["material-skin",
  "plugin-actions"]` CLI call side by side, and only the GET emits — so whichever wins, the
  snapshot is taken when the *file* lands. A static file beats a JSON-RPC POST through the Perl
  dispatcher essentially every time, which leaves `pluginCustomActions` still `undefined` at
  snapshot time. Nothing re-emits, so **"Add" is missing from Now Playing and the queue for the
  whole page session.** Confirmed live: `["material-skin","plugin-actions"]` returns all eight
  sections including both of these, and the served `customactions.json` has no LL entry in
  either. **Fix:** `track` and `queue-track` move back to the FILE half of `_materialActionSet`.
  Neither is a per-app override, so the file costs nothing; the one price is the 0.1.57 stale-tab
  cache (a hard refresh after install). The upstream one-liner — emit from the plugin-actions
  `.then` too — is a Material change, not ours.

  Two more from the same review:
  1. **The Settings save didn't do what its comment claimed.** "Turning `material_action` ON
     from Settings mid-run now works" (0.1.96) was only true with `debug_log` ALSO on — i.e.
     never, on the default config. **Fix:** `Settings::handler` now mirrors `postinitPlugin`'s
     two branches exactly — ON → `_writeMaterialActions`, OFF → `_clearMaterialActions` —
     gated on MaterialSkin alone. `debug_log` gates the diagnostics SNAPSHOT, which is all it
     was ever meant to gate.
  2. **The "entries go at the next restart" warning was unreachable.** `_clearMaterialActions`
     was only ever called from `postinitPlugin`'s `elsif`, which is mutually exclusive with the
     branch that sets `$REGISTERED_N` — so within one server run the condition could never be
     true. Fix (1) is what makes it live: turning the pref OFF from Settings, after postinit
     registered, is exactly the case the warning describes. Kept, not deleted.

  Covered by `t_material_actions.pl` (54 cases): the two client-resolved surfaces are file-only
  and *not* also registered, the file half survives the API-path strip pass, and both Settings
  directions with `debug_log` off. Anti-tested — putting the pair back on the API path fails 8,
  restoring the `debug_log` gate fails 3.

- **0.1.98** — **Three code-review findings on the 0.1.95–0.1.97 work. None shipped; no
  feature change.** All three sit on paths that 0.1.96/0.1.97 opened or widened.

  1. **Turning the pref OFF *added* "Add" where it had been suppressed.** `_clearMaterialActions`
     deleted the empty `listenlater-*`/`LLHome-*` suppressors (and, via the delete-empties pass,
     the radio ones) unconditionally — but on Material 6.4.6+ the registered `online-*` pair
     **cannot be withdrawn**, so removing what was hiding it is the exact opposite of turning the
     feature off: every Listen Later/Played row gains "Add to Listen Later" until the next
     restart, and using it on a Played row bounces that row back to Listen Later. Reproduced by
     driving the real code against a fake 6.4.6 — 12 actions still registered, all three
     suppressor families gone from the file. **Fix:** while `$REGISTERED_N` is non-zero the
     suppressors are KEPT and re-asserted (the `-e $file` early return no longer skips that), and
     the per-command delete-empties pass is skipped; only the top-level `album`/`playlist`/
     `online-*` husks go, and those suppress nothing — Material's per-app override reads
     `<command>-<type>`, never a bare `album`. The pref-was-off-at-startup path
     (`$REGISTERED_N == 0`) still clears everything, exactly as before. Newly reachable only
     because 0.1.97 made the Settings save call this sub at all.
     **Amended after a second review pass:** the first fix re-asserted only the
     `listenlater-*`/`LLHome-*` families. Preserving the radio empties was left to the
     exempted delete-empties pass, which preserves what is on DISK — so on the one path this
     hunk exists for, *live registrations + the file gone* (a first-ever write that failed,
     or someone deleting actions.json to reset it), the radio empties were never re-created
     and TuneIn/BBC Sounds browse rows regained a live "Add" until the restart. That is the
     regression class the hunk exists to prevent, so it now re-asserts those too. The list
     moved into **`_radioSuppressorCats()`** — its own sub because both writers need the
     identical list and they compute it from lexicals declared *below* `_clearMaterialActions`
     (a sub call resolves at runtime; the variables would not resolve at all). `||=` for the
     radio ones, `=` for ours: the `<cmd>-*` namespace isn't ours to reset (0.1.48).
  2. **The TRACK path's Now Playing fallback had no gate.** 0.1.96 mirrored `knownSource` onto
     the track path but not the *call-site gate* the album path grew alongside it, and
     `_nowPlayingTrackFallback` deliberately has no match guard of its own (a streaming Track
     exposes no title/album to match against). So a `kind:track` add with an empty `$FAVURL` and
     a non-positive `$TRACKID` — a remote queue row, or an online-track row whose service sent no
     favurl — adopted whatever was playing. Reproduced: tapping queue row 7 while row 1 played
     stored a hybrid (row 7's album+artist, row 1's title and PLAY URL — a row that plays the
     wrong track). **The album path's "no svc" test does not transfer on its own**, and that is
     the thing to know: `queue-track` and the Now Playing panel are the SAME lmscommand
     (`$trackCmd`), so a queue row also arrives with no `svc`. Only `online-track` carries one.
     The discriminator is the **track id**: Material substitutes the tapped item's own values and
     any real row has an id, while the Now Playing panel item has neither id nor favurl (0.1.64).
     **Fix:** the gate requires no `svc` AND no `trackid` — testing PRESENCE, not validity.
     `_nowPlayingTrackFallback`'s header now says the caller's gate is its only protection
     rather than merely noting it has none.
     **Amended after a second review pass — the gate was right, its premise wasn't.** The
     original reasoning was "a *positive* id was already resolved to a url above, so an id
     still here is a remote row's" — true, and it made every REMOTE QUEUE ROW unaddable,
     including the playing one, because the id branch only accepted `/^\d+$/`. Those rows are
     exactly the shape with nothing else to go on: Material builds a queue row id as
     `"track_id:"+i.id` and substitutes it into `$TRACKID`, and queue rows carry **no
     `presetParams` at all**, so `$FAVURL` is always empty there. **Resolve rather than
     relax:** the id branch now accepts `/^-?\d+$/`, because a negative id is LMS's own
     spelling of a remote track — `Slim::Schema::find` tests `$_[0] < 0` and hands off to
     `Slim::Schema::RemoteTrack->fetchById` (9.1 source, `Schema.pm:597`). Row 7 stores row 7;
     an id that resolves to nothing still falls to the unchanged gate and is refused. Two
     details that fall out of the same edit: the branch no longer hardcodes `source =>
     'library'` (a remote row's url names its own service — but `sourceFromUrl` answers
     `'library'` only for a url with NO scheme, so `file://` is mapped explicitly, exactly as
     the scheme branch above does), and a `RemoteTrack` has no Album ROW — its `->album` is
     the album NAME — so the metadata pull branches on `ref $alb`.
  3. **A rejected add logged nothing identifying.** `_rejectAdd`'s `$source // '?'` doesn't catch
     the EMPTY STRING, and since 0.1.96 that is the common case rather than an edge — every
     container verb that isn't a service name leaves `$source` empty — so three unrelated
     rejections all logged the identical `unsupported source ''`. The reject is silent to the user
     by necessity (0.1.51), so this warn is its entire trace, and triage of "Add did nothing" runs
     on it. **Fix:** empty renders as `(none identified)` and the line names the CONTAINER VERB,
     which is what identifies the surface (`unsupported source (none identified) via container
     'favorites'`). Read off the request with the same unsubstituted-`$VAR` filter
     `_addCtxCommand` uses, so a literal `$SERVICE` can't leak into the log.

  **`$TRACKID` — now SETTLED, was "not verified live".** Both halves confirmed against the
  real thing rather than argued: `queue-page.js` builds every queue row as
  `id: "track_id:"+i.id` and `doReplacements` fills `$TRACKID` from `id.split(':')[1]` for any
  id containing a colon, so a queue row always carries one; the Now Playing item's id is a
  bare number with no colon, so it never does. And a live `status` query on the box returned
  `id: "-94606967852688"` for `qobuz://420282126.flac` — remote ids are negative, which is
  what finding 2's amendment turns on.

  **One incidental, corrected in the comments:** an unpopulated `$VAR` does NOT generally
  arrive as the literal token — `doReplacements` ends by stripping every name in its
  `ACTION_KEYS` list to `''`. **`$IMAGE` is the exception: it is not in that list**, so an
  item with no image really does send the literal `"$IMAGE"`, which is why `_addCtxCommand`'s
  `/^\$[A-Z]/` filter is still load-bearing rather than dead code. Every 0.1.98 gate tests
  length, so both spellings read as absent either way.

  Covered by `t_material_actions.pl` (+8) and `t_addpath.pl` (+15); 520 checks across 11
  suites, up from 508. Every fix anti-tested against the bug it claims to catch: finding 1 →
  3 failures on the original hunk plus 1 more on the amendment (the radio empties are not
  re-created when the file is gone), finding 2 → 2 on the original gate, and on the amendment
  4 (a remote queue row is refused outright) + 1 (its source files as `library`), finding 3 →
  3 (and the one case the old line already got right still passes, which is why it is in the
  suite). `t_stubs.pl`'s `Slim::Schema` gains `find('Track', $id)` over a test-registered
  `%TRACKS` — **not found by default**, so a track lookup can never pass vacuously — with a
  `RemoteTrack`-shaped entry for a negative id (`->album` is a string, not a row).

- **0.1.99** — **A second review pass over 0.1.98's own fixes. Two of the three needed
  amending, and 0.1.98 never shipped, so the amendments are written INTO its findings above
  rather than restated here — read them there.** In short:
  1. **Finding 1's re-assert dropped the RADIO suppressors** on the exact path the hunk was
     written for (registrations live, `actions.json` gone), so TuneIn/BBC Sounds rows would
     regain a live "Add" until the restart. The list is now `_radioSuppressorCats()`, called
     by both writers.
  2. **Finding 2's gate refused every REMOTE QUEUE ROW.** Those rows carry a `$TRACKID` and
     never a `$FAVURL`, and the id branch only accepted `/^\d+$/` — so the row hit the gate
     and was rejected on the presence of the very id that identifies it. Now resolved rather
     than relaxed (`/^-?\d+$/` → `Slim::Schema::find` → `RemoteTrack->fetchById`), with the
     source read off the resolved url instead of a hardcoded `'library'`.
     **A trap on that second half, worth its own line:** `Sources::sourceFromUrl` answers
     `'library'` only for a url with NO scheme, so a plain switch to it files a library
     track's `file://` url as source `'file'` — which fails `_isReplayableSource` and rejects
     every LIBRARY queue row, i.e. trades one broken surface for another. `file://` is mapped
     explicitly, exactly as the scheme branch above it does. The library-row test is what
     caught this, which is why that test is in the suite alongside the remote one.
  3. **Finding 3 (the README badge) needed no code** — it is a build artifact, regenerated
     here from `install.xml` by `tools/make_readme_html.py`.

  Also corrected: three comments claiming an unpopulated `$VAR` arrives as its literal token
  (see the incidental above — true of `$IMAGE` alone, and that is why the filter stays).

  **A THIRD review pass over the amendment itself. Two findings, both fixed; still unshipped.**

  1. **`//` does not catch what a RemoteTrack actually returns.** The amendment's id branch
     took the object's metadata with `$track = (eval { $t->title }) // $track` — but a
     RemoteTrack answers **`''`, not undef**, for anything it doesn't hold (Qobuz/Tidal serve
     track metadata dynamically; this file already says so twice, and it is exactly why
     `_nowPlayingFallback` fails open). `''` is defined, so `//` KEPT it and wiped the title
     and artist Material substituted from the row. An emptied artist stores `artist=''`, which
     then skips BOTH dedupe guards in `_insertTrackRow` (they test `length $artist`), never
     matches in `Played::_matchRecord`, and renders with no artist; an emptied title fails the
     add gate outright — so the common shape of the very rows the amendment exists to support
     was **rejected**. The `$album` lines four below were already length-guarded; these two
     weren't. Fixed by taking the object's value only when it has one.
     **The suite missed it because the STUB was friendlier than the server**: `Slim::Schema::
     Track` handed back whatever the test registered, so the remote-queue-row test — which
     supplies a title and an artist — took them off the object and looked free. The stub now
     answers `''` for any field a NEGATIVE-id (remote) track wasn't given, which is what the
     server does; a library Track still answers undef. Same hazard as 0.1.94's prefs stub: the
     vacuous pass was sitting in the stub, not in an assertion.
  2. **The reject warn only ever printed the source clause.** 0.1.98's finding 3 made that line
     name the source and the container verb — but the track gate fails three separate ways
     (unreplayable source, no play url, no title) and reported all of them as "unsupported
     source 'qobuz'", pointing triage at the service when the real cause was an empty title.
     Same shape on the podcast path, where a row that resolved to no enclosure was reported as
     "unsupported source 'favorites'". `_rejectAdd` now takes an optional REASON from the call
     site and prints `<reason> (source '<src>')`; call sites that fail on the source alone pass
     none and read exactly as before.

  Covered by `t_addpath.pl` (+6, 526 across 11 suites), anti-tested against both: reverting
  finding 1 fails 3 (the decisive one being the add REJECTED, which is the live symptom), and
  reverting finding 2 fails 2 while the unsupported-source case still passes — which is what
  shows the default wording is untouched.

- **0.1.101** — **A review pass over 0.1.100. Two behaviour fixes, both in the actions.json
  bookkeeping, and both of the same shape: a REGEX standing in for the list of categories we
  actually own.** The rule this settles: never test a category by its SHAPE — take the names
  from the writers (`_materialActionSet`, `_radioSuppressorCats`), which is also what makes
  the code self-correct the next time the register/file split moves.

  1. **The diagnostic reported our own entries as foreign.** `_dumpMaterialState`'s shadow
     scan splits `<svc>-album|track` and exempted by PREFIX (`online`/`listenlater`/`LLHome`/
     `podcasts`) — but three of our populated categories are not `<service>-<type>` shaped at
     all, so `album-track(2)`, `playlist-track(2)` and `queue-track(2)` were listed as
     "NON-EMPTY per-service categories that SHADOW online-\*" (`queue-track` on the API path
     too, since it is file-only). That line exists purely for remote triage on a fault we
     can't reproduce, so a false positive there points the user — and us — at the plugin's
     own correct entries. Exemption is now by FULL category name, out of `_materialActionSet`
     plus `_radioSuppressorCats`. Diagnostic only; nothing it reports on changed.
  2. **The clear pass could eat a third-party plugin's suppressors.** `_clearMaterialActions`
     deleted every EMPTY `*-album/-track/-artist` when nothing of ours was registered — but an
     empty per-command category is not litter, it is a deliberate Add-suppressor (the 0.1.52
     rule, and the reason we write our own). So it silently disarmed another plugin's hiding.
     Pre-existing, and nothing in this stack writes those today (Discography and Album Booklet
     checked) — but 0.1.97 made that branch run on every Settings save rather than at install
     only, so the reach is real. It now deletes only what `_radioSuppressorCats()` names.
     (The same `||=`-guarded list is now computed ONCE in that sub and reused by the re-assert
     below it, instead of enumerating the `radios` menu twice.) Its twin in
     `_writeMaterialActions` was NOT changed here, on the reasoning that that pass has to
     delete empty per-command cruft it cannot name — the 0.1.46–0.1.50 scoping experiments —
     which is the 0.1.51 regression fix. **Superseded: see the unversioned entry below.** The
     reasoning was wrong in its premise, not its aim: the pass never had to NAME the cruft.

  Also: a duplicate `==== end diagnostics ====` (the snapshot is built from `@lines`, so only
  the one after the `$prefs->set` belongs), and the comment claiming the six registered
  categories are resolved "SERVER-side" — they are resolved client-side too, just RE-RESOLVED
  per browse response, which is the property that actually matters (`track`/`queue-track` are
  resolved once, off a bus event; that is what they can't survive). Reworded here and in
  `_materialActionSet`; the conclusion both draw is unchanged.

  Podcast `CACHE_VER` bumped with the build per the dev-build cache rule; nothing here parses
  a feed, so it is hygiene, not a fix.

  Covered by `t_material_actions.pl` (+6, 532 across 11 suites), anti-tested against both:
  the old prefix skip-list reports 3 of our categories on the legacy path and 1 on the API
  path, and the old regex deletes the injected `otherplugin-album/-track`. The shadow scan's
  positive control — a populated FOREIGN `tidal-album` — is in the suite alongside them, so
  the exemption can never be widened into silence.

- **0.1.102** — **A third finding of the same class as 0.1.101's two — the clear pass left
  `podcasts-*` HUSKS, which hides Add on the Podcasts app for good.** 0.1.101's finding 2 replaced
  a `/-(?:album|track|artist)$/` empty-sweep with a NAMED list, and the list missed the one
  category that is ours, file-only, AND per-app. The chain: `_materialActionSet` writes
  `podcasts-album`/`-track` to the file (they can only work from there); the strip pass empties
  them, because they carry the `listenlater` verb; the delete-empties pass then names neither
  `%ourCats` (`album album-track playlist playlist-track track queue-track online-album
  online-track` — no podcasts) nor `_radioSuppressorCats()`, whose podcast entry is TuneIn's
  **singular** `podcast`, not the Podcast plugin's browse command `podcasts`. So the file keeps
  `{"podcasts-album":[],"podcasts-track":[]}` — and by this plugin's own 0.1.52 rule an empty
  per-app `<command>-<type>` category overrides `online-*` and SUPPRESSES Add on every
  Podcasts-app row. Nothing repairs it later: the pref-ON write pass that would is exactly the
  one the pref being off stops from running. The old regex caught them, so this is a regression
  from 0.1.101 rather than a pre-existing hole; its twin in `_writeMaterialActions` still uses
  the regex, which is why only the CLEAR path is affected. **Neither shipped** — 0.1.95–0.1.101
  are all unreleased dev work (last tag: v0.1.94), so no install ever ran the husk-leaving build.
  **Fixed as a suppressor, NOT by adding the pair to `%ourCats`** — the review suggested the
  latter and it would be wrong in the `$live` direction: `podcasts-album` IS a per-app override,
  so deleting it while the `online-*` pair is still registered and unwithdrawable puts "Add"
  BACK on Podcasts rows until the restart, which is the regression class the whole hunk exists
  to prevent (the bare `album`/`online-album` husks `%ourCats` does delete suppress nothing).
  So the pair joins `%suppressor`: deleted only when nothing is registered, re-asserted with
  `||=` beside the radio empties when the file has gone. **Hardcoded rather than read from
  `_materialActionSet`'s `%fileOnly`** — that only emits `podcasts-*` while
  `Podcast::hasFeeds()` is true, so a user who unsubscribed everything would keep the husks,
  which is precisely the state that needs cleaning.
  Covered by `t_material_actions.pl` (+6, **538 across 11 suites**), anti-tested: emptying the
  list fails 3 — the two husk cases (subscribed and unsubscribed) reproduce the live symptom,
  and the file-gone re-assert fails the other way. The `$live` "override STAYS, and stays EMPTY"
  assertions pass in both states by design; they are the positive control that stops the fix
  being widened into an unconditional delete.

  **The rule this settles, which 0.1.101 stated and then broke in the same pass:** a category
  list is only correct if it is checked against every category the writers can emit — and
  `%fileOnly` is a *conditional* set, so "read it from `_materialActionSet`" is not the safe
  answer it looks like. Enumerate the per-app overrides explicitly, and put a new one in BOTH
  the delete list and the re-assert list at the moment it is added.

  Podcast `CACHE_VER` bumped 6 → 7 with the build per the dev-build cache rule; nothing here
  parses a feed, so it is hygiene, not a fix.

- **0.1.103** — **A review pass over 0.1.102. Two behaviour fixes, and both are the SAME
  mistake made twice: a gate that worked by side effect, and a fix that landed on one of two
  twin passes.**

  1. **0.1.96 re-opened the self-add hole: a row in our OWN surfaces could be added again.**
     Every row in the list view / home shelf is already saved, and re-adding one bounces a
     Played album back to Listen Later — which is exactly what the empty `listenlater-*` /
     `LLHome-*` suppressor categories exist to stop. But a written category is not a gate:
     Material serves `customactions.json` from cache (the documented 0.1.57 post-upgrade
     window), and a home shelf's `$SERVICE` is the shelf id, which those categories were never
     certain to match — the 0.1.102 NB in `_writeMaterialActions` says so itself.

     Until 0.1.96 the add COMMAND gated it by accident: the `^[a-z0-9]+$` shape test made
     `svc='LLHome'` the `$source`, and an unreplayable source was rejected downstream.
     `knownSource` (rightly) leaves a non-service command EMPTY so the cover-URL sniff can
     identify a home-shelf row — but **our own cards carry the ORIGINAL streaming cover**, so
     the sniff answers `qobuz` for a row we saved from Qobuz and the re-add goes through.
     Reproduced with the repo harness: `add(svc => 'LLHome', image => <a qobuz cover>)` →
     `STORED source=qobuz`.

     Fixed by naming the surfaces instead of leaning on a side effect of how `svc` is judged:
     `Sources::ownSurface` (`listenlater`/`LLHome` + both pre-rebrand spellings, EXACT match,
     same discipline as `knownSource`), checked in `_addCtxCommand` **ahead of every branch** —
     `kind:podcast` and the track path included, since an episode or a track in our own list is
     no more re-addable than an album. `_rejectAdd` carries the reason, so the log says "row is
     already in Listen Later" rather than blaming a source.

  2. **0.1.101's suppressor fix landed on the clear path only; the write path is the one that
     runs constantly.** `_writeMaterialActions` still deleted every empty
     `*-album/-track/-artist` not in `%keep`, so another plugin's deliberate empty suppressor
     was disarmed at every startup, on every Settings save (0.1.97 widened that) and on the
     +60s deferred write. Verified: seeding `otherplugin-album`/`-track` and running the write
     deletes both.

     **The 0.1.101 reasoning for leaving it — "that pass has to delete cruft it cannot name" —
     had the wrong premise.** It never had to NAME the cruft, only to know it is ours, and it
     already does: the 0.1.46–0.1.50 scoping experiments wrote OUR entries into those
     categories, which is precisely what makes them ours. So the strip pass now records
     `%emptied` — the categories it took from non-empty to empty — and delete-empties skips
     anything not in it. An empty that ARRIVED empty was never ours and no run of this code can
     leave one behind (the same pass that creates one deletes it), so nothing is lost.
     The unsuffixed `album`/`playlist` husk sweep below it is left alone: those are not
     `<cmd>-<type>` overrides, so an empty one suppresses nothing and deleting it is litter
     collection, not disarmament.

  Covered by `t_addpath.pl` (+7) and `t_material_actions.pl` (+3) — **548 across 11 suites**.
  Both anti-tested: neutering `ownSurface` fails 6 of the 7, and restoring the old sweep fails
  the suppressor case. Each carries a positive control that stops the fix being widened into
  silence — a verb that merely BEGINS with one of ours must still resolve normally
  (`LLHomeworkHelper` → `qobuz`), and a category holding only our own entry must still be
  swept. The own-surface cases deliberately use DISTINCT titles: sharing one lets the
  cross-kind dedupe drop the second add, which reads as "rejected" and let two of them pass
  with the guard removed.

  Podcast `CACHE_VER` bumped 7 → 8 with the build per the dev-build cache rule; nothing here
  parses a feed, so it is hygiene, not a fix.

- **0.1.104 — category ownership is RECORDED, not inferred. Closes the 0.1.103 review's two
  findings, and the class both belong to.**

  Six review rounds have each found a different husk bug in these two passes, and 0.1.101's
  own note ("the same mistake made twice: a fix that landed on one of two twin passes") named
  the pattern without escaping it. The sixth round found two more:

  1. **0.1.103's `next unless $emptied{$cat}` disabled the sweep for the categories it exists
     for.** Its justification — that the 0.1.46-0.1.50 experiments "wrote OUR entries into
     them (that is what makes them ours)" — is contradicted by this file's own 0.1.47/0.1.48
     entries, which record those versions writing `$data->{"<svc>-album"} ||= []`, i.e. an
     EMPTY category with no entries in it. Those arrive empty, so `%emptied` is false and they
     can never be swept. An install upgrading from 0.1.47-0.1.50 keeps an empty `deezer-album`;
     Deezer is replayable today, and an empty `<cmd>-album` overrides `online-album`, so "Add"
     is hidden on Deezer browse rows for good — **the 0.1.51 regression, reintroduced.**
  2. **`_clearMaterialActions`'s `$live` re-assert creates `podcasts-*` for a user with NO
     subscriptions** (`@fileOnlySup` is hardcoded, by design — 0.1.102). Toggle the pref off
     and on under Material 6.4.6+ and the husks are permanent: on the re-enable `hasFeeds()`
     is false so they miss `%fileOnly`/`%keep`, and they arrived empty so finding 1 skips them.
     **This one needs no upgrade history — it is reachable on a clean install.**

  **The fix is not another list.** The standing proposal (0.1.101, and the memory note on this
  area) was one function returning the complete category set, every site consuming it. That
  cannot work, and knowing why is the point: `podcasts-*` with no subscriptions is a category
  the CLEAR path *creates* and no write pass can emit, so no derived set can name it. The
  defect was never duplicated lists — it is that **ownership is INFERRED**, by `%emptied` on
  one path and a hardcoded list on the other, and a husk is those two guesses disagreeing.

  So it is recorded instead: **`_ownedCats`/`_setOwnedCats`**, a list persisted in
  `material_owned_cats`, read by both passes. The rule is *whatever LL writes to the file, LL
  writes down* — including the clear path's `$live` re-assert, which is the half that creates
  the podcast husks and the half a derived set can never see. A pre-ledger install gets a
  one-time seed of the only litter that can exist (`<supported-cmd>-album/-track` plus
  `podcasts-*`, both ours by construction; `listenlater` excluded, its empty pair is the
  deliberate 0.1.52 suppressor).

  **Finding 3 was probed and DISMISSED** — `//` on `$t->albumname` is safe; the defect was the
  comment beside it, which had `->album` backwards. See the Review Ledger for the verification,
  and note the stub carried the same wrong belief, so the suite could not have expressed it.

  Covered by the new `tools/t_material_matrix.pl` — **656 checks across 12 suites**, up from
  548. Anti-tested per half rather than as a whole: reverting the write-path ledger consult
  fails 48, reverting the clear-path record fails exactly the 2 cases finding 2 walks through
  (`boot on → off → on`, with and without a following restart, on 6.4.6+ with no
  subscriptions). The suite itself was run against the unfixed tree first and failed 60.

  Podcast `CACHE_VER` bumped 8 → 9 with the build per the dev-build cache rule; nothing here
  parses a feed, so it is hygiene, not a fix.

- **0.1.105 — the ownership ledger is recorded only AFTER the write lands. One finding from
  the 0.1.104 review, in 0.1.104's own fix.**

  `_ownedCats` returns its one-time seed only while `material_owned_cats` is unset, so
  **setting the ledger at all retires the seed permanently.** Both passes recorded it BEFORE
  calling `_writeMaterialActionsFile` — which has four `die` paths (open/print/close/rename),
  and whose two callers both wrap it in `eval { ...; 1 }`. So a full disk or an unwritable
  prefs dir was swallowed, the plugin carried on, and the ledger now claimed categories the
  file never received. A pre-ledger husk — an empty `<svc>-album` from 0.1.47-0.1.50 — was
  then in NEITHER `%emptied` (it arrives empty) NOR `%owned` (the seed is gone): the
  delete-empties pass skips it forever and "Add" stays hidden on that service, unrecoverable
  without hand-editing the shared `actions.json`. **The 0.1.51 regression again, through the
  mechanism built to prevent it.**

  One-line fix on each pass — hold the set in `$record`, call `_setOwnedCats` after the write
  returns. The clear path's is `if $record`, since the set is only built inside `$live`.

  Worth naming because it is the same shape as everything else in this area: the ledger made
  ownership RECORDED rather than inferred, which was right, but a record written against an
  action that did not happen is just a different way of guessing. Persist after the effect,
  never before.

  Six new checks in `t_material_actions.pl` (**662 across 12 suites**, up from 656).
  Anti-tested: against the previous ordering three fail, and the one that matters is
  `the next successful write sweeps the pre-ledger husk → got='survived'` — the user-visible
  bug itself, not a proxy for it.

  Podcast `CACHE_VER` bumped 9 → 10 with the build per the dev-build cache rule; nothing here
  parses a feed, so it is hygiene, not a fix.

- **0.1.106 — a review pass over 0.1.105. One finding, comment-only; no behaviour change.**

  `_radioSuppressorCats`'s doc block was left stranded above the newly-inserted `_ownedCats`,
  so it read as documentation for the ownership ledger — "BOTH writers need the identical
  list… Sorted, so both writers produce the same order", none of which is true of `_ownedCats`
  — while `_radioSuppressorCats` itself was left undocumented. Moved back onto its own sub.

  **The review found no correctness defect, and that is a checked verdict rather than a thin
  pass** — every load-bearing external claim in the 0.1.104/0.1.105 diff was verified against
  the real upstream instead of against the comments asserting it. Worth recording, so the next
  pass doesn't re-derive it: `registerCustomAction` in Material master is a plain
  `sub ($section, $action)`, so calling it through `->can` as `$register->($cat, $action)` is
  right (a method call would pass the class as the section); `plugin-actions` is in Material's
  allowed `_cmd` list and serves `$PLUGIN_CUSTOM_ACTIONS`, so registration is not going into a
  void; `appCat in customActions` is file-only in `browse-resp.js`, so the `podcasts-*` override
  and the empty suppressors genuinely cannot move to the API; `track`/`queue-track` are the only
  two categories snapshotted off the `customActions` bus event, so keeping exactly those two
  file-only is right; `$IMAGE` is still the one variable absent from `ACTION_KEYS`, so the
  `^\$[A-Z]` filter is still load-bearing; the Now Playing gate opens as intended (NP passes a
  bare integer id, so `$TRACKID` is stripped to `''`, while a queue row's `track_id:<n>` carries
  one and is correctly excluded); and `Slim::Schema::find` still routes a negative id to
  `RemoteTrack->fetchById`, whose `album`/`albumname` are independent accessors — so `ref $alb`
  really does separate a library row from a remote one.

  Two things chased and deliberately NOT reported, so they aren't re-chased: `%UNREGISTERED`
  looks like dead code (Material's `registerCustomAction` is a bare `push` that cannot fail)
  but the unguarded `Data::Dump::dump` behind `main::DEBUGLOG` gives the per-action `eval` a
  real if narrow trigger, and it degrades correctly; and `_ownedCats`'s pre-ledger seed claims
  `<svc>-album/-track` for every supported command, which collides with nothing — Discography
  writes only `artist`, Album Booklet only `track`, both unsuffixed.

  Per the Review Ledger the `//` on `$t->albumname` was not re-raised (settled 2026-08-27,
  section B). Suites unchanged and green: **662 checks across 12 suites**.

  Podcast `CACHE_VER` bumped 10 → 11 with the build per the dev-build cache rule; nothing here
  parses a feed, so it is hygiene, not a fix.

- **0.1.107 — a streaming-service PLAYLIST is a first-class saved row (`kind='playlist'`).**

  Adding a curated playlist used to fail SILENTLY rather than be refused. A Tidal/Deezer
  playlist row carries `favorites_url: tidal://playlist:<uuid>`; `favurlIsTrack` correctly
  answers 0 for a container ref, so the row fell straight through to the ALBUM path, matched
  no `album:`, and was stored as a `ref_kind='search'` row that replayed by searching the
  service for an *album* called "Dance Pop". A Qobuz editorial playlist carries no favurl at
  all, so it reached the no-favurl branch, `qobuzAlbumIdFromImage` was asked for an album id
  the playlist cover doesn't hold, and produced the same junk row.

  Now: `Sources::playlistFromRow` is the single detector — a `playlist:` container favurl
  (Tidal/Deezer, both from one shared upstream renderer, so curated AND personal lists work),
  or a Qobuz cover URL, whose `/images/playlists/<ID>_` filename IS the playlist id (verified
  live: `69183531` = "Hi-Res Masters: 2016 / Qobuz UK"). The path is deliberately DISJOINT
  from `qobuzAlbumIdFromImage`'s `/images/covers/`, so the two can never both fire.
  `_savePlaylistRecord` stores it flat and synchronously — no `_finishAlbumAdd`, whose
  cross-kind single dedupe, `_verifyRelease` and `_backfillStreamingArtist` are all release
  semantics that would give a playlist a bogus `rel_type`/`track_count`. Replay goes through
  the service's own playlist call (`QobuzPlaylistGetTracks` / `getPlaylist`), gated by
  `_serviceCanPlaylist` on the same "don't store what we can't replay" rule, with **no search
  fallback** — a playlist cannot be found by an artist+album search, and falling through to
  `_searchService` is exactly how the junk rows arose.

  **Two things the written plan got wrong, both caught by the suite rather than by review.**
  (1) The planned single-regex detector, `^(\w+)://.*?[:/]playlist:`, cannot match
  `tidal://playlist:<uuid>` — `^(\w+)://` consumes both slashes, leaving nothing for `[:/]`,
  so the PRIMARY case was the one that would have failed silently. Scheme and container ref
  are now matched separately, as `_addCtxCommand` already does for `album:`. (2) The plan put
  the playlist branch BEFORE the track branch; it now runs after, because the Qobuz half reads
  the IMAGE and a track browsed inside a playlist can carry that playlist's cover — a
  track-shaped favurl must win. Both are covered by named cases.

  The single most load-bearing edit is in `Browse::_albumTracks`: its write-back guard
  `ne 'track'` became `eq 'album'`. Left alone, opening a playlist would write a `track_count`
  and a `rel_type` onto it from the playlist's length, and it would start reading as an Album.

  Settled scope, recorded so it isn't re-raised: curated/service playlists only — a Qobuz
  PERSONAL playlist with no artwork of its own has no recoverable id (its cover falls back to
  a constituent track's album art) and is deliberately NOT supported; playlists live in Listen
  Later only ("Add to Wish List" redirects, and the "Move to Wish List" entry is suppressed),
  same rule and reason as a podcast episode; and a playlist never auto-moves to Played, which
  needs no new code because every Played lookup is already filtered to `kind='album'`/`'track'`.
  The long-term fix for the Qobuz hole is upstream — `Qobuz::Plugin::_playlistItem` emits no
  `favorites_url`, unlike Tidal and Deezer; a one-line `qobuz://playlist:<id>` would close it
  for everyone.

  **728 checks across 12 suites**, up from 662. Anti-tested per half: neutering
  `playlistFromRow` fails 15 add cases and NONE of the six positive controls (an album favurl,
  a cover-URL album row, a track favurl carrying a playlist cover — the rows that would break
  if detection widened); reverting the `_albumTracks` guard to `ne 'track'` fails exactly the
  2 cases it exists for and nothing else.

  The last 5 of those checks were added AFTER the build, and are worth their own note because
  of what they pin: `t_played.pl` now asserts that a saved playlist is invisible to
  `Played::_matchRecord`. The ledger entry above says the exclusion "needs no new code" — every
  Played lookup already filters `kind='album'`/`'track'` — and that is exactly why it needed a
  test. **The mechanism is an ABSENCE**, so a refactor can delete it and nothing else notices.
  The cases assert the behaviour at `_matchRecord` rather than the filters (`t_db.pl` pins
  those individually), so the promise survives however the lookups are rewritten. The risk is
  real, not hypothetical: a playlist is routinely NAMED after a release it draws from, and
  Played matches streaming plays on artist+title alone with no id anchor. Anti-tested against
  all THREE finders `_matchRecord` walks — stripping the `kind='album'` filter from
  `findByArtistAlbum`/`findByAlbum`, or from `findBySourceRefTitle` alone, each fails the 2
  negative cases while both positive controls still pass. Reaching the third one is why the
  test's playlist row carries a `ref.svc_title` that `_savePlaylistRecord` never writes: with
  the field empty that finder would pass for the wrong reason. Tests only — no plugin code
  changed, so no version bump and no rebuild.

  Podcast `CACHE_VER` bumped 11 → 12 with the build per the dev-build cache rule; nothing here
  parses a feed, so it is hygiene, not a fix.

- **0.1.108 — the rebrand pref copy is DELETED, not guarded.** **NB the reverting tickbox was
  NOT this** — that was diagnosed wrong twice and the real cause is 0.1.109 below. This entry
  stands on its own merits (the copy was guarding nobody), but do not read it as the fix for
  the reported bug.
  **Cause:** `_migrateRebrandPrefs` copied six prefs — `material_action` among them — from
  `plugin.listentolater`. 0.1.94 fixed the flag so the copy runs once, but *once* is still one
  clobber: on the first start after upgrading, an install lacking `threshold_90_migrated` runs
  the copy, which re-imports `material_action` and undoes the 90 that `_migratePrefs` set two
  lines earlier.
  **Decision: the copy protected nobody.** The plugin was never distributed under the old name —
  the pre-0.1.25 `repo.xml` bumps in git are a published manifest, not an install; only Simon's
  own box ever wrote a `plugin.listentolater` pref. So it was guarding a population of one while
  costing two settings-reverting bugs. Deleted: `_migrateRebrandPrefs`, its `initPlugin` call,
  the `rebrand_migrated` pref, and the seeding branch in `_migratePrefs`. **`DB::_migrateDbFile`
  STAYS** — that one renames `listentolater.db` if present, is file-based and idempotent, has no
  flag and none of this failure class, and dropping it would lose saved albums.
  **The underscore rule is kept** under "Prefs Namespace" — it still governs
  `threshold_90_migrated` and anything added later; only the migration it was written about is
  gone.
  `t_prefs_migration.pl` rewritten around the deletion: the old suite drove
  `_migrateRebrandPrefs` directly, so it had to be replaced rather than trimmed. The new
  fifth section seeds a populated legacy namespace *and* asserts a full startup leaves
  `material_action=0`, `sort`, `played_threshold` and `played_retention_days` untouched — twice,
  because "reverts at every restart" was the symptom — plus a `->can` check that the sub is
  actually gone rather than merely uncalled, since an orphan is one call site from bringing it
  back. 14 checks where the old suite had 17.

  **Second half — `shutdownPlugin` is now the UNINSTALL HOOK, and this is the part that fixes
  the reported bug.** Our "Add" entries live in Material's SHARED `actions.json`, a file we
  write but do not own, so removing the plugin never removed them: LMS rmtree's our directory
  and nothing of ours runs again, stranding the entries in every Material menu with hand-editing
  JSON as the only remedy. **Verified in `Slim::Utils::PluginManager` (9.1):** `disablePlugin` /
  the uninstall action set `preferences('plugin.state')->get(<module>)` to `needs-disable` /
  `needs-uninstall` **the moment Apply is clicked**, and the removal happens at the NEXT start
  (`init` dispatches the `needs-*` states; `_needsUninstall` rmtree's the dir). `shutdownPlugins`
  calls `shutdownPlugin` on every loaded module on the way down — so shutdown is the last moment
  we are loaded, our state pref already says we are going, and the file is still ours to tidy.
  Keyed on `__PACKAGE__`, which is exactly what `plugin.state` is keyed on.
  **Deliberately NOT gated on `material_action`** — the user may have turned it off long ago and
  the entries written while it was on still need removing.
  **New `$departing` argument to `_clearMaterialActions`.** The `$live` branch keeps and
  re-asserts the empty suppressors on purpose: they are all that stops the still-live registered
  `online-*` pair showing "Add" inside our own list until the restart. On the way out that
  reasoning inverts — there is no next run to protect, so keeping them strands them for ever,
  suppressing another plugin's `online-*` on podcasts and every radio command. `$departing`
  forces `$live = 0`. The ownership ledger is cleared too, so a reinstall starts from a clean
  sheet instead of inheriting a record of categories no longer in the file.
  14 checks in `t_material_actions.pl`, anti-tested per half: reverting `$live` to
  `$REGISTERED_N ? 1 : 0` fails exactly the suppressor assertion, and removing the state guard
  fails exactly the two normal-shutdown controls. Third-party entries — populated *and* an empty
  suppressor of their own — are asserted to survive the uninstall, which is the least recoverable
  place to get it wrong since that pass runs with no user present to notice.
  Suite total 728 → **739 across 12 suites**, all green.

- **0.1.109 — AN UNTICKED CHECKBOX POSTS NOTHING, and the base settings handler writes that
  absence as `undef`.** The real cause of "I untick 'Add to Material context menus', restart,
  it comes back on" — reported repeatedly while 0.1.94 and 0.1.108 chased the rebrand pref copy.
  It is **version-independent**: 0.1.93, 0.1.107 and 0.1.108 all behave identically, which is
  exactly the evidence that should have ruled the migration out early.
  **The chain, all verified in LMS 9.1 source, not inferred:**
  1. An unticked checkbox sends no field at all, so `pref_material_action` is ABSENT from
     `$params` — not 0.
  2. `Slim::Web::Settings::handler` does an **unconditional**
     `$prefsClass->set($pref, $paramRef->{'pref_'.$pref})` for every pref in `prefs()`
     (`Slim/Web/Settings.pm:162`), and it runs AFTER the subclass handler — so it writes
     **undef** straight over the 0 the plugin just set.
  3. `Prefs::Base::init` re-seeds any pref that "doesn't exist, **or exists as an undef value**"
     (`Slim/Utils/Prefs/Base.pm:200`) — so the default `material_action => 1` came back at the
     next module load.
  Net: the toggle could not be turned off at all. And because it was stuck ON, `postinitPlugin`
  always took the write branch, so `_clearMaterialActions` — the only thing that removes our
  entries from `actions.json` — was **unreachable**. That is why the residue never cleared, and
  why 0.1.108's uninstall hook was necessary but not sufficient.
  **Fix:** materialise the value into `$params->{pref_*}` and let the base class store it, which
  is exactly what the numeric prefs on that page already do. The direct `$prefs->set` stays,
  because the write/clear below needs the chosen value live in the same request. Both
  checkboxes on the page were affected — `material_action` and `debug_log`.
  **`debug_log` hid it**: its default is 0, so init re-seeding undef→0 still reads as "off". Only
  a checkbox whose default is **1** shows the symptom. Any future pref of that shape has the same
  trap.
  **Why the suite missed it, and the stub fix that matters more than the one-liner:**
  `t_stubs.pl`'s `Slim::Web::Settings::handler` was an empty sub — a base class that saves
  nothing — and `t_material_actions.pl`'s `save_settings` passed an explicit
  `pref_material_action => 0`, which is not what a browser posts. **The stub now mirrors the real
  base handler's unconditional set**, the same way the prefs stub was already made to mirror
  `Base::set`'s underscore discard. Treat that stub as a model of the server, not a placeholder:
  both of this plugin's silent-settings bugs lived in the gap between them.
  7 checks in `t_material_actions.pl` posting a genuinely unticked form (key omitted) and
  re-running `$prefs->init` to simulate the restart. Anti-tested: reverting just the two
  materialise lines fails 4 of them with `got='1'` after restart — the reported symptom exactly.
  Suite 739 → **746 across 12 suites**, all green.

- **0.1.110 — Material 6.4.8 shipped our PR #1257, so EVERYTHING registers and the shared
  `actions.json` is now PRUNED rather than written.**

  Upstream merged [PR #1257](https://github.com/CDrummond/lms-material/pull/1257) verbatim in one
  commit (`8f3e777be`, merge `f4cfb95`) and **released it in Material 6.4.8**; 6.4.9 still carries
  it. It is in **neither release's ChangeLog**, so "did it ship" is only answerable from the tree —
  `git merge-base --is-ancestor f4cfb95 6.4.8`. That closed all three gaps that forced the file
  half, so `track`, `queue-track`, `podcasts-*` and every empty suppressor can now be registered.

  **A DELIVERY TIER replaces the bare `->can` gate** (`_materialActionTier`, and `_useActionApi` is
  gone). Tier 2 requires the capability AND `>= 6.4.8`, and the version half is not belt-and-braces:
  on 6.4.6/6.4.7 the one-argument `registerCustomAction($section)` pushes **undef**, Material serves
  `{"<cat>":[null]}`, and `customactions.js` reads `sect[i].locked` off the null and throws — taking
  out every custom action in that section, **other plugins' included**. No side-effect-free probe
  exists (`$PLUGIN_CUSTOM_ACTIONS` is a file-scoped `my`; registering cannot be undone), so it is a
  version parse, with a dev build treated as newest like `Browse::_headerType`.

  **`_pruneMaterialActions` is the removal mechanism**, and the design constraint that shaped it is
  that **a hand-written `actions.json` must be assumed to exist**. LL has always MERGED into that
  file rather than overwriting it — the strip pass only removes what `_isOurAction` matches, entries
  are `push`ed, radio categories use `||=` — so a user's own actions have coexisted with ours the
  whole time and nothing would have told them otherwise. "Nobody has one, it would have broken" is
  false, and was the premise this release started from. So the prune never writes and never
  clobbers: it strips, deletes what is ours *and now empty*, and **unlinks the file only when that
  leaves it empty**. Anything foreign keeps the file alive, so "remove ours" and "leave theirs
  alone" never conflict. Deleting it is safe — verified in the served 6.4.9 bundle: the axios GET
  has a `.catch`, `getCustomActions` tests `if (customActions || pluginCustomActions)` and
  `getSectionActions` tests `if (list && list[section])`, so a missing file and an empty one are
  identical to Material.

  **`_isOurAction`'s title fallback is deleted.** It matched our four titles on an entry with no
  `lmscommand` — and **every** version of `_materialActionSet` back to the 0.1.25 rebrand builds
  every action with one (checked across the twelve commits that touched it), so the branch could
  never have caught anything of ours. It could only ever delete a THIRD PARTY's
  `script`/`command`/`weblink` action that happened to share a title, on every startup.

  **`%REGISTERED_EMPTY` makes the register guard per-category.** *(The premise below — "the
  positives never grow" — was made FALSE by this very release's tier-2 fold, and 0.1.119 fixed
  it; read that entry before quoting this one.)* `$REGISTERED` is a single latch
  because the positives never grow; the suppressors do — TuneIn's radio directory is fetched
  asynchronously, so the +60s deferred pass finds commands postinit could not (0.1.56) and must
  register those without re-pushing the rest. That pass now registers as well as writes.

  **Two things the tests found that review had not:**
  1. **The prune's early return on a missing file skipped the fallbacks.** A `registerCustomAction`
     that failed put its entries in `%UNREGISTERED` for the file to carry — but with the file
     already gone the prune returned before writing them, so a refused registration landed in
     NEITHER place. The guard is now `!-e $file && !%fallback && !%emptyFallback`.
  2. **The suppressor fallback needed gating on `$REGISTERED_N`.** A suppressor exists to hold OUR
     live `online-*` pair off our own rows; with nothing of ours registered there is nothing to hold
     back, and writing the empty `<cmd>-*` categories anyway would suppress **another plugin's**
     `online-*` on every radio and podcast row, with nothing of ours left to clean up. The
     pref-off-at-startup path reaches the prune in exactly that state. `$departing` forces both
     fallbacks empty, which is 0.1.108's rule unchanged.

  **Tried and REVERTED — do not re-propose: gating `_ownedCats`' pre-ledger seed on "has LL ever
  touched this file".** The concern was sound (a hand-written empty `qobuz-album` is
  indistinguishable from our 0.1.47-0.1.50 husks, and the seed sweeps it), but the husks have
  EXACTLY that shape — those versions wrote `||= []`, an empty category with no other mark — so any
  test for a trace of LL also withholds the seed from the file that needs it and the 0.1.51
  regression returns. `t_material_matrix.pl`'s I3/I4 caught it on `legacy_husks`. There is nothing
  in the file to tell the two apart; the protection lives where it can be exact instead.

  **Downgrades self-heal:** every file-writing path is kept, so a Material rollback or uninstall
  drops the tier and the tier-0/1 write rebuilds the file the prune removed.

  **The whole tier-2 path was untested when the code was first green** — the suite has no
  `getPluginVersion` stub, so all 746 existing checks ran at tier 1 and passed against code they
  never executed. `t_material_actions.pl` gains `set_material_version()` and 55 checks: the tier
  table, the folded action set, the upgrade-then-unlink path, a third party's file surviving
  verbatim, both refusal fallbacks, the deferred radio discovery, the pref off at startup vs
  mid-run, the uninstall, and both downgrade steps. **806 checks across 12 suites**, up from 746.
  Anti-tested per fix: reverting the tier gate to a bare capability test fails 23, restoring the
  title fallback fails 2, an unconditional early return fails 4, dropping the per-category empty
  guard fails 1, and each of the two gates above fails exactly the case written for it.

  **The one path this release changes for an install NOT yet on 6.4.8** is
  `_writeMaterialActionsDeferred`, which now registers as well as writes (tier 2 needs it for the
  radio commands TuneIn reveals late). On tier 0/1 it must be completely INERT — the positives are
  latched and the empty-section loop is gated on tier 2, because on 6.4.6/6.4.7 that loop would
  push a NULL into every suppressor section and break every custom action in it. Pinned by its own
  tier-1 case: no further entries, NO empty section, the late radio suppressor still reaching the
  FILE exactly as before, and the rest of the file byte-identical. Anti-tested — ungating the loop
  fails 5. So on a 6.4.7 box 0.1.110 is behaviourally identical to 0.1.109 apart from
  `_isOurAction` no longer guessing from titles, which only ever affected a third party's entries.

  **Not yet verified in a browser.** Both halves of #1257 were proven with `osascript -l JavaScript`
  against upstream JS, never in Material itself. Now that 6.4.9 is a real tag, install stock
  Material 6.4.9 on the box and check Now Playing, the queue, the Podcasts app, our own list rows
  and a radio browse row before trusting tier 2 in the field.

  Podcast `CACHE_VER` bumped 14 -> 15 with the build per the dev-build cache rule; nothing here
  parses a feed, so it is hygiene, not a fix.

- **0.1.111 — on Material >= 6.4.8, ticking "Add to Material context menus" ON did nothing
  until a restart. Reported from the live box, one release after 0.1.110 shipped it.**

  `Settings::handler` only ever called `_writeMaterialActions`, on a comment that claimed the
  save "cannot register — `registerCustomAction` has no de-dupe and no unregister, so it runs
  once per server run, in postinit", and that the FILE write was "precisely why turning it on
  mid-run works at all". Both halves stopped being true the moment tier 2 removed the file
  write: the prune writes only refused entries, so the save wrote nothing AND registered
  nothing. Dead toggle.

  **The premise was wrong, not just outdated.** `$REGISTERED` IS the de-dupe — a per-run latch —
  and it is FALSE in exactly the case this branch exists for, because the pref being off at
  startup is what sent `postinitPlugin` down its `elsif` without registering. There was never
  anything to double. The save now mirrors postinit on every tier: register, then write.

  **Tier 1 changes shape too, for the better.** It used to write all 16 entries to the file;
  now the 12 positives register and only the client-resolved half stays in the file — the
  normal tier-1 split, reached a different way. Registering is also the better half to land
  late: the `plugin-actions` CLI query is not browser-cached, where `customactions.json` is
  (0.1.57). Either way the user needs a Material reload, not a restart.

  **MISDIAGNOSIS, recorded so it is not repeated: the `actions.json` on the box is NOT ours.**
  The report was "ticking it on created an actions.json, which we are supposed to be getting
  away from". Checked live rather than reasoned about — the served `/material/customactions.json`
  holds exactly two sections, Discography's `artist` and Album Booklet's `track`, and no Listen
  Later entry anywhere; `material_owned_cats` is `[]`, i.e. the prune ran to completion. The
  file exists because two OTHER plugins write it, and LL correctly left it alone — that is the
  prune's only-ours/only-empty rule working, not failing. **Tier 2 itself was verified healthy
  in the same query**: `["material-skin","plugin-actions"]` returns 38 sections — all ten
  populated LL ones including `track`, `queue-track` and `podcasts-*` (the tier-2 fold), every
  empty suppressor, `bbcsounds-*` proving the +60s deferred pass registered a late-discovered
  radio command, and **no nulls anywhere**, which is the 6.4.6/6.4.7 hazard confirmed absent on
  6.4.9.

  **The live probes that settled it, worth reusing** (no SSH, and `log.txt` was useless — the
  tail was flooded by another plugin):
  `curl -s http://plex:9000/material/customactions.json` for what the file actually serves, and
  `["material-skin","plugin-actions"]` over `jsonrpc.js` for what is registered. Between them
  they distinguish "our entries are in the file" from "a file exists" — which is the whole
  question, and one the log could not answer.

  Six checks in `t_material_actions.pl`, and **two existing tier-1 assertions were REWRITTEN
  because they encoded the defect**: they demanded the save write the full set to the file and
  register nothing ("without registering behind postinit's back"). That is the repo's own rule
  about a suite arguing for a bug, hit from the inside. **814 checks across 12 suites**, up
  from 806. Anti-tested: reverting the save to write-only fails 6, including the live symptom
  (`ticking it ON registers the whole set there and then -> got '0'`).

  Podcast `CACHE_VER` bumped 15 -> 16 with the build per the dev-build cache rule.

- **0.1.112 — LL joins the fleet matcher sync, and because `DB::_norm` builds a STORED
  key rather than a cache key, it comes with a MIGRATION.**

  DSC/PFR/LBF took three Discography-origin rules; LL takes **two** — apostrophe elision
  (+ the `'n'` guard) and the ~90-entry `%FOLD`. The compound-word collapse was
  deliberately skipped: it only reaches the replay gate, where `_bestMatches` re-ranks
  afterwards.

  **WHY THIS WAS PARKED, and what actually made it safe.** LL's shape is the reason the
  memory note said "a rewrite, not a copy". It has THREE normalisers, and the fleet check
  only ever saw one of them:

  | sub | job | changing it |
  |---|---|---|
  | `Sources::_norm` | fuzzy match gate | live only |
  | `Sources::_normStrict` | replay ranker | live only |
  | **`DB::_norm`** | **dedupe_key — UNIQUE, on every row** | **data migration** |

  In the other three repos `_norm` feeds caches, so a fold change is a cache bump. Here it
  rewrites stored identity. The two are genuinely separate subs and never meet, which is
  what makes the live half free — and what makes the stored half unavoidable.

  **What LL actually gained.** `_artistMatch` is an exact-token SUBSET test, so a playing
  "Jane's Addiction" (`jane s addiction`) against a saved "Janes Addiction"
  (`janes addiction`) shared no token for `janes` and **the row silently never moved to
  Played** — LL's core feature, failing the way it failed in DSC and LBF. Accents were
  worse here than anywhere else: `[^a-z0-9]+ -> ' '` turned every non-ASCII letter into a
  SPACE, so "Sigur Rós" keyed `sigur r s`, shattered into single-letter tokens.

  **THE FOLD LIVES IN `DB.pm`, NOT WITH THE MATCHER, and the reason is asymmetric damage.**
  Both are leaf modules (neither requires the other), so one has to reach the other at
  runtime through `->can` — which means one of them has a FALLBACK path. On the live
  matching path a fallback is a worse match, discarded at the end of the request; on the
  dedupe-key path it would write a wrong key into a UNIQUE column, permanently, and the row
  would be invisible to every later lookup. So the authority sits with the irreversible
  consumer: `DB::_norm` calls `foldLatin` directly, `Sources` reaches it via `->can`.
  Pinned by `t_refold.pl` §5, because the failure it prevents is a permanent wrong key
  rather than anything a passing call would show.

  **THE MIGRATION (`_migrateRefold`, `user_version` 5) — the collision policy is the
  design.** Every key written under the old fold is stale, and a stale key is INVISIBLE:
  `add()` stops deduping against it, Played's lookups stop finding it. Rows are GROUPED by
  their complete logical key, matching `add()`'s cross-source `findAnyByKey` rule, and each
  group settled as a unit — a per-row loop also collides transiently against rows it has not
  reached yet, so the constraint error tells you nothing about whether a real duplicate
  exists. Playlist/episode keys keep their service scope in their own `|p:` / `|e:` tails.
  - **Same status across the group** → genuinely one album saved twice under two spellings.
    Collapse into the EARLIEST save, carrying play history and release metadata. A missing
    replay carrier adopts **source + ref_kind + ref_json atomically**; a resolved count and
    release type are carried only from the survivor's resulting source, because one is
    service/region-specific and the other may be service-asserted.
  - **Mixed status** (one `later`, one `played`, one Wish List) → **LEFT ALONE on their old
    keys**, with a WARN naming the ids. Collapsing would have to silently pick a list for
    the user: resurrect something finished with, or mark something still queued. An old key
    costs one un-deduped row — visible and reversible by hand; guessing costs a list entry
    that vanishes unexplained. **Nothing is ever deleted without a same-status twin.**
  - **Playlists keep their identity segment verbatim.** A playlist's identity is the
    service's own id in the `|p:<source>:<id>` tail, which cannot be rebuilt from any
    column — only the title segment is re-folded.
  - Idempotent, and LAST among migrations that recompute keys from stored columns, so it
    must run after the migrations that change what a key is built FROM (0.1.43's year segment,
    0.1.71's artist-prefix cleanup). Rung 7 follows only to reconcile exact cross-source keys
    left by already-stamped development databases; it introduces no second key shape.

  **Two existing fixtures broke and were REWRITTEN rather than renumbered**, which is what
  they were for: `t_addpath.pl` pinned `'tomorrow s people|open soul|'` with a note saying
  the apostrophe becomes a space "so it can't drift silently" — it caught this exactly as
  intended and now pins the elided form; `t_db.pl` pinned the ladder height at 4.

  **TESTS.** New `tools/t_refold.pl`, **52 checks**: the fold in all three normalisers, the
  three punctuation passes still differing where they should, the lenient gates untouched,
  and the migration end to end against real SQLite (rekey, same-status merge with the ref
  carried across, mixed-status left alone, track and playlist identity segments, and
  idempotence). **Anti-tested five ways — 15 / 7 / 5 / 8 / 3 red.** The `->can`-miss mutant
  is the informative one: 5 red on the LIVE path while every §4 migration assertion stays
  GREEN, which is the asymmetry that put the table in `DB.pm`.

  **Fleet:** `matcher_sync_check.py` **exits 0**; LL's `_norm` re-pinned
  `92c2a19a0832 → a054575b2b5b`, and `ListenLater/DB.pm` is now scanned as its own tag
  (`LLDB`) so LL's `%FOLD` is compared — it hashes `3b0d43f368e9`, byte-identical to
  DSC/LBF/PFR — with `DB::_norm` pinned as the deliberate variant it is.

  **No cache bump** (LL matches live; the stored half is the migration). Podcast
  `CACHE_VER` bumped with the build per the dev-build cache rule.

- **0.1.113 — Spotify support, via the Spotty plugin.** Full parity with the other
  services: album replay by id, track saves, playlists (both URI spellings), the
  artist+album search fallback, release-type classification and artist backfill.

  **The bug that would have swallowed all of it, and did not:** Spotty sends a bare
  Spotify URI as `favorites_url` — `spotify:album:<id>`, no `//` — where every other
  service sends a scheme url. This plugin reads a favurl as a scheme url in FOUR
  places (`sourceFromUrl`, `favurlIsTrack`, `playlistFromRow`, `$favScheme` in
  `_addCtxCommand`), so all four failed: the album read as source `library`, a track
  was not recognised as a track, and the album id sitting in the favurl was never
  captured. Fixed with ONE normalisation at the boundary (`Sources::normaliseFavurl`,
  called from `_addCtxCommand` after `_stripPrivateParams`), not a Spotify case in each
  reader — and it is free on the track side, because `spotify://track:<id>` is exactly
  the play url Spotty itself builds.

  Also: `%SVC_ALIAS` folds Spotty's browse command (`spotty`) onto the source tag
  (`spotify`), and both add paths now ask `sourceFromSvc` instead of open-coding
  `knownSource(...) ? lc ... : ''`. Spotify becomes the second service after Qobuz
  whose album object settles type, count and year in one fetch — with the EP trap
  (Spotify calls EPs `single`) left to `singleIsWrong`/`_settle` rather than a new
  guard. **NOT done, by decision (Simon, 2026-09-02: "leave as is") — do not re-propose
  it:** an album id from a PLAYING track. Spotty's `getMetadataFor` flattens the album to
  a name string, exactly like Deezer; the id is reachable one layer down via
  `API->trackCached`, but that helper is called in four places and all four are inside
  Spotty — it is internal, not published. Same ruling as Tidal/Deezer took on 2026-07-25.
  The cost is narrow: it affects ONLY the Now Playing "Add" (the one path with no favurl
  to read an id from), which still works off the album+artist names Spotty does publish.
  Every other path carries the id and replays exactly.

  **SUPERSEDED IN PART (1.0.1, 2026-09-16) — read this before quoting the decline above.**
  What stayed declined is the ADD. `API->trackCached` itself is now USED, by
  `Played::_spotifyAlbumRecord`, to match a playing Spotify track to a saved row by release
  id; it reads the cache entry Spotty already built the playback metadata from (`noLookup`,
  no Web API call, so no 429 can stall a newsong). The internals objection was outweighed
  there by a MEASURED defect the title doors could not fix — `cleanupTags` strips a remaster
  suffix at playback but not at browse, so a Spotify row's stored title can never match, and
  two editions clean to the same string. See CLAUDE.md §B.

  **VERIFIED LIVE 2026-09-02** against Spotty v4.62.2 on the test server, from two real
  Material adds (`log.txt` + the rendered rows over `jsonrpc.js`):
  - a playlist add with `svc=spotty` → source `spotify` (the `%SVC_ALIAS` fold) and
    `playlist_id` extracted;
  - an album add with **`svc=` EMPTY** — the row carried no browse command, so the source
    came from the favurl SCHEME. That is exactly the path the normalisation fixes: before
    it, this fell through to the cover sniff, still guessed `spotify` from `i.scdn.co`, and
    **silently lost the album id**, leaving a row that replays by fuzzy search. The log
    printing `spotify://album:…` is itself the proof normalisation ran, since Spotty can
    only ever emit `spotify:album:…`;
  - the row rendering as **"Blondie – Parallel Lines (1978)"** from an add whose `artist=`
    was BLANK — i.e. `_backfillStreamingArtist`'s Spotify branch called `$api->album` with
    the URI rebuilt from the stored id and got an answer. That is the same
    `API::album` + URI mechanism `_streamingAlbumNode` replays through, so **the URI
    reconstruction is confirmed correct** — a bare id returns nothing there;
  - `rel=album` settled at insert, so `classifyRelType`'s Spotify branch answered too.

  **Still NOT observed directly:** audio. Spotify blocks playback on this rig entirely —
  see [[spotify-playback-blocked-on-test-rig]]; metadata and artwork arrive and the clock
  never moves. That is a Spotify restriction, not a plugin fault, and it is why every check
  above is an API/tracklist check rather than a play. Never verify a Spotify adapter by
  playing something. Also unobserved: the accented-artist `query_enc` case.

- **0.1.114 — ONE Material version comparator (`Sources::materialAtLeast`), and the
  list-context trap the refactor walked straight into.** A code-review reuse finding: the
  "parse `X.Y.Z` and compare against a threshold triple" logic was written out three times —
  the 6.4.8 tier gate (`_materialActionTier`), the 6.4.4 "online Add supported" diagnostics
  line (`_dumpMaterialState`), and `Browse::_headerType`'s 6.4.3 gate. Three copies of one
  comparison is three places a parsing change has to land, with nothing tying them together.

  All three collapse to a single line each, because **`undef` is falsy and every site had
  already chosen the same safe answer for the unknown case** as its false branch: tier 1, "not
  confirmed", and the long-standing `header`. So the helper returns THREE values — `undef`
  can't tell, `1` yes (a non-numeric dev/test build included, treated as newest), `0` no — and
  no caller needs a separate undef branch. The shape is pinned by test rather than left
  implied, so a future caller that must distinguish "cannot tell" from "too old" can, by
  testing `defined`.

  **It lives in `Sources.pm` and is the only thing in that file that is not service logic.**
  That is deliberate: Sources is the one LEAF module both `Plugin.pm` and `Browse.pm` already
  `use`, so sharing through it creates no new dependency edge. `Browse.pm` keeps its own
  `getPluginVersion` read rather than calling `Plugin::_materialVersion` — Plugin requires
  Browse, so reaching back the other way would invert the dependency for a one-line read.

  **THE BUG THIS SHIPPED WITH, caught by the suite and worth more than the refactor.** The
  first cut wrote the tier gate as `materialAtLeast(_materialVersion(), 6, 4, 8)`.
  `_materialVersion` is `return eval { ... }`, and **a failed `eval` BLOCK yields an EMPTY LIST
  in list context, not undef** — so inlined into an argument list the args collapse from
  `(undef, 6, 4, 8)` to `(6, 4, 8)`: `$ver` becomes `6`, fails the numeric match, and takes the
  dev-build branch. **Every install without Material silently reached tier 2 instead of the
  safest tier** — which on 6.4.6/6.4.7 is the one that pushes a null into every suppressor
  section and breaks every custom action in it, other plugins' included. 31 assertions went red
  (24 in `t_material_actions.pl`, 7 in `t_material_matrix.pl`). The other two call sites were
  never at risk because they already assign to a scalar first.

  **The rule: never inline a sub whose body is `return eval { ... }` into an argument list.**
  Assign it to a scalar first. Same family as [[lms-settimer-hands-back-obj]] and the
  hand-rolled-`ok()` trap — a context mismatch that changes ARITY rather than raising an error,
  so nothing warns and the wrong branch is taken silently. The comment at the tier gate says so
  at the point of temptation.

  **Tests:** `t_material_actions.pl` 172 → **192 assertions** (958 across 13 suites). The new
  section pins the comparison table, all three return values including `undef` as distinct from
  `0`, that the arg-collapse shape really does answer `1` (the trap, reproduced directly), and —
  as SOURCE checks, since no return value shows which spelling a caller used — that no site
  inlines the eval-returning sub and that neither `Plugin.pm` nor `Browse.pm` parses a triple of
  its own any more. `LL_PLUGIN_SRC=` / `LL_BROWSE_SRC=` point those at mutated copies:
  **anti-tested three ways** — the live inlined call 31 red, the inlined call site 1, Browse
  keeping its own compare 2.

  Behaviour is byte-identical at all three gates. Podcast `CACHE_VER` bumped 18 → 19 with the
  build per the dev-build cache rule; nothing here parses a feed, so it is hygiene, not a fix.

- **0.1.115 — ONE reader for a Spotty album object's artist (`Sources::spottyArtistName`).**
  The second reuse finding of the same review as 0.1.114, and the same shape: four lines
  written out twice, with nothing tying the copies together.

  **What the duplication knew.** Two album shapes are legitimate and both arrive — Spotty's
  cache normalises the album to a plain `artist` STRING (`API/Cache.pm`), while the raw
  Spotify API keeps `artists` as an array of hashes. Prefer the string, fall back to the first
  entry of the array. `_searchService`'s Spotify branch asked it of a search candidate (is
  this the right artist?), `Plugin::_backfillStreamingArtist` asked it of the album object it
  fetched (what artist does this row lack?), and the two answers differed only in what they
  returned on a miss — `''` vs `undef`.

  **Why it was worth closing even though both copies were correct.** Nothing connects them:
  no compiler error, no failing test. If Spotty's response shape ever moves, the fix has to be
  found twice, and missing the backfill copy leaves saved rows **artist-less** — the failure
  this plugin is worst at noticing, because the album plays perfectly and silently never moves
  to Played (see the `&al=` fleet rule for the same silence by a different route). The helper
  returns `''` on every miss so a caller can test `length` alone; the backfill's guard already
  treated `''` as absent, so behaviour is byte-identical at both sites.

  **NOT folded together with the Tidal and Deezer extractions eight lines above it in
  `_searchService`, which look nearly identical and are a DIFFERENT shape:** there `artist` is
  a HASH you read `->{name}` from, where Spotty gives a string. Pinned by a case that passes a
  hash in `artist` and expects `''` — so a future fold shows up as a failure rather than as a
  Tidal row that quietly loses its artist.

  **Tests:** `t_favurl.pl` 118 → **135 assertions** (977 across 13 suites). Both shapes, the
  string winning when both are present, and seven miss cases — including two the loose
  spelling gets wrong rather than merely differently (an `artists` array holding a string
  DIES under `strict refs`, and a hash in `artist` comes back as a stringified ref). The
  helper calls are `eval`'d for that reason: an assertion that dies aborts the run instead of
  reporting, which is how a suite goes quiet. Plus source checks that both modules ask through
  the sub, that only Sources defines it, and that neither open-codes the `artists[0]{name}`
  read anywhere outside the sub body (`LL_SOURCES_SRC=`/`LL_PLUGIN_SRC=` point those at
  mutated copies). **Anti-tested both halves** — the pre-fix tree fails the 5 source checks,
  and loosening the helper's guards fails 4 behaviour cases.

  Podcast `CACHE_VER` bumped 19 → 20 with the build per the dev-build cache rule; nothing here
  parses a feed, so it is hygiene, not a fix.


- **0.1.116 — the third checkbox, and the fold's `lc` in the wrong place.** Two review
  findings, both bugs that a green suite and a working live test hid for the same reason:
  each is invisible unless you feed it the one input shape nobody feeds it by hand.

  **`watch_outside` could not be turned off.** 0.1.108 fixed the unticked-checkbox chain
  (an absent `pref_*` → `SUPER::handler` writes undef → `Prefs::Base::init` re-seeds the
  default at the next module load) and materialised `pref_material_action` and
  `pref_debug_log` into `$params` to break it — but `settings.html` has THREE checkboxes,
  and the third, defaulting to 1, was left on the broken path. Unticking "mark Played from
  plays started outside the plugin" therefore came back ticked at every restart. The fix is
  the third line of the same shape; no direct `$prefs->set` beside it, because nothing in
  that request reads the value — `Played.pm` reads it at play time, after SUPER has stored
  it. `t_material_actions.pl` 192 → **195 assertions**: the pref is a real 0 (not undef)
  after the save, survives two restarts, and still re-ticks. **Anti-tested** — removing the
  one line turns 2 of the 3 red.

  **`DB::foldLatin` lowercased BEFORE decoding, so the octet path keyed differently from the
  character path.** `lc` on a byte string is ASCII-only, so an uppercase accented letter
  survived the fold as bytes, decoded to an uppercase codepoint, and `_norm`'s `[^a-z0-9]`
  then DELETED it rather than folding it: `SIGUR RÓS` keyed `sigur r s` from the raw CLI
  against `sigur ros` from everywhere else — two keys for one album in a UNIQUE column,
  the invisible row `_migrateRefold` exists to prevent. Both callers are real: `Plugin.pm`'s
  handlers take `artist`/`album` straight off `$request->getParam` (octets over the raw CLI),
  while service JSON and SQLite (`sqlite_unicode => 1`) are characters.

  **Only an UPPERCASE accented letter exposes it**, because the fold's output is lowercase —
  `Sigur Rós` and `Björk` agree on both paths, which is why a live add looked correct and
  why `t_refold.pl`'s all-lowercase fixtures could not see it. §4f now feeds both cases
  through both encodings: 52 → **61 assertions**, 6 red on the pre-fix tree.

  **This restores FLEET ALIGNMENT rather than diverging from it.** LBF, PFR and DSC all
  decode first and `lc` after; the 0.1.112 port into `DB.pm` reordered the two. Checked
  before the fix landed — `matcher_sync_check.py` exits 0 either way, because it compares
  `_norm` and `%FOLD` and LL's fold lives in a separately-named sub, so the ordering slip was
  outside what the gate can see. No sibling repo needed a change.

  **No migration owed, and that is worth stating** — the rule above `DB::_norm` says a fold
  change rewrites a stored key. Here it does not: `sqlite_unicode` means `_migrateRefold`
  already rekeyed every row on the CHARACTER path, so this makes CLI input agree with what
  is stored rather than changing it. Also corrected a stale comment claiming SQLite hands
  back octets — the handle has set `sqlite_unicode` since it was written.

  Two findings from the same round were DECLINED — see the Review Ledger, section A2: the
  prune's `favorites-*` claim (0.1.85 DID ship that category; `git log -S` cannot prove
  otherwise in a repo that commits versions in batches) and the `utf8::is_utf8` fold gate
  (no LL input producer downgrades). Podcast `CACHE_VER` bumped 20 → 21 with the build per
  the dev-build cache rule; nothing here parses a feed, so it is hygiene, not a fix.

- **0.1.118 — two diagnostics that reported what we BUILT as what Material TOOK.** The
  fourth 2026-09-03 review round. Five findings, and the shape of the round is the point:
  **the three DB findings were all withdrawn under challenge** and only the two Material
  ones survived. Neither changes behaviour — both are the log a "where did Add go" report
  is made from, which is the whole reason they have to be true. Suite 215 → 223, two red
  per fix.

  **`%regCount` credited refused entries as delivered.** `_pruneMaterialActions` counted
  "what we built minus `%fallback`" — the formula lifted verbatim from
  `_writeMaterialActions`, where it is correct because `%fallback` there IS `%UNREGISTERED`.
  But the prune deliberately zeroes `%fallback` on the `$departing` / `$prefOff` paths (a
  WRITE-POLICY decision: the pref being off must not re-write what the user asked to be rid
  of), and with nothing subtracted the count became "everything we built". Turn the pref off
  after registration refused the lot and the dump claimed `plugin API (Material 6.4.6+)`,
  `registered sections = album(2), online-album(2), …`, `streaming Add active` and
  per-service `Add shown (via its own registered '<cmd>-album' section)` — with nothing live
  anywhere and the file half just deleted. Same lie through the early-return branch, which
  did not subtract at all. **Fixed by `_deliveredCounts`**, one carrier that reads the
  refusal ledger directly and cannot be handed a substitute; all three copies now call it.
  *The lesson is narrower than "don't duplicate code": a formula is only as portable as what
  its inputs MEAN. The third round's knock-on pass traced the concept "is our half live"
  through the writers — it did not trace the arithmetic that reports on it.*

  **The pref-off warn was contradicted by the line below it.** With the positives registered
  but the one-argument empty-section calls refused (a dead `$register` coderef leaves either
  half at zero, independently), it logged *"No suppressor registered either, so another
  plugin's Add is not being held off those rows"* — and `_pruneMaterialActions` then wrote
  exactly those suppressors into `actions.json` three lines later. Inside that branch the old
  text was not merely wrong but **unreachable as a true statement**: the outer condition means
  an empty `%REGISTERED_EMPTY` implies `$REGISTERED_N`, which is precisely when the file half
  gets written. The clause now recomputes the prune's own `%emptyFallback` set and reports
  what will be LIVE, so the message and the mechanism cannot drift; the test asserts the file
  really does contain the suppressors, pinning the message to the behaviour rather than to
  itself. *This warn had been rewritten one round earlier to state one fact per clause — and
  the second fact was still about registration when the sentence was about suppression.*

  **Three DB findings withdrawn, all recorded in the Review Ledger §A2** so the next round
  starts from the reasoning rather than re-deriving it: the refold "permanent retry loop"
  (said here to need a NON-MONOTONE fold rule that LL does not have — **wrong, and corrected
  in the ninth round: one exists, and the real barrier is that no service emits the title it
  needs**), the missing schema-6 rung for
  0.1.116's `lc` fix (real mechanism, empty population — **`main` is 0.1.93**, so 0.1.112–
  0.1.116 never shipped), and the rung-5 failure warn printing the entry `$schemaVer` rather
  than the stamped one (true, cosmetic, accepted). Podcast `CACHE_VER` bumped 22 → 23 with
  the build per the dev-build cache rule — hygiene, nothing here parses a feed.

- **0.1.119 — a latch that outlived its premise, a rollback that poisoned the handle, and the
  third copy of the delivery-honesty bug.** The fifth 2026-09-03 round. Three findings, all
  fixed, none shipped. Suite 1030 → **1052 assertions across 13 suites**.

  **1. The prune's dump credited an API half that never ran.** Third instance of the same
  substitution 0.1.118 closed twice, in the copy 0.1.118 did not reach: `_pruneMaterialActions`
  passed a hardcoded `$api = 1` and an ungated `_deliveredCounts($positive)`. The refusal
  ledger is honest ONLY once registration has run — with `%UNREGISTERED` empty because nothing
  was ever *asked*, subtracting it reports the whole built set as delivered. The reachable path
  is ordinary: `material_action` off at STARTUP sends postinit to `_clearMaterialActions`, which
  on tier 2 prunes with `$REGISTERED` false. The dump then printed `custom-action delivery =
  plugin API`, `streaming Add active`, `registered sections = …` and per-service `Add shown (via
  its own registered '<cmd>-album' section)` — two lines under `material_action pref = OFF`.
  Fixed with one `$api` carrier gated on `$REGISTERED`, feeding both `_deliveredCounts` sites and
  all three dump calls, exactly as `_writeMaterialActions` already does. *The lesson 0.1.118
  recorded — "a formula is only as portable as what its inputs MEAN" — was right and still
  under-applied: `_deliveredCounts` fixed the ARITHMETIC's inputs but nothing checked the
  PRECONDITION that makes the ledger meaningful at all.*

  **2. `_migrateRefold`: a rollback that itself fails left `AutoCommit` OFF for the rest of the
  server run.** `begin_work` turns it off and only a COMPLETED commit/rollback turns it back on.
  The failure branch logged the failed rollback and carried on, so every later `begin_work` died
  `Already in a transaction` (remaining groups ran unwrapped) and — far worse — **every plugin DB
  write for the rest of the run joined a transaction nothing ever commits**, which DBI discards at
  handle destruction. Saves and play counts vanishing silently at shutdown, hours later, with
  nothing in the log. Verified against real DBI 1.643 / DBD::SQLite 1.64, not reasoned about.
  **The first fix was WRONG and the test is what caught it:** restoring `AutoCommit = 1` while the
  transaction is still open **COMMITS** it, turning "the rollback failed" into "the half-applied
  merge is permanent" — losers deleted for good, survivor on its stale key, precisely the loss the
  transaction exists to prevent. Order is load-bearing: roll back by hand via raw SQL first (it is
  `->rollback` that just failed), THEN restore `AutoCommit`, THEN abandon the pass — the
  transactional state is the very thing we failed to settle, so nothing is safe to run against it.
  `$failed` withholds the version stamp, so the whole pass retries at the next start.
  *Caveat kept deliberately: DBD::SQLite would not fail a rollback on demand, so §4i injects one.
  The realistic trigger is SQLite having already auto-rolled-back (full disk, I/O error) — which
  is exactly what the branch's own retry comment names as the likely cause.*

  **3. On tier 2, the first podcast subscribed mid-session got no "Add" until a restart.**
  `$REGISTERED` was a single latch resting on "the positive entries are built once and never
  change" — a premise **0.1.110 made false in the same release that wrote it down**, by folding
  the `hasFeeds()`-gated `podcasts-*` override into `%positive` on tier 2. Subscribe to a first
  feed after startup and the section reached NEITHER half: the latch refused to register it, and
  the prune writes back only what registration REFUSED. Tier 0/1 were fine — the pair stays in
  `%fileCats` and the next file write carries it.
  Two halves, because the ledger alone would not have fixed the user-visible bug. `%REGISTERED_POS`
  tracks the positives per category, latched on the ATTEMPT exactly as the flag was, so a section
  present at startup behaves identically and only a NEW one is offered; `%UNREGISTERED` is MERGED
  rather than assigned, or a later pass would drop an earlier pass's refusals and those entries
  would disappear from both halves at once. And `postinitPlugin` now watches
  `plugin.podcast:feeds` via `setChange`, firing `_writeMaterialActionsDeferred` — the right
  callback, since it re-registers what is new and rewrites the file, and it covers unsubscribing
  the last feed too. `$REGISTERED` survives with a narrowed job: "did the API half RUN", which is
  what finding 1 reads.

  **Harness gaps this exposed, worth more than the one-liners.** `reset_all()` and `new_process()`
  did not clear the new ledger, so sections stayed latched ACROSS tests — 6 real failures until
  added, and a reminder that any state a test resets has to be reset in full or the suite silently
  tests a warmed-up process. And §4i passed and failed run to run while it was being written,
  until its squatter pair was switched to an ASCII apostrophe difference — **the cause was a
  broken literal in that new fixture** (a single-quoted `'Sigur R\x{f3}s'`, a backslash rather
  than an ó), NOT any property of §4h, whose own pair groups correctly (`sigur ros|takk|2005`,
  both ids) and which passes 40/40. An earlier draft of this entry said otherwise and warned
  against diacritics in fixtures; that was wrong, and the ledger records how the wrong
  conclusion was reached. The `%REGISTERED_EMPTY` gap noted here was closed straight after, by
  giving `t_material_matrix.pl` a Material-version axis — see below.

  Every fix anti-tested against the bug it claims to catch — finding 1: 3 red (`claimed the API` /
  `claimed active` / `listed some`), with the mirror case pinned so the gate cannot be widened into
  silence; finding 2: 3 red, the decisive one being *a write made after the failure is discarded at
  shutdown*; finding 3: 4 red on the single-latch mutant plus 1 on an unhooked source (a source
  check, because the harness's `setChange` is a no-op and no return value would show the wiring).
  Podcast `CACHE_VER` bumped 23 → 24 with the build per the dev-build cache rule — hygiene,
  nothing here parses a feed.

  **AND THEN THE GAP UNDERNEATH ALL THREE: `t_material_matrix.pl` had never run at tier 2.**
  That suite exists to catch husk bugs across restarts and pref toggles — the two-transition
  class no single-call assertion can see — and it never stubbed `getPluginVersion`, so with the
  API installed it pinned at tier 1 and **all 108 assertions drove a delivery mode that prunes
  nothing, registers no suppressors and never unlinks the file.** Tier 2 is where the prune
  lives, where two of this round's three findings live, and what Simon's own 6.4.9 box runs. Same
  shape as 0.1.110's own confession ("without it, 746 checks passed against code they never
  executed") — repeated one suite over, which is why it is recorded as its own lesson rather than
  a footnote.
  The configs gain a Material-VERSION axis, so the matrix is now 6 configs (tier 2 / tier 1 /
  tier 0, each with and without podcast subscriptions) x 9 journeys x 4 invariants: **108 → 162
  assertions.** Verified as executing rather than merely passing — at tier 2 the boot registers
  18 actions plus 26 empty sections and leaves NO file at all, at tier 1 12 actions and no
  empties with the file present, at tier 0 nothing registered. Three consequential edits fell
  out, each of which the tier-2 axis made necessary:
  - **`merged_view` had to learn what a ONE-ARGUMENT registration means.** It read `$_->[1]`
    for every `@REG` entry, so an empty-section declaration contributed a literal `undef` and the
    suppressor compared as POPULATED — the exact opposite of what it is. Harmless while no
    config reached tier 2; wrong for every suppressor the moment one did.
  - **I3 (no self-harm) now takes the merged view, not the file.** An empty suppressor suppresses
    whichever half it arrives through, and on tier 2 it arrives by REGISTRATION — so reading the
    file alone made that invariant *unfalsifiable* on the one tier where the prune runs.
  - **`do_op('on')` now registers before writing**, mirroring `Settings::handler` since 0.1.111.
    Its comment still said "a save can never register", which stopped being true a release
    earlier — and on tier 2 there is no file write left, so write-only delivers nothing and the
    journey could never converge.
  `new_process()` also clears `%REGISTERED_EMPTY` — the fourth registration fact a real restart
  drops. It could not bite before this, since the empty-section loop is gated on tier >= 2.
  **Anti-tested, because a green matrix is exactly the thing to distrust:** making the prune
  delete any empty category (the 0.1.101 bug) fails I2 with `otherplugin-track vanished`, and
  making it keep our own husks fails I3 and I4 naming `qobuz-album`, `tidal-track`,
  `deezer-album` — the 0.1.51 regression, caught by category name.

- **0.1.120 — Qobuz and Tidal were searched with the wrong string encoding, and a comment that
  documented it as correct.** The sixth 2026-09-03 round. Two findings, both fixed. **Read the
  round's ledger entry above before quoting this one — the encoding defect is PRE-EXISTING
  (2026-07-01), not a regression of the 0.1.113–0.1.119 work, and the round's most useful outcome
  is the scoping correction rather than either fix.**

  **`_searchService` octet-encoded ONE query and handed it to five branches that do not agree.**
  Qobuz escapes with `uri_escape_utf8` and Tidal transliterates with `Text::Unidecode`; both want
  CHARACTERS, so octets double-encode — "Sigur Rós" went out as `sigur%20r%C3%83%C2%B3s` and
  `Sigur RA3s` respectively, matching nothing. Deezer's `complex_to_query` and Bandcamp genuinely
  do want octets, which is why two of the four branches were right and the split was never
  obvious. Spotty was already correct, by passing the raw `$artist` — but the comment explaining
  why asserted octets were "right for the other three", so the one branch that got it right
  argued for the bug in the other two. Fixed the way the sibling did in **LBF 0.9.82** (after the
  same failure was found in Discography on 2026-07-10): build BOTH spellings at the top of the
  sub, pick per branch. LBF carries the split as a per-adapter `query_enc` field; here it is two
  lexicals, because the branches are hand-written rather than table-driven.

  **VERIFIED LIVE over `jsonrpc.js`, both services, 2026-09-03** — see the ledger round above for
  the exact probes and why no source grep was needed (Qobuz returns its own `uri_escape_utf8`
  output inside the child `item_id`). Real Sigur Rós albums in the result set: **Qobuz 47 → 1**,
  **TIDAL 44 → 8**. Note what that corrects: the search does **not** return nothing, it returns
  JUNK — Qobuz's 88 mojibake hits are *Sigue Caminando*, *Remembering Sigurd Rascher* and the
  like — which `_albumMatches` then rejects. Same user-visible end ("Could not find this album to
  play"), different mechanism, and TIDAL DEGRADES rather than fails, so an album may still be
  found by luck. Describe it as wrong/incomplete results, never as zero.

  **The failure is SILENT and that is the whole reason it survived**: a search that answers with
  the wrong records is indistinguishable from the album not being on the service, so replay
  reports a clean miss and nothing is logged. It also blunted 0.1.112's fold sync on this path —
  the local gate folds accents correctly now, while the service was never asked an answerable
  question.

  **Reach is narrow, which is why Simon had never seen it.** The search is a FALLBACK: a row
  carrying a native `album_id` replays directly through `_streamingAlbumNode` and never reaches
  the sub. It needs `ref_kind='search'` AND a non-ASCII artist together.

  **Only the QUERY changed — nothing that Played depends on.** `$artistQuery` was write-only and
  outbound, used at three call sites and never stored, compared or returned; every branch already
  matched candidates with `_norm($artist)` on the RAW value, and the only DB write downstream of a
  search is `_cacheBandcampUrl`, which writes a URL. So the fix cannot alter what matches, only
  what the service offers to match against — it can turn a miss into a hit and not the reverse,
  since today that path returns an empty set. Played reads a different pair entirely (the playing
  track's metadata against the stored row), and add-time capture is untouched.

  **Finding 2 is comment-only.** `postinitPlugin`'s podcast watcher claimed unsubscribing the last
  feed is "the mirror case and the same call handles it". On tier 2 it cannot be — the file three
  paragraphs up already says `registerCustomAction` PUSHES with no unregister — so `podcasts-*`
  stays registered with our "Add" until the restart, on rows `_savePodcastEpisode` can no longer
  honour. Tier 0/1 really do mirror it. The residue is accepted (with no feeds there are few
  podcast rows left to press Add on) and the comment now says which tier does what, so the next
  change here starts from the truth.

  New `tools/t_query_enc.pl`, **12 assertions** (1118 across 14 suites). Anti-tested: the pre-fix
  single spelling fails 5 — including the two that show the consequence rather than the mechanism,
  the double-encoded URL and `Sigur RA3s` — while every ASCII positive control still passes, which
  is what shows the suite is not simply failing everything. `matcher_sync_check.py` exits 0
  (nothing here touches a matcher). Podcast `CACHE_VER` bumped with the build per the dev-build
  cache rule; nothing here parses a feed, so it is hygiene, not a fix.

- **0.1.121 — ships the seventh 2026-09-03 review round's four fixes (dev build; see that
  round's ledger entry above for the full write-up).**

  1. **The `plugin.podcast:feeds` `setChange` watcher is now installed regardless of the
     Material-action pref at boot.** It was wired only inside postinit's pref-ON arm, so a
     server that starts with "Add to Material context menus" unticked ran watcher-less — ticking
     it on later from Settings registers and writes, but nothing was listening for a
     subsequently-subscribed podcast feed. The `setChange` block is hoisted out of the
     `if/elsif` to after it, gated only on Material being present; the callback itself already
     self-gates on the pref, so no behaviour changes on the ON-at-boot path (the overwhelmingly
     common one, since the pref defaults to 1).
  2. **`PLUGIN_LL_MATERIAL_ACTION_DESC` rewritten per delivery tier.** The old copy described the
     pre-tier-2 model — claimed Now Playing/queue actions go through `actions.json` and that the
     registered half "only changes at the next server restart, in both directions" — which
     stopped being true the moment the Settings save started registering on ON (0.1.111).
  3. **Spotify added to every user-facing service list in `README.md`**, and moved into the
     "carries a release year" camp — `Sources.pm` reads `release_date` off the same `$api->album`
     call that answers type and count, so it was already free. Playlist support (0.1.107)
     documented for the first time: the ≡ glyph, the four services with a playlist call, the
     no-Wish-List / never-auto-Played rules shared with a podcast episode, and the Qobuz
     personal-playlist limitation. `README.html`/`index.html` regenerated via
     `tools/make_readme_html.py`; CLAUDE.md's "WHICH SOURCES CAN SUPPLY A YEAR" table gained its
     Spotify row.
  4. **The Spotify search branch in `Sources.pm` now sends `$artistChars`** instead of the raw
     `$artist`, matching Qobuz and Tidal — the other two services in the characters camp
     (0.1.120 fixed those two; Spotify's own branch had the same shape and was missed until this
     round).

  **Test coverage added this session — all 14 suites green, 1,125 assertions** (up from 1,118):
  `t_stubs.pl`'s `setChange` now RECORDS into `@Slim::Utils::Prefs::Obj::CHANGES` instead of
  being a no-op — the earlier no-op stub is exactly what let finding 1 through six review rounds
  unnoticed (`t_material_actions.pl` already asserted the watcher, but only by grepping source,
  which matches just as happily with the call in the wrong branch). `t_material_actions.pl` now
  drives `postinitPlugin` on both the pref-ON and pref-OFF arms and adds the
  subscribe-first/tick-second ordering (1 red without the hoist). `t_query_enc.pl` gained the
  Spotty branch it never had (a camp named in a comment with no fixture is not covered).

  Podcast `CACHE_VER` bumped 25 → 26 with the build per the dev-build cache rule; nothing in
  this build parses a feed, so it is hygiene, not a fix.

- **0.1.122 — the eighth 2026-09-03 review round's two fixes (dev build; see that round's ledger
  entry above).** A version of its own rather than a fold into 0.1.121, because 0.1.121's zip had
  already been built: **a rebuilt zip always gets a new version**, or the installed copy and the
  built one are indistinguishable to both the server and its caches.
  1. **The Bandcamp search branch's encoding exemption is now stated, and tested.** It was
     listed under OCTETS in the `_searchService` comment while applying no conversion at all —
     harmless, because `_norm` makes that query ASCII-only by construction, but indistinguishable
     from an oversight. `t_query_enc.pl` gained the Bandcamp fixture it never had and asserts the
     invariant rather than the camp (5 red without it). LL's own "the search returns NOTHING"
     wording in `Sources.pm` and that suite's header corrected to the junk/degraded results round
     6 actually measured; the canonical `docs/streaming-adapter-spec.md` R6 row is deliberately
     left for the fleet pass.
  2. **`README.md`'s playlist Wish List claim corrected.** It said playlists have no *Add to Wish
     List*; the entry is shown on `playlist` and `online-album` rows and redirects to Listen
     Later. *Move to Wish List* genuinely is absent. `README.html`/`index.html` regenerated.
     README on `dev` again, for finding 3's reason and section A's exception: a user-facing
     factual error, not routine churn.

  **All 14 suites green, 1,130 assertions** (up from 1,125): `t_query_enc.pl` 15 → 20.

  Podcast `CACHE_VER` bumped 26 → 27 with the build per the dev-build cache rule. Nothing here
  parses a feed either — it is the same hygiene 0.1.121 did, and it is per BUILD, not per
  feed-parsing change.

- **0.1.123 — a container with no adapter is REFUSED instead of stored (the tenth 2026-09-03
  review round; see that round's ledger entry above).** One new gate, `Sources::unsupported-
  Container`, called from `_addCtxCommand` ahead of every branch that stores.

  **What was actually wrong.** The add path had two gates and they answer different questions:
  `_isReplayableSource` → `_serviceCan` asks about the SERVICE (Spotty is installed, so
  `spotify` says yes whatever the favurl points at), and `favurlIsTrack` asks album-vs-TRACK,
  which presumes the row is one of the two. A podcast SERIES is neither, so nothing refused it.
  **Both halves were reproduced on the test server against 0.1.122 and then removed:**
  `spotify://show:5wMPFS9B5V7gg6hZ3UZ7hf` (Serial, from a Spotty search) stored as an ALBUM row
  with no album id — replay would be a fuzzy search for an album named after the show, with the
  show's *blurb* as the artist — and `deezer://podcast:19887` (The Minimalists, Deezer →
  Podcasts → Top 100) took `favurlIsTrack`'s FAIL-OPEN branch and stored as a `kind='track'` row
  pointing `type => 'audio'` at a series url, logging the "assuming TRACK for an unrecognised
  favurl shape" warning that exists to name exactly this.

  **It is a consistency repair, not a step toward series support.** The built-in Podcasts app
  has always refused a series — a feed row resolves no episode and `_rejectAdd` says so (verified
  live on "Darko.Audio podcast"). Episodes are unaffected and still store:
  `spotify://episode:…` remains a track, and `podcast://<enclosure>` is untouched.

  **The type list, and why each is in it.** `show`/`podcast` are the series shapes. `mix` is
  TIDAL's — refused rather than routed to the playlist path because TIDAL's own plugin keeps
  them apart (`getPlaylist` takes a `{uuid}` → `$api->playlist`, `getMix` takes an `{id}` →
  `$api->mix`), so replaying one needs a getMix adapter. **Spotify's "mixes" are not this** —
  Daily Mix / Popular Playlists are plain `spotify:playlist:` URIs, reach `playlistFromRow`, and
  store as playlists exactly as before. `artist` is defence in depth: Material resolves an
  artist favurl to `online-artist`, which this plugin deliberately never defines, so no Add
  renders on an artist row — but since 0.1.51 the COMMAND is the gate precisely because it does
  not depend on Material's button.

  **The scheme split is load-bearing, and live data proved it.** `podcast` is both a Deezer type
  name and OUR OWN scheme — `Podcast.pm` stores an episode as `podcast://<enclosure url>`, which
  matches `^podcast:` at position 0. Matching the whole url unanchored would have refused every
  episode add in the plugin. The false-positive sweep below caught the real row
  (`podcast://https://feeds.soundcloud.com/stream/…`, already saved in the list) and it is now a
  fixture; removing the guard turns three assertions red.

  **A FALSE-POSITIVE SWEEP AGAINST REAL DATA, not just fixtures.** 286 distinct favurls
  harvested by crawling every installed service on the test server (Qobuz, Bandcamp, TIDAL,
  Deezer, Spotty, Podcasts, Radio Paradise, LastMix, Favourites) and run through the new sub:
  **8 refused, all of them TIDAL mixes** — the intended target, no false positive. It also
  surfaced the two Deezer Flow shapes (`deezer://user/…/flow.dzr`, `deezer://user.flow`), which
  say `user` with a SLASH rather than the `:` the legacy Spotify playlist form uses; both are
  now fixtures, because a widened type list would take them first. **Coverage limit, stated
  rather than glossed:** Qobuz and Bandcamp contributed ZERO favurls (their browse rows carry
  none — Qobuz's album id comes off the cover url), so they cannot be affected by a favurl gate,
  but the sweep says nothing about them. The crawl went two levels deep, which is why the show
  and Deezer-series rows were confirmed by hand instead.

  **All 14 suites green, 1,173 assertions** (up from 1,150): `t_favurl.pl` 133 → 156,
  `t_addpath.pl` 133 → 142. Anti-tests: stub the sub → 4 red in `t_favurl.pl`; remove the gate →
  4 red in `t_addpath.pl`, each naming the wrong shape it stored as (`album`, `track`, `album`)
  — which is why the Deezer row is asserted alongside the Spotify one. **Move the gate inside
  `favurlIsTrack` and the Deezer row merely becomes an album instead of a track, still stored,
  and a Spotify-only assertion stays green.** That is what the placement test exists for.

  Podcast `CACHE_VER` bumped 27 → 28 with the build per the dev-build cache rule.

- **0.1.124 — Deezer podcast EPISODES are supported, and the podcast docs now cover all three
  sources.** Not a review round; asked for directly after 0.1.123's series gate made the state of
  podcast support worth stating properly.

  **The gap, measured.** Deezer browses its episodes as `deezerpodcast://<id>` — a scheme of its
  OWN, not `deezer://` (verified live). `deezerpodcast` was in neither `%SCHEME` nor
  `_serviceCan`, so every episode was refused: `rejected add — unsupported source
  'deezerpodcast' via container 'deezer'`, confirmed against the live list (49 rows before, 49
  after). **0.1.123's gate was NOT the cause** — `unsupportedContainer` splits the scheme off,
  so `deezerpodcast://` names no container and passes; the refusal was years older.

  **Why it needed no adapter.** A saved episode is `kind='track'`, and a track row replays
  straight from its stored url (`_trackPlayableItems` — no album node, no matcher, no search).
  So the only question is the one `podcast` has always asked: does a protocol handler for that
  scheme exist. `_hasPodcastHandler` generalised to `_hasSchemeHandler($sample)` and
  `_serviceCan` gained one clause. Played needs nothing: `_markPlayedTrack` derives the source
  from the PLAYING url via `sourceFromUrl`, which answers `deezerpodcast` for both the stored
  row and the stream, so `findTrackByUrl` matches exactly.

  **The source tag is deliberately NOT folded onto `deezer`.** The album adapter has nothing to
  do with an episode, and a tag of its own is what lets Browse mark the row as a podcast. That
  cost two small pieces of shared vocabulary rather than more `eq` tests:
  - `Sources::isPodcastSource` — Browse asked "is this a podcast" in THREE places (glyph, type
    word, whether to print the source), each spelled `eq 'podcast'`. A fourth source would have
    been added to some and not others; that is how the three drifted apart in the first place.
  - `Sources::sourceLabel` — `ucfirst` was the whole rule until a source tag stopped being a
    service name. `deezerpodcast` would have read "Deezerpodcast" in every row; only exceptions
    are listed, so adding a service still needs no entry.

  `favurlIsTrack` also names the scheme explicitly. It would have answered TRACK anyway via the
  fail-open branch — but that branch LOGS, and its warning has to stay a real signal rather than
  firing on every Deezer episode add. Same reasoning as the Spotify `episode:` line above it.

  **Spotify episodes were already working and are deliberately NOT podcast sources.** Spotty
  plays them as `spotify://episode:<id>`, so they store under source `spotify` and read as a
  Spotify track — which is what they are. Verified stored live; PLAYBACK unverified, because
  Spotify audio is blocked on this rig ([[spotify-playback-blocked-on-test-rig]]).

  **README on `dev`, under section A's exception** — the same one 0.1.122 used. It was a
  user-facing factual error, not churn: the podcast section described the built-in app as the
  only source, and the Limits section said episodes "must belong to a show you subscribe to",
  which is true of that app and false of a Deezer or Spotify episode. It now carries a
  three-source table, states that a whole SHOW is never savable on any source, and scopes the
  subscription rule to the app it belongs to.

  **A pre-existing docs bug fixed in passing:** `README.md` wrote the show placeholder as the
  entity `&lt;show&gt;`, which `make_readme_html.py` escapes again — so the published page has
  been rendering the literal text `Podcast · &lt;show&gt;` since the section was written. Angle
  brackets cannot survive both renderers (GitHub eats a raw `<show>` as a tag), so the
  placeholder is now italics. `grep -c 'amp;lt' README.html` = 0.

  **All 14 suites green, 1,173 → 1,195 assertions**: `t_favurl.pl` 156 → 169, `t_addpath.pl`
  142 → 149. The add-path section stubs `handlerForURL` for the one scheme — and note it is
  called as a CLASS method, so the url is `$_[1]`; reading `$_[0]` silently answers "no handler"
  for everything and the whole section fails as a rejected add. It also must NOT chain onto a
  previous handler: `t_stubs.pl` defines none, so taking `\&...handlerForURL` first creates a
  forward reference that resolves to the new sub itself — infinite recursion. Both mistakes were
  made and are written into the test's comment. ANTI-TEST alongside it: the Deezer SERIES stays
  refused, so episode support cannot quietly reopen the container.

  Podcast `CACHE_VER` bumped 28 → 29 with the build per the dev-build cache rule.

- **0.1.125** — Eleventh review round, two findings, both reproduced before being fixed. **(1) A shared `actions.json` we cannot READ is no longer treated as an empty one.** `_readMaterialActions` answered `{}` for "absent", "could not open" and "malformed JSON" alike, so a hand-edit syntax error — or a file left root-owned/0600, which LMS running as `squeezeboxserver` cannot open — was OVERWRITTEN by the tier-0/1 writers and UNLINKED by the tier-2 prune, taking every other plugin's custom actions with it and logging "removed the now-empty" file about it. It now answers `undef` for unreadable and all three callers bail out without writing; an EMPTY file still reads as `{}` so the husk removal is unaffected. Safe to bail because Material streams this same file and neither an unopenable nor an unparseable one reaches `customActions` (`MaterialSkin::Plugin::_customActionsHandler` + `customactions.js`), so nothing can be doubled. **(2) The Wish List rule has one carrier.** `_wishListable(kind, source)` replaces four independent answers; a Deezer podcast episode (`deezerpodcast://`, 0.1.124) stores through `_saveTrackRecord`, which had no redirect, so it landed in the Wish List the identical built-in episode was redirected out of — and `Move to Wish List` was offered on the saved row of BOTH podcast sources, because the old exclusion tested `kind eq 'playlist'` and an episode is `kind='track'`. `_moveCommand` now asks the same carrier, since the menu is presentation and the command is enforcement (Material replays a stale page without re-querying). Spotify episodes are deliberately excluded — see §B. Tests 1183 → 1220, 14 suites green. Podcast `CACHE_VER` 29 → 30 per the dev-build cache rule.

- **0.1.126** — Twelfth review round. **(1) The uninstall/disable hook has never run.**
  `shutdownPlugin` read `plugin.state` with `__PACKAGE__`, but LMS keys that pref by the
  plugin's SHORT name — verified live (`plugin.state:ListenLater` → `"enabled"`, the module-name
  key → `null`) — so from 0.1.108 until now removing the plugin stranded every LL entry and every
  empty suppressor in Material's shared `actions.json`, where the leftovers then hid ANOTHER
  plugin's `online-*` on podcast and radio rows. The short name is derived from `__PACKAGE__`
  so a rename cannot re-open it. `dataForPlugin(__PACKAGE__)` a few hundred lines up is keyed by
  MODULE and is correct as written — the two PluginManager APIs differ, which is how this was
  got wrong. The test fixture had the same wrong key, so all six assertions passed against dead
  code; fixed, 6 red without it. **(2) Spotify podcast episodes are podcasts.** They were
  Wish-Listable, drew the ♪ note and read "Track", because `_wishListable` was asked of
  `(kind, source)` and Spotify is the one episode source with NO source tag of its own — Spotty
  stores an episode under plain `spotify` and says `episode:` only in the play url. The carrier
  now takes the url as its third fact: `Sources::isPodcastSource` is replaced by
  `isPodcastEpisode($source, $url)` at all four consumers (glyph, type word, Wish List rule,
  move command), both Spotify spellings accepted so a pre-0.1.113 row is covered too. Anti-tested
  both ways — 7+2 red reverted to the source-only predicate, 7+4 red on the positive controls if
  widened to "spotify is always a podcast". README corrected (it documented the old asymmetry as
  deliberate) and the ledger's section B entry reversed. **(3)** `_canClassifyTrack`'s comment
  corrected: Spotify's absence is a measurement (Spotty's `getMetadataFor` returns the album as a
  plain STRING on every path, so `trackAlbumId` can never answer) and adding it would also let a
  podcast series be classified as a release; Deezer, which the old comment said could not yield
  an id, can. **(4) A Spotify episode now stores what the service will report while it PLAYS.**
  Spotty's browse row sends a date-prefixed title and the episode DESCRIPTION where the artist
  goes, so the row read `<blurb> – 2026-01-05 - Mission Killer` and Played's metadata fallback
  (`findSavedTrack`, which matches artist + album + title) could never find it.
  `_saveSpotifyEpisode` asked `Plugins::Spotty::API::episode` for the show and publisher.
  **(4) WAS REVERTED IN 0.1.127 — see below. The diagnosis was right; the fix was built on an
  unmeasured guess about a third party's response shape, and its test stub was written from the
  same guess.**

- **0.1.127** — Thirteenth review round, and the one that fixed the METHOD rather than another
  symptom. The Spotify/podcast work had produced a contradiction per round for four rounds, and
  the cause was not any of the individual findings: **every Spotify fact in this file had been
  derived by reading fragments of Spotty's source instead of observing a payload, and each test
  stub was then written from the same assumption — so a stub could only ever confirm the guess
  that produced it.** 0.1.126 shipped two instances of exactly that in one release (the
  `plugin.state` fixture, caught; the episode-API stub, not).
  **(1) The identity contract is now written down** — see *Identity: what Played actually
  matches on*. A TRACK row is matched on its play URL (exact compare, `findTrackByUrl`); an
  ALBUM row on its names. Both read straight out of `Played.pm`, both were being re-derived per
  service, and neither is a judgement call.
  **(2) `_saveSpotifyEpisode` and `SPOTIFY_EPISODE_TIMEOUT` are DELETED**, and with them LL's
  only dependency on a Spotify API call. It was a 130-line per-service async subsystem with a
  six-second timeout serving the FALLBACK match — while the primary URL match, which needs none
  of it, already worked. Spotify additionally rate-limits the test account (`429`, measured), so
  that lookup could never have succeeded there.
  **(3) `_fillFromPlayingMeta` replaces it** — one carrier, no service named in it, that fills a
  blank title/artist/album from `Sources::playingMeta`, the same reader Played falls back to. The
  two ends now agree by construction instead of by prediction. Synchronous, cache-only, no HTTP,
  nothing to hang the add. Scoped to podcast EPISODES: a music track's row is already its title
  and artist, and widening it would change stored albums on Qobuz/Tidal/Deezer browse-track adds
  for no reported defect. Deezer and Spotify episodes now take the identical path — pinned by a
  Deezer case in the same test section.
  **(4) Measured at last, and recorded in section C:** Spotty's `getMetadataFor` really does
  return `url => "spotify://track:<id>"` (byte-identical to what LL stores, so the URL contract
  holds), `album` as a plain string with no id, and EVERY artist credit joined — which
  `spottyArtistName` does not store, so a multi-credit track's fallback cannot match. Harmless
  under the URL contract, and the clearest available measure of how far naming may drift.
  `isPodcastEpisode` and `stripEpisodeDatePrefix` are unchanged and still right.
  **(5) VERIFIED LIVE on 0.1.127, 2026-09-04, by driving `listenlater addctx` over jsonrpc with a
  real Spotty browse row** (`favorites_url: spotify:episode:0tQdtR5srOLPVaevOrLyhR`, whose `text`
  really is `"2025-08-25 - Mission Killer: …\n<description>"` — the diagnosis confirmed from the
  wire rather than from Spotty's source). The row stored as
  `❝ Mission Killer: "Real Life Dexter" Manny Pardo / Podcast · Spotify`: date prefix stripped,
  blurb kept out of the artist, ❝ glyph, "Podcast" type word, and the context menu offered only
  Move to Played and Remove — no Wish List. A pre-existing Deezer episode renders identically,
  which is the "no different from other services" requirement met.
  **WHAT THE FILL ACTUALLY RETURNS — corrected 2026-09-04 after a first, overstated reading.**
  The first observation was "it answers nothing" (the row stored with no show, and `songinfo`
  returned no rows for the same url), and that was written up as an absolute. It is not: with
  Spotty's cache WARM — browsing the episode list is enough — `getMetadataFor` supplies the
  episode's own TITLE, proven by an add that SENT `name:2026-01-01 - Trailer` and STORED
  `Mission Killer: "Real Life Dexter" Manny Pardo`. What it never supplies is the **show or the
  publisher**, on either path. So: the fill works and is not a no-op; the missing show is a real
  and permanent gap in what the browse row and the handler between them can say.
  **Do not "fix" the missing show by reaching for a service API — that is the thing this round
  removed.** README is correct as written: a streaming episode reads `Podcast · <Service>` with no
  show; only the built-in Podcasts app has one, from the RSS feed.
  *Recording the correction as well as the fact, because it is the third time in this area an
  absolute has been written from a single observation.* One probe showing nothing means "nothing
  here, now" — not "nothing, ever".
  Tests: `t_addpath.pl` 204 → 205, the episode section rewritten against a handler stub modelled
  on MEASURED output rather than on inferred API internals (5 red without the fill; the
  "PLAYED finds it by url" case stays green either way, which is the contract working).

- **0.1.128** — `DB::episodeKey`: a STREAMING podcast episode is keyed on its PLAY URL, not its
  title. Same problem and the same answer as `playlistKey` two subs above — the title is not an
  identity. A Deezer/Spotify episode row stores no artist and no show (measured on the live
  server: the browse row carries an episode title and a description, and `getMetadataFor` supplies
  a title once its cache is warm but never a show), so the plain track key collapsed to
  `|||t:<title>` and two episodes called "Trailer" from different shows became ONE row —
  confirmation toast shown, and the surviving row playing the other show's audio.
  Keyed on the url because that is already the row's identity everywhere else
  (`Played::_markPlayedTrack` matches `findTrackByUrl` on it first), so dedupe and matching now
  agree instead of holding two notions of sameness; and it needs no per-service id parsing.
  **Built-in Podcasts-app episodes are deliberately excluded** — they store the show in
  `album_title` from the RSS feed, so their key already carries a discriminator and cannot
  collide, and they DO exist in released builds (0.1.87, `main` is 0.1.93), so re-keying them
  would owe a migration for no defect. The rule is "an episode with no show stored keys on its
  url", which is exactly the set that lost its discriminator, and nothing released is re-keyed.
  `_migrateRefold` keeps the `|e:` tail verbatim, like the playlist `|p:` tail, so a fold change
  can never disturb an id. The metadata-fallback trade is recorded in the round entry above.
  Tests: `t_addpath.pl` 205 → 208 (4 red without `episodeKey`); blast radius probed across all six
  row shapes — album, music track, playlist, built-in podcast, Deezer episode, Spotify episode —
  and only the two streaming-episode shapes change.

- **0.1.129** — The knock-on pass the user asked for after 0.1.128, and it found two more of
  the same class. **(1) `DB::_keyForRow` is now the ONE writer of a dedupe key**, replacing five
  that had already drifted — `updateArtist`/`updateYear` rebuilt without the track segment and
  would silently re-key a track row as an album. Unreachable today (both callers sit behind
  `_finishAlbumAdd`, album-only — verified, not assumed), but the guard was in the caller, so it
  was a trap armed for the next caller rather than a bug. The carrier prefers a stored `|p:`/`|e:`
  id tail over a rebuild, which is what lets `_migrateRefold` share it instead of keeping its own
  answer. **(2) `_insertTrackRow` now dedupes on the PLAY URL first**, with no artist gate. Both
  existing guards require `length $artist` and fall back on a key that varies by add surface, so
  an artist-less track added from two surfaces stored twice for one url — the add path was the
  last place deciding sameness purely by name while Played had always matched the url first.
  **(3)** Recorded as a known residual and then **DECLINED BY THE USER** (*"the chances of that
  is very slight to occur"*): two artist-less music tracks sharing a title still collapse,
  because `DB::add` dedupes on the name key before the url check is reached. Fixing it means
  url-keying music tracks, which exist in released builds and so owe a migration — and no
  service checked emits an artist-less track row. Pinned as a limitation, closed as a decision.
  Also checked and CLEAN in the same pass: multi-artist albums, where Spotty joins every credit
  at play time (`"Kygo, Khalid, Gryffin"`) while the row may store one — `_matchRecord`'s
  `findByAlbum` + `_artistMatch` subset rescue matches in BOTH directions, so Played is not
  affected. Tests: `t_addpath.pl` 208 → 213, `t_db.pl` 60 → 66 (4 red without the carrier).

- **0.1.130** — Fourteenth review round. Three findings, **one fixed and two disproven**, and
  the two disprovals are the more useful half — both are now in Review Ledger A2 with the
  evidence, because each had a plausible "obvious fix" and one of them was a regression.
  **(1) FIXED — `_fillFromPlayingMeta` accepted a handler's ERROR TEXT as an episode's name.**
  Its header claimed a guard ("some return a placeholder while an async fetch runs… which is why
  the value has to differ from what we hold") that the code did not implement: `$t ne $$trackRef`
  only skips a redundant write. Reading both handlers that can reach it — the caller gates on
  `isPodcastEpisode` and the built-in Podcasts app takes `_savePodcastEpisode`, so it is Spotty
  and lms-deezer's `PodcastProtocolHandler`, nothing else — **the placeholder it names does not
  exist** (both answer no title at all on a cache miss), while two shapes that DO answer a
  non-empty name were being taken: Spotty's `!hasCredentials()` and `!hasSSL()` early returns set
  title AND artist to a `cstring` hint with `duration => 0`. A Spotify episode row arrives with
  `$artist` deliberately undef'd, so the fill-only path took the hint outright. Now gated on a
  positive `duration` for the whole fill — source-agnostic, and NOT to be copied onto
  `_nowPlayingFallback` (live radio reports 0 with a real title). Reachable at ADD time and not at
  play time, because this runs against a browse row that is not the playing track. Anti-tested
  both ways: gate off → 4 red naming the stored hint string; gate always-on → 2 red on the
  positive controls, so it cannot be widened into refusing every fill.
  **(2) DISPROVEN — `_migrateArtistPrefix`'s four-column SELECT, and the proposed fix breaks it.**
  Measured against a real pre-0.1.74 table rather than argued: the ladder adds `kind`/`track_title`
  BELOW that rung, so the "fixed" SELECT dies `no such column: kind`, which `eval {…} or return`
  swallows — the cleanup would silently stop running on exactly the databases needing it. The call
  site now asserts `kind => 'album'` so the invariant is stated. The other three `_keyForRow` feeds
  were checked in the same pass and are complete.
  **(3) DECLINED — the prune's `%ours` deleting an empty category by NAME.** Already settled at
  `Plugin.pm`'s `_ownedCats` header; the ledger entry now names this route too.
  **A correction made mid-round, recorded because it nearly became a finding:** the reasoning that
  Spotty's cached `'Failed to get access token'` entry makes `getMetadataFor` DIE (`@{undef}` on
  the missing `artists` key) is wrong — that is an rvalue deref, it yields an empty list. Ran it.
  The entry is harmless for an unrelated reason: it stores `title`/`duration` where the reader
  looks for `name`/`duration_ms`, so it surfaces as `title => undef, duration => 0`.
  **A stale comment removed at the call site**: "whatever it does not know it simply does not
  answer" was the 0.1.127 assumption this round disproves. Tests 1,287 → 1,292, 14 suites green;
  `matcher_sync_check.py` exits 0. Podcast `CACHE_VER` 34 → 35 per the dev-build cache rule;
  nothing here parses a feed, so it is hygiene, not a fix.

- **0.1.131** — **The podcast RSS body is decoded ONCE, before anything reads it — the feed was
  the last producer handing octets to consumers that want characters.** Not a review round: it
  came out of verifying a finding the ledger had DECLINED twice (§A2, now corrected), and the
  verification is what found the real defect somewhere else entirely.

  **Three bugs, one cause.** `Slim::Networking::SimpleHTTP::Base::content` is
  `${ $self->contentRef }` — raw bytes, no charset step anywhere above `_parseFeed` — so every
  field it pulls out is octets:
  1. **The visible one, and it needs no entity at all.** `DB`'s handle sets `sqlite_unicode`, so
     it takes CHARACTERS; handing it the raw `"Bj\xc3\xb6rk"` stores codepoints U+00C3,U+00B6
     and the list renders **"BjÃ¶rk"**. Every accented episode title and show name was stored
     double-encoded. Measured on a real DBD::SQLite 1.64 handle, not argued.
  2. **The dedupe key.** `_clean`'s `chr($1)` entity pass put byte 0xF6 into an unflagged string
     for `Bj&#246;rk`, which is not valid UTF-8, so `DB::foldLatin`'s decode failed, the accent
     fold was SKIPPED and the key came out `bj rk` against `bjork` from every other producer.
     `dedupe_key` is UNIQUE and permanent, and `Played::findSavedTrack` then never matches the
     row — **the episode can never be marked played**.
  3. **A WIDE entity beside raw UTF-8.** `chr(8217)` upgrades the whole string, so bytes already
     in it are reread as latin-1: `"La\xc3\xads Martins&#8217;"` stored as `"LaÃ­s Martins’"`,
     wrong on screen AND in the key. This is the likeliest of the three to be hit — `&#8217;` is
     common in RSS and needs only one accented character beside it.

  **Fix: `_charset` + `_decodeText`, applied through a `_cleanText` wrapper to the TEXT fields
  only.** Decoding is UNCONDITIONAL, pure-ASCII fields included — the entity pass that runs after
  it can introduce a codepoint that was never in the bytes (`Bj&#246;rk` is ASCII until `chr(246)`
  runs), and appending a codepoint to an unflagged string is bug 2. Falls back charset → utf-8 →
  cp1252, so a mislabelled feed yields text rather than dying.

  **THE URLS DELIBERATELY STAY OCTETS, and that is the load-bearing half.** Decoding the whole
  document is the obvious fix and it is WRONG: both url fields are compared with `eq` against a
  value that reaches them as octets — `DB::findTrackByUrl` against the PLAYING track's url
  (measured: as characters the JSON round-trip stops matching, so an accented episode silently
  stops being marked played, which is bug 2 by another route), and `resolveEpisode`'s image branch
  against `_realImageUrl($IMAGE)`, which `uri_unescape`s Material's escaped url and so yields
  octets too. `duration` and `pubDate` are ASCII by format. Section 3 of the suite pins the split
  rather than the fix that produced it.

  **Verified against real data, not just fixtures.** ~6,700 episodes across 7 live feeds (Simon's
  own subscription plus 6 major ones) run through OLD and NEW `_parseFeed` side by side:
  **0 url changes, 0 image changes, 0 duration changes, 0 KEY changes** — every real feed is raw
  UTF-8, so their keys were already right and the fix is inert on them; only the title BYTES move
  (octets → characters), which is bug 1 being repaired. Separately, all 244 non-ASCII
  artist/album strings from the live library were run through the real `DB::_norm` in both shapes
  real producers emit: **0 disagreements**, confirming the other producers are sound.

  **Why it was never seen in the field:** the one subscribed feed on the test server
  (Darko.Audio/SoundCloud) is raw UTF-8 with zero numeric entities, and across 8 sampled major
  feeds there were **0 latin-1-range entities** (the one feed using any had 16× `&#39;`, ASCII).
  Rare, not unreachable — and bug 1 needs no entity at all, so any accented episode title was
  already storing mojibake.

  New `tools/t_podcast_enc.pl`, **23 assertions** (1,315 across 15 suites). Anti-tested three ways
  against the real numbers: drop the decode → 10 red, skip a pure-ASCII field → 2 red, route the
  urls through `_cleanText` too → 5 red. Podcast `CACHE_VER` 35 → 36 — **a real invalidation here,
  not the usual build hygiene**: parsed feeds are cached with the mangled titles.

  **Known residual, accepted and MEASURED — no migration rung. See the ledger entry in §A2, which
  separates the two damage classes and states what a re-raise needs.** Rows stored before this
  build keep whatever they were given: a mojibake'd TITLE (display only — its key was always
  correct, which is why the real-feed run showed `KEY_changed=0`), or, only from a latin-1-range
  numeric entity, a wrong KEY (never marked played, and re-adding makes a second row). Zero of
  either on the live list — read back over jsonrpc 2026-09-04, 44 rows, 38 non-ASCII, all albums
  from already-decoded producers and **0 showing mojibake**.

- **0.1.132 — a tapped podcast episode resolves by SCORING both signals, not by trying one and
  then the other.** Fixes the two defects the 2026-09-04 podcast audit found in
  `Podcast::resolveEpisode`, the built-in Podcasts-app path. Neither had ever fired on this box,
  and the measurement is why: resolution needs a feed that REUSES artwork, and Darko.Audio — the
  only subscription here — carries a unique image on all 129 episodes.

  **1. Artwork is not an episode identity.** The header called it "the primary key … unique per
  episode"; `Slim::Formats::XML::parseXMLIntoFeed` gives every item the CHANNEL image and overrides
  it only where the item has its own `<itunes:image>`, and `_parseFeed` mirrors that fallback
  deliberately. So on a feed with no per-episode art every image is identical, and an order that
  tried image FIRST and returned on either signal answered **episode 1 for every tap** — including
  a tapped SHOW row, which is what `Sources.pm`'s "the Podcasts app already refuses a series"
  rests on. Measured across five real feeds: *Tech Won't Save Us* 351 of 360 episodes share one
  image, *The Daily* ~1,120 of 2,968.

  **2. An earlier feed's title collision beat a later feed's exact match.** Feeds were walked in
  subscription order and ANY signal returned immediately, so per-episode artwork did not protect
  you — "Trailer", "Introduction" and "Episode 1" are titles many shows share.

  **The fix is a SCORE because neither signal is an identity on its own**, so no fixed order of
  two `elsif`s can be right: 3 = title AND image, 2 = image unique within its feed, 1 = title only,
  **0 = image shared within its feed, which is not a candidate at all** — it names the show. Ties
  keep the earlier subscription. The walk short-circuits on a 3, so the ordinary add still costs
  one feed fetch; only an imperfect match pays for the rest, and they are cached.

  **The failure mode was the bad one, not a refused add:** a wrong row is internally consistent —
  the resolved episode's own title AND url — so it renders correctly, plays the wrong audio, and
  **cannot be identified after the fact**. There is no repair migration to write and none is owed:
  no schema change, no stored-shape change, same `podcast://<enclosure>` row, only which episode.

  **Why a full podcast rewrite did not surface it: `resolveEpisode` had no coverage at all.** Its
  only appearance was `t_addpath.pl`'s stub, which returns the tapped title as the resolved title —
  correct by construction, so no assertion in 1,315 could fail for this reason. Fourth entry in this
  file's stub-written-from-the-same-assumption series (0.1.94 prefs, 0.1.98 RemoteTrack, 0.1.126
  `plugin.state`). New `tools/t_podcast_resolve.pl`, **23 assertions** (1,338 across 16 suites).
  Anti-tested three ways and the numbers are MEASURED against copies of the tree, not asserted:
  the pre-fix sub 10 red, dropping the per-feed image-uniqueness test 3 red (all three are the
  series refusal), returning on the first feed with any candidate 3 red (every cross-feed case).

  **Also corrected in the same pass, comment-only:** `DB::episodeKey` and `_insertTrackRow` justify
  URL-keying a streaming episode with "a streaming episode row stores NO artist and NO show …
  never a show or publisher". That is false — Deezer's `getMetadataFor` sets
  `album = podcast->title`, and Spotty's `API/Cache.pm` sets `album->name = show->name` AND
  `artists = [show->publisher]`. **The DECISION stands and must not be reverted**; its real
  justification is the one already beside it — on a cold handler cache nothing fills and the key
  collapses to `|||t:<title>`, which collides across shows. And `Podcast.pm`'s "a positional
  item_id that Material never passes on" is wrong on the second half: `$ITEMID` is in Material's
  `ACTION_KEYS` and is substituted at `customactions.js:156`. It is genuinely positional
  (`XMLBrowser` builds `<parent>.<index>`; `Slim/Formats/XML` copies no `id` and drops `<guid>`),
  but durability governs what you STORE, and resolution happens at add time against the feed on
  screen. Using it was **considered and not taken here**: `_parseFeed` drops enclosure-less items
  so the indices skew (measured), and the feed segment is offset by however many search providers
  are registered. Recorded so the next round starts from the measurement rather than the comment.

- **0.1.132 audit residue — two podcast facts checked and recorded, neither fixed. Do not
  re-raise either without a real row.**

  **1. A BUILT-IN podcast episode CAN still collide, and "cannot collide" was too strong.**
  `DB::episodeKey` excludes the built-in app because those rows store the show, and the comment
  concluded their key "cannot collide". It carries a discriminator against other SHOWS; it does
  not against a sibling episode of the SAME show. Measured against a real SQLite DB:

      same show + same title + same YEAR   -> COLLIDES, second add swallowed, row keeps ep1's url
      same show + same title, diff year    -> distinct (the year segment separates them)
      same title, different shows          -> distinct (the show segment separates them)
      no <pubDate> in the feed             -> COLLIDES (year segment empty)

  **Population, read from real feeds rather than estimated:** 3 of 2,968 episodes in *The Daily*,
  and 0 in *Joe Rogan* (2,747), *Planet Money* (355), *Tech Won't Save Us* (360) and Darko.Audio
  (129). No feed sampled omits `<pubDate>`. **Left as-is deliberately:** the fix is url-keying
  these too, which owes a `user_version` rung because built-in episodes ship from 0.1.87 while
  `main` is 0.1.93 — and a permanent rung rewriting a UNIQUE column is where this file's most
  expensive bugs have all lived, for 0.1% of one feed.

  **CLOSED BY THE USER 2026-09-04 — do not re-raise this, and do not re-propose the "tell the
  user it is a different episode" mitigation that was offered alongside it.** *"Enough time been
  wasted on stuff for podcasts that won't likely bite a user, and if they did it's not the end of
  the world."* Two corrections that support that call and were overstated when this was first
  written: (1) **the damage is NOT a wrong row.** No row is created; the existing row is correct
  and plays correctly, and what is lost is the SECOND save plus a misleading "Already in your
  list" toast. The wrong-audio framing was carried over from the ARTWORK defect, which is a
  different bug with a different outcome — do not conflate them again. (2) **It has nothing to do
  with caching.** The play url is resolved once at add time into `ref_json` and never re-derived,
  so no `CACHE_VER` bump, `FEED_TTL` expiry or feed rotation can touch a saved row — which is also
  why the resolver fix owed no migration.

  **2. Played's METADATA FALLBACK IS DEAD FOR ALL THREE PODCAST SOURCES, the built-in one
  included — so the exclusion above buys nothing on the Played side.** The built-in handler has
  no `getMetadataFor` of its own and inherits `Slim::Player::Protocols::HTTP`'s, which answers
  remote-metadata-provider/WMA data and never a show. So at play time album is `''` while the row
  stores the show, and `findSavedTrack` misses — measured: it MISSES with `album=''` and would
  HIT if the show were published. The url is the only working route on every source, which is the
  contract already at the top of this file. **The consequence worth keeping:** the built-in
  exclusion is justified ONLY by "no released row is re-keyed", never by the fallback still
  working there. It does not.

  **3. RAISED AND WITHDRAWN — the Spotty `@{undef}` "fatal deref". THE LEDGER ALREADY SAID SO
  AND WAS NOT READ.** The 0.1.132 audit reported `join(', ', map { $_->{name} } @{ $cached->{artists} })`
  in Spotty's `getMetadataFor` as a die under `use strict` for an episode with no publisher, and
  that claim was written into `Plugin.pm`'s handler table as fact before anyone ran it. **It is
  wrong**: an rvalue deref of undef yields an EMPTY LIST, strict or not, so the branch answers
  `artist => ''`, the fill's `length` test rejects it, and nothing is written — the correct
  outcome, reached with no exception at all. Section C's 0.1.130 entry records this exact
  reasoning being raised and withdrawn, with "Ran it" against it. **The gate at the top of this
  file — read A and B, and check C's closed findings, BEFORE reporting — exists for precisely
  this, and skipping it cost a version.** Corrected in 0.1.134. Do not re-raise it a third time.

  **4. NOT a risk, measured so it is not raised as one:** the scoring walk's cost. On the largest
  real feed sampled (*The Daily*, 19 MB, 2,968 episodes) `_parseFeed` takes 0.160s, the per-feed
  image-uniqueness count 0.5 ms, and a full no-early-exit score sweep 18 ms. The parse is linear,
  not quadratic, so 0.1.131's decode-to-characters did not introduce that trap. The only real
  cost of walking further is the HTTP fetch of additional feeds, which is cached for FEED_TTL and
  only happens when no candidate scores 3.

- **0.1.135 — the podcast resolve walk gets its OWN clock, so a match it has already found is
  answered with rather than thrown away.** One finding from the 2026-09-04 review round, and it
  is 0.1.132's scoring walk meeting `_savePodcastEpisode`'s timer.

  **The defect.** Only a perfect 3 (title AND image) short-circuits the walk. A correct
  title-only 1 or unique-image 2 therefore keeps fetching every REMAINING subscribed feed with
  the answer already sitting in `$best` — and the only clock over that was the caller's single
  20s budget, which equalled ONE feed's `HTTP_TIMEOUT`. So one slow feed *after* the match fired
  the outer timer, `$finish->(undef)` rejected the add, and the episode that had been found was
  discarded. Roughly ten feeds' cumulative latency on a cold cache did the same. It is reachable
  whenever `$wantImage` is empty (`$IMAGE` unpopulated, or not an `http(s)` imageproxy url),
  which caps every score at 1. **A regression, narrowly:** pre-0.1.132 the walk returned on the
  first hit, so a dead feed after the match could never reach the add at all.

  **This is the hole in 0.1.134's point 4**, which measured the walk's CPU cost (0.160s to parse
  the largest real feed, 18 ms for a full score sweep) and concluded the only real cost of
  walking further was cached HTTP. True, and beside the point: the cost that mattered was not
  latency, it was that the latency was spent against a budget whose expiry DESTROYS the result.
  Measuring the walk in isolation could not see it; the two clocks had to be read together.

  **Fix, and the shape of it matters.** `RESOLVE_BUDGET` (15s) is the WALK's own clock, checked
  before each next fetch — when it runs out the walk stops and `$finish` answers with the best
  match it has. Each feed's fetch is capped at whatever is left of that budget (floored at 1s,
  never above `HTTP_TIMEOUT`), so one hung feed cannot spend the lot on its own. The caller's
  timer stays, demoted to a backstop and DERIVED as `RESOLVE_BUDGET + 5` so the two cannot
  cross again — when they were both 20 there was no ordering between them at all, which is the
  whole bug. Under budget nothing about the score moves.

  **NOT the fix that was offered first: short-circuiting on any positive score.** That is
  0.1.132 reverted — a title-only 1 in the first feed would beat a 3 in the second, which is
  exactly the cross-feed collision the scoring walk exists to prevent. The trade actually made
  is narrower and is pinned in the suite: once the budget is spent, the match in hand wins over
  a better one there is no longer time to find, because the alternative is not the better match,
  it is the add being rejected and nothing stored.

  **The cap's OWN knock-on, found by asking what else the change touched rather than by it
  going wrong in the field, and fixed in the same build — `_warmFeeds`.** A fetch that times
  out writes NEITHER cache (only a parse with items sets `$key` and `$fbKey`), and every fetch
  is now capped below `HTTP_TIMEOUT` — so a feed slower than the budget could never be fetched
  by the walk at all, and would stay cold for ever. Before the cap that case healed itself by
  ACCIDENT: the outer timer rejected the add, but the uncapped fetch underneath went on to
  complete and cache, so the next add resolved. The cap would have removed the accident and put
  nothing in its place. So when the budget stops the walk, every subscribed feed not already
  cached is warmed in the background — serial, fire-and-forget, full timeout, `%WARMING`
  guarding against a second sweep. Nothing waits on it: the add has already answered.

  `t_podcast_resolve.pl` §7, **9 new assertions** (1,347 across 16 suites). Anti-tested against
  reverted copies of the tree, not reasoned about: drop the budget check → 2 red (the walk
  overruns and answers the LATER feed, which is the discarded-match case); drop the per-feed cap
  → 2 red; drop the warm call → 2 red. `t_load.pl`'s called-vs-defined check also learned `use constant`, which defines a
  real sub — `Plugin.pm` now calls `Podcast::RESOLVE_BUDGET()` across packages and the checker
  reported it as undefined, a false positive indistinguishable from a true one.

- **0.1.141 — the six STANDING ACCEPTED ledger entries, closed.** Not a review round: these were
  the entries accepted as REAL and left alone on probability or cost rather than being disproven.
  Five changed, one confirmed as Material's limitation rather than ours. **Two carry a behaviour
  change a user can see**: two artist-less tracks that share a title now store as two rows instead
  of collapsing into one (`DB::trackUrlKey`, and it owes NO migration rung — the collision is
  disambiguated lazily, so no stored key is rewritten), and the Material prune now NAMES every
  empty category it removes, flagging separately the ones claimed by a retired name alone. The
  rest are a migration warn that named the wrong schema version, a guard on the podcast purge's
  reach into `Sources` that aborts the rung rather than deleting on a question it cannot answer,
  and one duplicate ref extraction folded away. **The round entry in the Review Ledger above is
  the record** — including the remedy this file itself had written down for one of them, which
  turned out to be impossible, and the four separate ways a green suite proved nothing.

- **0.1.142 — the 2026-09-10 review round, part 2: three findings against the `|u:` key, all
  REPRODUCED, and NO shipped code changed.** The round's whole output is tests and a ledger
  entry, which is the correct outcome when the findings are real at one layer and closed at
  another. **(1)** `DB::add`'s lazy disambiguation is not idempotent — delete the title twin and
  a re-add of the url-keyed track stores a SECOND row for one play url, measured by calling
  `DB::add` directly. It is unreachable, measured the same way: the identical sequence through
  `_addCtxCommand` is refused, because `kind='track'` has exactly one caller and
  `_insertTrackRow` checks `findTrackByUrl` first. Fixed by PINNING THE CALLER, not by adding a
  url check to `DB.pm`, which would make "same url = same track" a two-carrier concept.
  **(2)** A `|u:` row is reachable only by `findTrackByUrl` — both name finders anchor on a
  `|t:` suffix it does not carry. Driven through `Played::_markPlayedTrack`: a drifted stream
  url with artist-less metadata marks the title twin. Recorded as a LIMITATION, because the
  pre-0.1.141 control marks the same wrong row and the exact-url case got strictly better.
  **(3)** The no-url arm had ZERO coverage — the fixture that looked like its control was
  passing a favurl, and `length $mine && length $their` could be deleted with all 15 suites
  green. What it prevents is a `|u:` key built around an EMPTY url. Five new assertions in
  `t_addpath.pl` (1,452 → 1,457), each shown red against the code with its guard removed.

- **0.1.148 — the purge report's own em dashes were double-encoded. ONE-LINE CLASS OF FIX, plus
  the coverage that could not have caught it.**
  `_writePurgeReport` opens with `>:encoding(UTF-8)`, which encodes CHARACTERS. Row values are
  already characters (`dbh` sets `sqlite_unicode`), so they were always fine — but `DB.pm` has no
  `use utf8`, so the module's own `—` was three octets that the layer encoded a second time. The
  first line of the user's only recovery record read `Listen Later â<80><94> podcast rows
  removed`. Now `\x{2014}` at both literals.
  **Why the fix is NOT `use utf8` on the module**, and do not "tidy" it into one: that pragma
  would also reclassify ~20 log literals into wide characters bound for a log handle whose layer
  this repo does not control and cannot test, plus two SQL comments inside the CREATE TABLE
  heredoc. The escape is scoped to the one sub that has an encoding layer — and it is the only
  such layer in the plugin (`grep` for `>:encoding` finds exactly one write site).
  **Why 15 green suites missed it for 12 versions:** every assertion on the report was ASCII, and
  a double-encoded file is still VALID UTF-8, so reading it back with the same layer SUCCEEDS.
  Only the eye catches it. Four new assertions in `t_podcast_purge.pl` (45 → 49) close that:
  the header dash must survive as one character, the mojibake sequence must be ABSENT, and a CJK
  show name and a Cyrillic title carrying its own em dash must both come through intact.
  **ANTI-TEST, measured not assumed:** restore the literal dash and exactly 2 go red while both
  row-value assertions stay green — the split that proves the layer was never at fault.
  Suites 15/15 green at 1,566 assertions.

- **0.1.147 — the empty-artist finding RETRACTED for the third time, and a comment moved back
  onto the sub it describes. DOCS + ONE COMMENT. No behaviour change, no rung, no cache bump.**
  The 0.1.146 review round raised the artist gate in `_albumMatches`'s new short-title branch:
  the branch rejects an empty artist on OUR side but `_artistMatch` answers 1 whenever either
  side is empty, so a candidate with no artist would pass. **True about the branch, false about
  the world.** Simon: *"empty artists do not exist … we need an artist field, unless its a
  podcast"*, and then, of enforcing that at the add gate, *"no dont change that, that was just
  my assumption"*. Both halves are now in §A2 — the rule, and the fact that it is NOT a spec for
  `_saveTrackRecord`.
  **What made this the third round on one non-population:** the two earlier declines were both
  written about the RECORD side (our stored row), so a finding about the CANDIDATE side (the
  artist a service returns) read as new ground. It is not. All five branches take the candidate
  artist from an ALBUM SEARCH result and every service credits an artist on an album; the `''`
  in `ref $a->{artist} eq 'HASH' ? … : ''` is a shape default against a malformed response. The
  finding also needed a saved album normalising under 2 characters AT THE SAME TIME. The §A2
  entry is therefore written per-SIDE — candidate, record, playing — so the next round cannot
  find a fourth door.
  **The one real change:** inserting `_punctNorm` at 0.1.145 stranded `_albumMatches`'s contract
  line ("Candidate title must BE or START WITH our album, and artists must match") on top of
  `_punctNorm`, leaving `_albumMatches` with no header and pointing `_punctNorm`'s "the branch
  below" two subs away. Comment moved back; `_punctNorm` now names the branch it serves.
  15/15 suites green at 1,562 assertions, unchanged — a comment move cannot move a count, which
  is the whole reason this build carries no new assertion.

- **0.1.146 — the 2026-09-10 review round: one finding, DIAGNOSTICS ONLY. No behaviour
  change, no rung, no cache bump (nothing in the tree carries a `CACHE_VER` since the podcast
  path went in 0.1.136).**
  `_migrateCrossSourceIdentity` counted its new fold-split skips into `$skipped`, whose summary
  called every row in it mixed-status — so a database whose only skip was a fold split logged
  *"3 mixed-status row(s) left unchanged"* about rows no two statuses were ever involved in, and
  which the refold rung rekeys moments later. REPRODUCED by driving `_migrate` on a seeded v6
  database (中島みゆき/歌姫, サカナクション/新宝島, Кино/Группа крови, all on `'||'`), and
  confirmed against a mixed-status CONTROL that must keep the old wording.
  **Fix: one counter per cause.** `$split` is separate from `$skipped`, the `info` line joins
  only its non-zero clauses, and no clause claims what a LATER rung will do — a failed group
  here withholds the stamp and the refold rung then waits, so such a promise would be a lie in
  exactly the case that matters. A third skip reason gets a THIRD counter; a counter here is one
  cause, not "rows untouched".
  **Reachability, and why this is dev-only TODAY.** Released `main` was 0.1.93 at the time,
  stamping at most 4, so a released database is refolded by rung 5 before rung 7 groups anything
  and the guard never fires — MEASURED at entry 4 and entry 6, no row lost either way. **That
  verdict expires at the merge that releases these rungs.** The standing rule is in §A2: read the
  baseline off `main` every round, never quote a remembered number.
  Also in this build: the round written up in §C, and §A2's new reachability rule. Suite
  unchanged and green — 15 suites, 1,562 assertions.

- **0.1.145 — LL takes the two fleet matcher rules it never received. MATCHER ONLY; nothing
  here is persisted, so no rung and no cache bump.**

  **It was MISSED, not decided.** The stylised-letter rule landed 2026-07-21 as PFR 0.7.8 across
  the four full matcher copies. LL did not join the matcher sync until 0.1.112, and that port was
  scoped to the THREE Discography-origin rules — it took two and skipped the compound-word
  collapse with a stated reason. This is a fourth rule of different origin and date and appears
  in the 0.1.112 entry neither as taken nor as skipped. Nothing ever weighed it for LL.

  What it cost: `_artistMatch` is an exact-token SUBSET test, so `P!nk` keyed `p nk` against
  `pink` and matched NOTHING — **the row silently never moves to Played**, LL's core feature,
  the same failure the apostrophe rule fixed in 0.1.112. Measured: P!nk/Pink, Ke$ha/Kesha and
  $uicideboy$/Suicideboys all went from no match to match. `Wham!` and `Panic!` already worked,
  because a decorative mark falls through the separator pass either way — **the gap was only a
  mark standing in for a LETTER.**

  - **Placed at the TOP of `_punctPass`, above both existing substitutions.** That sub is shared
    by `_norm` and `_normStrict`, which 0.1.112 requires (the gate normalises a candidate and
    `_bestMatches` re-reads the SAME one). **The `_+` before `[^\w]+` order 0.1.144 fixed is
    untouched** and is pinned by three assertions on the ripped-file shape.
  - **The `&`/`+` arm changes the token SET and cannot cost a match**, because the subset test
    absorbs the extra token — asserted in both directions. It DOES change the Bandcamp outbound
    query text, so that was re-verified LIVE rather than reasoned: the same album returned the
    same hit count in both spellings over jsonrpc.
  - **The `else` branch of the `!` rule is the non-obvious half** and is pinned directly
    (`!!!` → `iii`). Deleting it sends an all-marks name to `''`, and LL's gates read empty as
    ABSENT, which is the 0.1.143 bug in a new costume. LL's own all-marks fallback still catches
    a name with NO mapping (`†††`), where the fleet answers `''` — **a BENEFICIAL variant, do not
    level it away.**
  - **The short-title escape hatch came FROM the fleet**, the reverse of the usual direction.
    `length $albumNorm < 2` had rejected `( )` and any one-character CJK title outright.
    `_punctNorm` is byte-identical to the fleet's and now reports IN SYNC across all five copies.
    **The artist gate on that path is MANDATORY** — the one place LL is not lenient, because a
    match that thin cannot stand on the title alone. `_albumMatches` gained a fifth arg
    (`$albumRaw`); all five call sites are in `Sources.pm`.

  **A GAP IN `matcher_sync_check.py` WAS FOUND AND CLOSED, and it had been giving false
  assurance.** LL's `_norm` DELEGATES its fold to `_punctPass`, which the check never hashed — so
  0.1.145 changed LL's entire punctuation pass and the check still reported LL's `_norm`
  "variant OK". `_punctPass` is now in `SUBS` **and pinned**, because a single copy is never
  compared against anything and listing it alone would have been theatre. Anti-tested: delete one
  line of the pass and it reports a `_punctPass` PIN MISMATCH while `_norm` still reads OK.
  Also re-pinned `_norm`/LLDB, which 0.1.144 changed and left stale, and whose note still said
  "rung 8".

  **THE KEY HALF IS DECLINED — Simon, 2026-09-10, and it is a SCOPE decision, not a cost one.**
  `DB::_norm` has none of these rules, so `P!nk` and `Pink` key as two rows. That is CORRECT:
  *"if any service has one variant over another we should not try to merge them they should be
  two entries. No user will add same album from different service its just not going to happen in
  real usage. We add what the service gives us."* LL stores what a service handed it; a spelling
  variant is that service's rendering of the release, not a duplicate to reconcile.
  - **Nothing to build — it is already the behaviour.** Verified on 0.1.145: `p nk|funhouse|2008`
    against `pink|funhouse|2008`. The case that prompted the decision is `-ii- – Ars Erotica`,
    where Bandcamp renders `Ars Erotica : Volume I` and Deezer renders `Ars Erotica, Vol. I` —
    keys `ii|ars erotica volume i|` and `ii|ars erotica vol i|2026`, two entries.
  - **The MATCHER not linking that pair is accepted too**, same reasoning: LBF carries one
    streaming match plus a separate Bandcamp link and they were never expected to agree. **Do not
    "fix" `volume` against `vol` on the strength of this pair.**
  - **DO NOT GENERALISE TO THE FLEET.** Discography is the opposite case — it folds variants so
    one artist's albums line up across sources, which is its whole job. This decline follows from
    LL storing what it was given rather than reconciling a catalogue.
  - The cost argument that previously deferred this (a MERGING rung, the `&` arm alone moving 8
    of 20 sample names) still holds and is now moot. If it is ever reopened, the guard 0.1.144
    put on `_migrateCrossSourceIdentity`'s DELETE is what stops rows the new rule brings TOGETHER
    being settled by a pass that ran against the older spelling — **do not remove it as
    redundant** — and the ladder in `_migrate` must be re-read for the current top rung.

  Tests 1,527 → 1,562 across 15 suites, all green.

- **0.1.144 — three defects in 0.1.143's own fold release, all REPRODUCED before being fixed.
  The release written to stop non-Latin albums being lost could destroy them, and its "pure
  split" claim was false for ordinary Latin titles.** None of it shipped past `dev`; `main` is
  0.1.93. The two 0.1.143 ledger claims this falsifies are corrected in place above rather than
  left standing, because a wrong claim beside a verdict is what this file keeps being bitten by.

  **(1) THE MIGRATION LADDER DELETED ROWS THE REFOLD WAS ABOUT TO SPLIT.** Rung 7
  (`_migrateCrossSourceIdentity`) merges rows that share a STORED key, and it ran BEFORE the new
  refold. A database at `user_version` 5 or 6 still holds keys written under the fold that ERASED
  a non-Latin name, so 中島みゆき/歌姫, サカナクション/新宝島 and Кино/Группа крови all sit on
  `||` — three albums, three services, one key. **Measured on a real ladder run: three rows in,
  ONE out.** Rung 8 then rekeyed the survivor, and the other two saves were gone. Versions 4 and
  7 are safe (at 4 the refold runs first as rung 5; at 7 the merge has already happened), so the
  window is a dev install that ran 0.1.112–0.1.136 and then jumped here — narrow, and the exact
  loss the release exists to prevent.
  **Fixed as a precondition on the DELETE, not by reordering the ladder.** Before merging a unit
  rung 7 now asks the CURRENT fold whether those rows are one album; if the fold tells them
  apart, the whole unit is left for the refold rung. That holds however the rungs are ordered and
  on every later retry, where a reordering holds for one ladder shape only. It does not violate
  the rung's "do NOT recompute keys here" rule: nothing is written, and the rung still only ever
  stores a key a row already holds. **The control is the half that matters** — a genuine
  cross-source duplicate must still merge, or the guard has simply disabled rung 7.

  **(2) THE FOLD'S TWO SUBSTITUTIONS RAN IN THE ORDER THAT DOES NOT COMMUTE.** `[^\w]+` ran
  before `_+`, and `_` is a \w character, so it stayed out of the separator run beside it and
  each one became its own space: `01_-_Intro` → `01   intro` where 0.1.142 gave `01 intro`. Five
  of twenty-three ordinary Latin inputs moved — every one the ripped-file `Artist_-_Album` shape
  — so the "rekeys ZERO rows in a Latin-only library" property the whole migration was sold on
  was false. `Sources::_punctPass` carries the same two lines, so it broke the LIVE match too: a
  saved `Boards_of_Canada_-_Roygbiv` stopped matching the service's `Boards of Canada - Roygbiv`,
  which `_albumMatches`/`_bestMatches` compare with `eq`. One-line fix in each carrier, and those
  two are the ONLY carriers in the fleet — the other repos still run the old `[^a-z0-9]` pass.
  **Why every test missed it:** an underscore BETWEEN word characters is its own whole run and
  folds identically either way, so `under_score` and `M_A_N_D_Y` pass against the bug. Only an
  underscore ADJACENT to other punctuation can show it, and neither `t_db.pl`'s Latin controls
  nor `t_refold.pl` §4j2 seeded one.

  **(3) A DEV DATABASE ALREADY STAMPED 8 WOULD HAVE KEPT THE WRONG KEYS.** Fixing (2) changes
  what `_norm` answers, so a database that ran 0.1.143 holds keys nothing will look up again.
  The refold rung now stamps **9** instead of 8, so such a database re-enters and is corrected;
  a database below 8 arrives exactly as before. Moving the stamp beats adding a tenth rung, which
  would run the identical pass twice everywhere else.
  **What it cannot repair:** rows rung 7 already deleted under (1). They are gone and only the
  user can re-add them, which is why (1)'s fix is a guard on the delete rather than a reordering.

  **(4) BANDCAMP'S SEARCH QUERY ACQUIRED A CAMP AND NOBODY NOTICED.** Its branch was exempt from
  the characters/octets split for one stated reason — it sends `_norm("$artist $album")`, which
  the old fold made ASCII by construction. 0.1.143 ended that invariant without touching the
  branch: `_norm('米津玄師 Lemon')` is now a real wide string. The comment beside it had already
  written down what to do when that day came ("it acquires a camp and must pick one — Bandcamp's
  own layer wants octets"), so the fix is that instruction being carried out. **Corroborated
  rather than reasoned:** the sibling ListenBrainz plugin calls the very same function and pins
  it as `query_enc => 'bytes'`, encoding at its own call site — two plugins were handing one
  function opposite spellings. Latin and accented artists are unaffected, which is why the suite
  stayed green.
  **MEASURED LIVE ON THE SERVER AFTER INSTALL (2026-09-10), and it is worse than "wrong results".**
  The same query was put through the Bandcamp plugin's own Search row over jsonrpc in both
  spellings. ASCII (`kristin hersh sugar on blackstone`) returns 4 hits either way — the invariant
  that hid this for a version. `sigur rós von` as CHARACTERS returns `Unknown error: 400 Bad
  Request` and as octets returns 7 hits. `Кино группа крови` as CHARACTERS **kills the request**:
  the connection closes with nothing, and the server log shows `Wide character in subroutine entry
  at Slim/Utils/DbCache.pm line 157` followed by `Bad dispatch!`; as octets it returns 18 hits
  including the exact `Группа Крови (Album) | Кино`. So Bandcamp caches its search on the query
  string and `DbCache->set` dies on a wide character — inside an async coderef under
  `Slim::Plugin::OPMLBased`, where **our callback never runs and we log nothing at all**. Under
  0.1.143 a saved non-Latin Bandcamp album would therefore have hung on replay with an empty log,
  not merely mismatched. `Sources::_norm` was confirmed to hand the branch a `utf8`-flagged string
  for Cyrillic, and the octets `_searchService` now builds are byte-identical to the spelling
  measured above. Do not repeat Search Hub's comment that a `query_enc` mistake "does not error,
  it silently returns nothing" — that holds for Qobuz, Tidal and Deezer, not for Bandcamp.
  **`t_query_enc.pl`'s Bandcamp section was the guard for exactly this and it did not fire**,
  because every fixture was accented LATIN and `Sigur Rós` still folds to `sigur ros`. All three
  ASCII-only assertions passed while the exemption underneath them was gone. **An invariant about
  character RANGE has to be tested with a character outside the range that motivated it.**

  Tests 1,513 → **1,527 across 15 suites**, and the three suites that pinned the false claims now
  pin the true ones. Anti-tested per fix, each against a copy of the tree with only that fix
  reverted: the ladder guard 4 red at versions 5 and 6 while the genuine-duplicate control stays
  GREEN (which is the asymmetry, not a detail — a guard that refused every merge would pass the
  other four); the fold order 3 red in `t_db.pl` plus §4j2 naming both offending rows; the
  Bandcamp encoding 2 red with the ASCII and latin-1 controls still passing. The ladder-version
  assertions across three suites moved 8 → 9 with the stamp.

- **0.1.151** — **Two stale comments corrected; no runtime change.** A review found both, and
  in each case the CODE was right and the PROSE had gone out of date, so this build ships
  identical behaviour to 0.1.150 and 16 new assertions that stop the prose drifting again.
  (1) `Sources::_punctPass`'s all-punctuation fallback listed `('!!!', '†††', '+/-')` as the
  names that reach it. That is `DB::_norm`'s list, copied onto a sub with two extra rules
  ahead of the fallback: `'!!!'` is folded to `'iii'` by the else branch (deliberate, and
  stated as such eleven lines above) and `'+/-'` to `'and'` by the 0.1.150 `&`/`+` rule, so
  only `'†††'` ever arrives. The examples are now the ones no rule above claims, with the
  divergence from `DB::_norm` written down as intended rather than as an oversight to sync
  away. Pinned in `t_refold.pl` §3f. (2) `findByArtistAlbum`, `findTrackByArtistTitle` and
  `findByAlbum` justified passing no ESCAPE on their LIKE patterns with "the normalised parts
  contain only `[a-z0-9 ]`" — a range 0.1.143 ended when `_norm` stopped erasing non-Latin
  names. Omitting ESCAPE remains correct, but on `_norm`'s strip rules (`'_'` dropped before
  the non-word run, `'%'`/`'|'` non-word, `[\s%_|]` stripped in the fallback), which is what
  the three comments now say. Same invariant-death 0.1.150 fixed for the Bandcamp query and
  `t_query_enc.pl`; these three sites were missed then. Pinned in `t_db.pl`, including the
  mixed shape the existing assertions did not cover — a metacharacter among marks (`'!%!'`),
  where a leak would land in a live non-empty key rather than an empty one. Both entries are
  in CLAUDE.md §A2. Suites 1,575 -> 1,591 assertions, all green.

- **1.0.1** (dev, 2026-09-16) — **Spotify albums: Played matches by release id, and a sibling's
  row shows the album it matched to.** Two causes were measured on plex:9000 (CLAUDE.md §B, `A
  SPOTIFY ROW'S STORED ALBUM TITLE CAN NEVER MATCH`). (1) Spotify's favurl cannot carry `&al=`,
  so a Pitchfork Reviews row stored its label (`The Cure - Mixed Up`) as the title. (2) Spotty's
  `cleanupTags` cleans the album only at PLAYBACK (`Mixed Up (Remastered 2018 / Deluxe Edition)`
  plays as `Mixed Up`), so even a native keyword add never matched, and the 2018 remaster's play
  marked a saved 1990 `Mixed Up` instead. Changes:
  - `Played::_matchRecord` first asks `_spotifyAlbumRecord`. It reads the playing track's album
    id from Spotty's track cache (`API->trackCached`, `noLookup`, no Web API call) and looks it
    up with the new `DB::findAlbumBySourceAlbumId` (`kind='album'` only). Any miss falls through
    to the title doors unchanged.
  - A Spotify add with no `&al=` now takes Spotify's own album name from the backfill it
    already makes (`_titleFromLabel` → `DB::updateAlbumTitle`, re-keyed through
    `_updateIdentityField`, merging with a same-list native twin).
  - A first, title-based attempt was reverted unapplied earlier the same day.
  - Qobuz, Tidal, Deezer, Bandcamp and library are untouched.
  - Suites 1,591 → 1,619 (t_played +12, t_db +13, t_addpath +3), each anti-tested.
  - Display title verified live. The id door could not be: Spotify audio does not play on the
    rig. (Settled at 1.0.3 — that test is DEFERRED and classed OK until a user reports
    otherwise.)

- **1.0.2** (dev, 2026-09-16) — **A failed Spotify lookup is refused and retried once.** Spotty
  reports a failure, 429 included, through `album()`'s SUCCESS callback as `{ name => <error
  text>, type => 'text' }`, so 1.0.1 would have stored the error message as the title of a
  label-titled row. No live row was affected. Changes:
  - `_spottyAlbumAnswered` accepts only an object with a Spotify `id`.
  - A failure goes to `_armBackfillRetry`: one retry after 60s, on the release verify's
    constants, then a WARN. `_backfillRetryTick` re-reads the row first.
  - Spotify only.
  - `classifyRelType`'s Spotify path was audited and is safe: it reads no field the error
    object has.
  - t_addpath +14; with the check disabled, 7 fail. Suites 1,633, all green.
  - Verified live for the success path; the retry path has not been seen live.

- **1.0.3** (dev, 2026-09-16) — **Stale comments corrected; no runtime change from 1.0.2.**
  A doc sweep before review found four comments today's work had made untrue:
  - the `svc_title` comment in `_addCtxCommand` ("TITLE only (no id anchor)", and "the raw label
    is exactly what the player will report");
  - two comments claiming `_backfillStreamingArtist` runs only for an artist-less add;
  - `t_played.pl`'s "no id anchor".

  `Plugin.pm` differs from 1.0.2 in comment lines only, 0 code lines. Suites 1,633, all green.
  1.0.3 INSTALLED and TESTED on plex:9000 (13:46): the test add plus three real Pitchfork Reviews
  adds listed with the Spotify album names. **The live playback test (the id door, and the
  failed-lookup retry) is DEFERRED by Simon and classed OK until a user reports otherwise.**

- **1.0.4** (dev, 2026-09-16) — **A silent Spotty failure now names itself.** The release-id door
  added in 1.0.1 reads the playing track's album id through `Plugins::Spotty::API->trackCached`,
  and every way that call can come up empty — Spotty absent, a non-track URI, an uncached track,
  a cached album with no id — is an expected fall-through to the title doors and stays silent.
  A DIE is not, and it is invisible: it produces the SAME fall-through, and the title doors are
  measured never to match a Spotify row, so a changed Spotty call signature would match nothing
  for ever with no symptom at all. Changes:
  - `Played::_spotifyAlbumRecord` WARNs on a die from the eval'd `trackCached` call:
    `LL: Spotty trackCached died for spotify:track:…`. Not latched (one line per newsong,
    Spotify only). **This is the one thing to grep `log.txt` for if Spotify plays stop matching.**
  - Nothing else changed: no new call, no behaviour change on any path that does not die.
  - t_played +4, including a CONTROL that a plain cache miss logs nothing; 2 of the 4 fail with
    the warn removed. Suites 1,633 → 1,637, all green.
  - The live playback test remains DEFERRED (settled at 1.0.3); this warn line exists precisely
    because it is. 1.0.3 is still the last build INSTALLED and TESTED on the rig.

- **1.0.5** (dev, 2026-09-16) — **A review round; one stale comment corrected, no runtime change
  from 1.0.4.** `_updateIdentityField`'s header claimed the album-title provenance guard "lives in
  updateAlbumTitle". It does not: `updateAlbumTitle($id, $title)` takes no provenance argument and
  checks none — it only skips the rewrite when the new title normalises equal to the stored one,
  then writes. The guard is the CALLER's `return unless $titleFromLabel`, which `Plugin.pm`'s own
  comment and `updateAlbumTitle`'s header (`THE CALLER OWNS THE GUARD`) both state correctly; the
  `DB.pm` line was the lone contradiction. Left standing it invites a later caller to fire the sub
  on an `&al=` handshake title and re-key the row, undoing the 0.1.92 `svc_title` decision.
  - `DB.pm` differs from 1.0.4 in comment lines only, 0 code lines. `Plugin.pm` and `Played.pm`
    are byte-identical.
  - The round also CLEARED six things it examined without finding a defect (`_spottyAlbumAnswered`
    widening to the artist backfill, `_backfillRetryTick`'s stricter ref-identity guard,
    `_mergeKeyRows`' title retention, the `_titleFromLabel` leak paths, the native-Spotty title
    repair, and the `trackCached` signature). Reasons are tabled in `CLAUDE.md` under
    "2026-09-16 review (1.0.5)" so the next round does not re-derive them.
  - Suites 1,637, all green. Nothing re-verified on the server: nothing executable changed.
  - 1.0.3 is still the last build INSTALLED and TESTED on the rig, and the live PLAYBACK test
    stays DEFERRED.

- **1.0.6** (dev, 2026-09-16) — **The Spotify title repair no longer renames a row it merged
  into.** An LBF Spotify add (label title, no artist) gets its year from classify and its artist
  from the backfill; if an earlier same-list row from another source had the same artist, title
  and year, the Spotify row merged into it and `updateAlbumTitle` then renamed that row to
  Spotify's edition name, so a re-add of it stored a duplicate. Reproduced live on 1.0.3 (rows
  362–364, removed). The title write — first attempt and retry — now requires the canonical row
  to still be that Spotify release (`_sameReleaseRow`, shared with `_backfillRetryTick`).
  - t_addpath +11 (5 red on the unfixed code). Suites 1,687, all green.
  - INSTALLED and VERIFIED LIVE (17:56): the merged-into library row kept its title, the WARN
    fired, and the re-add answered `already=1`. Test rows removed. Ledger: `CLAUDE.md`,
    "2026-09-16 review (1.0.6)". The live PLAYBACK test stays DEFERRED.

- **1.0.7** (dev, 2026-09-18) — **The service is Material's badge on the artwork, not a word in the
  row.** Every album, playlist and track row carries `extid` (`Browse::_extid`), which Material
  (upstream `d3f1d9227`) draws as a service emblem over the artwork. The ` · Qobuz` / ` · Deezer`
  tail is gone from line2, podcast episodes included (Simon: "remove the service from the
  display"). Release rows with an album id carry `<svc>:album:<id>`; `deezerpodcast` wears the
  Deezer badge; library rows get none.
  - t_resolve_count 72 → 82 (two subtitle assertions updated, 10 new), anti-tested. All 15 suites green.
  - BUILT (sha `847c91b3…`), NOT INSTALLED. The badge is UNVERIFIED LIVE until a Material release
    carries `d3f1d9227`. Ledger: `CLAUDE.md` §A2 `THE SERVICE IS A BADGE`.
