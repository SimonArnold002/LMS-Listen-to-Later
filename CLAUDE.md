# Listen Later — LMS Plugin

## Project Overview
A plugin for Lyrion Music Server (LMS) that lets you save an album — from the local library or any streaming service (Qobuz, Bandcamp, Tidal, Deezer, Spotify) — into a curated **Listen Later** list, browse it like a playlist *of albums*, and have albums move to a **Played** section once most of the album has been heard. A separate **Wish List** wishlist (0.1.22) sits alongside, and albums can be moved freely between the three lists. It also adds a **Material home-page shelf** for the list. Targets LMS v9.x, Material Skin preferred (classic best-effort). Storage is a plugin-owned SQLite database so the list is sortable, deduped, history-bearing, and ready for future features.

## Review Ledger — READ THIS BEFORE REPORTING ANY FINDING

**Why this exists.** Reviews kept re-reporting things that had already been
decided — deliberate conventions read as defects, and verdicts that lived only in
a chat transcript. Review and fix happen in separate sessions, so nothing carries
a decision forward. Everything below has already been settled; re-raising it costs
a round trip and teaches the next review nothing.

*Measured 2026-08-26, and worth recording because the obvious explanation is
WRONG: this is not caused by the uncommitted baseline. Pitchfork Reviews ran five
review rounds against a single uncommitted tree of 13,227 insertions, with a
baseline frozen for 13 days, and converged 4 → 4 → 4 → 2 → 1 → clean on one
commit. Diff size and commit cadence are not the variable. An undecided verdict
with nowhere to live is.*

### ⚠ PODCAST SUPPORT — THE BUILT-IN PATH WAS REMOVED IN 0.1.136. READ THIS FIRST.

A review pass has already thrown out rebuild work by citing entries below that were
written for the OLD implementation. They were correct then. They are superseded now.

**What changed.** The built-in Podcasts-app path (`ListenLater/Podcast.pm`, the RSS
resolver, the `podcasts-*` populated override, `_savePodcastEpisode`, the `kind:podcast`
action) is GONE — 637 lines. It did not fit LL's model: an episode is not an album, the
Wish List never applied to it, it duplicated the Podcast plugin's own resume tracking
while never reading it, and it had no identity, which is what the 441-line resolver
existed to guess at. **Streaming episodes (Spotify, Deezer) are KEPT** — they carry
durable ids, are url-keyed through `DB::episodeKey`, and need none of the deleted
machinery.

**Do not cite these against the removal, and do not re-report the old path's defects:**

| entry | why it no longer applies |
|---|---|
| "Identity: what Played actually matches on" (below) | the name-fallback half described a built-in row; those rows no longer exist |
| the 0.1.132 audit residue ("do not re-raise without a real row") | both accepted defects were removed with the path |
| "`$ITEMID` … considered and not taken" | it was rejected because `_parseFeed` skewed the indices; `_parseFeed` is deleted |
| `DB.pm` "Left as-is DELIBERATELY — url-keying these would owe a migration" | no migration is owed: the rows are PURGED (schema rung 6), with a report |
| the 13-site adapter list | its podcast sites are consolidated — but see the WARNING below |

**THE ONE INVARIANT THAT MUST SURVIVE, carried out of the 13-site entry:**
`_canClassifyTrack` is safe *only* because no episode source appears in its list, and the
0.1.126 early return that used to divert episodes was removed in 0.1.127. Adding one that
does would classify a podcast SERIES as a release. Superseding the entry is fine; losing
this is not.

**Two measurements, so they are never re-reported as findings:** the old warm-sweep thaw
was **1.6 ms** for a 2,968-episode feed (863 KB frozen) — waste, not a stall; and the old
resolve walk was **synchronous across cached feeds by design** (12 feeds → 12 cache reads,
stack depth 38). Neither was ever a performance defect.

### 2026-09-09 carrier audit — cross-source rekeys and purge retries

- **Every key-changing carrier now converges on the same cross-source identity as `add()`.**
  `_migrateRefold` groups by the complete logical key rather than `(source,key)`, and the
  live `updateArtist` / `updateYear` backfills use the same transactional merge. The fifth
  writer, `_migrateArtistPrefix`, remains earlier in the ladder and is reconciled by the
  refold afterwards; the legacy year-append SQL is reconciled there too. End-to-end schema-0
  fixtures pin both paths. Schema rung 7 repairs development databases that already stamped
  the older source-scoped refold before this correction.
- **Never separate a replay ref from its source.** A cross-source merge keeps
  `source + ref_kind + ref_json` as one bundle. If the earliest row has no replay carrier,
  all three move from the same loser. A service's `track_count` and `rel_type` move only with
  that same source because one measures what that account/region can actually play and the
  other may be that service's catalogue claim. Playlist and episode keys already embed their
  source in `|p:` / `|e:` and remain distinct across services.
- **A live rekey returns the canonical id and records process-local lineage for every deleted
  member.** Exact `get()` still answers whether that physical row exists; `getCanonical()` and
  logical Move/Remove/Played carriers follow the survivor, including already-rendered taps and
  timers. Late artist/year identity metadata may cross services. Track counts, release types
  and resolved URLs take an expected-source AND an expected-ref argument and follow only a
  survivor that still uses that service/ref bundle. `_verifyRelease`, its retry, first-play
  measurement, drill resolution and Bandcamp URL caching all enforce that boundary.
- **MIXED STATUS BARS THE MERGE, NOT THE REKEY (0.1.138) — and that asymmetry is the fix,
  not an oversight.** Once `_migrateRefold` grouped by the complete logical key, a wholesale
  skip of a mixed-status group started stranding rows that the older `(source,key)` grouping
  had rekeyed perfectly legally: the rung stamps either way, so nothing revisits them, and a row
  on a stale key is invisible to `add()` and to `Played`. `UNIQUE(source, dedupe_key)` is per
  SERVICE, so the group is split by source and every single-status service unit is rekeyed
  and merged on its own; only rows whose OWN service holds both statuses stay put, because
  they cannot both take the one new key. `_updateIdentityField` carries the same rule: a
  differently-statused twin on ANOTHER service no longer cancels the artist/year write, since
  dropping it leaves a streaming row keyed artist-less for ever and it can then never
  auto-move to Played. Same-source controls in `t_refold.pl` §4c/§4c2 and `t_db.pl` pin both
  halves; do not "simplify" either back into one status check.

### 2026-09-09 carrier audit, part 2 (0.1.139) — what part 1 got wrong

Two of part 1's claims above were written ahead of the code. Both are now true; both were
reproduced first, and each has a test that fails without its fix. Do not re-report either, and
do not assume the surrounding entries were verified to the same standard.

- **THE SERVICE IS NOT THE BUNDLE — `_sameSourceCanonicalId` compared only `source`.** Part 1
  says these writes "follow only a survivor that still uses that service/ref bundle"; the guard
  never looked at the ref. Two rows for one release on ONE service exist whenever their keys
  differ (a Qobuz save carrying the year, another without), a year backfill merges them, and
  `_mergeKeyRows` leaves the survivor on its OWN ref — so the deleted twin's callback passed a
  source-only check. Measured: catalogue B's track count, release type and purchase url all
  landed on the catalogue A row. The guard now takes an expected ref identity
  (`DB::refIdentity` — the album id, else the album/play url) and refuses a mismatch.
  `_verifyRetryTick` had the same hole one level up: it followed the canonical id, checked the
  source, then re-issued a request for the OLD album id against the survivor.
  - **Why not compare the whole `ref_json`:** `setRefValue` writes resolved decoration
    (`album_url`, `buy_url`) onto the very rows the guard protects, so a blob compare would
    reject a row's own follow-up write and silently kill every Bandcamp url cache. Only the
    identifying field is compared, and an EMPTY identity on either side stays permissive
    (library rows, `search` refs, and a Bandcamp row still resolving its first url carry none).
  - `findBySourceAlbumId` shares the id extractor but deliberately stays on `refAlbumId`, NOT
    `refIdentity`: widening a reverse lookup to match urls would let it answer for rows it has
    no business returning. `t_db.pl` pins the playlist-id exclusion that depends on this.
- **THE CONFLICT IS PER LIST, NOT PER GROUP — rung 7 and `_updateIdentityField` skipped whole
  groups.** Part 1 fixed the wholesale skip in `_migrateRefold` only. `_migrateCrossSourceIdentity`
  (rung 7) and `_updateIdentityField` still abandoned an entire identity group on one dissenting
  status. Measured on `later:qobuz` + `later:tidal` + `played:spotify`: all three rows survived
  and the rung stamped, so the two `later` rows stayed a duplicate the user sees twice, for ever.
  Both now partition by status and settle each list on its own.
  - **Rung 7 cannot collide, and this is why:** it never recomputes a key — every row in a group
    already stores the identical key — so a subset merge only deletes rows and rewrites the
    survivor to the key it already holds. `UNIQUE(source, dedupe_key)` additionally makes two
    rows of one group impossible on one service. A test that tried to seed that pair was refused
    by the constraint; the control in `t_refold.pl` §4c3 records it.
  - **`_migrateRefold` NEEDS NO CHANGE and was not touched.** Its split is by SOURCE because it
    is the only pass that rekeys, and a source can hold both statuses. Verified end-to-end from
    a stale mixed group: rung 5 rekeys all three rows correctly and rung 7 then collapses the
    same-list pair in the SAME boot. Part 1's warning against re-merging its two status checks
    stands.
  - **Deliberately NOT taken:** `_updateIdentityField`'s `$blocked` test still refuses on ANY
    same-source twin, including a same-LIST one that could legally be merged away to free the
    key. Refusing a write leaves rows untouched, which is the safe direction, and the control at
    `t_db.pl` "a same-source mixed-status twin does block the year" pins the current behaviour.
    Raise it only with a real row that needs it.
- **The podcast purge is one transaction.** A failed second DELETE rolls back the first,
  leaves schema version 5, and retries with the same complete row set and report. It never
  falls back to unwrapped destructive deletes.

**`podcasts-album` / `podcasts-track` are now deliberately EMPTY suppressors**, not
populated entries — the same rule as radio: we don't show an Add we can't honour. The
clearing and prune machinery still names them ON PURPOSE, so husks written by pre-0.1.136
builds are swept. Removing them from `@fileOnlySup` / `%ours` / `_ownedCats` turns 4
assertions red.

**If you are reviewing:** read sections A and B first, and report an item from
them only if you have genuinely NEW information — a case the recorded reasoning
does not cover. Say which ledger entry you are challenging and what changed.

### 2026-09-09 carrier audit, part 3 (0.1.140) — two findings DECLINED, and the comment rot behind both

A review round raised two findings against the podcast carriers. **Both were declined as code
changes**, and the round's real output was a comment sweep. Do not re-report either; the
reachability analysis below is the answer.

- **`Sources::isPodcastEpisode` has no `'podcast'` arm — DECLINED, and the absence is
  DELIBERATE.** The finding was that the sub's own comment table named three sources and the
  body tested two, so a built-in episode reads as a music track (wrong Browse glyph, and
  `_wishListable` lets it move to the Wish List). True as stated, and unreachable. **No writer
  can produce `source = 'podcast'` any more**, on three independent gates: `_serviceCan` has no
  arm for it so every add path's `_isReplayableSource` rejects it; `podcasts` sits in
  `@KNOWN_RADIO_CMDS` so no Add renders on the app's browse rows; and rung 6
  (`_purgeRemovedPodcasts`) DELETES every surviving row. The only window where such a row can be
  asked about is a boot in which rung 5 withheld its stamp so rung 6 waited — and released
  `main` is 0.1.93, so that upgrade is the one path where rung 5 does real work at all. In that
  window the row is unplayable regardless, so the arm would buy a glyph and nothing else.
  **The DEFECT was the comment, not the code**, and the comment now says so in the sub.
  - **On the "~40% of runs" figure** in `_migrateRefold`'s closing comment: that measures a
    SEEDED collision pair under randomised `values %group` order, not 40% of real upgrades.
    Do not cite it as a stall probability.

- **`_addedMsg` used `ucfirst` rather than `Sources::sourceLabel` — APPLIED, but as one-carrier
  hygiene, NOT as a live fix.** `%SOURCE_LABEL` has exactly one entry (`deezerpodcast` →
  `Deezer`), so the two spellings differ for that source alone, and that row cannot reach the
  branch: `DB::episodeKey` puts the source INSIDE the `|e:<svc>:<url>` tail, so the cross-source
  `findAnyByKey` in `add()` can never return an episode for an add from another service, and the
  three `findTrackByUrl` / `findByArtistAlbum` / `findTrackByArtistTitle` call sites are all
  filtered to `source = ?` so their existing source always EQUALS the new one. "Already saved
  from Deezerpodcast" is not reachable today. The swap is there so a finder that later widens
  its scope cannot reintroduce it by inheriting a private spelling.

**The root cause of both, and what was actually fixed.** 0.1.136 removed the built-in path but
left its CONTRACT COMMENTS describing it, so the code and its documentation disagreed in seven
places and a review read the documentation as the spec. All swept in this round:
`isPodcastEpisode`'s source table, `_wishListable`'s "three sources", `_materialActionSet`'s
`%fileOnly` (which had not held `podcasts-*` since 0.1.136), the four `Podcast::hasFeeds()`-based
justifications in `Plugin.pm`, and the `resolveEpisode` refusal note on the `unsupportedContainer`
gate. **A feed row is still refused twice** — `sourceFromUrl` answers `'https'`, which
`_serviceCan` has no arm for, and the Add never renders anyway.

**Two things that STAY, and why:**

| kept | why |
|---|---|
| the `$scheme eq 'podcast'` guard in `Sources::unsupportedContainer` | three anti-tests in `t_favurl.pl` pin it with REAL rows harvested from the test server. It guards the scheme SPLIT — that this sub reads a scheme as a scheme, not as text anywhere in the url — which outlives the built-in path |
| `podcasts-*` in `@fileOnlySup` / `%ours` / `_ownedCats` | unchanged from part 2 above: husks from pre-0.1.136 builds still need sweeping |

**Removed:** `t_addpath.pl`'s stubs for `Plugins::ListenLater::Podcast::hasFeeds` and
`::resolveEpisode`. The package no longer exists and nothing called them — a stub standing in for
a DELETED implementation can only mask its absence, never catch it (fleet rule). The suite reports
the same 214 assertions with and without them, which is what proved they were dead.

### Identity: what Played actually matches on — READ THIS BEFORE ANY NAMING CHANGE

Four review rounds re-derived this per service and got it wrong in a different way each time.
It is two rules, they differ by KIND, and neither is a matter of judgement — both are read
straight out of `Played.pm`.

**A TRACK row's identity is its PLAY URL.** `Played::_markPlayedTrack` calls
`DB::findTrackByUrl($source, $url)` first, an EXACT string compare against the stored
`ref.url`. Only when that misses does it fall back to
`DB::findSavedTrack($source, $artist, $album, $title)`. So:

> **Get the URL right and Played cannot fail. Naming is the fallback, plus display and the
> dedupe key.** A row whose URL matches will move to Played however badly its names read.

**An ALBUM row's identity is its NAMES.** `Played::_matchRecord` never looks at a URL for a
remote track — it matches `findByArtistAlbum` on artist + album as `Sources::playingMeta`
reports them, then two progressively looser fallbacks. There is no album-id route for
streaming, for ANY service, and there never was; do not report its absence as a Spotify gap.

**The corollary, and the rule that replaced four rounds of guessing.** When an add has to fill
a blank name, it asks `Sources::playingMeta` — `handlerForURL($url)->getMetadataFor(...)` — the
SAME sub Played will compare against later. That is the only source that cannot disagree with
the play side, because it *is* the play side. Asking a service's own API instead means
predicting what its protocol handler will report, which is the thing every previous attempt got
wrong. `Plugin::_fillFromPlayingMeta` is the one carrier; it is synchronous, reads the service
plugin's cache, makes no HTTP call, and answers `{}` rather than failing.

**So, before "fixing" a stored name:** say which of the two contracts the row is under, and
whether the change affects the PRIMARY match or only the fallback. If it is only the fallback,
it is a display and dedupe question, not a Played bug — and it is not worth a per-service
subsystem.

### A. NOT FINDINGS — deliberate, fleet-wide

- **The zip is not rebuilt and `repo.xml <sha>` is not recomputed in the working
  tree.** Both happen at build time, together with the version bump. A stale zip
  or sha on `dev` is the normal state, not a defect.
- **`CHANGELOG.md` and `README` are written at the MERGE TO MAIN, not on dev
  builds.** A CHANGELOG whose newest entry is many versions behind `install.xml`
  is CORRECT on `dev`. Dev builds update `CLAUDE.md`, `docs/*.md` and the memory
  notes only.
- **The large uncommitted working tree is deliberate.** It is the review diff.
  Do not report it, and do not prompt to commit as a fix for anything.
- **`install.xml` / `repo.xml` being ahead of the docs on `dev`** follows from the
  two rules above.

### A2. NOT FINDINGS — Listen Later specific

- **LL's matcher copy is a deliberately LENIENT, hash-pinned variant**, not drift.
  A saved streaming item replays with EMPTY artist metadata (0.1.66), so an empty
  artist must match. The pins live in
  `../LMS-ListenBrainz-New-Releases/tools/matcher_sync_check.py` (`_norm`,
  `_albumMatches`, `_artistMatch`, plus `DB::_norm` under the `LLDB` tag) and the
  check passes them as documented variants. Do not "fix" the leniency.
  **What is NO LONGER a variant (0.1.112): the FOLD.** LL took the fleet's
  apostrophe elision and ~90-entry `%FOLD`, so all four repos now agree about what
  a NAME is; what stays LL-only is the punctuation pass and the lenient gates.
  **The compound-word tier was deliberately NOT taken** — it only reaches LL's
  replay gate, where `_bestMatches` re-ranks afterwards. Don't report its absence.
- **LL has THREE normalisers and they must not be unified** — `Sources::_norm`
  (fuzzy gate, strips all parens), `Sources::_normStrict` (replay ranker, keeps
  "(LP4)"), `DB::_norm` (dedupe key, keeps qualifiers). They share `DB::foldLatin`
  and differ only after it. Unifying any pair breaks either the key or the gate.
- **An ASSERTED release type inserts immediately and corrects in the background.**
  Only an UNKNOWN type blocks the add. This is a settled UX call: a visible delay
  on every add is worse than a type that self-corrects seconds later.
- **Drag-and-drop to move between sections is NOT feasible** — Material hardcodes
  `canDrop` to Favourites/editable playlists/the queue. It needs an upstream
  Material change; see the section below.
- **Custom actions on Material HOME shelves work only after a streaming browse.**
  Diagnosed to a main-bundle limitation, and **deliberately left unpatched** to
  keep the Material footprint to the single deferred-bundle patch.
- **Individual-Track saves are SCOPED BUT NOT BUILT** (~1 day). Known risks are
  recorded. "Tracks aren't supported" is not a finding.
- **Playlist support is CURATED/SERVICE playlists only (0.1.107).** A Qobuz
  PERSONAL playlist with no artwork of its own has NO recoverable identity — its
  cover falls back to a constituent track's album art (`…/images/covers/…`), which
  is indistinguishable from an album row, so it cannot even be detected in order to
  be refused. It keeps its pre-0.1.107 behaviour. This is a decision, not a defect.
  The fix is upstream: `Qobuz::Plugin::_playlistItem` emits no `favorites_url` at
  all, unlike Tidal's and Deezer's shared playlist renderer.
- **A saved playlist never auto-moves to Played, and there is deliberately no code
  for that.** A playlist is not a release and a curated one changes under you, so a
  "% of it heard" threshold is meaningless. Every Played lookup is already filtered
  to `kind='album'`/`'track'`; the absence of a playlist branch in `Played.pm` is
  the mechanism, not an oversight. Pinned by the `_matchRecord` cases at the foot of
  `t_played.pl` — do not delete them as redundant with `t_db.pl`, they are what stops
  the absence being refactored away.
- **A playlist is stored with NULL `rel_type` and NULL `track_count`, and
  `_savePlaylistRecord` deliberately does not call `_finishAlbumAdd`.** Both are
  release semantics. `Browse::_albumTracks`'s write-back guard is therefore
  `kind eq 'album'` and NOT `ne 'track'` — that is the fix, not a typo.
- **PODCASTS ARE EPISODE-LEVEL ONLY. A SERIES/SHOW IS OUT OF SCOPE EVERYWHERE, and the
  streaming side refuses one (0.1.123). TWO sources supply episodes since 0.1.136** — Deezer
  (`deezerpodcast://<id>`, 0.1.124) and Spotify (`spotify://episode:<id>`, stored under source
  `spotify`). **The built-in Podcasts app was a THIRD until 0.1.136 REMOVED it** (`podcast://`,
  matched against subscribed feeds); everything below about that path is history, not current
  behaviour — see the banner at the top of this ledger. Qobuz, TIDAL and
  Bandcamp have no podcasts at all. Ask `Sources::isPodcastEpisode($source, $url)`, never
  `eq 'podcast'` — it is the predicate Browse's glyph and type word share with the Wish List
  rule. **It takes the URL as well as the source, and that is not decoration (0.1.126):** the
  built-in app and Deezer each have a source tag of their own, and Spotify has none — Spotty
  stores an episode under plain `spotify`, identical to a music track, and says `episode:`
  only in the url. A source-only predicate therefore cannot answer for a third of the
  sources, which is exactly how a Spotify episode kept the ♪ glyph, the word "Track" and a
  Wish List entry after 0.1.125 closed the identical Deezer hole. **The Podcasts-app half of this is HISTORY as of 0.1.136** — that
  path, `Podcast::resolveEpisode`, the `kind:podcast` action and `t_podcast_resolve.pl` are all
  deleted, and a Podcasts-app row now renders no Add at all (an EMPTY `podcasts-*` suppressor,
  the same rule as radio; verified on the server). It is left recorded because the reasoning
  still generalises: the old refusal rested on a feed giving every episode its own artwork, and
  on a feed that did not, the show row's channel image matched episode 1 and the SHOW STORED AS
  AN EPISODE — a claim about artwork identity has to be tested against a feed WITHOUT
  per-episode art, because that is the shape the defect needs and this box does not have one.
  The STREAMING side did not, because the two gates it
  has answer different questions: `_serviceCan` asks about the SERVICE (Spotty is installed, so
  `spotify` says yes whatever the favurl points at) and `favurlIsTrack` asks album-vs-TRACK,
  which presumes the row is one of the two. So a Spotify show stored as an ALBUM and a Deezer
  series took `favurlIsTrack`'s fail-open branch and stored as a TRACK — both verified stored on
  the test server against 0.1.122, then removed. `Sources::unsupportedContainer` is the third
  question, called from `_addCtxCommand` ahead of every storing branch. **Do not "fix" this by
  widening `favurlIsTrack`** — that only moves the Deezer row from the track path to the album
  path, still stored; the anti-test in `t_addpath.pl` asserts BOTH shapes for exactly that
  reason (4 red without the gate, and each names which wrong shape it stored as). Supporting
  series would be a `kind='playlist'`-shaped container feature per service, not a gate change.
- **AN EPISODE'S NAMES COME FROM THE HANDLER, NOT FROM THE SERVICE'S API (0.1.127).** A browse
  row is display-shaped — Spotty packs the release date into the title and the description into
  the artist slot — so the row's own strings are corrected (`stripEpisodeDatePrefix`, blurb
  dropped) and anything still blank is filled by `Plugin::_fillFromPlayingMeta` from
  `Sources::playingMeta`. **Do not "improve" this by asking the service's API for the show and
  publisher.** 0.1.126 did exactly that, and it was reverted: it predicted what the protocol
  handler would report later instead of asking it, its stub was written from the same prediction
  so it could not catch a wrong guess, and the account it depends on is rate-limited. The URL is
  the identity here — see *Identity: what Played actually matches on*. A blank show is a display
  and dedupe shortcoming, never a Played failure.
  **AND THE HANDLER'S ANSWER IS NOT SELF-VALIDATING (0.1.130).** "Whatever it does not know it
  simply does not answer" was assumed from 0.1.127 and is FALSE: Spotty's `getMetadataFor` has
  two early returns — `!hasCredentials()` and `!hasSSL()` — that set the title AND the artist to
  a localised hint string with `duration => 0`. Non-empty, and different from whatever the row
  holds, so the old "take it if it differs" test accepted them and stored "Please authorize this
  player…" as an episode's title, artist, and dedupe-key title segment, permanently. The gate is
  a positive `duration`, applied to the WHOLE fill: every genuine answer from both reachable
  handlers carries one (Spotty `duration_ms/1000` — `_removeUnused` keeps that field, checked —
  and Deezer the API's `duration`), and all three junk shapes carry 0 or none. **It is
  source-agnostic on purpose and must stay that way** — naming a service here would make this the
  fourteenth adapter site, which is precisely what the carrier exists to avoid.
  **Do NOT copy this gate onto `_nowPlayingFallback`**, which shares the reader: live radio
  legitimately reports `duration 0` with a real title, so it would refuse a valid fill there. It
  is right HERE because this runs against a browse row that is not the playing track, which is
  also the only reason the error branches are reachable at all.
- **`_migrateArtistPrefix`'s four-column SELECT is CORRECT, and the "obvious fix" is a
  REGRESSION — DISPROVEN 2026-09-04. Do not widen it.** The finding was that it now calls
  the one-carrier `_keyForRow` while still selecting only `id, artist, album_title, year`, so
  with no `kind`/`dedupe_key`/`track_title`/`source`/`ref_json` the carrier degrades to the
  plain album key for every row — the album-vs-track drift `_keyForRow` exists to close. The
  degradation is real and it is **unreachable, by ladder ORDER rather than by luck**:
  `_migrateArtistPrefix` runs at `$schemaVer < 1`, and `kind`/`track_title`/`rel_type` are
  added at `$schemaVer < 2`, i.e. AFTER it. So on the only DBs where it does any work — a
  pre-0.1.72 file — those columns **do not exist**, no track or playlist row can exist either,
  and `album` is the right answer for every row it can see. On a fresh install `CREATE TABLE`
  has the columns but `_migrate` runs inside `dbh()` before the handle is returned, so the
  table is empty at that moment. **MEASURED, not argued:** against a real pre-0.1.74 table
  (DBD::SQLite 1.64) the current SELECT returns its rows and the proposed one dies `no such
  column: kind` — which the `eval { … } or return` swallows, so the artist-prefix cleanup
  silently never runs on precisely the databases that need it. The call site now passes
  `kind => 'album'` explicitly so the invariant is stated rather than accidental. The other
  three `_keyForRow` feeds were checked in the same pass and are complete: `_migrateRefold`
  selects all 17 columns, and `updateArtist`/`updateYear` pass `get($id)`, which is
  `SELECT *`. **Re-raise only if the migration is ever MOVED below the column-adding rung** —
  reordering the ladder is what would make the extra columns both safe and necessary, and it
  would also regress `user_version` on the first boot after the move.
- **THE DEDUPE KEY HAS ONE WRITER: `DB::_keyForRow` (0.1.129). Do not add a second.** Five
  writers used to answer "what key does this row have" — `add`, `updateArtist`, `updateYear`,
  `_migrateArtistPrefix`, `_migrateRefold` — and two had drifted: `updateArtist`/`updateYear`
  rebuilt with `dedupeKey($artist,$album,$year)` and NO track segment, so either one called on a
  `kind='track'` row silently re-keyed it as an ALBUM (`|album x||t:song y` → `some artist|album
  x|`), losing it from `findTrackByArtistTitle` and `findSavedTrack` and letting it collide with
  a real album row under an eval that swallows the UNIQUE violation. **It was unreachable when
  found** — both callers sit behind `_finishAlbumAdd`, which only makes album rows — but the
  guard lived entirely in the CALLER, so the first future caller on a track row inherited it.
  The carrier also PREFERS a stored `|p:`/`|e:` id tail over rebuilding it, which is what lets
  `_migrateRefold` share it: a fold may change how the TITLE segment normalises, never the
  segment that identifies the row. Pinned in `t_db.pl` (4 red without it).
- **A TRACK ROW'S IDENTITY IS ITS PLAY URL AT THE ADD END TOO (0.1.129).** `_insertTrackRow`
  checks `findTrackByUrl` FIRST, with no artist gate, before the two name-based guards. Those
  both require `length $artist` and fall back on a key that varies by add SURFACE, so an
  artist-less track added from two surfaces stored TWICE for one url. Played has always matched
  the url first; the add path was the last place deciding sameness purely by name, so the two
  ends disagreed about what a duplicate IS. **KNOWN RESIDUAL, deliberately not fixed:** two
  genuinely different music tracks that are both artist-LESS and share a title still collapse,
  because `DB::add` dedupes on the name key before the url check is reached. The same
  `episodeKey` treatment would fix it, but music track rows exist in released builds (0.1.74;
  `main` is 0.1.93) so it owes a migration rather than a key change — and it needs a track with
  no artist at all, which no service checked produces (a Qobuz browse row carries
  `"Title\nArtist - Album"`). **DECLINED BY THE USER 2026-09-04** — *"the chances of that is very
  slight to occur"* — so this is a recorded decision, not an open item. Do not re-raise it as a
  finding. Pinned as a limitation in `t_addpath.pl`; it would only be worth a migration rung if
  artist-less track rows turn out to be common in the field, which nothing suggests.
- **A TIDAL `mix:` is refused, and that is NOT a claim that mixes are unaddable — it is that
  TIDAL keeps them off the playlist call.** `Plugins::TIDAL::Plugin::getPlaylist` takes
  `$params->{uuid}` and calls `$api->playlist`; `getMix` takes `$params->{id}` and calls
  `$api->mix` (read from the plugin source, 2026-09-03). Routing a mix id through
  `playlistFromRow` would hand it to the wrong endpoint, so replaying one needs a getMix
  adapter. **Spotify's "mixes" are NOT this** — Daily Mix / Popular Playlists come through as
  plain `spotify:playlist:<id>` (verified live), reach `playlistFromRow`, and store as
  playlists exactly as before. Nothing in the reject list touches them, and
  `t_addpath.pl` pins that with a positive `Daily Mix 1` row. Don't add `mix` to
  `playlistFromRow`'s container match without the adapter.
- **`_migrateRefold`'s merge sort puts a NULL `added_at` LAST, and that does not
  contradict "earliest save wins" — DECLINED 2026-09-03.** The finding was that the
  `9**15` sentinel sorts an unknown `added_at` as the NEWEST row, so the migration
  keeps a timestamped sibling over a possibly-earlier NULL one. The comment states
  the rule AND this exception in the same breath, and three things make LAST right.
  (1) **Nothing can produce a NULL**: `add()` is the only INSERT and always passes
  `time()`. (2) **Keeping the NULL row would be strictly worse.** The duplicate-collapsing
  fold (the `for my $lose (@sorted)` loop just above the DELETEs — not a git merge)
  carries `play_count`, `played_at`, `track_count`, `rel_type`, `artwork`, `year` and
  the `ref` pair across — but NOT `added_at`, so a NULL survivor keeps NULL for ever
  and `$SORT{added}` (`added_at DESC`) then files it unpredictably in "Recently added"
  with nothing left to repair it from. Sorting NULL last is what protects that view.
  (3) In an all-NULL group the `|| $a->{id} <=> $b->{id}` tiebreak keeps the lowest
  id, which IS the earliest save — so the stated rule holds in every reachable case.
  Don't "fix" the sentinel; if that fold is ever made to carry `added_at`, revisit
  reason (2) first, because it is the only one that would change.
- **`_pruneMaterialActions`'s `%ours` legitimately claims `favorites-album`/
  `favorites-track` — DECLINED 2026-09-03.** The finding was that `git log -S` shows
  the string first appearing in 0.1.110 in that very list, so no LL build can have
  written it and the prune deletes a THIRD PARTY's empty suppressor. The git evidence
  is an artefact of this repo's release convention: versions ship as zips and are
  committed in batches (0.1.73–0.1.85 all landed in the `0.1.86` commit), so **a
  shipped build's code need not exist as a commit**. 0.1.85 DID ship the category —
  the comment that removed it (`Plugin.pm`, "deliberately NO 'favorites-*'") says so
  in the same breath as why the strip-then-delete-empties pass has to clean it up,
  and CHANGELOG 0.1.85 is the release it belongs to. The residual — an empty
  third-party `favorites-*` is deletable — is the accepted trade-off `%ours` carries
  for every legacy name, bounded by the only-empty / only-ours rules. **Do not use
  `git log -S` alone to prove this repo never shipped something.**
  **RE-RAISED 2026-09-04 by a different route and RE-DECLINED — the entry above covers
  it, and this names the route so the next round recognises it.** The new framing was
  that `_pruneMaterialActions` deletes an empty category on NAME alone (`$ours{$cat} ||
  $emptied{$cat}`, where `%ours` folds in `@suppressors` and both legacy sets) while the
  WRITE path requires provenance (`$emptied{$cat} || $owned{$cat}`), so the prune "dropped
  the write path's rule". The asymmetry is real and is not drift: on a PRE-LEDGER install
  `%owned` is itself the name-based seed (`_ownedCats`'s `||=` fallback claims
  `<cmd>-album`/`-track` for every supported command), so both passes answer by name there
  — and the wide set is what lets the prune remove what an OLDER build wrote, which is the
  one thing the ledger cannot know. **The governing reasoning is already written out at
  `Plugin.pm`'s `_ownedCats` header**: an empty category with our name is indistinguishable
  from a third party's by content, there is nothing in the file to tell them apart, and the
  protection therefore lives where it can be exact (`_isOurAction`, and the only-empty /
  never-unlink-a-non-empty-file rules). Narrowing `%ours` to `%owned` for the suppressor
  family would trade a bounded, deliberate residual for the 0.1.51 regression class.
  **Re-raise only with a case the `_ownedCats` header does not cover** — restating the
  write-path/prune asymmetry is not new information.
- **`foldLatin`'s `utf8::is_utf8` gate is sound HERE — DECLINED 2026-09-03.** The
  finding was that gating the NFD/`%FOLD` pass on a STORAGE flag skips folding for a
  downgraded Latin-1-range character string (`Björk` → `bj rk`), which is not a
  semantic test for a permanent UNIQUE key. True in the abstract, unreachable here:
  LL has three input producers and none downgrades — JSON::XS and DBD::SQLite
  (`sqlite_unicode => 1`, `DB.pm`) both hand back UPGRADED strings, and the raw CLI
  hands back UTF-8 OCTETS, which the decode above the gate adopts. LL calls no
  `Slim::Utils::Unicode` and never calls `utf8::downgrade`. Revisit only if a
  producer that downgrades is added — the fix then is to upgrade a failed decode as
  Latin-1, and it changes a stored key, so it owes a migration.
  **RE-RAISED verbatim and RE-DECLINED 2026-09-03 (tenth round), with the three producer
  claims MEASURED rather than asserted, since the entry above stated them without a
  number:** JSON::XS 4.02 returns `is_utf8=1` for `Björk` from a `ö` escape, from raw
  UTF-8 bytes, AND from the non-`utf8` decoder; DBD::SQLite 1.64 under
  `sqlite_unicode => 1` returns flagged strings on every read, pure ASCII included; the raw
  CLI hands octets, which the decode adopts (already pinned by `t_refold.pl` §4f). The one
  `utf8::encode` in the plugin (`Sources.pm`, the search-query conversion) writes a LOCAL
  copy and never reaches `dedupeKey`. **Re-raising this needs a NAMED producer that
  downgrades — a module and a measurement, not the mechanism.** The mechanism is not in
  dispute and restating it is not new information.

  **THE PRODUCER WAS NAMED 2026-09-04, AND IT IS NOT `utf8::downgrade` — FIXED IN 0.1.131 AT
  THE PRODUCER, NOT AT THE GATE. Read this before declining another encoding finding here.**
  The census above is right about every producer it lists and was INCOMPLETE: it enumerated the
  ones that hand `foldLatin` a whole string (JSON, SQLite, the CLI) and missed the one that
  BUILDS a string a character at a time. `Podcast::_clean`'s numeric-entity pass is
  `s/&#(\d+);/chr($1)/ge`, run over the RAW FEED BYTES — `SimpleHTTP::Base::content` is
  `${ $self->contentRef }` with no charset step anywhere above it — so `&#246;` puts byte 0xF6
  into an unflagged string. Not valid UTF-8, so the decode above the gate FAILS to adopt it, the
  fold is skipped, and the key is `bj rk` against `bjork` from every other producer. A WIDE
  entity is worse: `chr(8217)` upgrades the whole string, so raw UTF-8 bytes already in it are
  reread as latin-1. Both measured through the real modules, and both reach `dedupe_key`.

  **The gate stays as it is, and that is the decided part.** `utf8::upgrade` in `foldLatin`
  would paper over the first case, cannot touch the second (the mojibake happens before DB sees
  the string), and would rewrite a stored UNIQUE key for every row — owing a migration, per the
  warning above `DB::_norm`. The feed was decoded ONCE instead, in `Podcast::_parseFeed` — a
  producer that no longer exists, since 0.1.136 removed the RSS path entirely, which only
  strengthens the verdict. So the ORIGINAL verdict holds — the gate is sound given its
  producers — and what was wrong was treating "which producers exist" as settled.

  **What a re-raise needs now:** still a named producer and a measurement, and the census to
  check against is *every site that composes a string from codepoints*, not just the three
  modules that hand one over whole. `chr`, `pack`, and `Encode::decode` on a fragment all
  qualify; `grep -n 'chr(' ListenLater/*.pm` is the cheap version of that sweep.

- ~~**0.1.131's feed decode OWES NO MIGRATION RUNG — DECIDED 2026-09-04.**~~ **MOOT as of
  0.1.136:** the RSS parser this entry is about was DELETED with the built-in path, and every
  row it could have damaged was PURGED (schema rung 6, with a report). Nothing is left to
  migrate or to re-raise. **Note the rung 6 that now exists is NOT a reversal of this
  decision** — it deletes the removed path's rows, it does not re-key anything. The general
  finding-shape warning below still stands for other parsers. Original reasoning kept because
  the two-damage-class distinction is the reusable part: That is a standing finding shape in this repo (cf. the 0.1.116 `lc`
  entry below), and here it has been asked and answered.

  **There are TWO damage classes and they behave differently — conflating them is what made the
  first write-up of this wrong.**
  - **A mojibake'd TITLE is display-only.** RSS bytes went into the `sqlite_unicode` handle and
    were stored as codepoints, so `Björk` renders `BjÃ¶rk`. Its **dedupe_key was always correct**,
    because `foldLatin` decoded those octets before folding — which is precisely why the old-vs-new
    run over ~6,700 real episodes reported `KEY_changed=0`. These rows dedupe and mark played
    normally. Only Podcasts-app (RSS) rows can have it; Deezer and Spotify episodes never touch
    the parser.
  - **A wrong KEY needs a latin-1-range numeric entity** (`&#246;`) and is the one that
    misbehaves: `findSavedTrack` can never match it, so the episode is never marked played, and
    a re-add computes the right key and stores a SECOND row.

  **CORRECTION, and it is the reason this entry exists rather than a one-liner: "the original
  bytes are gone, so a mojibake'd title cannot be repaired" is FALSE, and it was the stated
  justification in the first draft.** Double-encoding is losslessly reversible — the bytes are
  sitting there as codepoints U+00C3,U+00B6. Downgrade to latin-1, decode as UTF-8, done; proven
  round-trip on `Björk ’Homógenic’`. So a repair migration is entirely writable and the decision
  does NOT rest on it being impossible. Leaving a wrong reason in place is what invites a re-raise
  (the ninth round's lesson, one section down).

  **The decision rests on the population, which is zero and was read rather than assumed.** The
  live list over jsonrpc 2026-09-04: 44 rows, 38 with non-ASCII, **0 showing mojibake** — every
  non-ASCII row is an ALBUM from an already-decoded producer (`Tempos Difíceis`, `Sigur Rós`), the
  only podcast row is an ASCII Deezer one, and the single subscribed feed is raw UTF-8 with no
  numeric entities. Across 8 sampled major feeds there were **0 latin-1-range entities** (the one
  feed using any had 16x `&#39;`, ASCII). Against that, a `user_version` rung is permanent, runs
  on every install for ever, and rewrites a UNIQUE column — which is where this plugin's most
  expensive bugs have all lived (`_migrateRefold`, and the four ledger entries it generated).

  **What a re-raise needs: an actual affected ROW, not the mechanism.** The mechanism is not in
  dispute and is written out above. Detecting one needs no DB access — read the browse feed and
  match a UTF-8 lead byte reinterpreted as latin-1 (`/[\x{c2}\x{c3}\x{e2}][\x{80}-\x{bf}]/` over
  each row name), the same check used to measure the zero above. And the fix for a row that IS
  found is one row deep and needs no rung: **delete it and re-add** — the parser is correct now,
  so it returns with the right title and key. A rung only becomes the right answer if the field
  turns up rows in numbers that make hand-repair unreasonable.

- **A Spotify ARTIST row cannot reach the add command — do not report it as an unguarded
  source. WITHDRAWN 2026-09-03 (tenth round).** The finding was that
  `_isReplayableSource('spotify')` is true for every Spotify favurl shape, so
  `spotify://artist:<id>` stores as an album row with no album id. The add path really would
  store one — but nothing can hand it that favurl. Material maps a `spotify:artist:` /
  `deezer://artist:` / `qobuz://artist:` / `tidal://artist:` favurl to
  `STD_ITEM_ONLINE_ARTIST` (`browse-resp.js`, the `presetParams.favorites_url` branch), which
  makes `btype` = `artist`, which resolves the category `<command>-artist` → `online-artist` —
  and `Plugin.pm` deliberately defines NEITHER, so `getCustomActions` returns undef and no Add
  renders on an artist row at all. **Verified live 2026-09-03**: Spotty artist rows DO carry
  `favorites_url: spotify:artist:<id>` (so the premise is right), and no LL action is offered
  on them. The gate exists anyway since the tenth round — `Sources::unsupportedContainer`
  lists `artist` — but as defence in depth behind the 0.1.51 rule that the COMMAND is the
  gate, not as a fix for a reachable bug. Don't re-derive it from `_serviceCan` being
  per-service: that is true of every service and always was.


- **`_migrateRefold` CANNOT be trapped in a permanent retry loop by stored data —
  WITHDRAWN 2026-09-03 (fourth round); RE-RAISED and RE-WITHDRAWN 2026-09-03 (ninth
  round), with the fourth round's reasoning CORRECTED below. Do not raise it again.**
  The finding is that a group whose rekey collides with a PERMANENTLY-skipped
  mixed-status row fails on every boot for ever: same scan, same warn, `user_version`
  never stamped, rows stuck on the old fold.

  **The fourth round's reason was WRONG, and being wrong is what invited the re-raise.**
  It said an outside collision needs a NON-MONOTONE fold rule, that every LL fold change
  is a strict collapse, and so `oldfold(X) == newfold(B)` "has no solution". LL HAS a
  non-monotone rule. The old `_norm` (`git show main:ListenLater/DB.pm`) had no
  `foldLatin`, so an apostrophe fell through `s/[^a-z0-9]+/ /g` and became a SPACE;
  `foldLatin` now ELIDES it. The new fold still produces the old form from other input:

      Jane's Addiction    old=jane s addiction    new=janes addiction
      Jane s Addiction    old=jane s addiction    new=jane s addiction   <- reproduces it

  Seeded with those two rows the migration really does collide. So the algebra is not
  the barrier and must not be offered as one again.

  **THE BARRIER IS THE DATA — check this instead.** A collision needs
  `oldfold(R) == newfold(S)` with R and S in DIFFERENT groups. If the fold does not
  change R then `oldfold(R) == newfold(R)`, so R sits in S's OWN group and is DELETEd
  before the UPDATE. R must therefore be CHANGED by the fold — and all the change ever
  does is remove a character the old fold turned into a SPACE (an apostrophe inside a
  word, or a diacritic). `oldfold(R)` consequently always carries a space where the real
  title has punctuation, so for S to land on that key **S's own title must contain a
  LITERAL separator in that exact position**. Service metadata does not do that. Qobuz
  will hand you both `Jane's Addiction` and `Janes Addiction` as separate entities —
  that is WHY the refold exists — but never `Jane s Addiction`. The realistic
  apostrophes are not even candidates: `Guns N' Roses` and `Rock'n'Roll` fold to the
  SAME string under both folds (the `'n'` guard), so neither can be R. And the group key
  includes `source`, so both rows must come from the same service. A title is stored as
  the service spells it.

  **AND THE TIDY FIX IS UNSAFE — this is the part that matters most.** "A UNIQUE
  collision is policy, not an error, so count it as `$skipped` and stamp anyway" reads as
  obviously right. It is not. `for my $g (values %group)` is HASH order, randomised per
  process, so a collision against a row that a LATER group would have vacated is
  TRANSIENT — measured at ~40% of runs on the pair above, and healed by the next boot.
  Stamping through it would retire the migration with those rows stranded on the old fold
  for ever: the invisible-row state the migration exists to prevent, and precisely the bug
  the third round's finding #3 fixed. Withholding the stamp is the SAFE side of that
  trade and stays.

  **Re-raise ONLY with a service-supplied title that folds to a literal separator where
  its counterpart has punctuation.** Naming stored data that reaches the state is the new
  information. Naming a non-monotone rule is NOT — one exists, it is written out above,
  and it does not reach the database.
- **The 0.1.116 `lc`-ordering fix owes NO schema-6 rung — CONFIRMED 2026-09-03
  (fourth round), and the "no migration owed" note is right as written.** The
  finding was that `_migrateRefold` stamps `user_version = 5` at 0.1.112, so a row
  written by a raw-CLI add under 0.1.112–0.1.115's buggy fold keeps the mangled key
  and nothing rekeys it. The mechanism is real; the population is empty. **`main` is
  0.1.93** — 0.1.112 through 0.1.116 never shipped, so the only DB that ever ran
  them is the dev box's, and only for an add of an UPPERCASE-accented name made
  through the raw CLI in that window. Nothing in the wild can be in that state.
  Before re-raising any "this build owes a migration" finding, **check `git show
  main:ListenLater/install.xml` first** — a rung is only owed for a version a user
  can have run.
- **`_migrate`'s rung-5 failure warn prints the version `_migrate` was ENTERED at,
  not the current one — accepted 2026-09-03 (fourth round).** `$schemaVer` is read
  once at the top and never reassigned, so rungs 3/4 stamp `user_version` without
  updating it and a 2 → 5 upgrade that fails at the refold says "schema left at
  version 2" when the DB is at 4. True, and cosmetic: one word in a warn on a path
  that has already failed and already says it will retry. Not worth a change.
- **`_materialActionTier`'s version gate is NOT a hole — WITHDRAWN 2026-09-03 (ninth
  round). Every reachable case is already covered; check all four before re-raising.**
  The finding was that `materialAtLeast` answers 1 for any string that does not parse,
  so an unparseable version reaches tier 2 and calls the tier-2-only one-arg
  `registerCustomAction($section)` — which on a real 6.4.6/6.4.7 pushes `undef` into the
  section and takes out EVERY plugin's custom actions there, not just ours. The call is
  as dangerous as that says. It is just not reachable:

      no Material / no registerCustomAction  -> tier 0, returned by the ->can gate
                                                BEFORE the version is read at all
      getPluginVersion dies or is absent     -> undef -> materialAtLeast undef -> FALSY -> tier 1
      "6.4.6" / "6.4.7"                      -> parses -> 0 -> tier 1
      "6.4.7-beta1" and friends              -> the regex is UNANCHORED at the end, so the
                                                leading triple still parses -> tier 1

  So the ONLY route to tier 2 without a parsed >= 6.4.8 is a string that does not START
  `N.N.N`, and a released Material is always `N.N.N`. That is the dev-build case, which
  `Plugin.pm` documents as deliberate in the same breath as the window that made it wrong
  (a dev build cut between 6.4.6 and the #1257 merge, 2026-08-30 — closed). All four rows
  above are pinned in `t_material_actions.pl`'s tier table, the suffixed rows added by this
  round (`6.4.7-beta1`, `6.4.6.1`, `6.4.8-rc2`) because the bare-version rows alone did not
  cover the case the finding actually rested on. ANTI-TEST: anchor `materialAtLeast`'s regex
  at the end (`/^(\d+)\.(\d+)\.(\d+)$/`) and exactly those two below-threshold rows go red —
  they are what stops a real 6.4.7 reaching tier 2. The comparator's three-way answer (undef
  vs 0 vs 1) is pinned separately, because undef and 0 are both falsy today and a caller may
  one day need to tell them apart.

  **Before re-raising, check the `->can` gate first.** It returns tier 0 and never consults
  the version — reading the two gates as independent is what produced this finding.

### B. KNOWN-OPEN AND ACCEPTED — do not re-report as new

- **A STREAMING podcast SERIES row still shows a dead "Add" — ACCEPTED 2026-09-05, it
  cannot be fixed from the plugin side. Do not re-report, and do not "fix" it by emptying a
  category.** A Spotify show (`spotify://show:<id>`) or Deezer series (`deezer://podcast:<id>`)
  row renders LL's Add; pressing it stores nothing — `Sources::unsupportedContainer` refuses
  it (0.1.123) and `_rejectAdd` completes the request silently. Reported from the field.

  **Why suppression is not available.** Material resolves an action by
  `<browse command>-<type>`, per CONTAINER, not per row. A Spotify show row and a Spotify
  ALBUM row are both `-album` under the same browse command, so an empty suppressor there
  removes Add from every Spotify album and track as well. Same for Deezer. There is no
  category axis that separates a series from an album. **This is exactly why the built-in
  Podcasts app COULD be suppressed cleanly in 0.1.136 and these cannot** — it had its own
  browse command with nothing else in it.

  **Why the per-row filter does not help, checked rather than assumed.** Material's
  per-action `filter` matches `startsWith` against `presetParams.favorites_url`. LL used it
  in 0.1.49 and ROLLED IT BACK in 0.1.50 (see that entry): it is allow-by-prefix with no
  deny, so excluding `show:` means enumerating every allowed prefix instead — one action copy
  per prefix, the entry explosion 0.1.50 removed — and the filter is BYPASSED when the favurl
  is undefined, which is the case for home-shelf cards and LBF rows, so every copy renders.
  Registration does not change this: `registerCustomAction` alters DELIVERY; the filter
  semantics live in Material's `browse-resp.js`, so tier 2 behaves identically.

  **Why a message is not available either.** See the header above `_rejectAdd`: Material
  renders no toast for a custom-action command (server-side `showBriefly` reaches physical
  player displays only, not the web UI), and the sole feedback hook is a generic
  "'…' failed" snackbar that cannot be customised.

  **The position, and it is LL's existing one:** the COMMAND is the gate, not the button —
  the same treatment radio and BBC Sounds already get. The log names the refused container
  type, which is what triage needs. The only clean fix is upstream in Material (a deny
  filter, or a per-row predicate that is not bypassed on a missing favurl); it would close
  the same problem for every plugin, and it is not LL work.

- ~~**`matcher_sync_check.py` exits 1 fleet-wide.**~~ **CLOSED 2026-09-02** — the
  hold was lifted, the sync ran repo by repo (PFR 0.9.33, LBF 0.9.194, LL 0.1.112),
  and the check **exits 0**. A non-zero exit is a real finding again. LL's three
  matcher subs are still pinned variants, and `DB.pm` is now scanned too (tag
  `LLDB`) so LL's copy of `%FOLD` is under the same alarm.

- **The `//` on `$t->albumname` is NOT a defect — SETTLED 2026-08-27 against the LMS source.
  Do not re-raise it.** The finding was that the line uses `//` where its neighbours use
  `defined && length`, so a RemoteTrack's `''` would win over `$alb`. Probed
  `Slim/Schema/RemoteTrack.pm` (9.1): the harm cannot occur, for two independent reasons.
  (1) `$alb` is **undef** on every path reaching that branch — `album` and `albumname` are two
  independent rw accessors and `setAttributes` maps every incoming `album` key to `albumname`
  via `%localTagMapping`, so the `album` slot is declared and never written; the term was dead
  and has been removed. (2) The statement modifier means the line only runs when `$album` is
  already undef or `''`, so the `''` that `//` would wrongly keep is identical to the fallback
  it would keep it from. **The real error was the COMMENT** — both here and in `t_stubs.pl` it
  claimed a RemoteTrack's `->album` is the album name. It is undef. Both corrected, and the
  stub now models `album`/`albumname` as the separate accessors they are; the suite stays green
  through the correction, which is what shows behaviour never depended on it.

- ~~**A SPOTIFY podcast episode CAN go in the Wish List.**~~ **REVERSED 2026-09-04 by the
  user, and fixed in 0.1.126 — do not restore the asymmetry.** The 0.1.125 entry here recorded
  it as deliberate, on the reasoning that Spotty plays an episode through
  `spotify://episode:<id>` so it *is* a Spotify track to everything downstream. Simon found it
  in the field and ruled the other way: an episode is a podcast whichever service carries it,
  so all three sources now behave alike — savable to Listen Later, never to the Wish List, and
  rendered with the ❝ glyph and the word "Podcast".
  What made the old entry sound reasonable is worth keeping, because it is the mechanism:
  Spotify is the ONLY episode source with no source tag of its own, so `_wishListable(kind,
  source)` could not have caught it — the fix was to give the carrier the play url as its
  third fact, not to widen a list of source names. The stated cost ("it relabels those rows
  across Browse") was real and is exactly what was wanted; it came to four call sites.

### C. CLOSED FINDINGS

The version history below records review fixes inline (0.1.26, 0.1.32 onward).
Check it before reporting — the July `%counting`, `classifyRelType` and
`_verifyRelease` findings are all fixed and verified (`COUNT_STALE_SECS` is the
escape for the first).

**Round of 2026-09-03 — CLOSED, all four findings dispositioned.** Run against
the 0.1.113 tree (Spotify support). Recorded here as a round because the
version history alone does not show that a finding was RAISED and declined.

| # | finding | disposition |
|---|---|---|
| 1 | `_migrateRefold` sorts a NULL `added_at` LAST, contradicting "earliest save wins" | **DECLINED** — three reasons, section A2 above |
| 2 | the "ADDING A NEW SERVICE" site count was wrong (eight, actually ten) | **FIXED** — docs only; canonical spec §9 restructured into 6 unconditional + 4 conditional, re-copied to all three repos |
| 3 | the Material version parse was written out three times | **FIXED** — 0.1.114, `Sources::materialAtLeast` |
| 4 | the Spotty artist extraction was written out twice | **FIXED** — 0.1.115, `Sources::spottyArtistName` |

**Second round of 2026-09-03 — CLOSED, all four findings dispositioned.** Run
against the 0.1.115 tree (`main...dev`: playlist kind, Spotify/Spotty adapter,
Material registration tiers, dedupe-key refold).

| # | finding | disposition |
|---|---|---|
| 1 | `Settings::handler` materialises `pref_material_action`/`pref_debug_log` but NOT `pref_watch_outside`, so unticking it never sticks | **FIXED** — 0.1.116; the 0.1.108 checkbox fix missed the third field; `t_material_actions.pl` now covers all three (2 red without it) |
| 2 | `foldLatin` lowercases BEFORE the decode, so an uppercase accented letter on the octet path keys `sigur r s` against `sigur ros` | **FIXED** — 0.1.116; `lc` moved below the decode, which RESTORES fleet alignment (LBF/PFR/DSC all decode first); `t_refold.pl` §4f pins octets == characters (6 red without it) |
| 3 | `%ours` claims `favorites-*` that no LL build wrote | **DECLINED** — 0.1.85 did ship it; section A2 above |
| 4 | the `utf8::is_utf8` fold gate is a storage test, not a semantic one | **DECLINED** — no producer downgrades; section A2 above |

Carried forward from it: **only an UPPERCASE accented letter exposed #2**, because
the fold's output is lowercase, so `Sigur Rós` agreed on both paths and a live add
looked correct. A fold test that only feeds lowercase fixtures cannot see a
`lc`-ordering bug — `t_refold.pl` §4f now feeds both cases through both encodings.

Two things from that round worth carrying forward, both larger than the
findings that produced them:

- **The #3 refactor SHIPPED A REAL BUG and the suite caught it, not review.**
  `materialAtLeast(_materialVersion(), 6, 4, 8)` — `_materialVersion` is
  `return eval { ... }`, whose EMPTY LIST on failure collapses the argument
  list, so every Material-less install silently reached the newest delivery
  tier. See the 0.1.114 entry and [[return-eval-empty-list-trap]]. **Never
  inline a `return eval { ... }` sub into an argument list.**
- **The spec had drifted before this round started.** Commit 41768bf edited
  the canonical copy in the ListenBrainz repo without re-copying it to PFR and
  LL, so the three were out of sync for reasons unrelated to any finding here.
  The copies are byte-identical again and all three are committed. The header's
  "edit the canonical copy and re-copy" instruction is not optional — check
  `shasum` across the three repos when touching it.

Also carried forward: **`matcher_sync_check.py` could not have caught #2.** It compares
`_norm` and `%FOLD`; LL's fold sits in `DB::foldLatin`, a separately-named sub, so an
ordering slip INSIDE it is outside the gate's view and the check exits 0 on both trees.
The sync gate proves the tables agree, not that the code around them does.

**Third round of 2026-09-03 — CLOSED, all six findings dispositioned.** Run
against the 0.1.116 tree (`origin/dev...HEAD`: Spotify/Spotty adapter, fleet
matcher fold + `_migrateRefold`, Material delivery tiers 0/1/2 + prune, uninstall
hook, checkbox pref fix). **Shipped as 0.1.117** — five findings fixed, one
declined, plus two defects the knock-on pass found (below). Tests 13 suites green:
`t_material_actions.pl` 195 → 215, `t_refold.pl` 61 → 75.

| # | finding | disposition |
|---|---|---|
| 1 | `_pruneMaterialActions` gates `%emptyFallback` on `$REGISTERED_N` alone, so if tier-2 registration refuses EVERYTHING the refused `online-*` pair is written to the file with no suppressor on either half — "Add" back on our own list/Played/Wish List rows and on radio browse rows | **FIXED** — gate is now `($REGISTERED_N \|\| %fallback)`: "is anything of ours live", not "did anything register". `t_material_actions.pl` covers both directions (3 red without it) |
| 2 | `_migrateRefold` DELETEs the losing rows before the survivor's UPDATE on an AutoCommit handle, so a failed rekey commits the merge away and keeps the stale key — a saved album and its play history gone, silently | **FIXED** — one transaction per group, rolled back whole. `t_refold.pl` §4h pins it by PLANTING a squatting key (4 red without it, and the row count drops to 3). The plant is what makes the test deterministic: stored data cannot reach that state (§A2, ninth round), so §4h proves the TRANSACTION, not reachability |
| 3 | `PRAGMA user_version = 5` was stamped even when `_migrateRefold` bailed, retiring the migration for good and leaving every key on the old fold — the invisible-row state it exists to prevent | **FIXED** — `_migrateRefold` returns false on a failed SELECT or a rolled-back group, and only a true return stamps. A mixed-status skip does NOT withhold the stamp: policy, not error, and it could only re-log the same warn for ever. `t_refold.pl` §4g (6 red without it) |
| 4 | the Settings save now calls `_registerMaterialActions` ungated, so on tier 1 ticking then unticking leaves entries live until a restart where it used to clean up in-session | **DECLINED** — unavoidable and already reported to the user. On tier 1 `$api` is `($REGISTERED && $tier)`, so without registering on save the toggle writes nothing and does nothing until a restart (that is the 0.1.110 bug the save-register fixed). Material has no unregister API, so once registered the only honest answer is the restart warning `_clearMaterialActions` already logs |
| 5 | the per-service verdict in `_dumpMaterialState` reads only the file, so on tier 2 it reported `listenlater`/`LLHome`/`podcasts` as "Add shown (via online-\*)" when they are registered-suppressed/overridden | **FIXED** — it now reads both halves the way `browse-resp.js` does and NAMES the half ("registered empty … section" vs "empty … in actions.json"). Evidence, not intent: the old `@radioCats` fall-back claimed a suppressor we might never have delivered. 8 new checks (3 red without it) |
| 6 | `$rekeyed++` fell through the failure branch, counting a failed rekey in both `$skipped` and `$rekeyed` | **FIXED** — subsumed by #2: `$rekeyed`/`$merged` are now reached only after a successful commit, and a failed group counts once as `$skipped += @$g` |

**The knock-on pass (asked for explicitly, after PFR's repeat rounds).** Every
concept touched above was then traced to every OTHER place that answers the same
question, because PFR needed a second round of fixes for exactly this — a finding
fixed at one carrier while a second carrier kept the old answer.

- At that round the DB side had one migration transaction carrier: `_migrate` has one caller
  (`_dbh`, at connect) and `_migrateRefold` has one caller. Since the 2026-09-09 carrier
  audit, `_mergeKeyRows` owns transactional identity merges and the destructive podcast purge
  has its own all-or-nothing transaction; both share `_rollbackTransaction`'s handle recovery.
  The other `DELETE FROM albums` sites (remove-by-id, the played prune) carry no merge policy.
- The Material side was NOT, and the fix for #1 exposed it. "Is our file half
  still wanted" was answered in three subs, and `_pruneMaterialActions` only knew
  `$departing` — so **turning the pref OFF re-wrote the entries registration had
  REFUSED back into the file**, while tier 0/1's clear path deletes those same
  entries immediately. One concept, two answers. The prune now takes `$prefOff`,
  and with `%fallback` empty on that path the #1 gate collapses to `$REGISTERED_N`
  by itself — which is the right answer there, since only registrations are stuck
  until the restart. Pinned in `t_material_actions.pl` (2 red without it).
- `_clearMaterialActions`'s pref-off WARN asserted both halves ("the registered
  entries go at the next restart. The suppressors are registered too") on
  `$REGISTERED_N || %REGISTERED_EMPTY`, so whichever half was empty it claimed
  anyway — #5's untrue-diagnostic class, in the log a report starts from. Now one
  clause per fact.

Carried forward, and bigger than any of the six:

- **A migration is two decisions, not one: what to rewrite, and whether to
  RECORD that it ran.** #2 and #3 are the same bug seen from either end — the
  write was not atomic, and the version stamp did not depend on the write. Either
  alone is silent and permanent. Any future `_migrate` rung gets both: wrap the
  row work in a transaction, and stamp only on a reported success.
- **"Did our half register" is not "is our entry live".** #1 and #5 are both that
  substitution, in the writer and in the diagnostic. With two delivery halves that
  MERGE client-side, every question about a category has to ask both — Material
  does (`(appCat in customActions) || (appCat in pluginCustomActions)`), so a
  single-half test is wrong by construction, not by accident.
- **A diagnostic that reports INTENT cannot report the failure it exists for.**
  The dump's old radio fall-back read the list of categories we mean to suppress,
  which agrees with reality in every healthy state and lies in the one state worth
  a bug report. Diagnostics assert only what the file HAS and what Material TOOK.

**Fourth round of 2026-09-03 — CLOSED, five findings dispositioned, two fixed.**
Run against the 0.1.117 tree (`0639796..HEAD`: the refold transaction/stamping,
the `watch_outside` checkbox, the `foldLatin` `lc` ordering, the prune's `$prefOff`
argument and `%emptyFallback` gate, the per-service diagnostic). **Three of the
five were WITHDRAWN under challenge — all three DB findings — and the reasoning
for each is in section A2 above so the next round starts from it.** Tests
`t_material_actions.pl` 215 → 223.

| # | finding | disposition |
|---|---|---|
| 1 | `_pruneMaterialActions`'s `%regCount` counts entries registration REFUSED as delivered, because it subtracts the caller's `%fallback` — which the `$prefOff`/`$departing` paths deliberately zero | **FIXED** — `_deliveredCounts` subtracts `%UNREGISTERED` directly (2 red without it) |
| 2 | the pref-off warn says "No suppressor registered either, so another plugin's Add is not being held off those rows" and the prune then writes exactly those suppressors | **FIXED** — the clause now reports what the prune will leave live (2 red without it) |
| 3 | a refold collision with a permanently-skipped mixed-status group could withhold `user_version` for ever | **WITHDRAWN**, but the stated reason was WRONG and was corrected in the ninth round — a non-monotone rule DOES exist (old `_norm` spaced an apostrophe, `foldLatin` elides it); the real barrier is that no service emits the title that would trigger it, and stamping through a collision would be unsafe. Section A2 |
| 4 | the 0.1.116 `lc` fix changes the octet-path key with no new migration rung | **WITHDRAWN** — `main` is 0.1.93, those builds never shipped; section A2 |
| 5 | the rung-5 failure warn prints the entry `$schemaVer`, not the stamped one | **ACCEPTED, no change** — cosmetic; section A2 |

Carried forward, and the reason #1 and #2 existed at all:

- **A formula is only as portable as what its inputs MEAN.** `built minus %fallback`
  reads as "delivered" in `_writeMaterialActions`, where `%fallback` IS
  `%UNREGISTERED`. The prune copied the expression verbatim and then zeroed
  `%fallback` for an unrelated WRITE-POLICY reason (`$prefOff` must not re-write
  what the user asked to be rid of), at which point the same characters computed
  something else entirely. The third round's knock-on pass traced the *concept*
  "is our half live" through the writers; it did not trace the *arithmetic* that
  reports on it. Both now go through `_deliveredCounts`, which takes the refusal
  ledger directly and cannot be handed a substitute.
- **A message about what happens next must be computed from what happens next.**
  #2's warn was rewritten in the third round to state one fact per clause — and the
  second fact was still about registration when the sentence was about suppression,
  three lines above the code that does the suppressing. Inside that branch the old
  text was not merely wrong, it was UNREACHABLE as a true statement: the outer
  condition means an empty `%REGISTERED_EMPTY` implies `$REGISTERED_N`, which is
  exactly when the file half gets written. The clause now recomputes the prune's own
  `%emptyFallback` set, so the two cannot drift.

**Fifth round of 2026-09-03 — CLOSED, three findings, all three FIXED.** Run against the
0.1.118 tree (`origin/dev..HEAD`: the dedupe-key refold migration, Material delivery tiers
0/1/2, the Spotify/Spotty adapter, the Settings checkbox fix, the rebrand-migration removal).
Shipped as **0.1.119**. Tests 1030 → 1052 assertions, 13 suites green.

| # | finding | disposition |
|---|---|---|
| 1 | `_pruneMaterialActions` passes a hardcoded `$api = 1` and an ungated `_deliveredCounts`, so with the pref off at STARTUP the dump claims "plugin API", "streaming Add active" and "registered sections = …" under "material_action pref = OFF" | **FIXED** — one `$api` carrier gated on `$REGISTERED`, feeding both count sites and all three dump calls (3 red without it) |
| 2 | `_migrateRefold`: a rollback that itself fails never restores `AutoCommit`, so later `begin_work`s die and every plugin write for the rest of the server run is discarded at handle destruction | **FIXED** — roll back by hand via raw SQL, THEN restore `AutoCommit`, THEN abandon the pass (3 red without it) |
| 3 | on tier 2 the `hasFeeds()`-gated `podcasts-*` override folds into `%positive` behind the one-shot `$REGISTERED` latch, so a first podcast subscribed mid-session reaches neither half until a restart | **FIXED** — `%REGISTERED_POS` per-category ledger + a `setChange` watch on `plugin.podcast:feeds` (4 red + 1 source check) |

Carried forward, and each bigger than the finding that produced it:

- **A latch encodes a PREMISE, and the premise can be invalidated by a change that never
  touches the latch.** `$REGISTERED`'s comment said "the positive entries are built once and
  never change" — true when written, and made false by **0.1.110's own tier-2 fold**, three
  paragraphs away in the same release. Nothing connected them: no test, no compile error, and
  the comment kept asserting the old world. When a set that something is latched on becomes
  CONDITIONAL, the latch is a bug from that moment, not from the moment someone hits it.
- **"Restore the invariant" is not the same as "undo the damage", and doing them in the wrong
  order made the fix worse than the bug.** Setting `AutoCommit = 1` restores the invariant and
  COMMITS the half-applied transaction on the way. The test caught it; review had not. Any
  handle-state repair has to ask what is still OPEN before it flips the flag.
- **The third copy of a bug is found by asking what makes the input MEANINGFUL, not by
  re-checking the arithmetic.** 0.1.118 routed all three delivery counts through
  `_deliveredCounts` so no caller could pass a substitute — and the prune still lied, because
  the refusal ledger is only honest once registration has RUN. One carrier fixed the inputs;
  nobody checked the precondition. When a helper is introduced to make a formula unfakeable,
  enumerate what has to be TRUE for its own inputs to mean anything.
- **A standalone probe is not the suite, and a fixture is not "flaky" until you have watched
  the REAL one flake.** While building §4i I saw it pass and fail run to run, reproduced the
  grouping in a small script, and concluded §4h's `Sigur Rós`/`Sigur Ros` squatter pair had the
  same latent fault. **That was wrong, and it briefly went into this file as guidance.** §4h
  groups exactly as intended — dumping `%group` from the real suite shows `sigur ros|takk|2005`
  holding BOTH ids — and it passes 40/40. The flakiness was a broken literal in the NEW fixture
  (a single-quoted `'Sigur R\x{f3}s'`, i.e. a backslash, not an ó); the probe used to diagnose
  it folded that string differently from the suite, and the probe was trusted over the thing
  under test. Switching §4i to an ASCII pair was still right — it removed a real fault in a new
  test — but there is no diacritic hazard in §4h and no rule against one in a fixture.
  **Instrument the suite itself before believing a reproduction.**

**Sixth round of 2026-09-03 — CLOSED, two findings, both fixed. Shipped as 0.1.120.** Run against the
0.1.119 tree. **The round's most useful outcome is a SCOPING correction, not either finding**, and it is
recorded first because it governs how the next round should read its own results.

| # | finding | disposition |
|---|---|---|
| 1 | `_searchService` hands Qobuz and Tidal OCTETS where both URL layers want CHARACTERS, so replay-by-search returns nothing for any non-ASCII artist | **FIXED** — `$artistChars`/`$artistBytes`, picked per branch; `tools/t_query_enc.pl` (5 red without it) |
| 2 | the tier-2 podcast comment claims unsubscribing the last feed is "the mirror case and the same call handles it" — it cannot be, there is no unregister | **FIXED** — comment only; the residue is bounded and accepted, and the comment now says so |

**THE SCOPING ERROR, which is the part to carry forward.** Finding 1 was reported as a defect in the
updates under review. It is not: `git blame` puts the `utf8::encode` line at **2026-07-01**, untouched
since, so it was never in any release any round has reviewed — which is precisely why five rounds never
raised it and why Simon had never seen it fail. What IS in the diff is `dc3d57b` (0.1.113)'s comment
asserting octets are "right for the other three", i.e. a NEW comment documenting an OLD bug as intended
behaviour. The finding was then "verified" against LBF's ledger and a local repro before anyone asked
whether it was in scope at all. **Check `git blame` on the anchor line before writing up a finding**, and
report a pre-existing defect as pre-existing — the fix may still be worth making (it was), but calling it
a regression of the work under review misdirects the round.

**Why it has never been observed, which the first write-up also got wrong.** The search path is a
FALLBACK: `buildPlayableItems` replays directly whenever the row carries a native `album_id`, and
`captureFromRemote` sets `ref_kind => 'search'` only when none arrived. So it needs a Qobuz/Tidal row
saved without an id AND a non-ASCII artist. The defect is real and silent; its reach is narrow. The
exposure on a given install is countable —
`SELECT source, artist, album_title FROM albums WHERE ref_kind='search' AND source IN ('qobuz','tidal')
AND artist GLOB '*[^ -~]*'`.

**THE CONSUMING END IS VERIFIED LIVE, over HTTP, and the method is reusable.** An earlier draft of
this entry cited LBF's ledger and proposed grepping the plugin sources — wrong on both counts: the
plugins are under `/var/lib/squeezeboxserver/Plugins/`, not `/usr/share/`, and no grep was needed
because **the escape is visible in the response**. Drive each service's own search over `jsonrpc.js`
with the correct string and with the mojibake the double-encode produces, and compare:

    # Qobuz: item_id 0.0 is "New search"; drill the "Releases" child it returns
    ["<mac>",["qobuz","items",0,6,"item_id:0.0","search:<term>","cachesearch:0","menu:1"]]
    # TIDAL: 7.3 is Search > Albums, no drill needed
    ["<mac>",["tidal","items",0,200,"item_id:7.3","search:<term>","cachesearch:0","menu:1"]]

Qobuz hands back the escaped query INSIDE the child `item_id`, which is `uri_escape_utf8`'s output
in plain sight — `0.0_Sigur%20R%C3%B3s.0` for characters versus `0.0_Sigur%20R%C3%83%C2%B3s.0` for
octets. That is the whole hypothesis, confirmed without reading a line of the plugin.

**The measured damage, 2026-09-03 (real Sigur Rós albums in the result set):**

| service | correct query | what LL sends | |
|---|---|---|---|
| Qobuz | **47** of 200 | **1** of 88 | near-total loss |
| TIDAL | **44** of 100 | **8** of 74 | 36 albums unreachable, incl. *Ágætis byrjun*, *Von*, *Inni*, *Hvarf-Heim* |

**This CORRECTS the finding as first written, which said the search "returns nothing".** It does not.
It returns a degraded, largely irrelevant set — Qobuz's 88 hits are things like *Sigue Caminando* and
*Remembering Sigurd Rascher* — which LL's own `_albumMatches` then rejects, so replay still ends at
"Could not find this album to play". The user-visible outcome is the same; the mechanism is
**junk, not empty**, and TIDAL degrades rather than fails, so a given album may still be found by
luck. Say "wrong/incomplete results" rather than "no results" when describing this.

**THE SPEC ALREADY SAID THIS, and LL shipped against it for two months.**
`docs/streaming-adapter-spec.md` **R6** is exactly this requirement — *"Whether the plugin's URL
layer wants characters or octets … Encoding is picked per adapter at the call site"* — and its
acceptance checklist has *"An accented artist name returns results, confirming `query_enc`."* LL
carried that file, verbatim, while `_searchService` violated it. A conformance requirement that
nothing tests is a comment; **R6 now has a test here (`t_query_enc.pl`), and it should get one in
PFR too.**

**One FLEET follow-up, deliberately NOT done in this build:** R6's symptom column reads *"Silent:
accented names return nothing"*, which the live measurement above disproves — it is junk/degraded
results, not zero, and on TIDAL the album may still be found. That wording is the canonical copy's,
so per the spec header it must be edited in the ListenBrainz repo and re-copied byte-identical to
PFR and LL (`shasum` across the three). A one-line change across three repos is its own pass, not a
rider on an LL build — do it before the next adapter is written, since "returns nothing" is exactly
the wrong thing to be checking for.

**`cachesearch:0` does NOT stop Qobuz recording the term** — three probe searches landed in the
user's recent-searches list. They were removed individually via
`["qobuz","recentsearches","delete:<deleteMenu index>"]`, re-reading the list between each delete so
only the probe entries were touched. Never use `deleteAll`. Budget for that cleanup when probing
search.

**Finding 2's residue is ACCEPTED, not fixed** — on tier 2 `registerCustomAction` has no unregister, so
`podcasts-*` stays registered until the restart after the last feed is unsubscribed. With no feeds there
are almost no podcast rows left to press Add on, so the cost is a stale entry rather than a broken one.
If it ever needs closing the fix is a `hasFeeds()` check inside the add handler at invocation time, NOT
more registration bookkeeping — that is the direction every husk bug in this file came from.

**Seventh round of 2026-09-03 — CLOSED, four findings, all four fixed.** Run against the
0.1.120 tree. **The carry-forward is about the TEST that let finding 1 through, not the finding.**

| # | finding | disposition |
|---|---|---|
| 1 | the `plugin.podcast:feeds` watcher is installed only inside postinit's pref-ON arm, so a server that boots with the box unticked runs watcher-less — ticking it on the Settings page registers and writes but installs nothing | **FIXED** — the `setChange` block hoisted out of the `if/elsif` and gated only on Material being present; the callback already self-gates on the pref |
| 2 | `PLUGIN_LL_MATERIAL_ACTION_DESC` describes the pre-tier-2 model — claims Now Playing/queue go through actions.json, and that the registered half "only changes at the next server restart, in both directions" | **FIXED** — rewritten per tier, and the ON/OFF asymmetry stated correctly |
| 3 | Spotify absent from every user-facing service list, and the release-year note files it under "no year" | **FIXED** — `README.md` (3 sites) + `README.html` regenerated; the WHICH SOURCES CAN SUPPLY A YEAR table below gains its Spotify row |
| 4 | the Spotify search branch passes the raw `$artist` where Qobuz/Tidal pass `$artistChars` | **FIXED** — `$artistChars`, and `t_query_enc.pl` grew the Spotty branch it never had |

**FINDING 1 WAS OVERSTATED WHEN FIRST WRITTEN, and the correction is the useful half.** It went out
as "the exact hole the watcher was added to close, left open on one path". It is not: `material_action`
**defaults to 1**, so every ordinary boot takes the ON arm and installs the watcher. Reaching the gap
needs five things at once — box unticked *at server start*, re-ticked from Settings mid-run, **zero**
feeds at that moment, a first feed subscribed later in the same run, and Material ≥ 6.4.8 — and the
damage is a fallback `online-*` pair on podcast rows (a spurious Wish List entry, and the add taking
`_addCtxCommand`'s last-resort resolve instead of `kind:podcast`), cleared at the next restart. Fixed
because the hoist is two lines and strictly safe, **not** because it was reachable in practice.
**Before writing up a state-machine finding, check the pref's DEFAULT** — a repro that silently
begins "with the default inverted" is a dead branch, and saying so up front is the difference between
a finding and a false alarm.

**THE REAL LESSON: a source-grep test pins that a call EXISTS, never WHERE it lives.**
`t_material_actions.pl` already asserted the watcher, with an explicit note that "the test harness's
setChange is a no-op, so it is pinned at source" — and that regex matched just as happily with the call
in the wrong branch. The suite was green across every round while the hole was open. The stub now
RECORDS `setChange` (`@Slim::Utils::Prefs::Obj::CHANGES`) and the suite calls `postinitPlugin` on both
arms; 1 red without the hoist. **When a behaviour can only be pinned at source, that is a signal the
stub is too thin — fix the stub instead.** The same applies to `t_query_enc.pl`: its header named
Spotty in the characters camp from the day it was written, but the suite had no Spotty stub, so
finding 4 sat under a test that appeared to cover it. A camp named in a comment and not in a fixture
is not covered.

**README was edited on `dev`, deliberately.** Section A says the README is written at the merge to
main; finding 3 is a user-facing factual error (Spotify is shipped and undocumented), so it was fixed
now rather than banked. `README.html`/`index.html` were regenerated with `tools/make_readme_html.py`.
Not a precedent for routine README churn on dev.

**THE WATCHER'S TARGET IS VERIFIED LIVE, over HTTP, and this is the check to repeat if it is ever
doubted.** The `setChange` hangs off another plugin's pref, so a wrong namespace or key would fail
SILENTLY — no error, just a watcher that never fires. Read on the LAN 2026-09-03:
`["","pref","plugin.podcast:feeds","?"]` → `[ { name => 'Darko.Audio podcast', value => '<rss url>' } ]`,
i.e. exactly the namespace, key and `{name,value}` shape `Podcast::feeds()` reads. Two supporting
probes from the same session: a BOGUS namespace (`plugin.notarealplugin:feeds`) returns `null` cleanly
rather than dying, so `preferences('plugin.podcast')` on a server WITHOUT the Podcast plugin is
harmless and `feeds()`'s `ref $f eq 'ARRAY'` guard covers it; and `["","apps","0","200"]` lists the
browse command as `podcasts`, which is what makes the resolved category `podcasts-album`. **`pref`
reads are LAN-ONLY** — off-network they return empty and the log says "Access to settings is
restricted to the local network" — so this check cannot be run over Tailscale.

**A FIFTH gap, found by asking the same question about the OTHER kinds: PLAYLISTS (0.1.107) were
undocumented in full.** The README's only occurrence of the word was the simile "browse it like a
playlist"; the intro, the features table, the "Albums, tracks and podcasts" heading, the type list and
the glyph legend all predate playlist support and none had been revisited. Now documented — including
the ≡ glyph, the four services with a playlist call (`Sources::_serviceCanPlaylist`), the two rules a
playlist shares with a podcast episode (no Wish List either direction, never auto-Played) and the
Qobuz personal-playlist limitation from section A2. **The lesson generalises: when a new KIND ships,
the README has five separate places that name the kinds, and finding one of them is not finding them
all.** Both this and finding 3 were missed by every prior round for the same reason — a review that
diffs code against code never asks whether the prose still describes the product.

**Eighth round of 2026-09-03 — CLOSED, three findings: two fixed, one WITHDRAWN.** Run against the
0.1.121 tree (the seventh round's four fixes, still uncommitted and unshipped). **Shipped as 0.1.122**
— a version of its own, not a fold, because 0.1.121's zip was already built and a rebuild always
takes a new version. **The withdrawal is the round's whole value, and it is the round-6 scoping error
in a new disguise.**

| # | finding | disposition |
|---|---|---|
| 1 | the Settings tick path arms no deferred radio re-pass, so a box-OFF boot + mid-run tick leaves TuneIn rows unsuppressed for the run | **WITHDRAWN** — no reachable damage; `@KNOWN_RADIO_CMDS` covers it statically, below |
| 2 | Bandcamp is named in the encoding comment's OCTETS camp but its branch applies no conversion, and `t_query_enc.pl` has no Bandcamp fixture | **FIXED** — comment states the exemption and its reason; suite pins the INVARIANT (5 red without it) |
| 3 | `README.md` claims playlists have "No *Add to Wish List*" — the entry IS shown on `playlist` and `online-album` rows and redirects | **FIXED** — README + regenerated `README.html` |

**FINDING 1 WAS WRONG, AND THE PROBE THAT "CONFIRMED" IT USED A COMMAND NAME THE PRODUCT NEVER
EMITS.** The write-up asserted that `tunein-album`/`-track` go unsuppressed, and a probe run inside
the real `t_material_actions.pl` harness agreed — because the probe seeded the fake `radios` menu with
`cmd => 'tunein'` and then checked for `tunein-album`. **There is no `tunein` browse command.** TuneIn
appears as its top-level categories — `music news sports talk location language podcast search presets
local` — and those are exactly `@KNOWN_RADIO_CMDS`, a compile-time constant seeded at init *because*
the directory arrives async. They are therefore suppressed identically whether the set is built at
postinit, at the Settings save, or in the +60s pass. Re-probed with the real names: with the `radios`
menu completely empty at tick time all five still register, and `bbcsounds` — the sync-registered
case — is visible there too. The live enumeration is *more* complete at Settings-save time than at
postinit, so the missing timer costs nothing.

**The rule this adds, which `git blame` did not cover.** Round 6's lesson was "check `git blame`
before writing up a finding" — a scope test. This one passed that test and still failed, because the
error was upstream of scope: **the entity in the reproduction was fabricated.** A probe proves only
that the code does what you asked; it cannot tell you that you asked about something real. So:
**before trusting a repro, verify every identifier in it is one the product actually produces** — a
command name, a category, a pref key, a source tag — by finding it in the source or on the live
server, not by assuming the obvious spelling. The obvious spelling for TuneIn is `tunein`; the real
one is ten category names in a list twenty lines above the comment the finding was built on. Related,
and now twice over: the seventh round's own carry-forward said "a camp named in a comment and not in
a fixture is not covered" — the same shape, one level down.

**Finding 2 is that lesson applied to the one branch the seventh round did not reach.** Bandcamp sat
under OCTETS in the encoding comment while its branch sends `$query` — `_norm("$artist $album")` —
and no conversion at all. **Not a defect**: `_norm`'s `s/[^a-z0-9]+/ /g` leaves ASCII and nothing
else, so characters and octets are byte-identical there and applying a conversion would be theatre.
But "exempt by an invariant" and "nobody checked" are indistinguishable from outside, and the comment
read as a decision the code does not make — the same class as the "right for the other three" line
0.1.120 deleted. The suite now asserts the INVARIANT (ASCII-only out for character, octet and latin-1
input; the two encodings byte-identical; the album half still present) rather than a camp, so a
refactor that sends a raw artist or title down that branch goes red and has to pick one. **Pin the
reason a branch is exempt, never the fact that it is.**

**Also corrected in passing: LL's own copy of the "returns NOTHING" wording.** Round 6 measured the
double-encode as junk rather than empty (Qobuz 1 real hit of 88, TIDAL 8 of 74) and recorded that the
description must say wrong/incomplete results — then left `Sources.pm`'s own comment and
`t_query_enc.pl`'s header still saying the search "returns NOTHING". Both now match the measurement.
**The canonical `docs/streaming-adapter-spec.md` R6 row still says "accented names return nothing" and
is deliberately NOT touched here** — it is the shared copy, so per its header it is edited in the
ListenBrainz repo and re-copied byte-identical to PFR and LL (`shasum` across the three). That fleet
pass remains open, exactly as round 6 left it.

**Finding 3, and why a doc finding keeps coming out of these rounds.** `_savePlaylistRecord` redirects
a Wish List add to Listen Later and `_listItemMenu` suppresses *Move to Wish List*, so the OUTCOME
matches the README — but the menu entry itself is built per Material SURFACE, and both `playlist` and
`online-album` carry the plain role, whose pair includes "Add to Wish List". Verified by reading the
set back out of `_materialActionSet`, not from the prose. A podcast episode really does have no such
entry (the `podcasts-*` override replaces the pair), which is where the README's "same two rules as
podcast episodes" came from; playlists reach the same place by a different mechanism, and the README
now says so. Third round running that the prose was wrong where the code was right — a review that
diffs code against code never asks whether the product still matches its description.


**Ninth round of 2026-09-03 — CLOSED, two findings, both WITHDRAWN; no product-code change.** Run against the
0.1.122 tree (`@{upstream}...HEAD`, 19 commits, 0.1.107 → 0.1.122). Both were WITHDRAWN under
challenge; the value of the round is in what the ledger now says, not in the diff. Tests 1130 → 1133 assertions, 14 suites green — the round's only executable change, three rows in the tier table.

| # | finding | disposition |
|---|---|---|
| 1 | `_materialActionTier` treats an unparseable Material version as ≥6.4.8 and unlocks the tier-2-only one-arg `registerCustomAction($section)`, which on a real 6.4.6/6.4.7 pushes `undef` and takes out every plugin's custom actions in that section | **WITHDRAWN** — every reachable case is already covered: no API returns tier 0 BEFORE the version is read; `getPluginVersion` dying returns `undef` → falsy → tier 1; `6.4.6`/`6.4.7` parse → tier 1; and `materialAtLeast`'s regex is unanchored at the end, so `6.4.7-beta1` still parses → tier 1 (pinned, `t_material_actions.pl`). Only a genuinely non-numeric version reaches tier 2, which is the dev-build case `Plugin.pm` already documents as deliberate. The tier table gained `6.4.7-beta1` / `6.4.6.1` / `6.4.8-rc2` — the bare-version rows did not cover the suffixed case the finding rested on (2 red if the regex is anchored) |
| 2 | a refold collision with a permanently-skipped mixed-status group withholds `user_version` for ever | **WITHDRAWN — and the proposed FIX was unsafe.** Re-raised because §A2's stated reason was wrong (see §A2: a non-monotone rule DOES exist). The barrier is the DATA, not the algebra. More important: reclassifying a UNIQUE collision as `$skipped` would have stranded rows on the old fold on ~40% of upgrades, re-introducing the third round's finding #3 |

Carried forward:

- **A withdrawal is only as durable as its REASON.** §A2's fourth-round entry closed this
  finding with an argument that was false ("`oldfold(X) == newfold(B)` has no solution") and
  invited a re-raise by naming the exact key that unlocks it ("re-raise only with a concrete
  non-monotone rule") — which the ninth round then found in ten minutes. A ledger entry that
  states a slightly-wrong reason is worse than one that states none, because it hands the next
  reviewer a test to pass. §A2 now argues from stored data, and says outright that naming a
  non-monotone rule is NOT new information.
- **A test's fixture is not evidence of reachability.** §4h's comment claimed "the collision is
  REACHABLE without any injected failure", and the round-3 ledger row repeated it. True of the
  FAILURE — the UPDATE really does hit the constraint — and false of the STATE: §4h plants a
  `dedupe_key` on a Sigur Rós row that no fold could produce for it. Both now say PLANTED, and
  say what 4h actually pins (the transaction).
- **Check whether the tidy fix is safe before offering it, not after.** "A UNIQUE collision is
  policy, not an error" is true of the permanent case and false of the transient one, and
  `for my $g (values %group)` is HASH order — so the two are indistinguishable at the point of
  failure. §4i's own comment already recorded this test passing and failing run to run on group
  order; nobody connected it to the stamp policy. `_migrateRefold` now carries a DO NOT TIDY
  note at the `return`.

**Tenth round of 2026-09-03 — CLOSED, two findings: one HALF-WRONG and re-scoped into a real
fix, one RE-RAISED and RE-DECLINED. The round's value is that BOTH verdicts came off the live
server rather than off the code.** Run against the 0.1.122 tree. Tests 1150 → 1169 assertions,
14 suites green.

| # | finding | disposition |
|---|---|---|
| 1 | `_isReplayableSource('spotify')` is true for every Spotify favurl shape, so `spotify://show:` and `spotify://artist:` store as album rows with no album id | **SPLIT.** The ARTIST half is WRONG and unreachable (Material resolves an artist favurl to `online-artist`, which LL never defines — §A2). The SHOW half is REAL, reproduced live, and BIGGER than written: `deezer://podcast:` stores as a fail-open TRACK, which the Spotify-only framing missed entirely. **FIXED** — `Sources::unsupportedContainer` + a gate in `_addCtxCommand` (4 red without it) |
| 2 | `foldLatin` gates the fold on `utf8::is_utf8`, a storage flag, not on content | **RE-DECLINED** — verbatim re-raise of the second round's #4; the three producers are now MEASURED in §A2 rather than asserted |

**FINDING 1 WAS RIGHT ABOUT THE WRONG THING, AND THE REVIEW COULD NOT HAVE TOLD WHICH FROM THE
CODE.** Both halves read identically in `Sources.pm` — one favurl shape, one per-service gate,
no branch between them. What separates them lives in Material's `browse-resp.js` and in what
each service actually emits, and the answers went opposite ways: an artist favurl resolves to a
category LL deliberately never defines, so no button exists; a show favurl resolves to
`online-album` and gets the full Add. **The rule: a finding about what a Material row can DO is
not settled in this repo.** Read the served bundle for the category, and browse the service for
the favurl — both were a five-minute HTTP call away, and doing them turned one speculative
finding into one refutation and one reproduction.

**AND THE FRAMING HID THE WORSE HALF.** Written as "the Spotify replay gate widened in 0.1.113",
the finding pointed at a per-service test that has looked like that since 0.1.51 and is
identical for Qobuz, TIDAL and Deezer. The actual defect is that NO gate asks whether a favurl
names a container we can replay — `_serviceCan` asks about the service, `favurlIsTrack` asks
album-vs-track — and the moment that was stated properly, Deezer fell out of it, worse (a
kind='track' row pointing `type => 'audio'` at a series url) and years older than the Spotify
adapter. **Before writing a finding as a regression, check whether the same question has a
different answer at the OTHER services** — the sibling that never changed is the one nobody is
looking at.

**Carried forward, and the reason both rounds' fixes needed a live server:**

- **Three test rows on the real box settled what nine rounds of reading had not.** The show
  stored, the Deezer series stored, the podcast-app feed row did NOT — and that last one is
  what turned "should we support shows?" into "the streaming side is inconsistent with the
  Podcasts app", which is a fix rather than a feature. Adding a row and deleting it costs
  nothing and answers reachability outright; both the finding and the ledger entry that came
  out of it are stronger for it than any amount of tracing.
- **An anti-test has to name the WRONG shape, not just the absence.** Disabling the gate turns
  the three refusal rows red with `stored as album`, `stored as track`, `stored as album` — the
  Deezer one is the whole reason the gate cannot live inside `favurlIsTrack`, and an anti-test
  that only asserted "something stored" would have let that placement error through.

**Eleventh round of 2026-09-04 — CLOSED, two findings, both CONFIRMED BY RUNNING THE CODE and
both FIXED. Shipped as 0.1.125.** Run against the 0.1.124 tree. Tests 1183 → 1220 assertions,
14 suites green. The round's value is that executing each finding widened BOTH of them: neither
was as small as the read-only report said.

| # | finding | disposition |
|---|---|---|
| 1 | `_pruneMaterialActions` unlinks the shared `actions.json` on `!keys %$data`, but `_readMaterialActions` answers `{}` for "absent", "could not open" and "malformed" alike | **FIXED** — `_readMaterialActions` now answers `undef` for unreadable; all three callers bail out without writing. Reproduced first: a truncated file and an unopenable one were both DELETED, control kept |
| 2 | a Deezer podcast episode (`deezerpodcast://`, new in 0.1.124) stores through `_saveTrackRecord`, the one save path with no Wish List redirect | **FIXED** — one carrier (`_wishListable`) now consulted at five sites. Reproduced first: built-in episode → `later`, Deezer episode → `wishlist` |

**A READER THAT COLLAPSES "NOTHING THERE" WITH "I COULD NOT TELL" HANDS EVERY CALLER A
DESTRUCTIVE DEFAULT.** `_readMaterialActions` returned `{}` for three different questions, and
each of its three callers then acted on the emptiest possible reading: the tier-0/1 writers
overwrote the shared file, and the tier-2 prune unlinked it — logging "removed the now-empty"
file about a file full of another plugin's actions. No caller was wrong given what it was told.
The fix belongs in the reader, and the ZERO case has to be split from the UNKNOWN case there,
once, rather than re-guessed at each call site. **An empty file is still `{}`** — it holds
nothing of anyone's, so the husk removal stays; that distinction is pinned both ways in the
suite.

**RUNNING THE FINDING WIDENED BOTH OF THEM, AND A READ COULD NOT HAVE.** Finding 1 was written
about malformed JSON; executing it showed the identical delete for a file we merely lack
PERMISSION to open — the realistic case on the live box, where LMS runs as `squeezeboxserver`
and a root-owned `actions.json` is unopenable while being perfectly valid. Finding 2 was written
about Deezer; a control row proved the `Move to Wish List` half hits BOTH podcast sources
(an episode is `kind='track'`, and the old exclusion tested `kind eq 'playlist'`), so the menu
defect predated 0.1.124 entirely. **Write the control into the reproduction** — "playlist has no
Move to Wish List, podcast does" is the line that turned one finding into its real shape.

**FOUR CONSUMERS OF ONE RULE IS THREE TOO MANY** (the fleet's one-carrier rule, again). "You
cannot put this in the Wish List" was answered independently by `_savePodcastEpisode`,
`_savePlaylistRecord`, `_contextMenuQuery` — and not at all by `_saveTrackRecord`. The newest
consumer is where the hole appears, because a new storage path is written against the paths it
resembles, not against a rule nobody stated in one place. `_wishListable(kind, source)` is now
that place, and it is asked of the STORED shape, never of the menu the row was tapped in:
Material builds a menu per surface, not per row, so the menu can never be the guard.

**THE MENU IS PRESENTATION; THE COMMAND IS ENFORCEMENT.** Fixing `_contextMenuQuery` alone would
have left the rule holding only for users on a freshly-rendered page — Material replays a
history page without re-querying, so a `Move to Wish List` rendered before the upgrade stays
tappable, and a CLI caller never saw a menu at all. `_moveCommand` now asks the same carrier.
That gap was open for PLAYLISTS too, since the playlist redirect shipped, and was found only by
asking "what else can set this column?" — `DB::setStatus` has exactly one caller, which is what
made the answer cheap.

**Twelfth round of 2026-09-04 — two findings, one FIXED and one DISPOSITIONED as not-a-defect;
plus a third defect the follow-up audit found, which is the one that mattered to the user.**
Run against the 0.1.125 tree. Tests 1220 → 1272 assertions, 14 suites green.

| # | finding | disposition |
|---|---|---|
| 1 | `shutdownPlugin` reads `preferences('plugin.state')->get(__PACKAGE__)`, but LMS keys `plugin.state` by the plugin's SHORT name — so the 0.1.108 uninstall hook has never run | **FIXED** — short name derived from `__PACKAGE__`; 6 red without it |
| 2 | `_canClassifyTrack` omits `spotify`, so the Spotify branch of `classifyRelType` is unreachable from the track path | **NOT A DEFECT** — measured at the consuming end; comment corrected instead |
| 3 | a Spotify podcast episode was Wish-Listable, drew the ♪ note and said "Track" | **FIXED** — `isPodcastEpisode(source, url)`; 7+2 red reverted, 7+4 red widened |

**FINDING 1 IS THE ONE TO REMEMBER, because the suite was green and the live server was not.**
`plugin.state` is keyed by the plugin DIRECTORY name; the hook asked for the MODULE name, got
undef on every server, and quietly did nothing from 0.1.108 until now — so an uninstall left
every LL entry AND every empty suppressor in Material's shared `actions.json` for good, the
leftovers then hiding another plugin's `online-*` on podcast and radio rows. Verified live over
`jsonrpc.js`: `plugin.state:ListenLater` → `"enabled"`, `plugin.state:Plugins::ListenLater::Plugin`
→ `null`, same shape for MaterialSkin/Qobuz/Spotty/PFR/DSC.
**The fixture carried the same wrong belief** (`my $ME = 'Plugins::ListenLater::Plugin'`), so all
six assertions passed against a branch that could never run — the vacuous pass sitting in the
STUB, for the fourth time in this file (0.1.94 prefs, 0.1.98 RemoteTrack, 0.1.109 checkbox, now
this). **The two PluginManager APIs genuinely differ and that is the trap**: `dataForPlugin()` IS
keyed by module and the neighbouring call is correct as written — proven from the live box, where
the diagnostics snapshot reads `Listen Later version = 0.1.124`. Module for `dataForPlugin`,
short name for the `plugin.state` pref. **A pref key that another subsystem owns is verifiable in
one HTTP call; verify it rather than reasoning from the name you happen to have in scope.**

**FINDING 2 WAS REFUTED BY READING THE OTHER PLUGIN, not by argument.** Spotty-Plugin's
`ProtocolHandler::getMetadataFor` builds every return with `album => $cached->{album}->{name}` —
a plain STRING, no `albumId`, no `album_id`, `album` never a hash — so `Sources::trackAlbumId`
answers undef for every Spotify url and listing `spotify` would buy one wasted lookup and a WARN
per add. It would also be HARMFUL: a Spotify episode reaches `_saveTrackRecord` on that same
branch, so any service listed there that did answer with the show's id would classify a podcast
series as a release. Anything added to `_canClassifyTrack` must exclude episodes first.
The old comment was wrong in the other direction too and is corrected: Deezer IS listed and CAN
yield an id — `API.pm cacheTrackMetadata` stores `album => $entry->{album}`, the album OBJECT,
and `getMetadataFor` flattens it to a title only on the complete-cache return path.

**FINDING 3 — the user's report, and the reason the 0.1.125 one-carrier fix did not reach it.**
0.1.125 made `_wishListable` the single carrier and asked it of `(kind, source)`. That answers
for the two episode sources that have a source tag of their own and CANNOT answer for the third:
Spotty stores an episode under plain `spotify`, indistinguishable from a music track except in
the play url. So the newest source was the one the new carrier could not see. **One carrier is
not enough if it is asked the wrong question** — the carrier now takes `(kind, source, url)`, and
`Sources::isPodcastSource` is REPLACED by `isPodcastEpisode($source, $url)` at all four consumers
(Browse's glyph, its type word, the Wish List rule, the move command), so an episode cannot be
podcast-shaped in one place and track-shaped in another.
Both anti-tests were run, and both directions matter: reverting to the source-only predicate goes
7 red in `t_addpath.pl` (including `got='wishlist'` on the redirect — the reported symptom) and 2
in `t_favurl.pl`; making it "spotify is always a podcast" goes 7 and 4 red on the POSITIVE
CONTROLS, which is what stops the fix relabelling every Spotify album and track in the list.

**FINDING 4 — SUPERSEDED 2026-09-04 by the thirteenth round. The DIAGNOSIS below is right and
worth keeping; the FIX it describes has been removed. Read both halves before touching this
path again.**

*The diagnosis, unchanged and still true.* Spotty's episode rows arrive with their metadata in
the WRONG FIELDS. From `OPML::episodesList`: `line1 => join(' - ', $episode->{release_date},
$title)` and `line2 => substr($episode->{description}, 0, 512)`. Material maps an online row's
title to `$TITLE` and its subtitle to `$ARTISTNAME`, and a Spotty episode resolves to
`online-album` (no `metadata.type`), so LL stored a DATE-PREFIXED title and a 512-character
DESCRIPTION as the artist. Both corrections are made from the ROW alone and both stay:
`stripEpisodeDatePrefix`, and dropping the blurb.

*What was WRONG with the fix.* 0.1.126 resolved the show and publisher through
`Plugins::Spotty::API::episode` — a per-service async lookup with a six-second timeout, a
`->can` probe, and a bespoke failure path, all inside the add. Three things were wrong with it,
and only the third is a matter of taste:

1. **It rested on an UNMEASURED claim.** The shape it parsed (`show`/`artists`) was inferred by
   reading Spotty's source, and the test stub was written from the same inference — so the stub
   returned an object satisfying both readers and could not have detected a wrong guess. That is
   the identical failure as the `plugin.state` fixture two entries above, in the same release.
2. **The dependency does not work here.** Spotify rate-limits this account (`429 Too Many
   Requests` on `browse/new-releases`, measured in the server log 2026-09-04), so on the test rig
   that lookup 429s, sits out its full timeout, and falls back — on every add, forever. A code
   path that has never once succeeded anywhere cannot be shipped.
3. It made Spotify structurally different from every other service, for a field the primary
   Played route does not use.

**THE CONTRACT THAT REPLACES IT — this is the part that stops the churn.** See *Identity: what
Played actually matches on*, near the top of this file. In one line: a track row's identity is
its **play URL**, and naming is the fallback. So the naming is filled from `Sources::playingMeta`
— `handlerForURL($url)->getMetadataFor(...)`, the very sub Played falls back to — which makes
both ends agree BY CONSTRUCTION rather than by a per-service guess about what a service will
report later. Synchronous, reads the service plugin's own cache, no HTTP, no timeout, nothing to
hang the add, and no service named anywhere in it. `_fillFromPlayingMeta` is the one carrier.

**MEASURED, not inferred (server log, 2026-09-04) — the shape that reader really returns.**
`Plugins::Spotty::ProtocolHandler::getMetadataFor` for `spotify://track:5ObyGDxNWH0Uuuk3NvC5r8`:

    url => "spotify://track:5ObyGDxNWH0Uuuk3NvC5r8"
    album => "Save My Love"       artist => "Kygo, Khalid, Gryffin"
    title => "Save My Love"       year => 2026

Three facts follow, and none of them is a guess. (1) **The play URL is byte-identical to what LL
stores** — the load-bearing assumption of the whole contract, now observed rather than argued.
(2) `album` is a plain STRING with no album id anywhere, which is the measurement `_canClassifyTrack`
rests on. (3) **Spotty joins EVERY credit at play time** ("Kygo, Khalid, Gryffin") while
`spottyArtistName` stores only the first — so for a multi-credit track the stored artist and the
played artist differ and the metadata fallback cannot match. Harmless, because the URL matches;
recorded because it is the clearest measure of how far naming can drift while Played still works.

Two smaller decisions recorded so they are not re-argued: a BARE `YYYY - ` prefix is deliberately
NOT stripped (indistinguishable from a real title like "1979 - The Year In Review"; podcast
episodes carry day precision essentially always), and the artist is dropped only on the browse
shape — a queue or Now Playing add arrives with `$ALBUMNAME` populated and its artist already came
from the handler. **No migration is owed**: `main` is 0.1.93, so neither Deezer episodes (0.1.124)
nor Spotify ones (0.1.126) exist in any released build, and the live list holds none.

**Round of 2026-09-04 — CLOSED. Five findings; the user overruled two and redirected the
round, which is why the fix is a CONTRACT rather than five patches.** Run against the 0.1.126
tree. Shipped as 0.1.127. Tests 14 suites green, `t_addpath.pl` 204 → 205.

| # | finding | disposition |
|---|---|---|
| 1 | `_insertTrackRow`'s `findTrackByArtistTitle` guard is album-WILD, so two same-titled episodes from the same publisher collide and the second is silently refused | **DECLINED, then RE-RAISED on new information and FIXED in 0.1.128** — see below. Declined as remote while the design stored publisher-as-artist and show-as-album; the basis changed when the fill turned out to answer nothing, leaving BOTH fields empty |
| 2 | `_saveSpotifyEpisode` reads the show from BOTH response shapes but the publisher from only one, so a raw episode object silently loses the artist | **SUPERSEDED** — the whole sub was deleted. The finding was right about the asymmetry and, more importantly, about WHY it existed: nobody had measured the shape |
| 3 | the no-Spotty fallback logs nothing, unlike `_saveTrackClassify` which logs its decision unconditionally | **SUPERSEDED** — same deletion; `_fillFromPlayingMeta` logs each field it fills |
| 4 | `_contextMenuQuery` extracts `$rec->{ref}` twice, 22 lines apart, the second defended as "its own narrower copy" when it is identical | **OPEN, cosmetic** — left alone this round to keep the diff to one concern |
| 5 | the episode lookup runs even when the row already has album and artist, costing a round trip and up to 6s | **DECLINED by the user** — "adding from now playing of a podcast is also highly unlikely"; and moot after the deletion |

**WHAT THE ROUND WAS ACTUALLY FOR, and the reason it is worth reading when the next Spotify
finding appears.** The user's objection was not to any finding but to the pattern: *"you keep
coming up with contradictions each review and it is not consistent."* He was right, and the
cause was structural rather than a run of bad luck. **Every Spotify fact in this file had been
derived by reading fragments of Spotty's source rather than by observing a payload, and each
test stub was then written from the same assumption — so a stub could only ever confirm the
guess that produced it.** Four rounds each overturned an earlier round's Spotify assertion
(episodes "are Spotify tracks", `_wishListable` on `(kind, source)`, Deezer "cannot cheaply
yield an album id", the episode response shape). 0.1.126 shipped two instances of the
stub-confirms-the-guess failure in a single release — the `plugin.state` fixture, caught by
review, and the episode-API stub, not caught by anything.

**The three things that ended it, all measurements:**
1. `Played.pm` says a TRACK row is matched on its play URL and only falls back to names. That
   made most of the naming work optional and the async subsystem unjustifiable. It had been
   sitting in the code the whole time, unread — see *Identity: what Played actually matches on*.
2. Spotty's `getMetadataFor`, from the live server log, returns `spotify://track:<id>` —
   byte-identical to what LL stores. The URL contract is observed, not argued.
3. That account is rate-limited by Spotify (`429`, in the same log), so the API lookup 0.1.126
   added could never have succeeded on the test rig at all.

**The rule that comes out of it, and it is not Spotify-specific:** when an add needs a value the
play side will later compare against, get it from the play side's own reader
(`Sources::playingMeta`), never from a prediction of what that reader will say. And **a stub
written from the same assumption as the code under test proves nothing** — model it on captured
output, or accept that the test cannot fail for the reason you care about.

**THE ONE FINDING THAT CAME BACK, and the ledger rule working as intended.** #1 was declined on
the user's judgement that two podcasts sharing a name AND a publisher is remote — sound for the
facts at the time, because the 0.1.126 design stored the publisher as the artist and the show as
the album. When the live test showed `_fillFromPlayingMeta` answers NOTHING on the browse path,
both of those fields went empty and the key collapsed to `|||t:<title>`: the collision no longer
needed a shared publisher, only a shared TITLE. "Trailer", "Episode 1", "Introduction" and
"Chapter I" are titles dozens of shows share. Re-raised under the ledger's own rule (new
information, and say what changed), and fixed in 0.1.128 by `DB::episodeKey`.

**Worth keeping about the failure mode:** it was not "the episode did not save". `DB::add`
returned the FIRST row, so the user got a confirmation toast and a single list row whose play url
belonged to a DIFFERENT show's episode. A silent wrong-audio row is a much worse bug than a
refused add, and the toast is what hides it.

**THE TRADE THE FIX MAKES, recorded so it is not later reported as a defect.** A url-keyed episode
has no `|t:<title>` segment, so `DB::findSavedTrack` — Played's METADATA fallback — can never
match it. **The CONCLUSION stands and the fix must not be reverted; reason (1) as first written
was WRONG and was corrected in 0.1.132 — read the correction, not the original.** It said the
fallback "could not match in the field anyway, because a streaming episode stores no artist and no
show while the handler reports a publisher and a show at play time". Checked against both vendors'
source: a WARM handler reports the show on both services and the publisher on Spotify, and
`_fillFromPlayingMeta` stores exactly what that same reader answers — so on a warm cache the two
sides line up perfectly and the fallback WOULD have matched. Proved by running it: a Deezer episode
keyed the pre-0.1.128 way is found by `findSavedTrack`; keyed the new way it is not.
What actually makes the trade free is reason (2), which is unaffected: the fallback exists for url
DRIFT, and episode URIs do not drift — `spotify://episode:<id>` and `deezerpodcast://<id>` are
stable ids, not signed or expiring stream urls, and each service builds its favurl and its play url
from the same id (verified in `_renderEpisode` and `OPML::episodesList`). So `findTrackByUrl` is the
whole story for an episode and the fallback is redundant rather than lost. `t_addpath.pl` asserts
the absence explicitly so it cannot be "fixed" back.
**The lesson, and it is the ninth round's lesson again: a withdrawal is only as durable as its
REASON.** This entry carried a plausible-sounding wrong reason for four days and it is exactly what
made the 2026-09-04 audit re-open a settled decision. Reason (2) alone was always sufficient.

*Not investigated further, by the user's instruction:* Spotify playback does not work on the
test rig. Established this round: the helper exists and is current (spotty 2.1.2 / librespot
0.8.0), the architecture matches, ports 4070 and 443 are open, credentials are present, and it
is not lock contention — the helper simply produces no audio and no log output. The account is
separately rate-limited on the Web API. **No add path may therefore BLOCK on a Spotify API call
succeeding**, which is now a measured constraint rather than a preference. The line is whether
the add depends on the answer: `_backfillStreamingArtist`'s Spotify branch still calls
`$api->album` and is fine, because it is fire-and-forget — no `setStatusProcessing`, no timeout,
a guarded callback — so a 429 costs one row its artist rather than hanging an add. That is the
distinction, not "no API calls".

**Round of 2026-09-04 (second) — CLOSED, one finding, FIXED.** Run against the
0.1.134 tree. `Podcast::resolveEpisode` walked on past a non-perfect match while
`_savePodcastEpisode`'s 20s timer — equal to one feed's `HTTP_TIMEOUT` — could
fire and REJECT the add, discarding an episode already found. Fixed in 0.1.135
(`RESOLVE_BUDGET`, per-feed cap, the caller's timer derived from it); see the
version history. **What this round says about the ledger itself:** every other
candidate the review raised was already in §A/§A2 and was correctly dropped
before reporting — `materialAtLeast`'s version parse, `_migrateArtistPrefix`'s
four-column SELECT, `_migrateRefold`'s NULL sentinel and its collision retry,
`%ours` and `favorites-*`, `foldLatin`'s `utf8::is_utf8` gate, and
`_canClassifyTrack` omitting `spotify`. The one finding that survived was the one
about an INTERACTION between two files, which no single-file settled verdict
could have covered.

### D. ADDING TO THIS LEDGER

When a finding is declined, or accepted-but-deferred, add it here in the same
session — one line, with the reason. A decision that lives only in a chat
transcript will be rediscovered as a finding within days. That is the whole
mechanism this ledger replaces.

## Server Details
- **LMS Server**: 192.168.1.234:9000
- **OS**: DietPi (Debian Bookworm)
- **Service**: `lyrionmusicserver`
- **Plugin location (manual install)**: `/var/lib/squeezeboxserver/Plugins/ListenLater/`
- **Log**: `/var/log/squeezeboxserver/server.log`
- **Plugin DB**: `<server cachedir>/listenlater.db`

## Testing the live server WITHOUT SSH (important)
SSH to the box prompts for a password from this environment and is not reliable. Use **HTTP** instead (same channel the ListenBrainz project uses):
- **Log**: `curl -s http://192.168.1.234:9000/log.txt`
- **JSON-RPC**: `POST http://192.168.1.234:9000/jsonrpc.js`, body `{"id":1,"method":"slim.request","params":["<playerMAC>",[<cmd>...]]}`. Menu/feed queries **need a real player MAC** as the first param — an empty string returns instant HTTP 000 (not a hang). Known player: `dc:a6:32:77:ea:e0`.
- Handy probes:
  - feed: `["<mac>",["listenlater","items","0","10"]]`
  - context menus: `["<mac>",["trackinfo","items","0","100","track_id:<id>","menu:1"]]`, `[…,"albuminfo",…,"album_id:<id>","menu:1"]`
  - exists: `["","can","listenlater","items","?"]` (bogus tag → `_can:0`, so it's a genuine signal)
  - apps list: `["","apps","0","100"]`; plugin state: `["","pref","plugin.state:ListenLater","?"]`
- INFO logs from a plugin only appear in `log.txt` if its category is at INFO; while debugging, log at **WARN** to guarantee visibility.

Installing still needs filesystem access (the user runs the unzip+chown+restart); all verification is done over HTTP afterwards.

## Install Commands
```bash
sudo rm -rf /var/lib/squeezeboxserver/Plugins/ListenLater
sudo unzip -o ListenLater.zip -d /var/lib/squeezeboxserver/Plugins/
sudo chown -R squeezeboxserver:nogroup /var/lib/squeezeboxserver/Plugins/ListenLater
sudo systemctl restart lyrionmusicserver
```
File ownership must be `squeezeboxserver:nogroup` (DietPi), and the zip must extract directly as `ListenLater/` (no extra `Plugins/` wrapper).

## File Structure
```
ListenLater/
├── Plugin.pm     # OPMLBased init; registers TrackInfo + AlbumInfo "Add" providers; opens DB; starts play-detector
├── Browse.pm     # top-level (Listen Later / Wish List / Played / Settings); album rows; per-album submenu (Play / Move to … / Remove)
├── DB.pm         # SQLite (DBI/DBD::SQLite) connect + migrate + CRUD; dedupe by normalised source|artist|album
├── HomeExtras.pm # Material home-page shelf (HomeExtraBase subclass LLHome -> Browse::homeShelf)
├── Sources.pm    # per-source adapters: capture a record from a track/album, rebuild a playable node, match helpers
├── Played.pm     # subscribes to playlist newsong/stop/clear; threshold logic to auto-move albums to Played
├── Settings.pm   # default sort, played threshold %, streaming track count, auto-Played toggle
├── install.xml   # <extension> singular; <icon> = …Icon_svg.png; <optionsURL>; <homepageURL>
├── strings.txt   # PLUGIN_LL_* strings (EN)
└── HTML/EN/plugins/ListenLater/{settings.html, html/images/*Icon*.svg|_svg.png|.png}
```
Section/app icons (see "Icon system"): `ListenLaterIcon.{svg,_svg.png,.png}` (app icon + Listen Later section, the music-note+clock design), `PlayedIcon.{svg,_svg.png,.png}` (Google `music_history`, recoloured), `WishListIcon_MTL_icon_shopping_cart.png` (Material font trolley, single PNG fallback).

## Key Technical Decisions
- **Base class**: `Slim::Plugin::OPMLBased`, `is_app => 1` (Apps section), `menu => 'radios'`. Feed is `Browse::topLevel`.
- **Add path**: there is **no global hook** into every streaming plugin's own album "…" menu. The universal path is `Slim::Menu::TrackInfo->registerInfoProvider` (fires for local **and** remote tracks); `Slim::Menu::AlbumInfo` adds a direct entry for library albums. Both return an OPML drill item (`type=>'link'`, `url=>coderef`) that performs the add and shows a brief confirmation — renders in Material and classic. Custom providers are confirmed to show in `trackinfo`/`albuminfo menu:1` (alongside "Save to Favourites", "On Qobuz").
- **Register defensively**: `require Slim::Menu::TrackInfo`/`AlbumInfo` and wrap each `registerInfoProvider` in `eval` — an unguarded call dies and aborts the whole plugin if the module isn't loaded yet.
- **Storage**: SQLite over prefs (prefs give no query/sort/dedupe). One `albums` table; display metadata denormalised so the list renders without re-hitting any service; `ref_json` carries only what's needed to replay (album_id / passthrough / `_svc`). `UNIQUE(source, dedupe_key)` prevents duplicate adds; re-adding an album already saved in **any** section is a no-op (0.1.21) — it is not moved. `status` is `later` | `played` | `wishlist`; `add($rec,$status)` sets the target list for a new album (`later` default, or `wishlist`).
- **Replay**: library → load album tracks by `album.id`. Streaming → if a native album id was captured, rebuild the service's own album node (reattach `Qobuz…QobuzGetTracks` / `Bandcamp…get_album`, the same coderef round-trip the sibling uses); otherwise **search the originating service** by "artist album" and keep the title+artist match (resilient — no hard dependence on capturing the album id).
- **Played detection**: subscribe to `[['playlist'],['newsong','stop','clear']]`; per player, count distinct tracks of the currently-playing saved album. A release with a MEASURED length (library live count, or a stored streaming `track_count`) uses `Played::tracksNeeded` = `played_threshold`% of it, **rounded DOWN**, floored at 2 for a multi-track release (default 90 — see "The Played threshold"); only a release whose length can't be measured falls back to `streaming_min_tracks` distinct tracks (default 4, best-effort). Same path for inside- and outside-plugin plays; `watch_outside` is the master toggle.
- **Remote vs local detection gotcha**: trust `$track->remote`; do **not** treat a `file://` URL as remote (`$url =~ m|://|` matches `file://`). And `$remoteMeta` is **undef** for local tracks — dereferencing it under `use strict` dies and the menu wrapper swallows the error → no item appears. Always `$remoteMeta = {} unless ref $remoteMeta eq 'HASH'`.
- **install.xml**: `<extension>` singular (manual installs). `<icon>` → `…Icon_svg.png` (Material `_svg.png` convention loads the sibling `.svg` and recolours it; the SVG must use `#000`, not `#000000`). PNGs are real transparent RGBA (Pillow), not JPEGs misnamed `.png`.

## Icon system (0.1.24)
Three section icons, set in `Browse.pm` (`_iconFor($status)` → `_header`/`_albumRow`); the app icon (install.xml/home shelf) is `ListenLaterIcon`.
- **Two Material conventions, picked per icon** (authoritative rules mirrored from the sibling ListenBrainz plugin's "Icon System"):
  - **`_svg.png` recolour**: Material loads the sibling `.svg` and theme-recolours it (string-replaces the literal `#000` → theme colour, so the SVG MUST use `#000`, never `#000000`). Used by **Listen Later** (`ListenLaterIcon`, music-note+clock) and **Played** (`PlayedIcon`, Google `music_history`). Ship 3 files: `.svg` (source, `#000`), `_svg.png` (install.xml ref + non-Material fallback), `.png` (generic fallback).
  - **`_MTL_icon_<name>.png` font icon**: Material's `mapIcon`/`icon-mapping.js` parses `<name>` out of the filename and renders its own themed **font** glyph; the PNG itself is only a minimal non-Material fallback (single file, no `.svg`). Used by **Wish List** (`WishListIcon_MTL_icon_shopping_cart.png`) so it exactly matches the "Add to Wish List" context-menu trolley.
- **Why Wish List uses the font but Played can't**: Material's bundled icon font (Release 6.4.3, matching the box) **has** `shopping_cart` but **not** `music_history` (verified via the font's GSUB ligatures with fontTools) — an `_MTL_icon_music_history` would render blank. So Played's `music_history` had to be shipped as a recoloured `.svg` instead. (Confirm new font icons exist in `test-artifacts/lms-material/.../font/MaterialIcons.ttf` before using `_MTL_icon_`.)
- **No SVG rasteriser on this Mac** (no cairo/rsvg/inkscape; svglib's renderPM needs cairo). The PNGs are generated **qlmanage → Pillow** (the documented sibling-plugin path): `qlmanage -t -s 512` renders the `.svg` onto white, then Pillow does luminance→alpha (black art, transparent bg), trims to content bbox, and centres on a 256² canvas with 8% pad. Black-on-transparent so both the recolour and classic fallbacks look right.

## How the "Add" entries REACH Material (0.1.95, retiered 0.1.110) — registered, not written

**Material's registration API arrived in TWO steps, and which one the user is running decides
everything below.** `Plugins::MaterialSkin::Plugin::registerCustomAction($section, $action)`
stores the entry in Material's own `$PLUGIN_CUSTOM_ACTIONS`, served over the CLI query
`["material-skin","plugin-actions"]`; `customactions.js` fetches that at app start into
`pluginCustomActions` and `getSectionActions` walks **both** lists — `customactions.json` first,
plugin-registered second.

### The DELIVERY TIER (`Plugin::_materialActionTier`) — capability AND version

| tier | Material | what happens |
|---|---|---|
| **0** | no `registerCustomAction` (< 6.4.6, or no Material) | the shared `actions.json` carries everything, byte for byte as before 0.1.95 |
| **1** | 6.4.6 / 6.4.7 | the "Add" entries register; `track`, `queue-track` and every empty suppressor (`podcasts-*` among them since 0.1.136, when it stopped being a populated override) still have to be written to the file |
| **2** | **>= 6.4.8** (upstream PR #1257) | **everything** registers, suppressors included, and the file is **pruned**, not written |

**Tier 2 needs BOTH tests, and the version half is not belt-and-braces.** PR #1257 is what made
`registerCustomAction($section)` — one argument, no action — mean *declare an EMPTY category*.
On 6.4.6/6.4.7 that identical call pushes **undef** into the section, Material serves it as
`{"<cat>":[null]}`, and `customactions.js` then reads `sect[i].locked` off the null and throws —
taking out every custom action in that section, **other plugins' included**. So the
empty-section call is tier-2-only and must never be reached by capability alone.

There is **no side-effect-free capability probe** to prefer over the version parse:
`$PLUGIN_CUSTOM_ACTIONS` is a file-scoped `my` in Material's `Plugin.pm` so it cannot be read
back, and probing by registering a section cannot be undone (there is no unregister). A
dev/test build (non-numeric version) is treated as newest, like `Browse::_headerType`.

**The parse itself is `Sources::materialAtLeast` (0.1.114), shared with the other two gates** —
the 6.4.4 diagnostics line and `Browse::_headerType`'s 6.4.3. It answers `undef`/`1`/`0`, and
every caller reads it as `? A : B` because "cannot tell" and "too old" want the same safe
answer at all three. **Pass it a scalar, never an inlined `_materialVersion()`** — that sub is
`return eval { ... }`, whose empty list on failure collapses the argument list and lands this
gate on tier 2 for every Material-less install. See the 0.1.114 entry; it shipped once.

### What goes which way

`Plugin::_materialActionSet($tier)` builds every set from ONE definition, so there is never a
second spelling of a command; the tier decides only which bucket each lands in.

| | tier 0 | tier 1 | tier 2 |
|---|---|---|---|
| `album`, `album-track`, `playlist`, `playlist-track`, `online-album`, `online-track` | file | **registered** | **registered** |
| `track` (Now Playing), `queue-track` | file | file | **registered** |
| `podcasts-album`/`-track` | file | file | **registered** |
| `listenlater-*`, `LLHome-*`, the radio empties | file (empty) | file (empty) | **registered** (empty sections) |

**THE FAILURE MODE TO KNOW: the two lists are MERGED, so registering while our old entries are
still in the file shows every "Add" TWICE.** That is why the file pass still runs on every tier —
on tier 1 its strip pass is the upgrade, and on tier 2 `_pruneMaterialActions` is.

### Tier 2 — removing what earlier builds left behind (`_pruneMaterialActions`, 0.1.110)

On >= 6.4.8 nothing of ours belongs in `actions.json`, so the only work left there is taking it
back out. **This is not a migration with an end date** — the file is SHARED and survives plugin
updates and reinstalls — which is why the first thing the prune does is return when the file is
absent. After one successful prune that is every subsequent call, for one `stat()`.

**It never writes and never clobbers.** The tier-0/1 write hard-sets our own suppressor
categories and creates radio ones with `||=`; the prune does neither. It strips, deletes what is
ours *and now empty*, and puts back only what Material REFUSED.

> **A hand-written `actions.json` is a real possibility and must be assumed.** LL has always
> MERGED into this file rather than overwriting it — the strip pass only removes entries
> `_isOurAction` matches, entries are `push`ed, radio categories use `||=` — so a user's own
> custom actions have coexisted with ours the whole time and nothing would have told them
> otherwise. "Nobody has one, it would have broken" is **false**.

**The file is DELETED when the prune empties it.** Verified against the served 6.4.9 bundle: the
`axios.get` of `customactions.json` has a `.catch`, so a 404 leaves `customActions` undefined;
`getCustomActions` tests `if (customActions || pluginCustomActions)` and `getSectionActions`
tests `if (list && list[section])`. A missing file and an empty one are identical to Material.
Anything foreign keeps the file alive, so "remove ours" and "leave theirs alone" never conflict.

**...but only as far as the file can be READ (0.1.125).** "Anything foreign keeps it alive" was
true of a file we could PARSE and false of one we could not, and `_readMaterialActions` answered
`{}` to three different questions — absent, could-not-open, could-not-parse. So a truncated
`actions.json`, or a valid one left root-owned/0600 that LMS (running as `squeezeboxserver`)
cannot open, reached this delete with an empty `$data` and was removed, logging *"removed the
now-empty"* about a file full of someone else's actions. Both reproduced. The reader now answers
**`undef` for unreadable**, and all three callers — this prune, the tier-0/1 write and the clear
pass, which overwrote for the identical reason — return without touching the file. **An EMPTY
file still reads as `{}`**: it holds nothing of anyone's, so the husk removal above is unchanged,
and the suite pins that boundary in both directions.

Bailing out cannot double a menu, which is the standing hazard here: Material streams THIS file
for `/material/customactions.json` (`MaterialSkin::Plugin::_customActionsHandler`) and the client
does `customActions = eval(resp.data)` inside a `.then`. A file we cannot open does not stream;
one we cannot parse does not eval. Either way `customActions` stays undefined — so there are no
file entries to appear beside the registered ones.

**Two fallbacks keep it honest, and both are gated:**
- `%UNREGISTERED` — positives Material refused. Written to the file even if the file has to be
  created to do it (the early return is `!-e $file && !%fallback && !%emptyFallback`, *not* a
  bare `-e` test — that bug was caught by the new tests, not by review).
- suppressors whose empty-section registration failed. **Gated on `$REGISTERED_N`:** a
  suppressor exists to hold OUR live `online-*` pair off our own rows, so with nothing of ours
  registered there is nothing to hold back, and writing empty `<cmd>-*` categories anyway would
  suppress **another plugin's** `online-*` on every radio and podcast row. The pref-off-at-startup
  path reaches the prune with nothing registered and must leave no trace.
- `$departing` (uninstall/disable) forces both to empty — 0.1.108's rule, unchanged: on the way
  out there is no next run to protect, so nothing may be stranded.

**Turning the pref ON mid-run REGISTERS (0.1.111).** `Settings::handler` mirrors
`postinitPlugin` exactly — register, then write. It used to only write, on the belief that
registering outside postinit was unsafe; `$REGISTERED` is the per-run latch that makes it safe,
and it is FALSE in exactly this case because the pref being off at startup is what stopped
postinit registering. On tier 2 that belief was fatal: with no file write left, ticking the box
did nothing at all until a server restart.

**Ordering: registration comes FIRST, in the same run.** The file empties are load-bearing until
the equivalent sections are registered. `postinitPlugin` and the deferred pass both call
`_registerMaterialActions` before the write/prune, long before any client fetches either list, so
there is no window.

**`_isOurAction` no longer guesses from titles (0.1.110).** It used to match our four titles when
an entry carried no `lmscommand`. It cannot ever have caught anything of ours — **every** version
of `_materialActionSet` back to the 0.1.25 rebrand builds every action with an `lmscommand`
(checked across the twelve commits that touched it) — so that branch could only ever delete a
THIRD PARTY's `script`/`command`/`weblink` action that happened to share a title.

**`registerCustomAction` PUSHES — no de-dupe, no unregister.** So every section is handed over at
most once per server run, and **BOTH halves are tracked PER CATEGORY** — `%REGISTERED_POS` for the
positives (0.1.119), `%REGISTERED_EMPTY` for the empty suppressors — because both sets GROW.
The suppressors grow because TuneIn's radio directory arrives asynchronously, so the +60s deferred
pass finds commands postinit could not (0.1.56). The positives grew because on tier 2 the
`podcasts-*` override folded into them gated on `Podcast::hasFeeds()`, so subscribing to a first
feed mid-session added a section — which the old single `$REGISTERED` latch then refused for the
rest of the run (0.1.119). **That specific case is gone as of 0.1.136** — `podcasts-*` is now an
EMPTY suppressor, so it grows the SUPPRESSOR half if anything, not the positives. The per-category
tracking stays: it is the correct shape whether or not a growable positive currently exists, and
reverting it would re-introduce the 0.1.119 latch bug the moment one is added again. **`$REGISTERED` survives, but it now answers only "did the API half
RUN"** — the flag the diagnostics read to tell "delivered nothing" from "never asked" — and it is
no longer what decides whether a given section is offered.
With no unregister, turning `material_action` OFF removes the registered entries **at the next
restart** — and on tier 2 the suppressors are registered too, so until then "Add" still correctly
does *not* appear inside our own list.

**Downgrades self-heal.** Every file-writing path is kept. Material downgraded, rolled back or
disabled drops the tier and the tier-0/1 write rebuilds the file the prune removed.

**Historical — the three gaps, all now CLOSED upstream.** Through 6.4.7 Material resolved an app's
own `<command>-<type>` override with `appCat in customActions` (the file object only); `registerCustomAction`
took an action and pushed it, so "this category exists and is empty" had no spelling; and
`track`/`queue-track` were snapshotted in the browser on `bus.$on("customActions", …)` whose only
`$emit` was inside the `customactions.json` `.then`. LL's fix for all three was submitted as
[PR #1257](https://github.com/CDrummond/lms-material/pull/1257), **merged verbatim in one commit
(`8f3e777be`, merge `f4cfb95`) and released in Material 6.4.8** — though it is in neither the 6.4.8
nor the 6.4.9 ChangeLog, so "did it ship" can only be answered from the tree, not the release notes.
Drafts kept at `docs/material-plugin-action-sections.patch` + `docs/PR-body-plugin-sections.md`.

**The 0.1.57 app-start cache lesson applies to the FILE HALF ONLY.** `customactions.json` is fetched
with a `?r=<material version>` cache-buster, so a late write is invisible to an open tab until a hard
refresh; the plugin-actions CLI query is not browser-cached. On tier 2 there is no file half left, so
the only residue of that lesson is that a section registered LATE (the +60s pass) is still invisible
to an already-open tab — the snapshot is taken at app start either way. The `debug_log` snapshot's
first lines now name the tier and count the registered empty sections.

**Custom actions on SEARCH results came free in 6.4.6** — `buildSearchResp` emits `itemCustomActions`
keyed by type and `browseActions` falls back to `getCustomActions(<category for the stdItem>)`, so
LL's existing categories appear on library search results with **no plugin change**.

## Material custom actions on streaming "…" menus (the hard problem — solved, released in Material 6.4.4)
Goal: an **"Add to Listen Later"** entry on a streaming **album row while browsing** (Qobuz New Releases, etc.), where the service plugin owns the "…" menu so TrackInfo/AlbumInfo providers can't reach it. Material's **custom actions** (`prefs/material-skin/actions.json`, served at `/material/customactions.json`) are the only hook — but out of the box they appear on **library** items only.

**STATUS (2026-07): MERGED upstream AND RELEASED in Material 6.4.4** — [PR #1235](https://github.com/CDrummond/lms-material/pull/1235) landed on `dev` (`b631754`), merged to `master` (`519b03a`), and shipped in the **Material 6.4.4** release (tag `6.4.4`, master `9be80db`). So there is **no more local bundle patching** — the feature ships in stock Material. Verified live on the box: it runs the stock 6.4.4 deferred bundle (561 KB, i.e. the un-patched size — the old patched build was 889 KB) and the streaming online actions are served and functional. The released code does exactly what the patch did — sets `i.service`=browse command (exposed as **`$SERVICE`**), sets `i.album=i.title`/`i.artist=i.subtitle`, and resolves the per-app `<command>-<type>` category with `online-<type>` fallback. The `$SERVICE` streaming feature is **6.4.4+**; `header-basic` (below) predates it (**6.4.3+**). On Material older than 6.4.4 the streaming-browse "Add" degrades to *entry absent* (the online browse path doesn't exist there) — every other add path is unaffected. *(That was true of 6.4.4: no Perl-side registration API existed, so the plugin's direct `actions.json` write was the only mechanism. **Material 6.4.6 added one** — see the section above; the streaming `$SERVICE` mechanics described below are unchanged, only the delivery of the entries moved.)* The original full trace, kept for context:

- **Bundles**: Material ships two minified JS bundles. `material.min.js` (**main**) contains `customactions.js` (`getCustomActions`, `doReplacements`, `doCustomAction`) and `browse-page.js` (renders the menu). `material-deferred.min.js` (**deferred**) contains `browse-resp.js`, `browse-functions.js`, `standarditems.js`. The deferred build list is the `addJsToDocument("html/js/",[…])` array in `index.html`.
- **Why library-only**: per-item custom actions are added in `browse-functions.js` only when `item.stdItem < STD_ITEMS.length` **and** `STD_ITEMS[item.stdItem].actionMenu` contains the `CUSTOM_ACTIONS` (`-2`) marker. Online items have `stdItem` **300/301** (`STD_ITEM_ONLINE_ARTIST/ALBUM`), far beyond `STD_ITEMS.length` (~16) — so they **bypass that whole path**. (And `standarditems.js` has `CUSTOM_ACTIONS` commented out on the online-album entry anyway.)
- **How online/app items get their menu**: library content comes via `*_loop` branches (`albums_loop`, `titles_loop`, …); **app/streaming content comes via the SlimBrowse `item_loop` branch**, which builds each item's own `i.menu` array directly. The context menu renders `menu.itemMenu = item.menu`, and the `CUSTOM_ACTIONS` template (`browse-page.js`) iterates the **view-level** `itemCustomActions`. So showing a custom action on an online item needs BOTH: push `CUSTOM_ACTIONS` into that item's `i.menu`, **and** set `resp.itemCustomActions` (wired to the view via `browse-functions.js:676`). Setting only `resp.itemCustomActions` (my first patch) does nothing.
- **The real blocker — Qobuz album rows have no identity**: verified over JSON-RPC, a New Releases album row is only `{type:"playlist", text:"Album (Hi-Res)\nArtist (YYYY)", params:{item_id:"6.0"}, icon:…}` — **no `favorites_url`, no `metadata`** (even with `wantMetadata:1`; LMS is 9.1 so the server supports it — the Qobuz plugin just doesn't emit it). Title/artist/year are only in the 2-line `text`; play works via `base.actions.play` + the positional `item_id` (non-durable). **Track** rows inside an album *do* carry `presetParams.favorites_url: qobuz://<trackid>.flac` + `favorites_type:audio`. So Material can't classify album rows as online albums — and neither can a classification-based patch.
- **Working fix** (in `browse-resp.js`, the `item_loop` per-item section, after the play-action block): key off **playability** not classification — `addedPlayAction && undefined==i.stdItem && !isFavorites && !isAppsTop` (these are app/online rows; library albums never reach `item_loop`). For such rows, set `i.album=i.title` / `i.artist=i.subtitle` so `$ALBUMNAME`/`$ARTISTNAME` resolve, push `CUSTOM_ACTIONS` into `i.menu`, and set `resp.itemCustomActions=getCustomActions("online-album")`. Service identity = the browse **`command`** (`data.params[1][0]`, e.g. `"qobuz"`), set on `i.service`. The merged Material exposes it as the **`$SERVICE`** replacement variable, so the plugin's `online-*` commands carry `svc:$SERVICE` (0.1.28). (The pre-merge local patch *baked* a literal `svc:<command>` into each `lmscommand` instead — that workaround is gone now that `$SERVICE` exists.)
- **Variable map** (`doReplacements`): `$ALBUMNAME`←`item.album`, `$ARTISTNAME`←`item.artist`, `$TITLE`←`item.title`, `$FAVURL`←`item.presetParams.favorites_url`, `$IMAGE`←`item.image`, `$ALBUMID`←`item.album_id`. Online album rows populate none of these by default — hence setting `item.album`/`item.artist` in `browse-resp.js`.
- **Plugin side** (`addctx`): reads `svc` as the authoritative source (no guessing); strips a trailing `(YYYY)` off the **artist** line → year, and a format qualifier (`(Hi-Res…)`/`(Explicit)`/…) off the **album**. `Sources::sourceFromImage` (cover host → service) is a fallback only. `_writeMaterialActions` strips every prior LL entry from all categories, then writes the active set with the flat-array `lmscommand` shape (NOT the `{command,params}` `lmsbrowse` shape): library `album`/`album-track`/`playlist`/`playlist-track`; streaming `online-album`/`online-track` as a single Add/Wish-List pair; and the own-view suppressors `listenlater-*`/`LLHome-*` = []. **We do NOT scope "Add" per streaming service anymore** (0.1.51 removed the 0.1.46–0.1.50 experiments — scheme filter, app/radio blocklist, home-shelf suppression). Instead the **add commands reject any source we can't replay** (`_isReplayableSource` = library or `Sources::_serviceCan`): an unsupported service's "Add" button is a harmless no-op with a "not supported" toast, never a stored-but-unplayable row. This is the one reliable gate (runs on every add path, unlike the flaky/unscopeable Material button). **Deliberately NOT written:** `online-artist` (dropped 0.1.32 — we save albums, not artists), and the strip pass clears any `online-artist` entry an older version left behind. **The plain `track` category is NOT in that group, whatever the rest of this paragraph implies** — it was dropped in 0.1.34 and **restored in 0.1.62**, so it is in `%cats` today and reaches Material on every tier (verified live on 0.1.117: `registered sections = … track(2)`). Its sole consumer is Material's Now Playing screen (`nowplaying-page.js` `getCustomActions("track")`); browse track lists use `album-track`/`playlist-track` and the queue `queue-track`, so it puts "Add" on Now Playing and nowhere else.
- **Building/testing a dev Material (the feature is now released in 6.4.4 — this is only for future Material work)**: the clone is `test-artifacts/lms-material` (gitignored; remotes `origin`=CDrummond, `mine`=fork). The streaming feature no longer needs any local build/patch — stock Material 6.4.4+ carries it. To test *further* Material changes, build a real minified Material plugin from `origin/master`: `python3 mkrel.py test` → `lms-material-test.zip` (its contents = a `MaterialSkin/` plugin: install by replacing the box's MaterialSkin dir, chown `squeezeboxserver:nogroup`, restart; test in an **incognito** window — Material caches the bundle at app start). `mkrel.py` needs **Java 17** (runs the bundled Closure jar) + python **`requests`** (both installed on this Mac); CSS minify is pure-Python, no LESS step. Verify a build with e.g. `unzip -p lms-material-test.zip HTML/material/html/js/material.min.js | grep -c '\$SERVICE'`. *(Historical: before the merge, with no JDK on this Mac, the deferred bundle was hand-**concatenated** from the raw 6.4.3 sources and dropped onto the box. No longer needed.)* Proposal draft (now historical): `docs/material-online-custom-actions-proposal.md`.
- **Suppressing the action inside our OWN view (the per-app override)**: our plugin is itself an app, so its list rows are playable `item_loop` items → `isAppItem` matched and "Add to Listen Later" showed on albums already in the list (re-adding would bounce a *Played* album back to *Later*). Fix: the patched Material resolves the category for app items as `getCustomActions(command+"-"+btype)` **if** `command+"-"+btype in customActions` (the in-check is needed because `getCustomActions` returns `undefined` for an empty category), else falls back to `online-<btype>`. The plugin writes empty `listenlater-album`/`-track`/`-artist` categories, so its own rows show no "Add" while streaming services still do. This is also a general feature (any app can customise or suppress actions on its own view).
- **Remove/Move placement — kept in "… → More" (0.1.18 reverted in 0.1.19)**: they live in each row's `itemActions.info` → `listenlater contextmenu` query, and refresh the list **in place** via `nextWindow => 'parent'` (0.1.15). Putting them at the *top* of the "…" is possible as Material custom actions matched by the stock `$TITLE` variable (no db-id needed — identify the row by its displayed name, like Add) — but a top-level custom action can only refresh by `lmsbrowse` re-list (new page + awkward back path), and **in-place** refresh would need a second Material patch (`browse-page.js` `itemCustomAction` → `refreshList()` on a `refresh` flag) in the **main** bundle. To keep the Material footprint to the single deferred-bundle patch, we stayed with the More menu. (The would-be inline approach: `listenlater-album` holds `lmsbrowse` Remove/Move using `ltlremove:$TITLE`/`ltlmove:$TITLE`, handled in `topLevel` by matching a lowercased-alphanumeric key of the display name.) The empty `listenlater-*` and `LLHome-*` categories remain — they suppress "Add" on the plugin's own list and home shelf via the per-app override.
- **Context-menu actions: refresh in place, don't go home**: a "More"-menu `do` action's `nextWindow` governs navigation. `'grandparent'` jumps two levels (→ home); use **`'parent'`** — Material's rule `isMoreMenu && nextWindow=="parent"` calls `view.refreshList()`, updating the list where you are. (Path: `itemMoreAction` → `doTextClick(item, true)` sets `isMoreMenu`.) Remove/Move use `nextWindow => 'parent'`. Plugin-only — no Material change.
- **Diagnosing a streaming feed over JSON-RPC**: `["<mac>",["qobuz","items","0","5","item_id:<id>","menu:1","useContextMenu:1","wantMetadata:1"]]` returns the SlimBrowse `item_loop` Material parses — inspect each item's `presetParams`/`metadata`/`params` to see exactly what identity (if any) a row carries.

## Verification checklist (over HTTP)
1. App present: `apps 0 100` shows "Listen Later"; feed returns the three rows.
2. `trackinfo …menu:1` and `albuminfo …menu:1` include "Add album to Listen Later".
3. Add → `listenlater items` count increments; dedupe works.
4. Play album from the list; play ≥ threshold → moves to Played.
5. Remove / Move between sections; persists across `systemctl restart`.

## Prefs Namespace
`plugin.listenlater` — sort, played_threshold, streaming_min_tracks, watch_outside, material_action, played_retention_days, debug_log, threshold_90_migrated.

### A PREF NAME MUST NOT START WITH `_` (0.1.94 — this cost six weeks)

`Slim::Utils::Prefs::Base::set` stores a value only `if ($valid && $pref !~ /^_/)`. A pref whose
name begins with an underscore is **DISCARDED**: no error, no warning, no return value worth
checking, and `get` returns undef for ever after. The namespace reserves that prefix for its own
`_ts_<pref>` write stamps.

So a one-shot migration flag of that shape is not one-shot — it re-runs at **every** server start.
`_rebrand_migrated` (0.1.25) was exactly that, and `_migrateRebrandPrefs` therefore copied the
pre-rebrand `plugin.listentolater` namespace over the user's live settings on every restart until
0.1.94: `sort`, `streaming_min_tracks` and `played_retention_days` all silently reverted, and
**0.1.93's 90% threshold was overwritten with the old 60 seconds after the bump set it, in the same
startup** — which is why that release looked like it had never shipped.

That copy was **deleted outright in 0.1.108** (see the entry), so nothing reads
`plugin.listentolater` any more. The rule above is not retired with it: it still governs
`threshold_90_migrated` and every migration flag added from here on.

**Why it hid for six weeks, which is the more useful lesson:**
- The flag was write-only. Nothing read it back, so the failure had no symptom of its own.
- `set` **suppresses a no-change write**, so re-importing identical values left no trace — no `_ts_`
  update, nothing in the log. The copy only ever *changed* anything on the one restart after 0.1.93,
  where it read as a Played bug, which is the area with a long history of real ones.
- **0.1.93 was verified one level below where it broke.** `tracksNeeded(10) == 9` was proved offline
  and that was taken as the release being verified. **A pref migration is only verified against the
  live box, AFTER a restart** — `["","pref","plugin.listenlater:<name>","?"]` over `jsonrpc.js`,
  which showed 60 the whole time.
- **The test harness could not express it.** `t_stubs.pl`'s prefs stub stored every key and treated
  all namespaces as one store, so both behaviours that produce the bug were absent by construction —
  the vacuous-pass hazard sitting in the STUB rather than in an assertion. The stub now mirrors both;
  `t_prefs_migration.pl` fails 8 ways without the fix.

**`threshold_90_migrated` is now a VERSION, not a boolean** (`THRESHOLD_MIGRATION`, currently 2).
Installs that ran it as 1 had the result thrown away, so re-applying it needed a way to say "ran, but
not the current one". Both migrations live in **`Plugin::_migratePrefs`**, called at module load —
a sub purely so a test can drive them twice over a prepared store.

## The Played threshold: 90%, rounded DOWN (0.1.93)

`played_threshold` defaults to **90** (was 60) and the arithmetic lives in **`Played::tracksNeeded($total)`**,
split out of `_maybeMark` so it is directly testable — see the note below, it matters.

**Why 90.** 60% was a hedge from when a release's length was half-inferred from its TYPE. Since 0.1.90
a length is only ever MEASURED, so there is nothing left to hedge against and 60% moved an album to
Played well before it had been heard.

**Why rounded DOWN, and why that isn't a detail.** `ceil` is fine at 60% and punishing at 90%:
`0.9*N > N-1` for every `N < 10`, so ceil lands back on `N` and "90%" becomes arithmetically identical
to "100%" for any release under ten tracks. A skipped track — or one not licensed in the user's
region — would leave such a release permanently unmarkable. `floor` always leaves a track of slack:

| tracks | 2 | 3 | 5 | 9 | 10 | 12 |
|---|---|---|---|---|---|---|
| need | 2 | 2 | 4 | 8 | 9 | 10 |

**The 2-track guard is load-bearing.** `floor(0.9*2) = 1`, and "1 of 2 seen" is true on the very first
newsong — so a 2-track release would be marked the instant it started and auto-purged days later,
which is **0.1.83's bug arriving by a new route**. `tracksNeeded` never returns below 2 for
`$total > 1`, at ANY threshold (pinned at 90/60/10). A genuine 1-track release never reaches this
path — `_onChange` routes `total == 1` to `_armDeferredMark`'s played-through check.

**Existing installs are migrated once.** `$prefs->init` only fills an ABSENT pref, so every existing
user would have kept 60 silently and the change would have looked like it hadn't worked. `Plugin.pm`
bumps it unconditionally, gated on its own `threshold_90_migrated` flag so it runs once and can never
fight a user who then chooses their own value. Deliberately not "only if it's still 60" — this is a
change of default for everyone, not a repair of one setting.

**`tracksNeeded` exists because the test used to MIRROR the formula.** `t_played.pl` restated
`_maybeMark`'s arithmetic alongside it (on the grounds that `_maybeMark` needs `%tracking` and writes
to the DB), and a copied formula passes just as happily when the original is wrong — the exact hazard
that file exists to catch. It earned itself immediately: the first 90% assertion written was
`12 tracks -> 11`, carried over from the ceil table; the suite said 10 and the suite was right. Under
the old mirror that error would have been copied into both sides and passed. **Rule: pin the sum by
CALLING the code, never by restating it.**

## Played auto-retention (0.1.17)
Played albums are auto-removed after `played_retention_days` (default 7; **0 = keep forever**). `DB::purgePlayed($days)` deletes `status='played'` rows with `played_at < now - days*86400` (items moved back to Listen Later (`status='later'`) or to Wish List (`status='wishlist'`) are never purged). `played_at` is set when the album is first marked Played and is **not** refreshed by replaying an already-Played album (Played detection only tracks `status='later'` rows), so the clock runs from that first mark; to restart it, Move the album back to Listen Later and replay it. Scheduled in `Plugin::postinitPlugin` via `Slim::Utils::Timers` — first run ~60s after start, re-armed every 24h (`_purgeTick`). Settings field validates 0–3650.

## Streaming replay per service (Sources.pm) — the differences that bite

**ADDING A NEW SERVICE — READ `docs/streaming-adapter-spec.md` FIRST.** It is the adapter contract across the released plugins (LBF, PFR, LL), carried verbatim in each repo: what a service's own plugin must expose (R1-R8), the leg semantics (`undef` = inconclusive vs `[]` = a real miss, and the TTL each picks), the item fields to stamp, the acceptance tests, and — per plugin — every site that still forces an edit OUTSIDE the adapter table, with the registry field that closes it. **This repo is the exception the spec's section 9 describes: it RECOGNISES a service from a url scheme rather than searching one, and its capability logic sits in per-source branches across `Sources.pm` and `Plugin.pm` rather than in an adapter table.** The claim that full support "wants those branches collected into a sources table of coderefs first" was **DISPROVEN by the Spotify build (0.1.113)** — full parity landed in ten branches with no refactor. The refactor is still worth doing; it is not a prerequisite, so do not let it block a service. The THIRTEEN sites, so the next one is counted rather than guessed at: `_streamingAlbumNode`, `_streamingPlaylistNode`, `_searchService`, `_serviceCan`, `_serviceCanPlaylist`, `%SUPPORTED_CMD`, `classifyRelType` (only if the service states a type/count on its album object), `_backfillStreamingArtist` (only if its rows can arrive artist-less), `sourceFromSvc`/`%SVC_ALIAS` (only if the service's BROWSE COMMAND differs from its source tag — Spotty browses as `spotty` and plays `spotify://`), `normaliseFavurl` (only if its favurl is not a `<scheme>://` url — Spotty sends the bare URI `spotify:album:<id>`), `unsupportedContainer` (only if the service browses CONTAINERS we cannot replay — a podcast series, a mix; added 0.1.123 after Spotify shows and Deezer podcasts were found storing as albums and tracks respectively), `isPodcastEpisode` (only if the service browses podcast EPISODES under its ordinary music scheme, so the source tag cannot identify one — Spotify does, Deezer does not because its episodes carry `deezerpodcast://`; added 0.1.126), and `_canClassifyTrack` (only if the service's own protocol handler exposes an album id in its cached track metadata — read `getMetadataFor` at the consuming end before adding one, and note it must exclude podcast EPISODES, which reach `_saveTrackRecord` and now fall through to this very branch: 0.1.126's early return for Spotify episodes was removed with `_saveSpotifyEpisode` in 0.1.127, so nothing diverts an episode ahead of it any more. It is safe today only because no episode source — `podcast`, `deezerpodcast`, `spotify` — appears in the list; adding one that does would classify a podcast SERIES as a release). **Two of these were MISSED by this very sentence when 0.1.113 wrote it, and two more were added after 0.1.123 and 0.1.126 found them the hard way**, which is exactly the failure the count exists to prevent: both are conditional, like the two before them, so a service that needs neither reads the list as complete and a service that needs one finds nothing telling it to look. A missed alias silently drops the native album id (the row falls back to fuzzy search, 0.1.96's class of bug); a missed normalisation misreads the favurl in all four readers at once; a missed container type stores a row that can never replay, which is the one thing `_isReplayableSource` exists to prevent; and a missed episode predicate renders a podcast as a music track and lets it into the Wish List. **Every one of the conditional sites has now been missed at least once**, which is the argument for reading the whole list rather than the ones a new service obviously needs. **`_fillFromPlayingMeta` is deliberately NOT a fourteenth site, and that is the point of it:** it asks the url's own protocol handler, so it already answers for every service — including one that does not exist yet — without naming any. If a new service needs a branch there, the branch is the bug. Edit the canonical copy in the ListenBrainz repo and re-copy, per the header.

**AN ELEVENTH SITE, added 0.1.120: `_searchService`'s QUERY ENCODING.** It is inside a site already
on the list, which is exactly why it went unnoticed for two months — a new service's branch is written
next to four existing ones and inherits whichever spelling of `$artistQuery` its neighbour used. There
is no single right answer: **Qobuz, Tidal and Spotty want CHARACTERS** (`uri_escape_utf8`,
`Text::Unidecode`, `uri_escape_utf8`), **Deezer and Bandcamp want OCTETS** (`complex_to_query`). Both
spellings are built at the top of the sub as `$artistChars` / `$artistBytes`; pick per branch, and if a
new service's own plugin escapes or transliterates the query, it belongs in the character camp. Getting
it wrong is SILENT — the search returns nothing for a non-ASCII artist and replay reports "Could not
find this album to play", which is indistinguishable from the album not being on the service. LBF
carries the same split as a per-adapter `query_enc` field; `tools/t_query_enc.pl` pins it here.

Browse rows differ by service, which is why each needs handling (all confirmed from the live `addctx` log + the Tidal/Bandcamp plugin source):
- **Qobuz** New Releases rows carry **no** `favorites_url` and no metadata — only a positional `item_id` + title/subtitle. So Qobuz replays by **search** (`getAPIHandler->search(cb, query, 'albums')` → `{albums}{items}` → `_albumItem`). Works.
- **Tidal** rows **do** carry the album id in `favorites_url` (`tidal://album:<id>`). `addctx` extracts it (`m{(?:[:/])album:([\w.-]+)}`) into `ref.album_id`; `_streamingAlbumNode` replays via `Plugins::TIDAL::Plugin::getAlbum` with **passthrough key `id`** (not `album_id`!) — `getAlbum` reads `$params->{id}` and returns `{items=>...}`. `_searchTidal` (`search(cb,{type=>'albums',search=>..,limit=>20})` → arrayref of album hashes → `_renderAlbum`) is the no-id fallback. Tidal capture often has an **empty artist** (online-classified items don't fill `$ARTISTNAME`), which is fine because the id path needs no artist — but the search fallback is then title-only.
- **Bandcamp** rows carry no id (like Qobuz) → **search** (`Plugins::Bandcamp::Search::search`, keep items with `passthrough[0]{album_id}`). **Gotcha:** Bandcamp's album coderef (`get_album`) calls back with a **bare arrayref** of tracks, while Qobuz/Tidal pass `{items=>[...]}` — `resolveTracks` must accept both (the 0.1.20 `Sources.pm:195` "Not a HASH reference" crash).
- **Spotify (via Spotty, 0.1.113)** is the odd one out at every layer, because Spotty is an older, independent codebase. Each difference below cost a real bug or would have:
  - **Its favurl is a Spotify URI, not a url** — `spotify:album:<id>`, no `//` anywhere (`OPML::_albumItem`; tracks `spotify:track:<id>`, playlists `spotify:playlist:<id>`). **This plugin reads a favurl as a scheme url in FOUR places** — `sourceFromUrl`, `favurlIsTrack`, `playlistFromRow`, and `$favScheme` in `_addCtxCommand` — so every one of them failed on it: an album read as source `library`, a track was not seen as a track, and the album id sitting in the favurl was never captured. Fixed by **one** normalisation, `Sources::normaliseFavurl`, called from `_addCtxCommand` right after `_stripPrivateParams` — NOT by a Spotify case in each reader. It is free on the track side: `spotify://track:<id>` is byte-for-byte the play url Spotty itself builds, so a saved track needs no conversion anywhere.
  - **Its browse command is `spotty`, not `spotify`** (Spotty registers `tag => 'spotty'`). `Sources::%SVC_ALIAS` folds the two; `sourceFromSvc` is what both add paths now ask, replacing `knownSource(...) ? lc ... : ''`.
  - **Replay wants a full URI, never a bare id.** `API::album` does `$args->{uri} =~ /album:(.*)/`, so an id alone matches nothing and returns an empty tracklist — `_streamingAlbumNode` rebuilds `spotify:album:<id>`. That match being **greedy to end-of-string** is also why nothing may ever be appended to a Spotify favurl (the sibling LBF plugin leaves them undecorated for the same reason).
  - `getAPIHandler` is a **class** method (`Plugins::Spotty::Plugin->getAPIHandler`), unlike Qobuz's and TIDAL's function-form calls, and the renderers live in `OPML`, not `Plugin` — so `_serviceCan` probes `Plugins::Spotty::OPML->can('album')`.
  - Search wants `{query => …, type => 'album'}` (key `query`, type SINGULAR) and **characters, not octets** — `_prepareCall` escapes with `uri_escape_utf8`. It is in the SAME camp as Qobuz and Tidal; only Deezer and Bandcamp want octets. (Through 0.1.119 this line read "the octet-encoded `$artistQuery` that is right for the other three", which was wrong for two of the three and documented a real bug as intended — see 0.1.120.)
  - **Spotify is the SECOND service that answers type, count and year in one fetch** (after Qobuz): its album object keeps `album_type`, `total_tracks` and `release_date` through Spotty's cache, all via the public API. **The trap: Spotify has no EP class — an EP reports `album_type: 'single'`.** No Spotify-specific guard exists and none should be added: `singleIsWrong`/`_settle` already refuse a claimed single the count contradicts, so a 5-track "single" goes and proves itself against a real tracklist and settles as an EP. A hand-written `total_tracks` guard would only duplicate that, less carefully.
  - **No album id from a PLAYING track** — `getMetadataFor` flattens the album to a title, exactly like Deezer, so Spotify stays out of `_hasAlbumIdFromTrack` and a Now Playing add falls back to the recovered album/artist. Getting the id would mean reaching into `API->trackCached`, which is the private-internals route **declined for Tidal/Deezer on 2026-07-25** — do not re-attempt it here either.
  - `_backfillStreamingArtist` gives it its own branch rather than the shared `$getAlbum` coderef: Spotty's tracklist `line2` is `"Artist • Album"`, not the bare artist Tidal and Deezer put there, so the shared path would store the wrong artist. It asks the API for the album object instead, which carries a plain `artist` string.
  - **`spotty` is deliberately EXCLUDED from `_ownedCats`' legacy seed** (alongside `listenlater`). The seed may only claim Material categories LL can have written, and a service supported from the day it arrives has no pre-ledger husks — claiming `spotty-album`/`-track` would claim categories only somebody else can have written, which the prune could then delete.
- `resolveTracks` finds the playable node (`type=>playlist`, `url=>CODE`) from `buildPlayableItems`, then calls `node->{url}->($client,$cb,{},$pt)` where `$pt = passthrough[0]`. Source tag from `favorites_url` scheme via `sourceFromUrl`; `sourceFromImage` (cover host) is a fallback when there's no favurl.

## Drag-and-drop to move between sections — NOT feasible (Material limitation)
Material only enables list drag-drop for **Favourites, editable local playlists, and the queue**: in the SlimBrowse `item_loop` branch `resp.canDrop = isFavorites` (hardcoded), and `dragStart`/`dragOver` gate on `this.canDrop`. A third-party OPML feed can't opt in (no response field enables it), and the `drop` handler issues favourites/playlist-specific reorder commands, not a generic "moved item → section" callback. So drag-to-move between the Listen Later / Played sections would need a separate upstream Material change.

## Custom actions on Material HOME shelves — only after a streaming browse (main-bundle limitation, left unpatched)
The "Add to Listen Later"/"Add to Wish List" custom actions appear on streaming **browse** pages but on **home-page shelf cards only after you've opened a Qobuz/Bandcamp/Tidal browse area in the same session**. Cause: `itemCustomActions` is a single **view-level** property. Browsing a service runs `view.itemCustomActions = resp.itemCustomActions` (`browse-functions.js:640`, deferred bundle) and that value **persists** on the home view; but the home shelves are built by `handleHomeExtra` (`browse-page.js`, **main** bundle `material.min.js`), which takes only `resp.items` and never sets `itemCustomActions`. Our patch *does* push the `CUSTOM_ACTIONS` marker into each home-shelf card's menu, but the marker only expands when `view.itemCustomActions` is already populated (i.e. leftover from a prior browse). There is **no plugin-only fix** — the plugin can't influence `view.itemCustomActions`. The one-line fix is in the main bundle: in `handleHomeExtra`, after `this.topExtra = resp.items;`, add `if (undefined!=resp.itemCustomActions) { this.itemCustomActions = resp.itemCustomActions; }`. **Decision: left unpatched** — we keep the Material footprint to the single deferred-bundle patch (same reason 0.1.18's main-bundle patch was reverted). A candidate addition to upstream PR #1235 if revisited.

## GitHub Pages docs (README.html / index.html)
`README.html` and the `index.html` redirect are **generated** from `README.md` by `tools/make_readme_html.py` (zero-dependency Markdown→HTML; ported from the sibling ListenBrainz plugin). The version badge is read **live from `ListenLater/install.xml`** — never hardcode it. The first `## ` section onward becomes the body; the "Features at a glance" table renders as cards, other tables as styled tables; the intro paragraph becomes the hero tagline. **Re-run `python3 tools/make_readme_html.py` after editing `README.md` or bumping the version** (these are docs only, not in the plugin zip). GitHub Pages serves the repo root, so `index.html` → `README.html` and the `ListenLater.zip`/`repo.xml` links resolve at the Pages URL.

## Version History
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

## Regression tests — RUN THESE BEFORE ANY BUILD (added 2026-07-29)

    sh tools/t_all.sh          # one line per suite, non-zero exit on any failure
    sh tools/t_all.sh -v       # every case, for when one fails

Needs only perl + DBD::SQLite. **No LMS install and no server** — `tools/t_stubs.pl` fakes just
enough of the `Slim::*` tree to load the plugin's real modules, and `ll_require()` in there works
around the fact that the package names (`Plugins::ListenLater::*`) match the INSTALLED layout while
a checkout has no `Plugins/` parent.

**Why this exists.** Until 0.1.90 this repo had no committed tests at all. The invariants lived only
as prose in this file, every round of work re-derived them by hand, and 0.1.88 broke one that had
been settled in 0.1.74–0.1.80. Verification scripts WERE written in earlier rounds
(`verify_played_flow.pl`, `verify_track_dedupe.pl`, `verify_played_threshold.pl`) but lived in
session scratchpads and are gone — so nothing carried forward. Anything worth verifying belongs in
`tools/`, committed, named after the behaviour it protects.

| suite | protects |
|---|---|
| `t_db.pl` | dedupe keys and migrations against real SQLite: 0.1.43 (same title, different year), 0.1.33 (cross-source), 0.1.74+ (track vs album keys), 0.1.81 (same track from two surfaces), 0.1.88 (`track_count`, forced `rel_type`), an old schema file upgrading with its rows intact, and the live `updateArtist`/`updateYear` carriers reconciling a newly-equal key across services without separating source from ref or guessing across statuses. Also pins the inverse async race (year merge deletes the artist callback's id), exact vs canonical lookup, logical Move/Remove following, same-source result propagation, and cross-source rejection for counts/types/URLs |
| `t_played.pl` | the thresholds that keep regressing in both directions: 0.1.82 (a single/short EP CAN reach Played), 0.1.83 (a one-track release does NOT mark when it starts), 0.1.88 (a real total beats the 4-track floor), plus the live-library-count rule |
| `t_reltype.pl` | 0.1.88's classification: `singleIsWrong`, the full `relTypeFor` table, `classifyRelType` end to end, that the Qobuz album-object path fetches **no** tracklist, and that a CATALOGUE count comes back flagged provisional while a resolved one doesn't (the flag is the only thing stopping an inflated Played total) |
| `t_verify_retry.pl` | 0.1.90's retry: that it retries, retries EXACTLY once (an unbounded retry would be worse than the bug), never gives up silently, and re-reads the row first — plus the three distinct answers `_verifyRelease` must keep apart (real count → store; provisional → neither store nor retry; no count → retry), canonical-id propagation after a year rekey, service-independent year propagation to a cross-service survivor, and the rule that an in-flight result from one service never writes its count/type onto another service's survivor |
| `t_learn_count.pl` | 0.1.93's in-flight guard on `Played::_learnTrackCount` and specifically its EXPIRY: that a lost request stops blocking after `COUNT_STALE_SECS`, that it is logged rather than swallowed, that an answered request stays immediately re-askable, that records don't block each other, and that a library release is never asked at all. Uses `TestClock::advance()` |
| `t_favurl.pl` | the private favurl handshake (`Plugin::_stripPrivateParams`): `?cover=`/`?b=`/`&a=`/`&y=`/`&al=`/`&rt=`/`&tc=` — what each yields, that junk is stripped-but-rejected, that `&a=` can't eat `&al=`, that `&rt=`+`&tc=` really do reach `singleIsWrong`, and that a NATIVE favurl comes back byte-for-byte unchanged with no field set. Calls the real sub — see the `&tc=` lesson below |
| `t_addpath.pl` | the ADD PATH end to end — a Material action into `_addCtxCommand`, out as a row in SQLite. Also 0.1.92's `ref.svc_title`: that the service label is kept when it differs and not when it doesn't, that a play of the QUALIFIED title finds the row while a different artist's doesn't, and that the dedupe key still ignores the label. What the handshake params become on the stored row, that `&tc=` settles the type but never fills `track_count`, that the cross-kind single dedupe eats a REAL single but not a disproved one, that an UNKNOWN type defers instead of inserting a guess, and that unreplayable/unidentifiable adds are refused. Plus the NOW-PLAYING FALLBACK's gate on BOTH paths (0.1.98): on the album path, that a browse row with a non-service container verb does NOT adopt the playing track, while a genuine Now Playing add (no `svc` at all) still recovers its source; on the TRACK path, that a tapped row whose `trackid` resolves to NOTHING (no svc — it shares `$trackCmd` with Now Playing) and an online-track row with a container verb are both refused, while a real Now Playing track add still recovers the playing song and its url. In both cases both directions are needed, or "doesn't adopt" passes with the fallback simply switched off. And the other side of that gate: a REMOTE queue row (negative `trackid`, no favurl) is resolved by its id and stored as the row that was TAPPED — its own title, its own play url, its source read off that url and not hardcoded `library` — while the library row on the same branch still takes its album/year from the Album row — and, since the RemoteTrack that row resolves to is normally BARE, that a `''` title/artist off the object never overwrites what Material sent (the stub answers `''` for a negative id, so this cannot pass by the test having supplied the metadata itself). Also what a REJECTED add logs (0.1.98): that an empty source reads `(none identified)` rather than `''`, that the container verb is named, and that the clause which actually failed is named — a missing play url and an empty title each say so instead of blaming the service, while a genuinely unsupported source still reads exactly as it did. The reject is silent to the user, so that one line is the whole trace. Needs no service: the whole path asks only `client`/`getParam`/`setStatusDone`/`setStatusProcessing`/`addResult`/`addResultLoop`, and `client => undef` makes the background jobs no-op (pass `_client` for the Now Playing cases — it is pulled out of the params, not passed as one). **The service plugins must be declared** (`_serviceCan`) or the gate rejects everything and every assertion passes against an empty DB |
| `t_resolve_count.pl` | what a resolve writes BACK to the row (`Browse::_albumTracks`): a FAILED resolve records nothing and never clobbers a real `track_count`/`rel_type`, Bandcamp helper-only rows count as a failure too, and 0.1.88's successful-resolve refresh + forced single-correction still work. Plus `Sources::hasDirectAlbumRef` — whether a row's tracklist costs one album call or a whole service SEARCH (the Bandcamp page-url case), which is what gates background work |
| `t_prefs_migration.pl` | 0.1.94's pref migrations and the rule that makes them one-shot: that a leading-underscore pref cannot be stored at all (pinning the stub against `Slim::Utils::Prefs::Base::set` — if that assertion ever passes with a value, every other one here stops meaning anything), that the rebrand copy runs once and never reverts a later choice, that an install which already ran the broken copy isn't copied over again, and that the threshold bump re-applies exactly once. Runs the two migrations in the real startup order — the ordering IS the bug — for both an install that carries a pre-rebrand namespace and one that doesn't. **A real user's box is the second shape**: the rebrand landed in 0.1.25 and the first release was tagged v0.1.69, so no installed copy ever wrote a `plugin.listentolater` pref and the copy has nothing to import. `reset_prefs` seeds that namespace (Simon's dev box, the only one that ran the pre-rebrand code); `reset_prefs_no_legacy` doesn't — pick the one that matches the install you mean, or an assertion proves the wrong thing |
| `t_material_actions.pl` | 0.1.95's delivery split: that the six SERVER-resolved positive categories are REGISTERED with Material (6.4.6+) and no longer written to actions.json while `track`/`queue-track` stay in the file (0.1.97), that nothing registered is also left in the file (the merge is additive — a leftover means every "Add" shows twice), that registration happens exactly ONCE across a re-register, a Settings save and the deferred radio write, that the suppressors and `podcasts-*` stay in the file where Material can actually see them, that an older Material still gets the byte-identical file it always did, and that a third party's entries in a category we vacated survive. Plus the FAILURE path: a `registerCustomAction` that dies falls back to the file (all of it, or exactly the refused sections on a partial failure — never both places), and a file write with no registration behind it (the pref switched on mid-run) writes the full set. Plus the SETTINGS save itself, driven through `Settings::handler` with `debug_log` OFF (0.1.97): turning `material_action` off clears the file half on the save and warns about the registered half, turning it back on restores `track`/`queue-track` without re-writing anything Material already took, and turning it on when nothing registered writes everything. And the 0.1.98 rule that the OFF save must obey: while entries are still registered, the empty suppressors (ours and the radio ones) STAY and stay EMPTY — deleting them while the `online-*` pair cannot be withdrawn ADDS "Add" to our own rows instead of removing it — including on the path that rule was written for and originally missed, **the file being GONE**, where all three families have to be RE-CREATED rather than preserved. And the same rule from the other side for the one category that is ours, file-only AND per-app: with nothing registered, `podcasts-*` is DELETED rather than left as an empty husk — including for a user who has since unsubscribed from every feed, the state `_materialActionSet` can no longer name — because an empty per-app override hides Add on the Podcasts app for good; with entries still live it stays, and stays empty, for exactly the reason the radio empties do. Plus the 0.1.110 DELIVERY TIER, which needed `set_material_version()` because without a `getPluginVersion` stub every one of the previous 746 checks ran at tier 1 and could not reach the new code at all: the tier table (capability alone is never enough — the one-argument empty-section call pushes a null on 6.4.6/6.4.7), the folded action set, an upgrade from a file install ending with the file UNLINKED, a hand-written actions.json surviving verbatim — populated category, their own empty suppressor, and an entry titled like ours that is not ours — both refusal fallbacks (a refused positive and a refused empty section each reach the user through the file, and the file is created for them if it has gone), the deferred pass registering a late-discovered radio command without re-pushing anything, the pref off at STARTUP vs mid-run (only the latter has anything registered to suppress), the uninstall stranding nothing, and both downgrade steps rebuilding the file. Plus 0.1.114's `Sources::materialAtLeast`, the ONE version comparator the three gates now share: the comparison table, all THREE return values with `undef` (cannot tell) pinned as distinct from `0` (too old) even though both are falsy today, and the LIST-CONTEXT trap that shipped during the refactor — `_materialVersion` is `return eval {...}`, so inlining it into the argument list collapses `(undef,6,4,8)` to `(6,4,8)` and every Material-less install silently reaches the NEWEST tier. That last one is reproduced directly AND pinned as a source check on both callers (`LL_PLUGIN_SRC=`/`LL_BROWSE_SRC=` point those at mutated copies), since no return value shows which spelling a caller used. Plus 0.1.119's two Material fixes: that the PRUNE's diagnostics do not claim the API delivered anything when registration never ran (the pref off at STARTUP — the dump must not say "plugin API"/"streaming Add active"/"registered sections" under "material_action pref = OFF"), with the mirror case pinned so the gate cannot be widened into never reporting the API half at all; and that a category appearing MID-RUN still reaches Material — subscribing to a first podcast registers `podcasts-*` while pushing nothing already registered a second time (a duplicate push is how every "Add" comes to show twice), is not ALSO written to the file, and a repeat pass adds nothing. The `setChange` wiring that triggers it WAS a source check, because the harness's `setChange` was a no-op — and that is exactly how 0.1.121's finding 1 hid for six rounds: a source grep pins that a call EXISTS, never WHERE it lives, so it matched just as happily with the watcher inside the pref-ON arm, where a box-unticked boot installed none. The stub now RECORDS into `@Slim::Utils::Prefs::Obj::CHANGES` and the suite drives `postinitPlugin` on BOTH arms, plus the subscribe-first/tick-second ordering that shows why no second watcher belongs in `Settings.pm` (`setChange` STACKS). When a behaviour can only be pinned at source, the stub is too thin |
| `t_material_matrix.pl` | the actions.json STATE MACHINE, as invariants rather than scenarios. Enumerates starting file x Material version x podcast subscriptions x user journey and drives real op SEQUENCES (boot on/off, Settings on/off, restarts), checking after EVERY step: **I1** a pref-OFF terminal leaves none of our entries, and with nothing registered none of our categories either; **I2** a foreign category — entries AND deliberate empty suppressors — is byte-identical before and after every operation; **I3** no EMPTY `<cmd>-album/-track` exists for a command we can replay (the 0.1.51 regression as a property); **I4** any journey ending pref-ON converges on the clean baseline, whatever route it took. Exists because the scenario suite is structurally blind to both halves of these bugs: they are TWO-TRANSITION (the clear pass writing `podcasts-*` empty is correct — it goes wrong at the next WRITE) and they live in the one untested cell of a 2x2, since every `$live` case in `t_material_actions.pl`'s podcast block subscribes a feed first. The invariants deliberately carry almost no vocabulary of "which categories are ours" — that list is the bug generator, so a test restating it would inherit the fault; the reference is a BASELINE from a clean run of the same config. I4 compares the MERGED file+registered view, not the file, or a Settings-save enable (which cannot register, so it delivers through the file by design) reads as drift. **A world must reset `%Slim::Utils::Prefs::VALUES`** — a pref written by one journey turns the next journey's "upgrade from an older build" case into an already-migrated one, silently hiding this exact bug class. **And it must reset every registration fact, including BOTH per-category ledgers**, or a "restart" carries this process's registrations into the next one. Since 0.1.119 the configs carry a Material-VERSION axis and the matrix covers all three DELIVERY TIERS (2 / 1 / 0) x subscriptions x 9 journeys x 4 invariants; before that it pinned at tier 1 and every assertion ran against a mode that prunes nothing and never unlinks the file. Two things that only make sense once tier 2 is reachable: `merged_view` must treat a ONE-ARGUMENT registration as declaring an EMPTY section (reading `$_->[1]` puts a literal undef in and makes the suppressor look populated), and I3 must take the MERGED view — on tier 2 suppressors arrive by registration, so reading the file alone makes it unfalsifiable exactly where the prune runs |
| `t_addpath.pl` (Spotify section) | 0.1.113's Spotify support end to end: a bare `spotify:album:<id>` URI storing as an album with source `spotify` and its id captured, a track URI storing a playable `spotify://track:<id>`, both playlist spellings landing the same short id, `svc:'spotty'` resolving to source `spotify` with no cover to sniff — and **the rebuild test**, replaying each stored row and asserting Spotty received a full URI rather than a bare id (a bare id matches nothing in `API::album` and returns an empty tracklist, i.e. a row that plays once and is then gone). The Spotty stubs are declared at the END of the file on purpose, so every test above it runs with Spotty ABSENT and the `->can` refusal is covered by the same file |
| `t_favurl.pl` (Spotify sections) | `normaliseFavurl` itself, and then the four readers that consume it — including that none of them reaches `favurlIsTrack`'s fail-open branch, which the file's no-warnings check enforces. Plus `sourceFromSvc`: `spotty` → `spotify`, while a home-shelf id still answers `''` so the cover sniff keeps its turn. Plus 0.1.115's `spottyArtistName`, the ONE reader of a Spotty album object's artist: both legitimate shapes (the cache's plain `artist` string and the raw API's `artists` array), the string winning when both are present, and seven miss cases — including a hash in `artist`, which is the TIDAL/DEEZER shape and must NOT be read here, so a fold of the two extractions fails rather than quietly losing a Tidal row's artist. Calls are `eval`'d because a shape the sub fails to guard DIES rather than returning, and a dying assertion aborts the run instead of reporting it. Plus source checks that both modules ask through the sub and neither open-codes the `artists[0]{name}` read outside its body (`LL_SOURCES_SRC=`/`LL_PLUGIN_SRC=` point those at mutated copies) |
| `t_reltype.pl` (Spotify section) | That a Spotify EP — `album_type: 'single'` with `total_tracks: 5` — is NOT stored as a single, that it resolved a real tracklist to prove it, and that a 9-track "single" demotes to `album` rather than `ep`. Also that the album is requested by full URI, and that no album object at all falls through to the tracklist instead of dying or inventing |
| `t_podcast_purge.pl` | The 0.1.136 purge (schema rung 6), which is the one rung that DESTROYS user data, so the suite is about blast radius. Rows are seeded BELOW the rung by hand, not through `DB::add`, because the shapes under test are what OLDER builds wrote. It pins that every `source='podcast'` row goes; that a MIS-KEYED pre-0.1.126 streaming episode goes (a `|t:` key, and for Spotify the bare `spotify:episode:` spelling — only the url identifies those, which is why the test is `spotifyEpisodeUri` and not one SQL predicate); and that a CORRECTLY-keyed Spotify **or Deezer** episode SURVIVES, both being supported paths. Controls: an ordinary Spotify track, an album and a playlist are untouched. Also pins the report file — written BEFORE the delete, naming what went and nothing that stayed — the empty-library no-op (stamp, no report, the path most upgrades take), the LADDER rule that failures withhold the stamp, and a partial second-DELETE failure rolling the whole purge back so the retry report still contains every episode. Anti-tested 4/4/2/2/3 red |
| `t_refold.pl` | 0.1.112's fleet fold and the migration it owes: apostrophe elision (and the `'n'` guard) plus `%FOLD` in ALL THREE normalisers, that the three punctuation passes still differ where they must (the key keeps "(Deluxe)", the gate strips it, the ranker keeps "(LP4)"), that the lenient empty-artist gates are untouched, and `_migrateRefold` end to end against real SQLite — a stale key rewritten, same-status duplicates collapsed into the earliest save, MIXED-status rows left alone, and track/playlist/episode identity tails preserved. Its cross-source cases pin `add()` parity, atomic source/ref adoption, source-scoped track counts, mixed-status restraint, service-qualified `|p:`/`|e:` independence, and schema rung 7 repairing a database that already stamped the old source-scoped refold while retaining a retry on operational failure. Plus, at source level, that the fold lives in `DB.pm` and that `DB::_norm` calls it DIRECTLY while `Sources` goes through `->can` — the failure that guards is a permanent wrong key in a UNIQUE column, which no passing call can show. Plus §4i (0.1.119): a rollback that ITSELF fails must not poison the handle — `AutoCommit` restored, a later transaction still openable, the failed pass still withholding the ladder stamp, and the assertion that actually matters, that an ordinary write made AFTER the failure is durable rather than discarded at shutdown. DBD::SQLite will not fail a rollback on demand, so only the rollback is injected (a `RootClass` subclass); the failing GROUP is 4h's planted collision. Its squatter pair differs by an apostrophe rather than reusing 4h's accented one — that is fixture history, not a hazard in accents |
| `t_query_enc.pl` | 0.1.120's per-branch query encoding in `_searchService`: that Qobuz, Tidal and Spotty (0.1.121) are handed CHARACTERS and Deezer OCTETS, and the CONSEQUENCE rather than just the flag — the URL `uri_escape_utf8` actually builds (called for real) and the name Unidecode actually transliterates to (modelled, since Text::Unidecode is not a dependency here). Plus the fail-safe cases in both directions, since a raw-CLI add arrives as octets and must not be corrupted on the way out. **Its fixture is the fragile part and is asserted rather than assumed:** a `"\x{f3}"` literal is stored latin-1 with `utf8::is_utf8` FALSE, so the encode never fires and every branch looks correct — `utf8::upgrade` models what `sqlite_unicode`/JSON::XS really hand back, and the first assertion fails loudly if it is ever dropped. The ASCII positive control is what stops the suite being satisfied by a change that mangles every query equally. **Bandcamp (0.1.122) is in NEITHER camp and is tested for exactly that**, because "exempt by an invariant" and "nobody checked" look identical from outside: its branch sends the combined `_norm("$artist $album")`, which `s/[^a-z0-9]+/ /g` makes ASCII-only, so the two encodings are byte-identical there and no conversion applies. The assertions pin that INVARIANT — ASCII out for character, octet and latin-1 in, the two encodings identical, and the album half still in the query — so a refactor that sends a raw artist or title down that branch goes red and has to pick a camp (5 red without them) |
| `t_load.pl` | every shipped module compiles AND loads, plus a called-vs-defined sweep — `perl -c` passes on a call to a sub that doesn't exist, which nearly shipped a runtime crash in 0.1.83 |

Two rules that follow from how this suite is built:

- **Assertions must not be able to pass vacuously.** The stubs are deliberately dumb; anything a
  test depends on (a library track count, a pref, a tracklist) is set IN the test. The `&tc=`
  episode in the sibling ListenBrainz plugin is the cautionary case: every test for it SUPPLIED the
  field it was meant to be checking for, so all of them passed while the feature was inert.
  **This side of the same handshake then did it too** — see below.
- **A test of extraction must CALL the extraction.** 0.1.89's `&tc=` receiver shipped with
  `$favTracks = $1 + 0 if $1 =~ /^\d{1,3}$/ && $1 > 0`. The strip works and `$1` holds the count,
  but the validation match has no capture group of its own and **a successful match still resets
  `$1` to undef** — so every count was discarded and the whole handshake was inert on this side as
  well. It shipped "verified by 24 checks": that script pulled the seven strip regexes out of
  Plugin.pm *by grep* and applied them standalone, which sounds like the strongest possible test and
  was in fact incapable of failing, because the bug was in the four lines of validation NEXT to the
  regexes. `Plugin.pm` has `use strict` but **not** `use warnings` (unlike Browse/DB/Played/
  Sources), so the "uninitialized value $1" warning was never emitted either — completely silent on
  the server. Fixed by copying the capture into a lexical first; the extraction now lives in its own
  sub (`_stripPrivateParams`) purely so a test can call it, and `t_favurl.pl` does. Both new suites
  were checked against the pre-fix code and fail there (11 and 7 failures) — **a new suite is not
  done until it has been run against the bug it claims to catch.**
  *(Adding `use warnings` to Plugin.pm/Podcast.pm/Settings.pm/HomeExtras.pm would have caught this
  on the first add. Not done here — it's a change to a 2000-line module that could surface a pile of
  pre-existing benign warnings in `server.log`, so it wants its own pass.)*
- **A test that needs the server says so.** The retry's timer FIRING, and anything touching a real
  service, is not covered here — `tools/t_all.sh` proves logic, not integration. Live checks go
  through `curl http://plex:9000/log.txt` (see the testing note above) and their results belong in
  this file.
- **A PREF MIGRATION IS NOT VERIFIED UNTIL THE LIVE PREF IS READ BACK AFTER A RESTART.** A suite can
  only prove the migration computes the right value; whether that value SURVIVES startup is a
  property of the running server, and 0.1.94 is what happens when the two are confused — the
  arithmetic was proved offline and the pref was 60 on the box the whole time. One query settles it:
  `["","pref","plugin.listenlater:<name>","?"]` over `jsonrpc.js`.

## `&al=` carries the SERVICE's album title — FLEET RULE (SETTLED 2026-07-30)

**Whatever a sibling plugin packs into `&al=`, it must be the title the STREAMING SERVICE uses, not
the one the sibling prefers.** This was got wrong independently in both senders and cost a whole
debugging session; it is the single most important thing on this page about plugin interop.

**Why the service's name and nothing else.** `Played::_matchRecord`'s streaming branch has **no
album-id anchor** — it matches on artist + album TITLE, because a playing track's metadata is all
there is to go on. So the stored title has to be the string the service will report at playback.
Store anything else and the release **plays perfectly and silently never leaves the list**: no
tracking, no measure, no mark, and *nothing in the log*, because `_matchRecord` returning undef is
not an error. It is the hardest failure mode in this plugin to notice.

**How each sender got it wrong, and what each now sends:**

| sender | row label Material sends as `$ALBUMNAME` | was in `&al=` | now in `&al=` |
|---|---|---|---|
| **LBF** | the album name | MusicBrainz's release name | the service's own title |
| **PFR** | `"Artist - Album"` | Pitchfork's album title | the matched service item's title |

- **LBF** sent MB's name because it is the better name for DISPLAY and for the dedupe key. But MB
  keeps a release's distinguisher OUTSIDE the title (all four American Football LPs are titled
  `American Football`), and its name can differ outright: MB `Radio: Fourth Space (Original Music
  from Big Walk)` vs Qobuz `Radio: Fourth Space (Original Music from the Game "Big Walk")` — verified
  live, rec 205. **PFR** legitimately NEEDS `&al=` (its label really is `"Artist - Album"`, so
  `$ALBUMNAME` is polluted) — it just has to put the right title in it: the service item's title was
  sitting right there next to `_albumid` in the match loop and was being discarded.
- **An intermediate LBF fix over-corrected** and sent the service's ROW LABEL, which carries the
  artist — Qobuz labels artist-first (`aksfx - Radio: …`, rec 207), Bandcamp artist-last
  (`Radio: … - aksfx`, rec 208). Both unmatchable. The target is the album TITLE alone.

**Why the matcher can't be loosened to paper over this.** The shared matcher's `_norm` strips
brackets so it CAN match across an edition qualifier; `DB::_norm` deliberately KEEPS them so the
dedupe key can tell editions apart. Both are right. The consequence is that precisely the cases where
the matcher's leniency does useful work (`Extra Mile` matched against `Extra Mile (Deluxe Edition)`)
are the cases where a sibling's own title can never match at playback. **Fix it at the SENDER.**

**Checking it: `tools/add_naming_check.py`.** Every add logs both halves — Material's label and the
title actually stored — so the whole matrix is checkable from one log fetch, no DB access:

    python3 tools/add_naming_check.py            # non-zero exit if anything mismatches

Three verdicts: `OK` (identical), `strip(...)` (stored == label minus something `_addCtxCommand`
removes on purpose — a trailing `(YYYY)`, a format qualifier like `(Album)`/`(Hi-Res)`, a sibling's
`Artist - ` prefix), and `** MISMATCH` (a genuinely different title — the bug). It pairs each
`addctx` with the NEXT `add ->` in log order rather than zipping the two streams, because a rejected
add and an `already=1` re-add both break a positional zip silently.

**Its one blind spot, and it is not small: for PFR the check is VACUOUS.** On every other surface
Material's label IS the service title, so label-vs-stored is a valid proxy. PFR's label is
Pitchfork's own string, so `strip(artist-prefix)` proves only that the prefix came off — it says
nothing about whether the remainder is what the service calls the release. Post-fix LBF is partly the
same. **The only non-proxy test is playback**: play a track and read the log — a match logs
`measured on first play` / `marked album rec`; a miss logs nothing at all, and that silence IS the
diagnosis.

**Verified live 2026-07-30**, after both senders were fixed: Qobuz/Tidal/Deezer native `OK`, Bandcamp
via LBF `strip(qualifier)`, Qobuz via PFR `strip(artist-prefix)`. Rows saved before the fixes (205,
207, 208, 212, 215) are unrepairable — `svc_title` is captured at add time from a label that is gone —
and need a re-add.

**Two things the check surfaced that are worth knowing.** (1) `svc=` is EMPTY on some sibling adds
(rec 205, 207) and `listenbrainzfreshreleases` on others, so the `via` column tells you which Material
CATEGORY fired, not which plugin sent it — `$SERVICE` doesn't populate on every surface. (2) Bandcamp
appends `(Album)` to its browse titles and `_addCtxCommand` strips it.

**SETTLED by playback 2026-07-30: stripping `(Album)` is correct.** A Bandcamp release added via LBF
was played and moved to Played, so the stripped title DOES match what Bandcamp reports while playing —
i.e. `(Album)` is a browse-row decoration, not part of the album name. Nothing offline could have
predicted this; only playing it could.

**Status of `ref.svc_title` (0.1.92) after that.** Its two candidate justifications are now both gone:
the senders were the real bug and are fixed, and the qualifier-strip case turns out not to need
rescuing. **It has no known live case.** Keeping it anyway, deliberately: it is the LAST pass in
`_matchRecord`, guarded by the same `_artistMatch` as the pass above, so it can only ever rescue a
miss and never redirect a play that already matches — and the failure it guards against is the silent
one (a release that plays perfectly and never leaves the list). Cheap insurance against a future
sender regression or a service that starts decorating titles. Don't spend effort removing it; equally,
don't cite it as load-bearing.

**Played status is believed COMPLETE as of 2026-07-30** — verified end to end across native
Qobuz/Tidal/Deezer, Bandcamp via LBF, Qobuz via PFR, and Now Playing (both the counter path and
`_armDeferredMark`'s played-through path, including correctly NOT marking a track that was skipped
partway).

## Played length: MEASURE it, never infer it from the release type (DECIDED 2026-07-30)

**The rule: a release's length is only ever a COUNT of its real playable tracks. The release
TYPE never decides anything about Played.** Reported by Simon and rebuilt the same day, after
a saved release (adieu — *Wanna me*) was played through and refused to move to Played.

**Why the type can't be trusted, ever.** `rel_type` comes from MusicBrainz (via LBF's `&rt=`)
or a service catalogue. It is a BIBLIOGRAPHIC LABEL, not a count — MB calls a lead track plus
B-sides a *Single*, and calls a 1-track release an *EP*. **LBF cannot fix this**: it passes on
what ListenBrainz/MusicBrainz give it. Every threshold derived from the label was a guess
dressed as a fact, and it was wrong in both directions — a "single" of 3 tracks marked Played
after one (0.1.88's bug), and an "EP" of 1 track that could never be marked because the EP
floor asked for 2 tracks it doesn't have (the reported bug). Both were patched repeatedly;
the patches were the problem.

**The counting bug underneath it, VERIFIED LIVE 2026-07-30.** The resolved item list was
filtered with a DENY-list — not `type => 'text'`, no `weblink` — so anything a service invents
fails it OPEN. Qobuz returns 5-6 info rows with every album (`Artist: …`, `Add Release … to
Qobuz favourites`, `Credits`, `Description`, `Music Label: …`, `Copyright`, and one `Artist:`
row PER credited artist), and **none of them carries a `type` key at all** — confirmed over
`jsonrpc.js` against four releases, and against `Slim::Control::XMLBrowser`, which emits
`type` verbatim when present. So every one was counted as a track:

| release | rows | counted | real |
|---|---|---|---|
| adieu — Wanna me | 6 | **6** | 1 |
| 3OH!3 — MY FRIENDS | 8 | **8** | 3 |
| Cola — Cost Of Living Adjustment | 17 | **17** | 11 |
| Will Sheff — Extra Mile | 15 | **15** | 9 |

Wanna me therefore needed `ceil(60% × 6)` = 4 of its 1 track — impossible — and Cola needed
all 11 instead of 7.

**The four parts, all shipped in 0.1.90:**
1. **`Sources::isPlayableTrack`** — a port of LMS's own `hasAudio` (`Slim/Control/
   XMLBrowser.pm`), the predicate the server itself sets `isaudio` with. An ALLOW-list, so an
   unanticipated row fails CLOSED. **Note it accepts `playlist` as well as `audio`, plus
   `play` and audio `enclosure` — filtering on `type eq 'audio'` alone would be wrong.**
   Counting and DISPLAY are now separate: the drill view still shows the info rows.
2. **`Played::_totalTracks` returns only a MEASURED length** — library live count, or a stored
   resolved count. The `single ⇒ 1` inference is gone, and so is `_maybeMark`'s EP floor cap
   (dropping the floor to 2 for an "EP" still asks for a track a 1-track release lacks).
3. **`Played::_learnTrackCount`** — on the first play of a saved streaming release with no
   measured length, resolve the tracklist, count it and store it. Fired only in the branch
   that STARTS tracking, plus an in-flight guard, so an album asks once. If the answer arrives
   mid-play it updates the live `%tracking` total; **if it comes back 1 it cancels the counter
   and hands over to `_armDeferredMark`**, or the release would be marked the instant it
   started (0.1.83's bug).
4. **`user_version < 4` migration** — clears `track_count` on every non-library row. Wrong
   counts CANNOT heal on their own (Played only measures a length it doesn't have), so without
   this nothing already saved gets better. Library rows are untouched.

**The safety principle that falls out, and should govern anything similar: when the length is
unknown, fail towards NOT marking.** Failing to mark is recoverable and merely annoying;
marking wrongly moves the row to Played and auto-tidy then DELETES it. Uncertainty must never
destroy a saved row. That is why an unmeasurable release sits on the flat floor rather than
getting a smaller, friendlier guess.

**Consequence, accepted:** a release whose length can never be measured (service permanently
unreachable) and which holds fewer tracks than `streaming_min_tracks` won't auto-mark. Before,
the label rescued some of those — at the cost of wrongly marking others. Measuring is right;
guessing was not.

## Year backfill from the Qobuz album object (0.1.91)

A streaming BROWSE row carries no year. The only add-time sources are the siblings' `&y=`
handshake, an explicit `year` param, and Material's Now Playing `"Album (YYYY)"` label — so
measured on the live list, **14 of 45 rows had no year** (9 Qobuz, 4 Bandcamp, 1 other).

**It is not cosmetic.** The year is a segment of the dedupe key (`artist|album|year`), so a
yearless row keys as `artist|album|` and the SAME album added later from a source that does
supply one keys differently → a second row that dedupe cannot see. Same class as the
year-in-title pollution, from the opposite direction.

**Free on Qobuz, unavailable on Tidal/Deezer/Bandcamp.** Qobuz is the one service whose ID
call returns an album OBJECT rather than a tracklist, and that object states the date.
`classifyRelType` fetches that object anyway (for `release_type` + `tracks_count`), so the
year rides back as a FOURTH callback value at no extra cost, on both the short-circuit and
the resolve-fallback paths.

### WHICH SOURCES CAN SUPPLY A YEAR — the whole picture (0.1.93)

| source | year? | from where |
|---|---|---|
| **library** | ✅ always | `Sources::libraryAlbumYear` — the local DB, free |
| **Qobuz** (native or sibling) | ✅ | the album object, via `Sources::serviceYear` |
| **Spotify** (Spotty) | ✅ | the album object (`release_date`), via `Sources::serviceYear` — the same single `$api->album` call that answers `album_type` and `total_tracks`, so it costs nothing extra |
| **LBF / PFR** (any service) | ✅ when they have one | the `&y=` handshake |
| **Now Playing** | ✅ only if the label reads `"Album (YYYY)"` | Material's label, stripped by `_addCtxCommand` |
| **Tidal native** | ❌ | `getAlbum` returns a TRACKLIST, no album hash to read |
| **Deezer native** | ❌ | same |
| **Bandcamp native** | ❌ | same, and no date at all without scraping the page |

**The three ❌ rows are a DECISION, not an oversight.** Those plugins' raw `albums/<id>` /
`album/<id>` endpoints DO carry dates, but surfacing them means reaching into private plugin
internals, which was **DECLINED 2026-07-25** (breaks on plugin updates) — the same ruling that
makes catalogue-side single/EP detection Qobuz-only. The one legitimate route left is those
plugins' public SEARCH results, whose raw album hashes carry dates (`_searchService` already
reads them for `_bestMatches` ranking) — unused here because a search is far too expensive to
spend on a cosmetic-plus-dedupe field. **Don't re-attempt the private-endpoint route.**

**`Sources::serviceYear` is the reader, and it takes the HASH.** Ported from PFR's `_svcYear`
(0.1.93) after native adds were seen losing years that PFR kept. The earlier version asked for
three Qobuz fields by name, so anything spelled differently produced nothing. Key order is
PRECEDENCE: `release_date_original` (the original release — a reissue keeps the year it was
made) → `release_date_stream` → `release_date` → `releaseDate` → `date` → `streamStartDate` →
`released_at` (Qobuz's EPOCH, converted through `localtime` and range-checked) → `year`.
**`release_date_stream` is not in PFR's list — don't drop it when syncing, this plugin reads
it** (the regression suite caught exactly that).

**The epoch changed behaviour deliberately.** `_yearOf` (string input) still refuses
`released_at`, and must: there is no word boundary inside a digit run, so mining it would turn
`1767225600` into "1767". But refusing it *outright* meant an album object stating only the
epoch yielded no year at all — which is what PFR was getting right. `serviceYear` converts it,
because there it is known to be an epoch rather than guessed at.

**Material has NO `$YEAR` variable.** Its map is `$ALBUMNAME`/`$ARTISTNAME`/`$TITLE`/`$FAVURL`/
`$IMAGE`/`$ALBUMID` — so a **library** album added from a Material menu arrived yearless while
the same album added from the info-provider menu (`_addItemFor`, which always sent one) got its
year, and the two then keyed differently and could not dedupe. `_addCtxCommand` now reads it
from `Slim::Schema` off the `$ALBUMID` it is already given. Note LMS stores `year = 0` for
"unknown", which is not a year — `libraryAlbumYear` rejects it.

- **`DB::updateYear`** mirrors `updateArtist`: fills a MISSING year and RECOMPUTES the dedupe
  key. It never overwrites a year we already hold — that one came from the add, closer to the
  user's own view of the release, and a service date can be a reissue's.
- **`_classifyThenAdd` sets it BEFORE the insert**, so it reaches the key (`DB::add` builds
  the key at insert; a year arriving later would leave the key yearless).
- **`_verifyRelease` backfills it too**, ahead of the count check, so it lands even when the
  count is provisional or never arrives — that is what heals rows already saved.
- **An epoch `released_at` is deliberately NOT read.** `_yearOf` anchors on `\b`, and a run of
  digits has no internal word boundary, so `1767225600` yields nothing rather than a nonsense
  year. Pinned by a test.

## Release type: why an asserted type is not classified before insert (DECIDED 2026-07-29)

**Settled. Do not re-open — it was re-litigated once already, at length, and this is where that ended.**

The tension is genuine and has no third option: for a release type we cannot corroborate at insert
time, **"never show a type that changes" and "never delay the add" are mutually exclusive.** One of
them has to give. Both have now been chosen, in that order, for different reasons:

- **0.1.74–0.1.80 chose "never changes", accepting the wait.** Correct for what existed then: the
  only types available were an unknown one (nothing to show but a guessed "Album") and a resolved
  one, and the correction it was avoiding waited for a **first drill or play** — potentially days
  later, in front of the user, on the list itself.
- **0.9.141 created a third category that decision never considered: an ASSERTED type.** MusicBrainz
  (via LBF's `&rt=`) and Qobuz's `release_type` both state one — and both are wrong in exactly one
  way that matters, calling a multi-track release a Single (see 0.1.88). So it is neither "unknown"
  (there IS a label, and a good one for album-vs-EP) nor "known" (it can't be trusted on the one
  axis Played depends on).
- **DECISION (Simon, 2026-07-29): the add must not wait on a service.** An asserted type inserts
  IMMEDIATELY; `_verifyRelease` corrects it fire-and-forget afterwards. The first cut of 0.1.88
  blocked instead, and was rejected on exactly this ground: *"I dont want a delay to adding
  material."*

**What makes the flip acceptable here, where it wasn't in 0.1.74–0.1.80** — the two situations differ
in more than preference:

1. **Milliseconds, not days.** Measured live on the real server, 3-track MB Single, per service:
   Qobuz **1.5 ms**, Deezer **2–277 ms**, Tidal **150 ms** between the insert line and the
   `reclassified as ep` line. The old flip waited for a first play.
2. **Nobody is looking at the list.** An add happens from a streaming browse page or Now Playing —
   the LL list isn't rendered, and by the time it is, the correction has long landed. Simon's own
   report of the shipped behaviour: *"it did show up straight away in my test no delay."*
3. **An UNKNOWN type still blocks.** `_classifyThenAdd` is unchanged for it, because there the label
   would be a pure guess with nothing behind it. That half of 0.1.74–0.1.80 stands.

**If this is ever revisited, the only lever is going back to blocking** — there is no arrangement that
avoids both the delay and the correction. Storing NULL until verified was considered and rejected: it
still flips visually (NULL renders as "Album", `_typeLabel`), and it breaks 0.1.79's cross-kind
single↔track dedupe, which keys on `rel_type eq 'single'` at insert.

**Two further `_verifyRelease` holes, both fixed 2026-07-30 (code review):**

1. **It threw away a type it had just been handed.** It only ever wrote a type to DEMOTE a
   wrong 'single', so a row inserted with a NULL type — the shape `_classifyThenAdd`'s safety
   timeout leaves behind — kept showing `_typeLabel`'s neutral "Album" default for good, even
   though the callback had just returned 'ep'. Now a missing type is filled in, UNFORCED
   (`updateRelType`'s `WHERE rel_type IS NULL`), so it can't race over a type a drill/play
   stored meanwhile. A standing claim is still left alone.
2. **The gate asked the wrong question for Bandcamp.** It ran whenever the row had an album
   ID, but Bandcamp's `get_album` scrapes the album PAGE url — an id-only Bandcamp row
   resolves via a full service SEARCH, exactly the cost the gate exists to refuse.
   `buildPlayableItems` already got this right, so the predicate is now ONE sub,
   `Sources::hasDirectAlbumRef`, used by both — they had drifted, which is the same way
   `_albumTracks` drifted from `_resolveCount`. **Rule: anything deciding whether to do
   optional background work asks `hasDirectAlbumRef`, never "is there an album id".**

**Related item — MITIGATED in 0.1.90, not eliminated.** A failed verify leaves the unverified `single`
claim standing, and `Played::_totalTracks` reads it as a real total of 1 → marked Played after one
track → auto-purged days later. 0.1.90 retries once after 60s (`_armVerifyRetry` /
`_verifyRetryTick`) and, crucially, LOGS both failure routes — before that a service that answered
with nothing was completely silent, which is why this could have sat unnoticed indefinitely. A
sustained outage across both attempts still leaves the claim; the row is then corrected on first
play/drill from the list (`Browse::_albumTracks`), so what remains needs the service down for a
minute AND the release played only from outside LL.

**The corroboration fix was considered and REJECTED — do not build it.** Gating the single fast-path
on `rel_type='single' AND track_count=1` would put every pre-0.1.88 single (no stored count) back on
the 4-track floor, re-opening **0.1.82**. Trading a narrow new hole for a documented old one is the
wrong direction; heal the row, don't punish rows that predate the check.

## Podcast episodes (0.1.84) — what a browse row actually carries, and why resolution works this way

Measured over JSON-RPC (`["podcasts","items",0,2,"item_id:<feed>","menu:1","useContextMenu:1","wantMetadata:1"]`),
for BOTH a search result and a SUBSCRIBED feed — they are identical:

- An episode row has **no `presetParams`, no `favorites_url`, no `metadata`** — only a positional
  `item_id` ("3.0"). So `$FAVURL` and `$ALBUMID` are both empty on a custom action.
- That `item_id` is **not durable**: it's an index into the feed, so today's `3.0` becomes `3.1` when the next
  episode drops. An upstream Material change exposing it would therefore NOT help — this was checked before
  being ruled out.
- Its "… → More" is the Podcast plugin's **own OPML info window** (Description / Duration), NOT a `trackinfo`
  menu — so `Slim::Menu::TrackInfo` providers can't appear there either. On a browse row the plugin has no
  other reach.
- So an add arrives with only: `$TITLE` (episode title), `$ARTISTNAME` (= the row subtitle, e.g.
  "Monday, July 6, 2026 (58:05)"), `$SERVICE`="podcasts", `$IMAGE` (episode artwork).

**Resolution.** The Podcast plugin keeps subscriptions — with their real RSS urls — in its own prefs
(`plugin.podcast:feeds` → `[{name, value}]`). `Podcast.pm` fetches those feeds (SimpleAsyncHTTP +
`Slim::Utils::Cache`, 1h TTL / 7d fallback, the PFR API.pm idiom) and finds the episode by **SCORING both
signals together (0.1.132)**. The Material `$IMAGE` is the LMS image proxy wrapping the RSS url
(`/imageproxy/<escaped>/image.png`), so `_realImageUrl` unwraps it back. The matched `<enclosure url>` is
stored **podcast://-prefixed**, so the Podcast plugin's own protocol handler plays it AND keeps its
resume-position tracking. RSS
is DECODED TO CHARACTERS FIRST (0.1.131 — the body arrives as raw bytes and `_clean`'s
`chr()` entity pass would otherwise mix codepoints into them; the urls stay octets on purpose, see
that entry), then parsed with a tolerant regex scan, not an XML parser — podcast feeds are
machine-generated, only four
fields per item are needed, and a strict parser would die on the malformed-but-common ones.

**Category.** Confirmed from the SERVED bundle, not inferred: `ba = fb?"artist":wa?"track":"album"`, and `wa`
is only set when the parent view is an online ALBUM and the item has `metadata.type=="track"`. Podcast rows
have no metadata, so `wa` is false → `ba`="album" → the category is **`podcasts-album`** (`k` = the browse
command). Material prefers a PRESENT per-command category over `online-*`, so writing a POPULATED
`podcasts-album` is what swaps the generic "Add album …" for "Add podcast …" there and nowhere else — the same
per-app override used EMPTY for suppression elsewhere (0.1.55); populated, it can only add, never hide.
`podcasts-track` is written with the same pair as insurance if a future Material reclassifies these rows.

**ARTWORK IS NOT AN EPISODE IDENTITY, and the line above used to say it was — corrected 0.1.132.**
`Slim::Formats::XML::parseXMLIntoFeed` gives every item the CHANNEL image and overrides it only where the item
carries its own `<itunes:image>`; `_parseFeed` mirrors that fallback on purpose, so it agrees with what the
browse row displays. On a feed with no per-episode art **every episode has the same image**. Measured across
five real feeds 2026-09-04: *Tech Won't Save Us* 351 of 360 sharing one image, *The Daily* ~1,120 of 2,968;
Darko.Audio (the test box's only subscription), Joe Rogan and Planet Money one-per-episode — which is exactly
why this never bit here and why the 2026-09-03 live series-refusal check passed. **The rule now:** a TITLE
identifies an episode within a feed and can collide across feeds; an IMAGE identifies the FEED always and the
EPISODE only when it occurs once in that feed. So the two are scored together (3 = both, 2 = unique image,
1 = title, 0 = shared image alone → not a candidate) and the walk stops on a 3, which keeps the ordinary add
at one feed fetch. **Do not "simplify" this back into an ordered pair of `elsif`s** — no fixed order of two
signals that are each individually ambiguous can be right, and the 0-score row is what refuses a SHOW row.

**Limits (accepted, by measurement not choice):**
- **Only SUBSCRIBED feeds resolve.** An episode found via "Search feeds" on an unsubscribed show has nothing
  to match against and is rejected (no row) rather than stored as something that could never play.
- The categories are written **only when `plugin.podcast:feeds` is non-empty** — with no subscriptions the
  generic "Add album" stays and keeps rejecting as before, rather than offering a podcast add we can't honour.
  If the user later unsubscribes from everything, `podcasts-*` leaves `%cats`, so the 0.1.52 delete-empties
  pass removes it and the `online-*` fallback is restored (an empty category would otherwise SUPPRESS).
- The override applies to **everything under the `podcasts` command** — show rows, Search feeds, New episodes,
  Recently played — so "Add podcast" appears there too and rejects on anything that isn't an episode. It can't
  be scoped finer: Material's per-action `filter` keys on the favurl, and these rows have none (0.1.50).
- **Now Playing / queue adds were deliberately NOT pursued** — a podcast is saved to hear it later, so the
  moment that matters is the browse list, not playback. (They should nonetheless WORK for free: a queued /
  playing episode's track url IS the `podcast://` enclosure, so the ordinary track path handles it with no
  feed resolution — and would therefore even cover an unsubscribed show. Untested.)
- **You cannot favourite an individual EPISODE, only the feed** — an episode row has no `favorites_url`,
  which is exactly what favouriting requires. An earlier note here speculated the opposite; it was wrong.

**Glyph (0.1.87).** A podcast row uses **❝** (U+275D) rather than the ♪ music note, so speech reads as
distinct from music in a mixed list. There is **no plain-text microphone** to use: the only ones (U+1F3A4,
U+1F399) are emoji-plane characters, and although U+1F399 defaults to text presentation, virtually no font
ships a monochrome glyph for it — so it resolves from the colour emoji font, or renders as a missing-glyph
box where there is no emoji font. These glyphs are drawn by the VIEWER'S browser, not the server, so anything
emoji-backed varies per device. U+275D is Dingbats, BMP, no emoji variant — same coverage class as ♪/♫.

### 0.1.85 — episodes reached through OTHER containers (the route users actually take)

0.1.84 only covered the Podcasts app. Diagnosed live: the add logged `svc=favorites, favurl=` and
`rejected add — unsupported source 'favorites'`. Material picks the custom action from the **container's**
browse command, so a favourited FEED (verified: `favorites items item_id:<id>` lists its episodes, rows
identical in shape — no favurl, no metadata, positional item_id, same artwork key) is browsed under
`favorites` and never reaches the kind:podcast action. Home-shelf cards and search hits behave the same.

Fix is one **last-resort resolve** in `_addCtxCommand`, immediately before `_rejectAdd`: if the source isn't
replayable AND there's no favurl/albumid AND there are subscribed feeds, try `_savePodcastEpisode`. That
catches every such container at once instead of chasing them one category at a time, and costs nothing on a
working add — it only runs on one already destined to be rejected, against cached feeds. A rejection from
this path reports the ORIGINAL source, not 'podcast'.

**Wording.** `favorites-album`/`-track` are now written with a type-NEUTRAL "Add to Listen Later" / "Add to
Wish List" (same `$onlineCmd`, so behaviour is identical). A favourites list is heterogeneous — albums,
tracks, podcasts, radio — so "Add album" was already the wrong word there, podcasts aside. It cannot be made
per-item: the category comes from the container's command, and the per-action `filter` that could
discriminate is bypassed on a favurl-less row (0.1.50) — which is exactly what these are. So in the Podcasts
app the entry reads "Add podcast"; elsewhere it reads the neutral "Add to Listen Later".

**No Wish List for podcasts.** The Wish List is for things you might BUY. The `podcast` role has no wishlist
title, and the writer loop only emits the Wish List entry when the role defines one — so the Podcasts app
shows a single "Add podcast to Listen Later". An episode arriving through a GENERIC container's "Add to Wish
List" (where the menu can't know it's a podcast) is saved to Listen Later instead, with a WARN, rather than
dropped into a list where it's meaningless.

## Shared Matching Engine — FLEET SYNC RULE (2026-07-10)

The artist/album/track matcher (`_norm`, `%FOLD`, `_artistMatch`, `_albumMatches`,
fallback helpers `_stripFmt`/`_asciiNorm`/`_punctNorm`/`_stripArtistPrefix`; LBF also
`_trackMatches`) is ONE engine with a copy in each of these four repos:

- `LMS-ListenBrainz-New-Releases/ListenBrainzFreshReleases/Browse.pm` (origin, canonical)
- `LMS-Pitchfork-Reviews/PitchforkReviews/Browse.pm`
- `LMS-Discography/Discography/Sources.pm`
- `LMS-Listen-to-Later/ListenLater/Sources.pm` (hash-pinned LENIENT variant — empty-artist
  saved-item replay must still match; do NOT blindly align it)
- `LMS-Listen-to-Later/ListenLater/DB.pm` (tag `LLDB`, added 0.1.112) — LL's `%FOLD` lives
  here, so it is compared like any other copy; the `_norm` also found here is the
  DEDUPE-KEY normaliser, a different sub sharing the name, pinned as a variant
- `LMS-Search-Hub/SearchHub/Text.pm` (tag `SH`) — **FROZEN and pinned**, on hold with no
  development (Simon, 2026-08-29). It keeps the pre-sync `_norm` and the 10-entry `%FOLD`.
  Pinned rather than removed from the comparison, so it still raises the alarm if it moves;
  if it is ever unfrozen, take the fleet copy and DELETE its two pins

**LL TOOK THE FOLD IN 0.1.112** — apostrophe elision + the ~90-entry `%FOLD` — so all four
repos agree about what a NAME is. What stays LL-only is the punctuation pass and the lenient
gates. **Its fold is in `DB.pm` because `DB::_norm` builds a STORED key**, so a change there
is a MIGRATION, not a cache bump (see 0.1.112 and `_migrateRefold`).

**THE RULE: a matching fix in ANY of these repos must be applied to ALL repos carrying the
affected sub, in the SAME work session.** Enforcement — this must exit 0 before any matcher
change is called done (it does today; a non-zero exit is a real finding, not the old hold):

    python3 LMS-ListenBrainz-New-Releases/tools/matcher_sync_check.py

It diffs the comment-stripped CODE of every copy across all four repos. Deliberate variants
are sha1-pinned inside the script with a reason, and FAIL the check if they change without a
conscious re-pin (`--print-hashes` prints current hashes). After aligning: bump every touched
repo's plugin version AND its match/decision cache versions (LBF: `lbf:stream` + `lbf:track` +
`lbf:pl:resolved` — ALL layers; PFR: `pfr:stream`; DSC: `dsc:cand` only if the cached candidate
shape changed — matching runs live there; LL: none — matching is live), rebuild zips + repo.xml
sha. Never leave a matcher fix in one repo "to port later" — that is exactly how the 2026-07
drift happened (LBF missed the P!nk/EP/ascii rules for months).
