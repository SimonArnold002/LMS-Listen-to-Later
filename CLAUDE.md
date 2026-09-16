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

*Added 2026-09-10, after a FOURTH round re-reported the empty-artist finding: the ledger was
also failing for a mechanical reason, not only a discipline one. Sessions start one directory
ABOVE the repo, so this file is never auto-loaded, and at 6,227 lines it could not be read
whole anyway. Version History moved to `docs/VERSION-HISTORY.md` (3,111 lines), the workspace
root gained a short `CLAUDE.md` pointing here, and the index below exists so a review can
answer "has this been decided?" with one grep instead of a 300 KB read.*

### DECLINED / SETTLED INDEX — GREP THIS FIRST, BY SYMBOL

**One grep before reporting any finding.** Search this table for the symbol the finding is
about. A hit means it is already decided: open the cited section and either drop the finding
or answer that entry's stated reason with new evidence. Do not re-report it as new.

```
grep -n "_artistMatch\|_albumMatches" CLAUDE.md
```

**Cited by PHRASE, not line number** — grep the phrase in the "find it with" column. Line
numbers rot on the next edit; these do not.

| symbol / subject | verdict | find it with |
|---|---|---|
| `_artistMatch`, `_albumMatches`, empty artist, artist-less candidate/record | **DECLINED ×4, reinforced fleet-wide 2026-09-16** — out of scope BY DECISION; a compilation is credited upstream (Various Artists / curator), so a local artist-less row disproves nothing | `AN ARTIST-LESS MUSIC ROW` |
| `_norm`, `_normStrict`, `DB::_norm`, three normalisers | not unified, deliberately | `THREE normalisers` |
| `_norm` non-Latin fold, CJK/Cyrillic erasure | FIXED 0.1.143; the old generator is gone | `NO LONGER DELETES A NON-LATIN` |
| `trackUrlKey`, `\|u:` key, nameless track, `_keyIsNamelessTrack` | DELIBERATE, owes no rung; needs a WRITER named | `THE \`\|u:\` KEY IS DELIBERATE` |
| `_keyForRow`, dedupe key writers | one writer only, by design | `THE DEDUPE KEY HAS ONE WRITER` |
| `_insertTrackRow`, track identity = play url | settled 0.1.129 | `IDENTITY IS ITS PLAY URL` |
| `_migrateRefold` retry loop | cannot be trapped in one | `CANNOT be trapped` |
| `_migrateRefold` NULL `added_at` sort | NULL sorts last, not a defect | `puts a NULL \`added_at\` LAST` |
| `_migrateArtistPrefix` four-column SELECT | correct; the "obvious fix" is the bug | `four-column SELECT is CORRECT` |
| `foldLatin`, `utf8::is_utf8` gate | sound here — DECLINED 2026-09-03 | `gate is sound HERE` |
| `_materialActionTier` version gate | WITHDRAWN 2026-09-03 (ninth round) | `version gate is NOT a hole` |
| `_pruneMaterialActions`, `%ours`, `favorites-album` | legitimate claim; three narrowings tried and rejected | `legitimately claims` |
| `_migrate` rung-5 warn, ladder version | correct as written | `rung-5 failure warn` |
| `$t->albumname` and its `//` | SETTLED 2026-08-27 against LMS source | `on \`$t->albumname\` is NOT` |
| streaming podcast SERIES row, dead "Add" | ACCEPTED 2026-09-05 | `SERIES row still shows a dead` |
| podcast series/show scope, `Podcast.pm` | REMOVED 0.1.136 — see the warning directly below | `PODCASTS ARE EPISODE-LEVEL ONLY` |
| episode names from the handler, not the API | settled 0.1.127 | `NAMES COME FROM THE HANDLER` |
| TIDAL `mix:` refused | not a claim that mixes are unaddable | `A TIDAL \`mix:\` is refused` |
| Spotify ARTIST row reaching add | cannot; not an unguarded path | `Spotify ARTIST row cannot reach` |
| playlist: no auto-Played, NULL `rel_type`, curated-only | all deliberate | `Playlist support is CURATED` |
| drag-and-drop between sections | NOT feasible, Material hardcodes it | `Drag-and-drop to move between` |
| custom actions on Material HOME shelves | only after a streaming browse | `Material HOME shelves work only` |
| asserted release type inserting immediately | decided | `ASSERTED release type inserts` |
| `lc`-ordering fix (0.1.116) | owes NO schema-6 rung | `owes NO schema-6 rung` |
| matcher divergence from the fleet | deliberate, hash-pinned variant | `LENIENT, hash-pinned variant` |
| `&`/`+` -> ` and `, ampersand credits, `_punctPass` token injection | **SETTLED 0.1.150** — net zero on real data (1 win, 1 loss), ZERO effect on Played; both pinned | `THE AMPERSAND RULE COSTS` |
| a `+`/`&` ALBUM TITLE, `length($albumNorm) < 2`, the short-title hatch | **NOT A FINDING** — reachable, never reached; measured across 3 corpora | `A MARKS-ONLY ALBUM TITLE` |
| `_punctPass` fallback examples, `'!!!'`/`'+/-'` reaching the fallback | **COMMENT FIXED 0.1.151** — the code was always right; DB's example list had been copied onto a sub with two rules ahead of it | `WHICH MARKS-ONLY NAMES REACH` |
| `ESCAPE`, LIKE metacharacters, `[a-z0-9 ]`, `findByArtistAlbum`/`findTrackByArtistTitle`/`findByAlbum` | **COMMENT FIXED 0.1.151** — no ESCAPE is still correct, but by `_norm`'s strip rules, not the dead range claim | `THE ESCAPE JUSTIFICATION` |
| migration reachability vs `main` | judge against what main ships TODAY, never a quoted number | `JUDGE MIGRATION REACHABILITY` |
| Spotify album TITLE never matching Played, `cleanupTags`, a Spotify row storing `"Artist - Album"`, `ref.svc_title` | **B, 1.0.5 BUILT (dev, suites green) 2026-09-16 — 1.0.3 is the last build INSTALLED + TESTED on the rig; live PLAYBACK test DEFERRED and classed OK until a user reports otherwise (Simon) — do not re-raise as unverified** — Spotify plays now match by release id (`_spotifyAlbumRecord`), title doors are the fallback; a label-titled Spotify row now DISPLAYS the Spotify album it matched to (`updateAlbumTitle`, Simon's call; verified live 1.0.1), with a failed/429 lookup refused and retried once (1.0.2). **The repair is gated on `!$already`, so a pre-existing row is repaired by DELETE-then-add, never by a plain re-add — accepted, not a defect (2026-09-16)** | `A SPOTIFY ROW'S STORED ALBUM TITLE CAN NEVER MATCH` |
| `_updateIdentityField` / `updateAlbumTitle` guard ownership, `_titleFromLabel` provenance, "the caller owns the guard" | **C, FIXED 1.0.5 (prose only) 2026-09-16** — the DB.pm header wrongly named `updateAlbumTitle` as the guard's owner; the guard is the caller's `return unless $titleFromLabel`. Same round CLEARED `_spottyAlbumAnswered`, `_backfillRetryTick`'s stricter guard, `_mergeKeyRows`' title retention and the `_titleFromLabel` leak paths — reasons tabled in the entry, do not re-derive | `2026-09-16 review (1.0.5)` |

**Two standing rules that kill most repeat findings:**

1. **Name the WRITER, not just the branch.** A hand-built input proves the branch, never the
   population. If nothing upstream can reach a guarded branch, say so in the finding instead
   of reporting it as live.
2. **A comment is not the contract.** Where a comment claims an invariant the code does not
   enforce, the comment is the defect. Fix the prose and pin the behaviour in a suite; do not
   report the code as broken without checking which side the ledger settled.

### HOW TO LOG A VERDICT so the next round finds it

Every new decision goes in §A2 (declined), §B (accepted/open) or §C (closed) as a bullet
whose FIRST LINE names the **symbols** a future review would grep for, then the verdict, then
the date and who decided. Add a row to the index above in the same edit. State the reason as
a fact that can be DISPROVEN ("no service returns X"), never as "unlikely" — a rarity claim
invites the next round to find one counter-example and reopen the whole entry.

**CLOSING A ROUND IS NOT A SUPPRESSION** (Simon, 2026-09-14). A §C entry records that a defect,
as described, was fixed. Never head it "Do not re-report" — that wording is for a DECISION Simon
asked for (declined, by design, a stated residual, null behaviour that keeps being mis-reported),
always with its reason, and those stay suppressed. The code a fix added is new and open to review.

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
reproduced first, and each has a test that fails without its fix. This closes the two defects as
described (the fix code is not thereby settled); the "Deliberately NOT taken" item below is a
recorded decision and stays. Do not assume the surrounding entries were verified to the same
standard.

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
the same 214 assertions with and without them, which is what proved they were dead. (That count
was current at 0.1.140. The suite has grown since — do not re-run it expecting 214.)

### 2026-09-10 review (0.1.146) — two `|u:` findings RETRACTED: the branch is real, the INPUT is not

A review round raised two findings against the new `DB::trackUrlKey` disambiguation. **Both are
withdrawn**, and not because the analysis of the branch was wrong — it was right about what the
code does once it runs. Neither finding established that anything can make it run. Do not
re-report either; the reachability analysis below is the answer.

**The two findings, stated so the next round recognises them:**

- *"The nameless-track disambiguation re-keys on the play url, which always differs between
  services, so the same artist-less track saved from Qobuz then Tidal stores two rows instead of
  deduping — it drops the cross-source dedupe contract stated ten lines above."*
- *"`findSavedTrack` and `findTrackByArtistTitle` anchor their LIKE pattern on a `|t:<title>`
  suffix, so a row re-keyed to a `|u:<svc>:<url>` tail is invisible to both, and a played track
  reporting no artist and no album marks the wrong row."*

**Both need a track with an EMPTY artist, album AND year, and no surface produces one.**
`_keyIsNamelessTrack` is strict `^\|\|\|t:` — all three segments empty. Three independent
reasons that shape cannot be reached by a music track:

- **The only real generator was the FOLD, and it is fixed in this same diff.** Until 0.1.143
  `_norm` deleted every non-Latin character, so 米津玄師 or Кино produced `|||t:<title>` while
  the RECORD carried a perfectly good artist. That is why the nameless shape looked common
  enough to be worth code. It was a key bug, not a metadata one, and 0.1.143 closes it — see the
  `_norm` header and the entry at "THE `|u:` KEY IS DELIBERATE" below.
- **The two genuine empty-artist producers are podcast handlers, and they route elsewhere.**
  lms-deezer's `PodcastProtocolHandler` has NO artist key, ever; Spotty answers `''` when an
  episode lists no artists. Both are episodes, so `Sources::isPodcastEpisode` sends them to
  `DB::episodeKey` and the `|e:` tail. They never reach the track key at all.
- **The ledger already said so and the user already declined it.** The "A TRACK ROW'S IDENTITY IS
  ITS PLAY URL AT THE ADD END TOO (0.1.129)" entry records that the case "needs a track with no
  artist at all, which no service checked produces (a Qobuz browse row carries
  `Title\nArtist - Album`)", and the user's decision of 2026-09-04 — *"the chances of that is
  very slight to occur"*. **The 0.1.141 fix superseded the DECLINED VERDICT, not the population
  argument.** That wording is now corrected at the entry itself, because reading "superseded" as
  covering both is exactly how this round got here.

**THE METHOD ERROR, which is the transferable half.** Both findings were called *measured*, and
both measurements were real: `DB::add` was invoked directly with `artist => ''` and it did insert
a second row. **A hand-built input proves the BRANCH, never the POPULATION.** Nothing upstream
contradicted it either — the add gate in `_saveTrackRecord` requires only a replayable source, a
play url and a title, so an artist is genuinely optional *at that gate* and the search stopped
there. **Before reporting a defect in a guarded branch, find the writer that reaches it**: name a
surface, or say in the finding that you could not. This is the producing-end twin of the existing
"assert at the layer the fix lives" rule.

**What is NOT settled by this entry, and is the only live question from the round:** whether
`trackUrlKey` should exist at all. It is new code on a UNIQUE column — this repo's most expensive
bug class — written for a population the same diff's fold fix removes the last mechanism for.
That is a SCOPE question for the user, not a correctness finding, and it is open.

**Two comment claims the round flagged, recorded so they are not re-raised as defects.** Both are
accurate observations about comments, neither is a code defect:

| claim | status |
|---|---|
| `_norm`'s "THE NEW FOLD IS A PURE SPLIT" does not hold for the 8→9 re-entry — collisions ARE reachable there | true; `_migrateRefold` handles them, so the property is narrower than the comment states, not absent |
| a released database below rung 5 runs `_migrateRefold` twice per upgrade, not "one pass either way" | true; wasted work on a one-off upgrade path, not a wrong result |

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

- **AN ARTIST-LESS MUSIC ROW DOES NOT EXIST, ON EITHER SIDE OF ANY COMPARE — DECLINED FOR THE
  THIRD TIME (Simon, 2026-09-10). Podcast episodes are the ONLY exception and they route
  elsewhere.** *"empty artists do not exist, if they did we just don't add, we need an artist
  field, unless its a podcast."* Two earlier rounds declined this on the RECORD side (the
  `|||t:` nameless key, §2026-09-10 above and "A TRACK ROW'S IDENTITY IS ITS PLAY URL AT THE
  ADD END TOO" in §C). The 0.1.146 round found it a third door — the CANDIDATE side of the new
  0.1.145 short-title branch in `_albumMatches` — and that door is closed by the same argument.
  **State the rule once, for every door:**

  - **CANDIDATE side (`$candArtist`, the service's answer).** All five branches derive it from
    an ALBUM SEARCH result: Qobuz `$a->{artist}{name}`, TIDAL/Deezer `$a->{artist} ||
    $a->{artists}[0]`, Spotty `spottyArtistName`, MAI `$pt->{artist}`. Every one of the four
    services credits an artist on an album — the `''` in `ref $a->{artist} eq 'HASH' ? … : ''`
    is a SHAPE default against a malformed response, not a population. No service surface
    returns an artist-less album.
  - **RECORD side (`$artistNorm`, our stored row).** Declined twice already; the only generator
    was the pre-0.1.143 fold erasing non-Latin names, and that is fixed.
  - **PLAYING side (`Played`).** Already strict on its own: `_albumFallback` returns undef
    unless both sides carry an artist.
  - **ONE non-population, not two — this leg was overstated and is CORRECTED (0.1.148).** The
    entry originally read "the finding needed BOTH non-populations at once", citing `( )` as
    the only short title. **The title half is not a non-population.** Measured 2026-09-10:
    `x`, `÷`, `=`, `-` (four Ed Sheeran albums), `4` (Beyoncé), `∞`, `…` and any one-character
    CJK title all normalise under 2 characters and enter the branch. It is ordinary. **The
    decline stands on the CANDIDATE leg alone, which is sufficient** — no service surface
    returns an artist-less album. Left uncorrected, this is the sentence a fifth round would
    disprove and read as re-opening the whole entry; it does not. **RETRACTED.**

  **WHY THREE LEDGER ENTRIES DID NOT STOP A FOURTH ROUND, AND WHAT DOES (0.1.148).** A review
  reads the CODE first and the ledger second, and the code said the opposite of the ledger: the
  comment on the short-title branch opened `THE ARTIST GATE IS MANDATORY HERE` three lines above
  a call to a matcher that accepts an empty candidate. That contradiction is self-reporting —
  every round that compared comment to code found it, correctly, and then had to guess which one
  was wrong. **The prose is now precise at the site** (mandatory on the RECORD side, lenient on
  the CANDIDATE side, with the decline and its reason inline), **and `t_refold.pl` §3e asserts
  the candidate side as a passing test**, so the next round meets a decision instead of an
  apparent bug. Fleet lesson: a declined finding needs its pin where the reader is, and an
  invariant a comment CLAIMS but the code does not enforce will be re-reported forever.

  **`_artistMatch`'s `return 1 unless length $a && length $b` STAYS**, and reading it as the
  bug is the mistake this entry exists to stop. It is the 0.1.66 replay leniency, pinned; with
  no artist-less writer on either side it can only ever be reached by a malformed response,
  where accepting is the same answer the branch gave before the guard was written.

  **REINFORCED 2026-09-16 (Simon): artist-less is out of scope FLEET-WIDE, not just here.** PFR's
  ledger now carries its own copy in §A2. Every leg of this entry stands as written; the note below
  exists only because I tried to weaken one and was corrected, and the next round should not repeat
  the attempt.
  - **A COMPILATION IS NOT A COUNTER-EXAMPLE — settled the same day.** `Melodies International
    presents Ariwa Sounds` sits in the live list on plex:9000 with an empty `artist` (`Browse.pm`
    prefixes the artist only `if $rec->{artist}`, so it renders bare), and I cited it as
    disproving "no service surface returns an artist-less album". **It does not.** Simon: *"That
    would be classifed as Various Artists or sometimes it would be under the person who curated it
    in a service."* A comp IS credited upstream — Various Artists, or the curator. So that row is
    a LOCAL record gap, not a population of artist-less releases, and **the CANDIDATE-side leg is
    untouched by it.**
  - **Do not report the row, and do not hunt its writer as review work.** It stores, displays and
    resolves its tracklist perfectly well. The decision is that such a row is left exactly as it
    is — stored, playable, never special-cased. Name its writer only if some OTHER defect turns
    on it.
  - **Simon's steer for the case is MATCH BY ALBUM TITLE ALONE** — which is precisely what the
    pinned 0.1.66 leniency (`_artistMatch`, the paragraph just above) already does. **Nothing is
    owed here**; it is the existing behaviour, not a change to build, and not a gap to report.
  - **Where that row came from, verified 2026-09-16:** PFR's High Scoring Albums, Spotify-matched.
    PFR parsed no artist for that review (its label is album-only where every neighbour is
    `Artist - Album`). Why the Spotty artist backfill left it empty is NOT established and is not
    review work — see the rule above.

  **THE ADD GATE IS NOT GOING TO ENFORCE IT, AND THAT IS SETTLED (Simon, 2026-09-10).**
  `_saveTrackRecord` requires source + play url + TITLE only, so "we need an artist field" is a
  property of the SERVICES, not a rule LL applies. Adding an artist requirement was RAISED IN
  THE SAME BREATH AS THE RULE AND IMMEDIATELY WITHDRAWN by Simon — *"no dont change that, that
  was just my assumption"*. **The rule above describes what arrives; it was never a spec for
  the gate.** So the gate's leniency is NOT a gap, NOT deferred and NOT a finding: there is
  nothing to enforce against, because nothing artist-less arrives to be rejected. Do not
  propose the gate change, and do not cite this entry's own rule as the reason to.


- **THE AMPERSAND RULE COSTS A MATCH AS OFTEN AS IT WINS ONE, AND IT STAYS — SETTLED
  2026-09-11 (0.1.150). The COMMENT was the defect; the code is fine.** 0.1.145's
  `s/[&+]/ and /g` in `_punctPass` carried a comment claiming it "cannot cost a match here",
  measured on five hand-built pairs. **That claim is FALSE** — `_artistMatch` is a MANDATORY-subset
  test, so an injected token is a new REQUIREMENT on whichever side is shorter, not an extra
  spelling. A review round reported six flipped pairs against it. **All six were hand-built, and
  the round named no writer** — the standing rule at the top of this file, missed again.

  **MEASURED against real corpora rather than argued, 2026-09-11:**

  | corpus | result |
  |---|---|
  | every &/+ credit vs every other name, 8,958-artist library | **1 loss, 1 win** |
  | track artist vs album artist WITHIN an album, 43,684 tracks | **0 flips either way** |

  - **The one loss:** `Davie Allan & the Arrows` vs `The Arrows feat. Davie Allan`.
  - **The one win:** `Carole King & Gerry Goffin` vs `Goffin And King` — the other side spells
    `and` as a WORD and is the SHORTER string, so the pre-0.1.145 strip failed it. **This is why
    reverting to a plain strip is NOT the fix** and must not be proposed as one.
  - **A loss needs the &-side to be the SHORTER string AND the other connector to run 4+
    characters** (`with`/`feat`/`featuring`). A shorter connector (`vs`) fails before and after,
    so it is a pre-existing miss, not a regression.
  - **THE SHAPE THAT DRIVES PLAYED IS UNAFFECTED.** `Played::_albumFallback` compares a playing
    TRACK's artist to the stored ALBUM artist, both from the same service. Zero within-album
    pairs flip. The review's claim that this "breaks three live consumers" was branch-tracing,
    not population.
  - **Both directions are now pinned in `t_refold.pl` §3d** — the LOSS assertion is the
    load-bearing one, because it is what stops the comment reverting to "cannot cost a match".
    Anti-tested: remove the rule and 4 go red, the two new ones in OPPOSITE directions.
  - **FLEET:** the same rule is in PFR (`Browse.pm`) and DSC (`Sources.pm`). LL's `_artistMatch`
    picks short/long by STRING LENGTH, the fleet's by TOKEN COUNT — a pre-existing divergence,
    not introduced here. The fleet shape fails the same pair, so this is a fleet-wide matcher
    property rather than a bad port. **No fleet change was made and none is owed.**

- **A MARKS-ONLY ALBUM TITLE (`+`, `&`) BYPASSES THE SHORT-TITLE HATCH — REACHABLE, NEVER
  REACHED. NOT A FINDING (2026-09-11).** `_norm('+')` is `'and'` (length 3), so it clears
  `length($albumNorm) < 2` in `_albumMatches` and falls into the PREFIX rule instead of the
  0.1.145 `_punctNorm` escape hatch. A saved `+` can therefore prefix-match a same-artist
  `And Then There Were Three`. The branch is real and was reproduced. **It does not bite, and a
  code change was DECLINED by Simon on that basis** — *"I am not changing whole base code for
  something if it doesn't bite."* Three independent measurements, so a re-raise needs new data:

  | check | result |
  |---|---|
  | Pitchfork review titles harvested (8 pages) that are `+` or `&` | **0 of 779** |
  | MusicBrainz artists with a `+`/`&` album who ALSO have an "And…" album | **0 of 56** |
  | Library artists with both | **0** |

  - **The collision needs ONE artist to hold both a marks-only album and an "And…" album.** All
    56 MB artists holding a `+` or `&` release group were checked, retrying the 22 that first
    rate-limited. Ed Sheeran, Pinegrove, Eric Church and Kristin Hersh are all clean.
  - **LL has a SECOND layer the other repos lack.** `_bestMatches` ranks an exact `_normStrict`
    title above everything, so whenever the real album is in the result set the decoy is filtered
    — simulated. The decoy can only win if the service has LOST the album, and the save path
    means the service carried it at add time. The one unranked branch is Bandcamp, which prefers
    the stored `album_id` first.
  - **The one Pitchfork title that DID change branch is `+3`, and it moved the RIGHT way:** it
    now matches a `+3 (Deluxe)` spelling that the exact-only hatch rejected. The `?` title in
    that corpus still reaches the hatch, since nothing expands it.
  - **DSC is the most exposed of the three, not the least** — no `_bestMatches`, no `_normStrict`,
    `_titleHit` returns on the first match, and its titles come from MusicBrainz where `+` and `&`
    albums genuinely exist. Still zero on the data. If this ever bites, that is where.
  - **The fix that was designed and NOT applied**, recorded so it is not re-derived: replace the
    length test with "after qualifiers come off, is there a letter or digit left?"
    (`_punctNorm($albumRaw)` with parens stripped, tested for `\p{Alnum}`). Verified surgical —
    it moves `+`, `&`, `+ (Deluxe)`, `+/-`, `!!!` and `†††` into the hatch and **zero of 2,894
    real album titles**. A plain `length(_punctNorm($albumRaw)) < 2` guard was tried first and
    REJECTED: it misses `+ (Deluxe)`. Per this file's own rule, a recorded remedy is a
    HYPOTHESIS — this one was measured, but never run in anger.

- **JUDGE MIGRATION REACHABILITY AGAINST WHATEVER `main` SHIPS TODAY — read it, never quote
  a number from this file.** House rule across all repos (2026-09-10). A rung that only `dev`
  has ever stamped describes Simon's own install and nothing else, so a defect needing a
  database at such a height is not a user-facing defect. **THE BASELINE MOVES AT EVERY
  RELEASE**: the moment `dev` merges to `main`, its ladder height becomes the released one and
  what was dev-only becomes reachable. Re-read it at the start of every round:

  ```
  git show main:ListenLater/install.xml | grep -m1 '<version>'
  git show main:ListenLater/DB.pm | grep -o 'user_version = [0-9]*' | sort -u
  ```

  Judge the ENTRY POINT the same way — what a released database can be stamped at, and which
  rungs therefore run on the way up — not the top of the ladder in this tree.

  *Snapshot at 2026-09-10, already stale if a release has happened since:* `main` was 0.1.93,
  topping out at stamp 4, with no refold rung and no cross-source identity rung. Entering at
  4, rung 5 refolded every key BEFORE rung 7 grouped anything, so rung 7 never saw a stale
  key — MEASURED, see the 2026-09-10 round in C. **That conclusion expires with the merge that
  releases those rungs**; re-measure, do not re-cite it.

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
- ~~**Individual-Track saves are SCOPED BUT NOT BUILT** (~1 day).~~ **WRONG SINCE 0.1.74 —
  DELETED 2026-09-10. Individual track saves SHIPPED in 0.1.74-0.1.78** and the version history
  below says so in as many words. The entry survived the feature it described by about seventy
  versions, and it was quoted back at the user as outstanding work in this session before anyone
  checked it against the code. `kind='track'` rows, `Plugin::_insertTrackRow`, the `track` /
  `queue-track` Material categories and the whole track half of `t_addpath.pl` are the
  disproof. **What IS still true and is the useful half:** a track row is keyed by name unless
  it is nameless, in which case the play url decides — see the `|u:` entry below — and a saved
  track never auto-moves to Played by threshold, because a track has no "most of it".
  **And the one piece of the original scope that was never built is now DECLINED, not deferred
  — the user closed it as unwanted, 2026-09-10.** That piece was the cross-plugin DOUBLE entry
  on streaming track rows: an "Add album" beside an "Add track" on a ListenBrainz Fresh Releases
  playlist row, while a generic streaming track row keeps the single context-based entry.
  **Do not propose it, and do not report its absence as a gap.** Material can only tell those two
  row kinds apart by browse command, so it needs a dedicated `<lbf-command>-track` category —
  more of the per-command surface behind the 0.1.46-0.1.60 churn — plus a favurl-packing
  handshake on the sibling plugin's side to populate the track name. That is a lot of fragile
  cross-plugin machinery for a second button, and the context-based rule already covers the case:
  a track row adds the track, an album row adds the album.
  **The lesson, since this is the second stale claim this file produced in one day** (the other
  being the `use` remedy in §B that could not compile): an entry that says something does NOT
  exist ages worse than any other kind, because nothing in the code contradicts it where a
  reader will look. When a "not built" entry is older than a few releases, grep for the feature
  before repeating it.
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
  **FIXED 2026-09-10, and WITHOUT the migration rung this entry said it owed. Read this before
  proposing a key change anywhere else in the file.** **ONLY THE DECLINED VERDICT IS SUPERSEDED.
  THE POPULATION ARGUMENT ABOVE STILL HOLDS IN FULL** — no service checked produces a track with
  no artist at all, and since 0.1.143 the fold no longer manufactures one out of a non-Latin
  name either, so the empty-artist generator that made this look reachable is GONE. The fix
  shipped because it was cheap and lazy, not because the case became reachable.
  **A finding against the `|u:` branch therefore needs a WRITER named, not just the branch
  traced** — two were raised and retracted on exactly this in the 2026-09-10 round; see that
  ledger entry before reporting a third.

  **What made it look expensive was assuming the fix had to be a KEY SHAPE.** Re-keying every
  track row on its url would indeed owe a rung on a UNIQUE column — this repo's most expensive
  bug class — and it would also destroy cross-source track dedupe, which is a feature. Neither
  is necessary. The collision is disambiguated **lazily, at the moment it happens**, inside
  `add()`: on a name-key hit where the key is the nameless `|||t:<title>` shape, both rows carry
  a play url and those urls DIFFER, the key is rebuilt as `trackUrlKey` — `|<title>||u:<svc>:<url>`.

  - **No stored key is ever rewritten**, so nothing owes a migration. The row already in the
    database keeps `|||t:<title>` for ever; only the second row, which did not exist at all
    before, carries a `|u:` tail.
  - **`|u:` is the third identity tail and behaves like `|e:` and `|p:`** — `_keyForRow`
    preserves a stored one over a rebuild, so a later artist backfill cannot re-key such a row
    into its twin, and `_migrateRefold` refolds the TITLE segment around it untouched.
  - **A key carrying any name at all is untouched**, so cross-source and cross-surface dedupe of
    real names is exactly as it was.
  - **No url on either side keeps the OLD behaviour deliberately** — there is nothing better to
    key on, and treating it as a duplicate is the safer of two guesses.

  **THE TESTING LESSON, which cost more than the fix.** Two assertions passed against a
  deliberately broken build, for two different reasons, and both were found only by running the
  anti-test rather than trusting the green suite:

  - the re-add case passed because the INSERT hit `UNIQUE(source,dedupe_key)` and DIED — the add
    command evals that away, so "nothing was stored" is indistinguishable from a clean dedupe
    from outside, while the user gets no confirmation and the log gets a DBI error;
  - the named-track control passed because `_insertTrackRow`'s `findTrackByArtistTitle` guard
    catches an artist-bearing track BEFORE `DB::add` is ever reached, so it could not see what
    `DB::add` did with a named key at all.

  Both now ask `DB::add` directly and assert the ANSWER — id and already-saved flag — not the row
  count. **When a fix lives in a lower layer, assert at that layer**: a pass through the command
  path can be produced by any of the three guards above it.
- **THE `|u:` KEY IS DELIBERATE AND OWES NO MIGRATION RUNG — SETTLED 0.1.141, and both of the
  obvious findings against it were considered first.** A nameless track key (`|||t:<title>`:
  no artist, no album, no year) cannot prove a duplicate, so two different songs sharing a title
  used to collapse into one row. `DB::add` now rebuilds such a key as
  `trackUrlKey` — `|<title>||u:<svc>:<url>` — but **only at the moment two rows actually
  collide**, and only when both carry a play url and those urls differ.
  - **"This changes a UNIQUE column, so it owes a rung" — no.** Nothing already stored is
    rewritten. The row in the database keeps `|||t:<title>` for ever; the `|u:` shape appears
    only on the SECOND row, which did not exist at all before the fix. That is the entire reason
    the disambiguation is lazy and lives in `add()` rather than in `_keyForRow`. Pinned by an
    assertion that reads the first row's key back unchanged.
  - **"Then key EVERY track on its url, like an episode" — no, that is a regression.** Two
    services' rows for the same song dedupe on the name today, and that is a feature. A key
    carrying any name at all is untouched, which is what keeps it.
  - **`|u:` is an identity tail like `|e:` and `|p:`,** so `_keyForRow` prefers a stored one over
    a rebuild: a later artist backfill cannot re-key such a row into its twin, and the refold
    migration refolds the TITLE segment around it. Pinned in `t_refold.pl` at `_keyForRow`
    directly, because `updateArtist`'s callers only make album rows today — the guard exists for
    the first caller that is not.
  - **A nameless track with no url keeps the OLD behaviour on purpose** — there is nothing better
    to key on, and treating it as a duplicate is the safer of two guesses.
  - **`_keyIsNamelessTrack` is strict (`^\|\|\|t:`) on purpose.** A key whose artist, album and
    year SEGMENTS are all empty carries no name to collide on; a key with any of them filled is
    a real name and its collisions are real duplicates.
    - **CORRECTED 0.1.143 — this used to read "a key with an artist … in it", which is true of
      the KEY and false of the RECORD.** Until 0.1.143 `_norm` deleted every non-Latin
      character, so a track by 米津玄師 or Кино produced `|||t:<title>` while the record carried
      a real artist. The gate read the shape, took the `|u:` branch, and minted a duplicate
      where 0.1.140 had answered "already saved". The gate was not wrong about keys; the key
      was wrong about names, and the fix is in the fold (see below). This sentence is what hid
      it for two releases — the gate cannot tell the two apart and was never asked to.

  **THE 2026-09-10 ROUND, PART 2 — three findings against this entry, all REPRODUCED, none of
  them the two pre-answered above. Two are now pinned by tests; one is a recorded limitation.**
  The DECISIONS here stay suppressed — the url guard deliberately NOT fixed in `DB.pm`, and the
  `|u:` reachability limitation (re-raise only with a real row). The tests and caller pin added
  for them close those findings as described; they are not thereby settled against new findings.

  - **The lazy disambiguation is NOT idempotent at the `DB::add` layer, and the CALLER is what
    closes it.** An add rec carries no `dedupe_key`, so `_keyForRow` rebuilds the plain
    `|||t:<title>` key on every add, and the `|u:` branch is gated on FINDING the twin. Delete
    the twin and the branch cannot fire. Measured by calling `DB::add` directly: the re-add
    stores a SECOND row for the url-keyed row's own play url, no UNIQUE violation, because the
    two keys differ. **Unreachable, and measured that way too** — the same sequence through
    `_addCtxCommand` is refused. `kind='track'` reaches `DB::add` from exactly one caller,
    `_insertTrackRow`, whose `findTrackByUrl` check runs FIRST with no artist gate, and the
    case needs the re-add to carry a url, so that guard always fires.
    - **DELIBERATELY NOT FIXED IN `DB.pm`.** A `findTrackByUrl` check inside `add()` would make
      "same url = same track" a TWO-carrier concept — the rule this file exists to enforce —
      and `_insertTrackRow` cannot give its copy up, because it also serves NAMED tracks and
      raises the user toast that names the existing row. The remedy is to pin the caller, which
      is what the 0.1.129 `_keyForRow` entry above should be read as asking for: that entry's
      complaint was never "a caller guards this", it was "ONLY a caller guards this, silently".
    - Pinned in `t_addpath.pl` by two assertions that delete the twin and re-add through the
      command. Anti-tested: disabling `_insertTrackRow`'s url guard turns them red (with four
      older assertions that cover the same guard from the other direction).

  - **A `|u:` row is reachable ONLY by `findTrackByUrl`, and that is a LIMITATION, not a
    regression.** Both name finders anchor on a `|t:` suffix that a `|u:` key does not have, so
    neither can ever return one — measured with the title twin removed, both answered undef.
    Driven through `Played::_markPlayedTrack`: an exact url marks the right row; a DRIFTED
    stream url with artist-less metadata marks the TITLE TWIN; a drifted url carrying an artist
    marks nothing at all. **The pre-0.1.141 control is what settles it** — with only the twin
    stored, that same drifted play marked that same wrong row, and the exact-url play marked the
    twin too. So the fix strictly improved this: it fixed the exact-url case and left the drift
    case exactly as bad as it already was. Same property as `|e:` since 0.1.124. It needs two
    nameless same-titled tracks AND url drift AND artist-less playing metadata, all at once.
    Re-raise only with a real row.

  - **The no-url arm had ZERO coverage until 2026-09-10, and the fixture that looked like its
    control was passing a url.** `length $mine && length $their` could be deleted with all 15
    suites still green. What it prevents is a `|u:` key built around an EMPTY url — an identity
    that identifies nothing. The case is not expressible through the add command at all, since
    `_addCtxCommand` refuses an add with no play url, so the control asks `DB::add` directly —
    the same lesson as the re-add and named-track controls above. Three assertions, all red with
    the guard removed.

- **THE DEDUPE FOLD NO LONGER DELETES A NON-LATIN NAME — 0.1.143, and it closed a SHIPPED
  data-loss bug, not just the review finding that led to it.** `DB::_norm`'s punctuation pass
  was `s/[^a-z0-9]+/ /g`, which does not fold a non-Latin name, it ERASES it: 米津玄師,
  中島みゆき, 아이유, Кино, †††, !!! and +/- every one normalised to `''`. The whole key is built
  from those segments and sits in a UNIQUE column, so a name that folds to nothing produces a
  key that identifies nothing.
  - **ALBUMS WERE SILENTLY LOST, and this was in released 0.1.93.** Artist and title both
    erased, plus no year or a shared one, collapses unrelated releases onto `||`. Measured at
    `DB::add`: 中島みゆき/歌姫, サカナクション/新宝島 and Кино/Группа крови (two services, three
    artists) produced ONE row — the second and third adds refused "already saved" with a
    success toast. **There is no url fallback on the album path**, so nothing recovered them.
    This is the half the review that found the track bug did not reach, and it is the worse one.
  - **The track duplicate was real but never shipped.** `main` is 0.1.93 and `origin/dev` was
    0.1.140; neither has `trackUrlKey`. The `|u:` regression existed only in the unpushed
    0.1.141/0.1.142 commits.
  - **THE REMEDY THE FINDING PROPOSED IS WRONG — do not apply it.** Gating the nameless branch
    on `$rec->{artist}` having content stops it firing for 米津玄師, which returns those tracks
    to the plain `|||t:` key — and 感電 and 糸 BOTH normalise to `|||t:`, so the second add is
    swallowed. It trades a visible duplicate for a silent loss. Pinned by the "two different
    all-non-Latin tracks are not folded into one row" pair in `t_addpath.pl`.
  - **THE FIX IS A PURE SPLIT, and that is the whole reason a rung on the UNIQUE column was
    affordable.** The new pass keeps `\w` (Unicode-aware on a decoded string) and only stops
    DELETING characters, so two names that folded equal either stay equal or come apart, and
    nothing that folded apart can come together. `_migrateRefold`'s collision-resolution path —
    the expensive half of `DB.pm` — is unreachable for this change. Every Latin key is
    byte-identical (`sigur ros`, `janes addiction`, `album deluxe`, `834 194`, `100 free`,
    `under score`), so **the refold rung rekeys ZERO rows in a Latin-only library**. Pinned by
    §4j2 in `t_refold.pl`, which is not decoration: without it every other assertion still
    passes against a fold that quietly moved every stored key.
    - **AS SHIPPED IN 0.1.143 THAT CLAIM WAS FALSE, and §4j2 did not catch it — corrected in
      0.1.144.** The new pass is two substitutions, and they ran in the order that does not
      commute: `[^\w]+` first leaves the `_` (a \w character) out of the separator run beside
      it, so `01_-_Intro` keyed `01   intro` against `01 intro`. Five of twenty-three ordinary
      Latin inputs moved, all of them the ripped-file `Artist_-_Album` shape, and the same two
      lines in `Sources::_punctPass` broke the LIVE match as well. §4j2's Latin seeds all
      separate words with a character that is ALREADY non-\w, so the order could not show; the
      underscore seeds now in it are what make the control able to fail. **The lesson is the
      one this entry already states about `_norm`'s own controls being Latin: a control chosen
      from the half of the input space the change cannot touch is not a control.**
    - **FUZZED 2026-09-11 (review round): 400,000 inputs, ZERO merges.** Because this claim
      shipped FALSE once (0.1.143, directly above), it is now measured: 400,000 random strings
      pushed through the old `s/[^a-z0-9]+/ /g` and through the current pass produced **no case
      where the new fold makes two names equal that the old fold held apart**. No output
      contained `e:` or `u:` either, so `_keyForRow`'s leftmost-match tail regex cannot be
      fooled by a name segment. §4j2 remains the control; this states the property across the
      input space rather than across its seeds.
  - **A name that is ALL PUNCTUATION keeps its punctuation** rather than answering `''`. `!!!`,
    `†††` and `+/-` are real acts and a self-titled album by one of them collided with the next.
    Three characters are dropped there and each for its own reason: `|` is the key's SEGMENT
    DELIMITER, so an artist named `|` could otherwise forge a `|p:`/`|t:` tail and be read as
    another row's identity; `%` and `_` are LIKE metacharacters, and `findSavedTrack` /
    `findTrackByArtistTitle` build patterns straight out of `_norm` with no ESCAPE. A name made
    only of those still folds to `''`, exactly as before. Confirmed against real SQLite that
    `'!!!|%|t:even when'` matches its own row and nothing else.
  - **The refold is a NEW rung, not an edit to rung 5**, for the reason rung 7 already records:
    a dev install has stamped 5 and never revisits it, and a released install still needs rung 5
    doing its own job on the way past. `_migrateRefold` needed NO edit — it recomputes through
    `_keyForRow`, skips unchanged rows, preserves the `|p:`/`|e:`/`|u:` tails, and withholds
    its answer on failure so the stamp is retried.
    - **IT STAMPS 9 SINCE 0.1.144, not 8**, so a dev database that already stamped 8 under the
      wrong-order fold above re-enters and is corrected. Moving this rung's stamp rather than
      adding a tenth rung is deliberate: a rung 9 calling `_migrateRefold` a second time would
      run the identical pass twice on every other database.
  - **`|u:` rows left by 0.1.141 are NOT reconciled by the refold rung** — afterwards the
    duplicate pair holds two different keys, and rung 7 groups by identical key. No released
    build can contain one, so the only affected database is a local dev install.
  - **AND RUNG 7 COULD DESTROY THE VERY ROWS THIS RELEASE EXISTS TO SAVE — fixed 0.1.144, see
    the round entry below.** The ladder ran the cross-source merge BEFORE the refold, and that
    merge deletes rows sharing a stored key. On a database at 5 or 6 the erased non-Latin names
    all sit on `||`, so three unrelated albums were merged to one before the refold could split
    them. Reproduced, not argued. The guard is a precondition on the DELETE rather than a
    reordering, because a reordering only holds for one ladder shape.
  - **THE MATCHER WAS FIXED TOO, in the same release, because there it produced WRONG
    ANSWERS rather than missing ones.** `Sources::_norm` and `_normStrict` now share
    `_punctPass` with the same shape as `DB::_norm`. The gates there are lenient BY DESIGN —
    an empty artist accepts, for LL 0.1.66's Now-Playing replay path — so an ERASED name
    arrived looking ABSENT and absent means ACCEPT ANYTHING. Measured 2026-09-10: a play of
    'Lemon' by 米津玄師 MARKED a stored 'Lemon' by 中島みゆき as Played, which is the exact
    outcome `Played::_albumFallback`'s own comment promises cannot happen; replay had the same
    hole through `_albumMatches`. A non-Latin album title was also rejected outright by the
    `length $albumNorm < 2` guard, since it normalised to ''. **The leniency is NOT the bug and
    was NOT touched** — `_norm('')` is still '' — and two assertions in `t_refold.pl` §3c exist
    to stop it being "tidied" into strictness, which would break the replay path. Nothing here
    is persisted, so unlike the key this owed no rung. Anti-tested: restore the old pass and 5
    go red while both leniency controls stay GREEN, which is the asymmetry that hid it.
  - **STILL OPEN in LL after 0.1.143:** a ONE-character title (CJK or Latin) is still rejected
    by `length $albumNorm < 2`, and `_norm` strips parens before the pass so "( )" still
    normalises to ''. DSC/LBF/PFR handle both with a `_punctNorm` escape hatch on the raw
    title, gated on a MANDATORY artist check. LL has no equivalent. Not a regression and not
    urgent; it belongs with the fleet round below.
  - **`Sources::_norm` still has the old pass and is DELIBERATELY not changed here.** `DB::_norm`
    is called only inside `DB.pm`, so this change's blast radius is one file plus the stored
    keys.
    - **CORRECTED, same day: "the same fold sits in five repos" is FALSE and was withdrawn.**
      It came from a grep that hit `_asciiNorm`, a deliberately ASCII-only helper. PFR, LBF and
      DSC all use `\p{Alnum}` on a DECODED string in their real `_norm`, which matches every
      script — measured by extracting each shipped `_norm` and running it: 米津玄師, 아이유 and
      Кино all survive, and two different CJK artists correctly fail to match. **LL was the
      only repo with this defect**, so 0.1.143 brought it UP to the fleet rather than diverging
      from it. A second claim from the same round, that LBF's track cache key collides for
      non-Latin tracks, was also measured and is FALSE — the key is non-empty because LBF's
      `_norm` preserves the script. Do not re-raise either. See `docs/fleet-fold-rollout.md`.
    - **The stylised-letter gap this entry used to describe is CLOSED (0.1.145). Do not
      re-raise it.** LL's matcher had never received the fleet's fold, so `P!nk` keyed `p nk`
      against `pink`; it now takes the fleet block verbatim in `Sources::_punctPass`, shared by
      `_norm` and `_normStrict`. P!nk/Pink, Ke$ha/Kesha and $uicideboy$/Suicideboys all match.
      The `!!!` divergence 0.1.143 introduced went with it — LL folds `!!!` → `iii` like the
      fleet now, and the all-marks fallback survives only for a name with NO mapping (`†††`),
      which is a variant BETTER than the fleet's rather than drift.
    - **THE DEDUPE KEY HAS NONE OF THOSE RULES, AND THAT IS DECLINED — NOT PENDING, NOT
      DEFERRED (Simon, 2026-09-10).** *"if any service has one variant over another we should
      not try to merge them they should be two entries. No user will add same album from
      different service its just not going to happen in real usage. We add what the service
      gives us."* So `P!nk` and `Pink` are TWO ROWS by design, and so are `Ars Erotica : Volume
      I` (Bandcamp) and `Ars Erotica, Vol. I` (Deezer) for `-ii-`. **The matcher not linking
      that pair is accepted too.** Already the behaviour, so nothing was built. Do not report
      the two rows as a dedupe defect, do not propose a rung for it, and do not "fix" `volume`
      against `vol` on the strength of that pair. **DO NOT GENERALISE TO THE FLEET** —
      Discography is the opposite case and folds variants deliberately, because lining one
      artist's albums up across sources is its whole job.
    - **THE FLEET ROLLOUT THAT STARTED ALL OF THIS IS CLOSED — 2026-09-10, nothing outstanding
      in any repo.** The port to PFR/LBF/DSC was never the work: they were measured correct
      before it began, and 0.1.145 brought LL up to them. The last fleet-wide item, the `†††`
      residue, ended in TWO verdicts and an earlier draft of this line recorded only one.
      **The `_norm` port is DECLINED, and MEASURED rather than waved off:** carrying LL's
      all-marks fallback into the fleet's `_norm` flips four cases through their
      `_albumMatches` and only one flip is wanted, because it moves an all-marks artist out of
      their lenient empty-artist branch and into their strict artist gate. **LL having the
      fallback is NOT evidence they should** — LL's `_artistMatch` returns 1 on an empty side
      so the fallback can only tighten a total free pass, theirs returns 0 so it converts
      working matches into rejections, and LL replays a saved item to the SAME source where
      they match a foreign credit against a catalogue. Same code, opposite effect.
      **LBF separately BUILT the TRACK half**, which was never a mere miss there: single-copy
      subs, no fleet obligation, nothing for LL to take. `docs/fleet-fold-rollout.md` is now a
      RECORD, not a work order — do not open work from it, and do not propose porting LL's fold
      anywhere.
  - **The whole thing is anti-tested in both halves**, because either alone would pass against
    a fix that does nothing: revert the fold entirely and 27 assertions go red across
    `t_db.pl`, `t_addpath.pl` and `t_refold.pl`; remove ONLY the punctuation fallback and
    exactly 8 go red, all of them punctuation cases.
  - **The controls that made this invisible were Latin.** `t_addpath.pl`'s named-track control
    used the artist `A Band`, which folds to `a band`, so the key carried a name and the
    nameless branch never fired. The same question asked with 米津玄師 fails on the shipped
    build. **A control chosen from the ASCII half of the input space is not a control.**

    **If you are re-raising any of this, the discriminating tests are in `t_addpath.pl` and they
  ask `DB::add` DIRECTLY** — through the add command an artist-bearing track never reaches it
  (`_insertTrackRow`'s guard catches it first) and a colliding INSERT dies on the UNIQUE
  constraint inside an eval. Both of those made an earlier draft of those assertions pass against
  a build with the fix removed. See the 2026-09-10 round in §C.

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

  **REVISITED 2026-09-10 as one of the standing accepted entries, and the VERDICT STANDS — but
  the residual is no longer invisible, and three narrowings were tried and rejected. Do not
  re-derive them.**

  - **Narrowing `%ours` to `%owned` — no.** Already argued above; it trades a bounded residual
    for the 0.1.51 class.
  - **Dropping `favorites-*` and letting `_ownedCats`'s seed cover it — no, the seed does NOT
    cover it.** Checked: the fallback seed is `podcasts` plus `keys %SUPPORTED_CMD` minus
    `listenlater`/`spotty`, i.e. qobuz, bandcamp, tidal, deezer, listenbrainzfreshreleases.
    There is no `favorites` in it, and the tier-0/1 write path's claim sets
    (`%ourCats`, `@fileOnlySup`) do not carry it either. **The retired-name list is the ONLY
    sweeper of a `favorites-*` husk anywhere in the plugin.** Drop it and the husk is permanent.
  - **Claiming retired names only while no ownership ledger exists ("self-retiring") — no, and
    this is the one that looks right.** The upgrade it is meant for does work: `main` is 0.1.93,
    so a user jumps 0.1.93 → the next release, and on that first run there is no ledger, the
    seed applies, the husk is swept and the ledger is written afterwards. It breaks on a
    DIFFERENT path. The sweep lives in the tier-2 prune only, so a user on Material < 6.4.8
    writes the ledger from the tier-0/1 path — which never claims `favorites-*` — and sweeps
    nothing. When they later upgrade Material and reach tier 2, the ledger exists, the rule
    withholds the claim, and the husk becomes permanent. **The ledger records what a pass
    ASSERTED, not what older builds left behind**, which is why it can never retire a
    retired-name claim.

  **What changed instead: the cost is now VISIBLE.** The prune reported how many sections it
  KEPT and never which it removed, so a third party's user had nothing to go on. It now names
  every empty category it deletes, and names separately the ones claimed by a RETIRED NAME
  alone — no provenance from this pass, none from the ledger, and not a category any current
  tier asserts. That set is exactly the residual, and the second line says in as many words
  that another plugin's suppression may have gone with it. Pinned in `t_material_actions.pl`
  with both controls: a name we have never written (`otherplugin-album`) survives untouched,
  and a category WE emptied is reported as removed but NOT as a retired-name claim. 4 red if
  the claim is dropped, 2 red if only the second log line is silenced.
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
- ~~**`_migrate`'s rung-5 failure warn prints the version it was ENTERED at.**~~ **FIXED
  2026-09-09 — the accepted verdict that follows is SUPERSEDED, kept because it was sound when
  made.** Reopened deliberately, as the cheapest of the six standing accept-and-ignore entries.
  Rung 5 now reads the live `user_version` on its failure path and rung 6 uses the `$ladderVer`
  it already had to hand, so all five ladder messages match rung 7, which was written correctly
  from the start. Pinned in `t_podcast_purge.pl` by entering the ladder at version 2 — the only
  shape that separates the entry value from the stamped one, since rungs 3 and 4 stamp before
  the refold is reached (2 red with either `$schemaVer` put back). No control flow changed, and
  the added read is no more exposed than the `$ladderVer` read that already ran unguarded three
  lines later on the same failure path. The original entry:
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

- **WHICH MARKS-ONLY NAMES REACH `Sources::_punctPass`'s FALLBACK — the comment was wrong,
  the code was not. FIXED 0.1.151 (prose only), found by review 2026-09-11.**

  The fallback's example list read `('!!!', '†††', '+/-')`. That is `DB::_norm`'s list, and it
  is correct THERE. `Sources::_punctPass` has two rules `DB::_norm` does not, both ahead of the
  fallback, and each intercepts one of the examples:

  ```
  srcn('!!!') = 'iii'   the else branch, deliberate — its own comment 40 lines up says so
  srcn('+/-') = 'and'   the '&'/'+' -> ' and ' rule
  srcn('†††') = '†††'   the only one of the three that actually arrives
  ```

  **No behaviour changed and none should.** Both interceptions are wanted: `'iii'` is what
  agrees with the fleet, and the `&`/`+` rule is SETTLED 0.1.150 on measured data. The defect
  was that one comment block contradicted another inside the same sub — the else-branch note
  states the `'!!!'` interception as a deliberate design point, while the fallback note eleven
  lines below lists `'!!!'` as something that reaches it.

  Verified by EXECUTING the sub, not by reading it. Pinned in `t_refold.pl` §3f (11 assertions),
  which also asserts that `DB::_norm` and the match gate DISAGREE about both names — if those
  two ever answer the same, a pass has grown a rule it should not have. ANTI-TEST: drop the
  else branch and the `&`/`+` rule and 6 of the 11 go red, both divergence controls included.

  **Why this is logged rather than left as a tidy-up.** The two lists look like they should be
  kept in sync, and syncing them is exactly the wrong move. The next reviewer to notice the
  divergence should find this entry, not re-copy DB's list back.

- **THE ESCAPE JUSTIFICATION IN THE THREE LIKE FINDERS — the conclusion survived 0.1.143, its
  stated reason did not. FIXED 0.1.151 (prose only), found by review 2026-09-11.**

  `findByArtistAlbum`, `findTrackByArtistTitle` and `findByAlbum` each build a LIKE pattern
  from `DB::_norm` and pass no ESCAPE, justified as "the normalised parts contain only
  `[a-z0-9 ]`". **0.1.143 ended that range** — `_norm` now keeps every script, so a CJK,
  Cyrillic or marks-only part reaches those patterns intact. The comments went on asserting
  the dead invariant for seven versions.

  **Passing no ESCAPE is still correct**, on a narrower guarantee that lives in `_norm` itself
  and that none of the three sites mentioned: the main pass drops `'_'` BEFORE the non-word
  run and `'%'`/`'|'` are non-word, and the all-punctuation fallback strips `[\s%_|]`
  explicitly. `'|'` matters as much as the two metacharacters, because it is the key's segment
  delimiter and these patterns anchor on it.

  This is the same invariant-death 0.1.150 chased down for the Bandcamp query and
  `t_query_enc.pl`; these three sites were missed in that sweep. Pinned in `t_db.pl` by five
  new assertions covering the shape the existing four did not: a metacharacter among MARKS
  (`'!%!'` -> `'!!'`), where the leak would land in a live non-empty key, plus a sweep over
  13 names asserting no `_norm` output ever carries `%`, `_` or `|`. Checked while writing
  them: weakening the fallback strip to `\s+` turns the four older assertions red too, so
  they are the empty half of the same rule rather than redundant with the new ones.

  **Fuzzed 2026-09-11 (review round) so the guarantee is measured, not argued.** 300,000
  random strings over ASCII punctuation, Unicode connector characters, the fullwidth forms
  `＿` `％` `｜`, combining marks and CJK produced **ZERO `_norm` outputs carrying
  `%`, `_` or `|`** — main pass and all-punctuation fallback alike. The 13-name sweep in
  `t_db.pl` is the cheap regression guard; this is the coverage standing behind it.

  **`Sources::_norm` is deliberately NOT held to this** and needs no such strip — nothing in
  the repo builds a LIKE pattern from it (checked 2026-09-11; every LIKE lives in `DB.pm`).

### B. KNOWN-OPEN AND ACCEPTED — do not re-report as new

- **A SPOTIFY ROW'S STORED ALBUM TITLE CAN NEVER MATCH PLAYED FOR TWO MEASURED REASONS — FIXED IN
  DEV 1.0.2 (current dev build 1.0.3, comments only), 2026-09-16, UNCOMMITTED. INSTALLED AND
  TESTED on plex:9000; the live PLAYBACK test is DEFERRED and CLASSED OK (Simon).

  Symbols: `_addCtxCommand` title choice,
  `_backfillStreamingArtist`, `Played::_matchRecord`, `Played::_spotifyAlbumRecord`,
  `DB::findAlbumBySourceAlbumId`, `DB::updateAlbumTitle`, `_spottyAlbumAnswered`,
  `_armBackfillRetry`, `ref.svc_title`, Spotty `cleanupTags`.**

  **THE FIX (1.0.1, uncommitted, suites green, t_played 56 → 68).** Played no longer relies on the title
  for Spotify. `_matchRecord` first asks `_spotifyAlbumRecord`: the playing url, with its slashes
  stripped (Spotty's own URI form), goes to `Plugins::Spotty::API->trackCached(undef, $uri,
  {noLookup=>1})`. That is the cache entry Spotty builds the playback metadata from, so there is
  no Web API call. The cached track's `{album}{id}` is then looked up with
  `DB::findAlbumBySourceAlbumId('spotify', …)`, which filters `kind='album'` in SQL so the
  playlist guarantee (0.1.107) holds. A hit is exact and tells the two editions apart. Any miss
  falls through to the unchanged title doors: Spotty not loaded, a non-track URI (episodes), an
  uncached track, a cached album with no id (Spotty pages tracks past the 50th of a long album
  with `{name,image}` only), or no row with that id. Only `source eq 'spotify'` reaches it; no
  shared-matcher, PFR or fleet change. Source-read basis: LMS 9.1.2 never gives a Spotty
  RemoteTrack an `albumname` (`setRemoteMetadata` sets no album), so the title doors see the
  cleaned handler string; Spotty's `API::Cache::normalize` stamps an album fetch's tracks with
  the album's `id`.
  **Deliberately NOT changed:** when the playing album id is known and NO row carries it, the
  title doors still run, so a saved 1990 `Mixed Up` is still marked by a 2018-remaster play when
  only the 1990 row exists. That is today's behaviour; blocking it would also block a
  market-relinked track whose album id differs from the saved one.

  **A DIE inside `trackCached` is WARNed (1.0.4, 2026-09-16), and this is the one thing to grep for if
  Spotify plays stop matching.** Every other miss — Spotty absent, a non-track URI, an uncached
  track, a cached album with no id — is an expected fall-through to the title doors and stays
  silent. A die is not: it produces the SAME fall-through, and the title doors are measured
  never to match a Spotify row, so a changed Spotty call signature would match nothing for ever
  with no symptom but silence. The live playback test being deferred is exactly why this line
  exists. `log.txt`: `LL: Spotty trackCached died for spotify:track:…`. Not latched (one line
  per newsong, Spotify only). Pinned by t_played +4, including a CONTROL that a plain cache miss
  logs nothing; 2 of the 4 fail with the warn removed. **`API->trackCached` being 'DECLINED' is
  an ADD-path entry only** — see the scoping note at the `_hasAlbumIdFromTrack` bullet and in
  `Plugin.pm::_canClassifyTrack`; a grep landing there from `Played.pm` has the wrong entry.

  **THE DISPLAY TITLE (Reason 1) — decided by Simon 2026-09-16: "it should show what its matched
  to".** Also in the working tree. It is the reverted patch re-applied, minus its rename, with
  its rationale corrected: it is for DISPLAY, not for Played. `_addCtxCommand` records a
  transient `_titleFromLabel` (no `&al=` arrived, so the title can only be the row label).
  `_finishAlbumAdd` then also runs `_backfillStreamingArtist` for Spotify when that is set.
  Its Spotify branch takes `$album->{name}` off the album object it already fetches and calls
  `DB::updateAlbumTitle`, which does nothing when the normalised titles agree and otherwise
  re-keys through `_updateIdentityField` (now accepting `album_title`). Effects:
  - A PFR row shows `Mixed Up (Remastered 2018 / Deluxe Edition)`, the same as a native add.
  - A native add is a no-op, because its label is already the name.
  - A row that lands on a native save's key on the same list MERGES into the earlier save.
  - A same-source twin on another list blocks the write, and the row keeps its label.
  - A handshake (`&al=`) title is never overwritten.
  - Tests: t_db +13, t_addpath +3 (the wiring test fails with `_titleFromLabel => 0`).
  - Fire-and-forget: nothing waits on it. A failed lookup (429) is retried once from 1.0.2
    (below); on 1.0.1 the row kept its label.
  - **Rows saved before this build (349–351) are not repaired, and a plain re-add does not
    repair them either — BY DESIGN, not a bug (Simon, 2026-09-16). ACCEPTED: delete the row,
    then add it again.** The trigger is gated on `!$already`, and a re-add of a label-titled row
    rebuilds the same label title, so it lands on the same `dedupe_key`, sets `already=1` and
    never reaches `_backfillStreamingArtist`. Letting the repair run on an existing row was
    considered and declined: the add path's job is to add, a silent title rewrite of a row the
    user did not think they were touching is the wrong surface for it, and the affected set is
    three rows on Simon's own list. **Do not report the `!$already` gate as a defect.**
  - **VERIFIED LIVE on 1.0.1 (dev build, 2026-09-16 13:14):** a PFR-shaped addctx
    (`name=Jazmine Sullivan - Heaux Tales`, `artist=`, `svc=`, `favurl=spotify:album:4cogt2uq…`)
    logged `_finishAlbumAdd (3318)` and listed as `Jazmine Sullivan – Heaux Tales, Mo' Tales: The
    Deluxe (2022)`: title, artist and year all came from Spotify. Test row 356 was removed. The
    same add on the old 1.0.0 build (13:07, row 355) kept the label, because Spotify answered
    `429` and the one-shot backfill gave up.
  - **A FAILED SPOTIFY LOOKUP WAS STORED AS THE TITLE on 1.0.1. Fixed in 1.0.2, with the retry
    Simon approved.** Spotty reports every failure, a 429 included, through `album()`'s SUCCESS
    callback as `{ name => <error text>, type => 'text' }` (`API::_gotError`; `album()`
    normalises it and passes it on). 1.0.1 would have written "rate limit exceeded" as the
    album title of a label-titled row. No live row was affected (list scanned 13:2x). 1.0.2:
    - `_spottyAlbumAnswered` accepts only an object with a Spotify `id`; `normalize` keeps `id`
      and strips `type` from a real album.
    - A failure, or a die, goes to `_armBackfillRetry`: ONE retry after `VERIFY_RETRY_SECS`,
      within `VERIFY_MAX_ATTEMPTS`, then a WARN.
    - `_backfillRetryTick` re-reads the canonical row and does nothing if it was removed, now
      replays a different source or id, or has an artist and no label title left to replace.
    - Spotify only; the Tidal and Deezer backfill is unchanged.
    - t_addpath +14. With the answer check disabled, the error text is stored and 7 of them fail.
    - **Live on 1.0.2 (server restarted 13:29, after the 13:24 build):** the same PFR-shaped add
      listed as `Jazmine Sullivan – Heaux Tales, Mo' Tales: The Deluxe (2022)`; test row 357 was
      removed. Spotify answered first time, so the failure and retry path has NOT been seen
      live. To confirm it, look for `spotify album details unavailable, retrying in 60s` in the
      log after a 429.
    - **Real PFR adds on 1.0.3 (Simon, 13:48–13:49):**
      - `The Cure - Mixed Up` (row 359) → `The Cure – Mixed Up (Remastered 2018 / Deluxe Edition) (1990)`.
      - `Art of Noise - In Visible Silence` (row 360, Wish List) → `The Art Of Noise – In Visible Silence (1986)`.
      - `The Eagles - Their Greatest Hits (1971-1975)` (row 361) → `Eagles – Their Greatest Hits 1971-1975 (2013 Remaster) (1976)`.
      - No 429 occurred. `Melodies International presents Ariwa Sounds` answered `already=1`: it
        cross-source-deduped onto the existing artist-less QOBUZ row 248 (0.1.33), so no
        backfill ran, by design. It is not a gap in this fix; the artist-less row is the A2
        DECLINED class.
  - **Same callback, audited SAFE:** `Sources::classifyRelType`'s Spotify path reads only
    `album_type`, `total_tracks` and `release_date`. The error object has none of them, so it
    gets no count and no year, falls to `_countThen`, and then to the verify retry. The 13:07
    log shows exactly that: `release verify got no track count, retrying in 60s`.
  **INSTALLED AND TESTED (1.0.3, 2026-09-16). LIVE PLAYBACK TEST DEFERRED — Simon's call: classed OK until a user reports otherwise.** What was tested live: the display title and the add path (real PFR
  adds, above). What was NOT, and why: the Played trigger needs real audio, and Spotify
  playback does not work on this rig even after a fresh Spotty sign-in (2026-09-16: `mode play`,
  `time 0` for 18s). The retry after a failed lookup has also not fired live, because no 429
  occurred during testing. Both are covered by the suites and are **treated as working**. A
  review must NOT report either as "unverified". Reopen only on a USER REPORT: a Spotify album
  that did not move to Played, the wrong edition moving, or a label or error text left as a
  title. To check then: play 2+ tracks of the album on a player that plays Spotify, and look
  for `LL: marked album rec <id>` for the right row, or for `spotify album details
  unavailable, retrying in 60s`.

  **The original investigation** (written before the fix above; nothing had been built yet):
  a first fix was written, tested green, then **reverted unapplied** the same day because live
  probing showed it would have stored a string Played still cannot match. Once the id door made
  Played independent of the title, it was re-applied for DISPLAY (above). Everything below was MEASURED on plex:9000 (Spotty signed in; audio blocked for new
  Web API accounts, but **track metadata still resolves** — append a `spotify://track:` url to a
  stopped player and read `status tags:aAlKuN`; that is the playback-layer test, and it works).

  **Reason 1 — a sibling's row LABEL becomes the title (sender: PFR).** Four PFR adds logged:
  `name=The Cure - Mixed Up, artist=, year=(undef), svc=, favurl=spotify://album:3huHRC…`. No
  `&al=` because the Spotify favurl is `native_favurl` (see PFR `_attachFavUrl`), so
  `$album = $p{name}` = the label. Stored as `The Cure – The Cure - Mixed Up (1990)`.
  - **The artist and year are NOT part of this.** `artist=` arrives empty. Material's
    `browse-resp.js` app-item branch would set `item.artist = item.subtitle` AND `item.service`,
    and both arrived empty, so that branch did not run for PFR rows; with `item.artist` undefined,
    `customactions.js` never substitutes `$ARTISTNAME` and addctx drops the literal. And `_backfillStreamingArtist` recovered the
    right artist on 4/4 (`The Cure`, `The Art Of Noise`, `Dinosaur Jr.`, `Haruomi Hosono`), with
    the year also recovered. Only the title has no recovery.
  - `svc_title` is not set either: it is written only when `$p{name} ne $album`, and with no `&al=`
    they are the same string.

  **Reason 2 — Spotty cleans the album at PLAYBACK but not at BROWSE (sender: any, native Spotty
  included).** `Plugins::Spotty::ProtocolHandler::getMetadataFor` — what `Played` reads — runs
  `API::Cache->cleanupTags` over title and album when pref `cleanupTags` is on. **It defaults ON**
  (`$prefs->init({ cleanupTags => 1 … })`) and is on here. The regex is KEYWORD-GATED, not a
  bracket strip:
  ```
  s/[([][^)\]]*?(deluxe|edition|remaster|live|anniversary)[^)\]]*?[)\]]//ig;
  s/ -[^-]*(deluxe|edition|remaster|live|anniversary).*//ig;
  ```
  The album OBJECT (`$album->{name}`, the browse rows, any API album fetch) is never cleaned.

  | album id | `$album->{name}` / browse | playback `album` |
  |---|---|---|
  | `3huHRCpnBNMIrU4e10HDtr` | `Mixed Up (Remastered 2018 / Deluxe Edition)` | `Mixed Up` |
  | `3Q0yrBSY6UjCPfUZvT7JyF` | `In Visible Silence` | `In Visible Silence` |
  | `0DOnSBWpWwGGrO5DQZZ0Qf` | `American Football (LP2)` | `American Football (LP2)` — kept, no keyword |

  **Consequence: a natively-added Spotify album whose name contains one of those five keywords
  already fails Played today, whoever sent it** — it stores the raw browse name and Played looks
  up the cleaned one. **REPRODUCED 2026-09-16** with two native Spotty adds of the same album
  (Simon added them from Spotty's own browse; the earlier PFR row 352 was removed first):

  | id | addctx `name=` (native label, `artist=` empty, `svc=` empty) | stored title | playback album (track probed) | Played |
  |---|---|---|---|---|
  | 353 | `Mixed Up (Remastered 2018 / Deluxe Edition) (1990)` — `album:3huHRC…` | `Mixed Up (Remastered 2018 / Deluxe Edition)` | `Mixed Up` (`track:3oHh50…`) | **misses all three doors** |
  | 354 | `Mixed Up (1990)` — `album:705VGsDQ…` | `Mixed Up` | `Mixed Up` (`track:6VyG0O…`) | door 1 hits |

  Doors replayed with `DB::_norm` (which keeps bracket WORDS, turning only punctuation into
  spaces): 353's key is `the cure|mixed up remastered 2018 deluxe edition|1990`, so the
  year-agnostic prefix `the cure|mixed up|` misses it, `findByAlbum` misses it, and its
  `svc_title` is the raw label WITH the year (`… deluxe edition 1990` after `_norm`), so door 3
  misses too. Artist and year were backfilled on both. **Worse than a miss:** playing the 2018
  remaster reports `Mixed Up` / `The Cure`, which hits row **354** through door 1, so with both
  saved the WRONG row moves to Played and 353 stays for ever. Native adds do NOT hit Reason 1:
  Spotty's label is the bare album name plus ` (YYYY)`, and LL strips that year.

  Two side facts from the same probe: (a) the comment at the `svc_title` write in
  `_addCtxCommand` said `$p{name}` "is exactly what the player will report". That is false for
  a native Spotty row, because the label carries ` (YYYY)` and the player does not. The comment
  was corrected 2026-09-16. (b) Which string `_matchRecord` reads for a Spotty track was
  settled from source (LMS 9.1.2): a Spotty RemoteTrack never gets an `albumname`, so it reads
  `playingMeta`, the same handler string the probe's `status` tags show.

  **What this rules out — read before designing a fix:**
  - **`$album->{name}` as the title source.** It is the uncleaned string. This is the reverted fix.
  - **Stripping parentheticals.** Playback KEEPS `(LP2)`; A2's American Football entry depends on it.
  - **Copying `cleanupTags` into LL** without accepting the coupling: it is another plugin's
    private pref and private regex, and a drift fails silently in exactly the no-log way the
    `&al=` FLEET RULE calls the hardest failure in this plugin to notice.
  - **Judging a Spotify title by the browse layer.** The two layers disagree by design.

  **Two earlier inferences that were WRONG, so nobody reuses them:** that PFR rows arrive with the
  review capsule as `$ARTISTNAME` (they arrive empty — see above), and that the recovered year
  (1990) proved the matched album was the original release (`3huHRC…` is the 2018 deluxe; Spotify
  keeps the original release date on it).

  **Rows already saved** (ids 349–352 and any earlier Spotify keyword album) keep their titles
  until a fix decides whether they are repaired or re-added.

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

- ~~**`DB::_purgeRemovedPodcasts` calls `Sources::spotifyEpisodeUri` DIRECTLY, with no `->can`
  guard.**~~ **FIXED 2026-09-09, and the remedy this entry originally named was WRONG.** `DB.pm` never `use`s `Sources`, so this is the
  DB→Sources direction of the leaf-module rule stated above `%FOLD` — a rule which mandates
  `->can` for the Sources→DB direction and says nothing about this one. It is safe today
  because `Plugin.pm` compiles both modules before anything can reach `dbh()`, and rung 6 runs
  from the first `dbh()`. Recorded rather than "fixed", because a `->can` would be the WRONG
  repair here: it needs a fallback, and every fallback KEEPS the mis-keyed Spotify episodes the
  rung exists to clear. That is the same irreversible-consumer asymmetry the `%FOLD` comment
  describes, pointing the other way. If it ever needs hardening the answer is an explicit `use
  Plugins::ListenLater::Sources;` at the top of `DB.pm` — no cycle is created, since Sources
  reaches DB through `->can` and never `use`s it.

  **The `use` is IMPOSSIBLE, measured rather than argued.** The package name matches the
  INSTALLED layout, so `use Plugins::ListenLater::Sources;` in `DB.pm` compiles only where a
  `Plugins/` parent exists. In a checkout it dies at `BEGIN`, and it takes EVERY suite with it,
  because `t_stubs.pl`'s `ll_require` seeds `%INC` one module at a time and `DB` is loaded
  first almost everywhere. Do not re-suggest it; the failure is one command away
  (`perl tools/t_podcast_purge.pl` with the line added).

  **What shipped instead is a `->can`, and the objection this entry raised against one was
  answered rather than overruled.** The objection was that every fallback keeps the mis-keyed
  rows the rung exists to clear. True of a PER-ROW fallback. The guard aborts the WHOLE RUNG:
  nothing is deleted, no report is written, the stamp is withheld, the next start tries again.
  Waiting is the one option that is not irreversible, which is the same reasoning the `%FOLD`
  header uses to argue the opposite way for `DB::_norm` — that header is now scoped in the
  file so it cannot be read as a blanket rule about the direction. Pinned in
  `t_podcast_purge.pl` by localising the glob away: the built-in row is the assertion that
  matters, since it is already doomed when the guard trips, plus a mirror pass proving the
  rows still go once the carrier is back (4 red with `next` in place of the abort).

### C. CLOSED FINDINGS

The version history below records review fixes inline (0.1.26, 0.1.32 onward).
Check it before reporting — the July `%counting`, `classifyRelType` and
`_verifyRelease` findings are all fixed and verified (`COUNT_STALE_SECS` is the
escape for the first).

**Review round of 2026-09-10, 0.1.147 — CLOSED, one finding, FIXED in 0.1.148.**

| # | finding | disposition |
|---|---|---|
| 1 | `_writePurgeReport` double-encodes its own `—`: the handle encodes characters, but `DB.pm` has no `use utf8` so the literal is octets | FIXED 0.1.148 — `\x{2014}` at both literals, +4 assertions in `t_podcast_purge.pl` |

**The trap worth carrying forward, because the fix looks wrong at a glance.** The obvious repair
is `use utf8` at the top of `DB.pm`. **Do not.** The module holds ~20 non-ASCII LOG literals and
two SQL comments in the CREATE TABLE heredoc; the pragma reclassifies all of them into wide
characters, the log ones bound for a handle whose encoding layer this repo neither controls nor
can test (there is no LMS source checkout on the dev machine). The scoped escape is the fix, and
there is a comment above the `open` saying so. `_writePurgeReport` is the ONLY write site with an
encoding layer in the whole plugin, so the blast radius of the escape is one sub.

**And the reason a fully green suite could not see it.** Every report assertion was ASCII, and a
double-encoded file is still valid UTF-8 — reading it back through the same layer SUCCEEDS and
throws no warning. A test that only greps ASCII out of a text file proves nothing about that
file's encoding. The new section asserts the dash as a CHARACTER and the mojibake as ABSENT,
which is the pair that actually discriminates.

**Review round of 2026-09-10, 0.1.145 — CLOSED, one finding, applied as diagnostics only.**
(Distinct from the standing-entries sweep of the same date further down this section, which was
not a review round.)
Run against the 17-commit `dev` lead over `origin/dev` (0.1.140 → 0.1.145). The tree was
clean; the code diff was confined to `DB.pm`, `Plugin.pm` and `Sources.pm`.

| # | finding | disposition |
|---|---|---|
| 1 | rung 7's summary reported fold-split skips as "mixed-status row(s) left unchanged" | **FIXED** — separate counter, see below. Log wording only, no data effect, and **unreachable from a released install** |

**The finding, and what it actually was.** `_migrateCrossSourceIdentity`'s new fold-split
guard added its rows to `$skipped`, and the rung's closing `info` called every row in that
counter mixed-status. So a database whose only skip was a fold split logged *"3 mixed-status
row(s) left unchanged"* and told the user to merge by hand — rows no two statuses were ever
involved in, and which the refold rung rekeys moments later. REPRODUCED by driving `_migrate`
on a seeded v6 database with 中島みゆき/歌姫, サカナクション/新宝島 and Кино/Группа крови all
on `'||'`: all three survive with distinct keys, `user_version` reaches 9, and the summary
still said "mixed-status".

**The fix is ONE COUNTER PER CAUSE, and the summary names the cause it counts.** `$split` is
now separate from `$skipped`, the `info` line joins only the clauses that are non-zero, and
neither clause claims what a LATER rung will do with a row — a failed group here withholds
the stamp, and the refold rung then waits rather than running, so any such promise would be a
lie in exactly the case that matters. If a third reason to leave a row alone ever appears in
this rung, give it a third counter; a counter here is one CAUSE, not "rows untouched".

**Carriers checked, and the two left alone deliberately:**

| carrier | verdict |
|---|---|
| `_migrateRefold`'s `$skipped` (mixed-status-stuck + merge failure) | LEFT — its summary says "left on the old key", which is true of both causes. Not the same defect |
| the live backfill warn in `update()` ("left unchanged") | LEFT — it sits inside a genuine `keys %status > 1` branch |
| tests, docs, `CLAUDE.md` | no assertion or document quoted the old string |

**REACHABILITY — why this was dev-only.** Simon raised it during the round and it is the
reason the finding is diagnostics-grade rather than user-facing. Released `main` was 0.1.93 AT
THE TIME OF THIS ROUND, stamping at most 4 — a baseline that moves at every release, so this
paragraph is a record of what was true on 2026-09-10, not a standing fact. A database entering at 4 is refolded by rung 5 first, so its non-Latin
rows are split into distinct keys BEFORE rung 7 groups anything; rung 7 then finds no shared
key and logs nothing at all. MEASURED both ways: entry at 6 fires the guard, entry at 4 does
not, and in neither case is a row lost. The only rows rung 5 can strand on an old key are
mixed-status ones on a single service, and those land in rung 7's mixed-status branch, where
the wording was already correct. Recorded as a standing rule in A2 above.

**Cleared under verification, not by reading** (do not re-derive these):

- **The 0.1.143 refold is a PURE SPLIT.** 82k distinct inputs over an alphabet mixing ASCII,
  punctuation, accented Latin, CJK, Cyrillic and daggers: ZERO cases where two previously
  distinct old keys collapse onto one new key. The underscore-before-hyphen ordering holds
  for `01_-_Intro`, `Artist_-_Album`, `under_score` and `M_A_N_D_Y`.
- **The missing `ESCAPE` on `findSavedTrack` / `findTrackByArtistTitle` is safe.** 250k
  fuzzed inputs through `DB::_norm`, including raw random byte strings: no output ever
  contained `%`, `_` or `|`, on the main path or the all-punctuation fallback.
- **`add()`'s nameless-track `|u:` re-key cannot duplicate.** The second `findAnyByKey`
  blocks a third row, `_keyForRow`'s `(\|[eu]:.*)$` tail cannot be forged because `|` never
  survives `_norm`, and delete-then-re-add is caught by `_insertTrackRow`'s `findTrackByUrl`
  guard first.
- **`_albumMatches`' short-title branch** is strictly stricter than the `return 0` it
  replaced. Its one soft spot — a candidate whose own artist is empty passes `_artistMatch` —
  is a VERBATIM copy of `LMS-Discography/Discography/Sources.pm` and matches the normal
  path's existing behaviour. Fixing it locally would break the matcher sync. Not a regression,
  do not re-raise.
- Full suite green throughout: 15 suites, 1562 assertions, 0 failures.

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
| 5 | the rung-5 failure warn prints the entry `$schemaVer`, not the stamped one | **ACCEPTED then FIXED 2026-09-09** — cosmetic; section A2 |

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

**Finding 2's residue is MOOT as of 0.1.136 — checked 2026-09-10, and the remedy named below
cannot be written any more.** `hasFeeds` went with the built-in path, and nothing gates a
`podcasts-*` registration on a subscription now: `podcasts` sits in `@KNOWN_RADIO_CMDS`, so the
pair is an UNCONDITIONAL empty suppressor and `t_material_actions.pl` pins that no `podcasts-*`
positive is ever registered at all. There is no feed-shaped residue left to close. What survives
is the general limitation, which is not LL's to fix: Material has no unregister call, so entries
registered before the pref is turned off stay until the restart — which the pref-off warn tells
the user in as many words, and which no invocation-time check improves. **The harness carried the
same stale claim** (`t_stubs.pl` said its `setChange` recorder existed for the podcast-subscription
watcher); the recorder is kept, for the 0.1.121 reason that a pref watcher is invisible to any
other assertion, and the comment now says which of those two facts is still true. The original
verdict, for the shape of the reasoning:

**Finding 2's residue was ACCEPTED, not fixed** — on tier 2 `registerCustomAction` has no unregister, so
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
| 4 | `_contextMenuQuery` extracts `$rec->{ref}` twice, 22 lines apart, the second defended as "its own narrower copy" when it is identical | **FIXED 2026-09-10** — deferred that round to keep the diff to one concern. The Bandcamp entry now reads the `$recRef` the Wish List rule reads. The branch turned out to be UNCOVERED, so the green suite had never said anything about it; `t_addpath.pl` now pins the Buy entry by its output (stored album url, cached buy url winning, the no-url drill, and a non-Bandcamp control) — 3 red if the entry stops reading the ref. The fold itself is invisible to any test, which is why the pins are on behaviour: both forms pass |
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
distinction, not "no API calls". (From 1.0.2 that branch retries a failed lookup ONCE, 60s later,
on a timer; the add still never waits. And its callback must check the answer: Spotty reports a
429 through the success callback with the error text as `name` — §B, `A FAILED SPOTIFY LOOKUP`.)

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

**Round of 2026-09-09 — CLOSED, one finding, DECLINED; NO code change.** Run against the
0.1.140 tree (`@{upstream}...HEAD`: 31 commits, 10,344 insertions, working tree clean). The
finding was that `_verifyRelease`'s no-year path arms `_armVerifyRetry` with a STALE
`$albumId` — the `if ($year)` branch three lines above refreshes `$recId`/`$rec`/`$source`/
`$albumId` from the merge survivor, the sibling path refreshes nothing, so
`_verifyRetryTick`'s `refIdentity` guard rejects the retry, `track_count` is never measured
and Played is left on the flat `streaming_min_tracks` floor. **Declined on three grounds,
each sufficient. Do not re-report it.**

- **The asymmetry is the point, not an oversight.** The `$year` branch refreshes because its
  OWN `updateYear` call can merge the row synchronously, in that statement. The no-year path
  issues no write at all, so nothing has moved under it — `$albumId` is still the id `$recId`
  was armed with.
- **A CONCURRENT merge (an artist backfill) cannot produce a wrong write either.**
  `updateTrackCount` and `updateRelType` both re-resolve through `DB::_sameSourceCanonicalId`
  against the answered source AND ref id, and return empty for a survivor that no longer
  carries them. The stale-capture case is guarded at the writer, not at the caller, which is
  what the 0.1.139 carrier audit above settled.
- **The retry declining is DELIBERATE and says so in `_verifyRetryTick`'s own comment**: a
  survivor that no longer carries the requested id must not be re-asked, because it would
  receive a DIFFERENT catalogue entry's count and type. Such a row falls back to the floor and
  heals on first play from the list (`Browse::_albumTracks`), which is the stated behaviour of
  the whole retry ladder — see the `VERIFY_RETRY_SECS` header.

**Checked and found sound in the same round** (recorded so the next one can skip them): the
migration ladder's rungs 5/6/7 each re-read `PRAGMA user_version` rather than trusting the
entry-time value, so a withheld stamp blocks the later rungs instead of being stamped over;
`_mergeKeyRows`/`_updateIdentityField` column coverage on all three row shapes, with lineage
published only after a committed merge and `canonicalId` cycle-safe; the Bandcamp case where
`refIdentity` flips from `url` to `album_url` mid-flight (`_cacheBandcampUrl` mutates the
same in-hand `$rec` it writes through, and all three readers compute `refIdentity` after it);
Material tier 0/1/2 delivery, `_readMaterialActions`' three-way return and the prune's
never-unlink-an-unreadable-file / only-empty / only-ours rules; `normaliseFavurl` running
before every favurl reader; the podcast removal leaving no dangling `Podcast::` references;
and build hygiene — `install.xml` and `repo.xml` both 0.1.140, `<sha>` equal to
`shasum ListenLater.zip`.

**One open note went to §B** rather than becoming a fix: `DB::_purgeRemovedPodcasts` reaching
into `Sources` with no `->can` guard. **It was fixed the next day** — see the 2026-09-10 round
below, which also disproves the remedy this round proposed for it.

**Round of 2026-09-10 — the STANDING ACCEPTED entries, reopened on purpose. ALL SIX now
dispositioned: five changed, one confirmed unfixable-here.** Not a review round: the user asked which ledger entries were accepted as REAL and
left alone on probability or cost rather than being disproven, and then to work them in ascending
risk. That question is worth keeping, because it is the one this ledger cannot answer by itself —
an accepted entry reads exactly like a declined one after a few months.

**The six, and what separated them.** Accepted-and-live: the ladder warn version, the purge's
undeclared `Sources` dependency, `_contextMenuQuery`'s repeated ref extraction, the tier-2
unregister residue, `%ours` claiming `favorites-*`, and two artist-less tracks sharing a title.
NOT on the list, though they read similarly: everything judged UNREACHABLE rather than unlikely
(`isPodcastEpisode`'s missing `podcast` arm, `_migrateArtistPrefix`'s narrow SELECT, `foldLatin`'s
storage gate, the Spotify artist favurl), and the dead "Add" on streaming podcast SERIES rows,
which is accepted for unfixability, not for probability.

| # | entry | outcome |
|---|---|---|
| 1 | the rung-5/6 failure warn names the entry `$schemaVer` | **FIXED** — live read on the failure path; §A2 |
| 2 | `_purgeRemovedPodcasts` reaches `Sources` with no guard | **FIXED** — `->can` that aborts the RUNG; §B |
| 3 | `_contextMenuQuery` extracts the ref twice | **FIXED** — one read; twelfth round of 2026-09-04 |
| 4 | tier-2 `podcasts-*` stays registered with no feeds | **MOOT since 0.1.136** — nothing is feed-gated now; sixth round of 2026-09-03 |
| 5 | `%ours` can delete a third party's empty `favorites-*` | **VERDICT STANDS, residual now VISIBLE** — three narrowings tried and rejected, including a self-retiring one that looks right; the prune now names what it deletes and flags the retired-name class. §A2 |
| 6 | two artist-less tracks sharing a title collapse | **FIXED** — lazily, in `add()`; owes NO rung after all. §A2 |

**THE PART WORTH CARRYING FORWARD: a written-down remedy is not a verified one.** Entry 2's own
ledger text named the fix — "an explicit `use Plugins::ListenLater::Sources;` at the top of
`DB.pm`" — and that fix is IMPOSSIBLE. The package name matches the INSTALLED layout, so it
compiles only where a `Plugins/` parent exists; in a checkout it dies at `BEGIN` and takes every
suite with it, because `ll_require` seeds `%INC` one module at a time and `DB` is loaded first
almost everywhere. It was written into the ledger the previous day by the same reasoning that
declined the finding, and never run. **Measured in one command.** A remedy recorded beside a
verdict inherits the verdict's confidence without inheriting its evidence, so treat one as a
hypothesis until it compiles.

**Second thing worth carrying, and it happened FOUR times: a green suite proved nothing, for a
different reason each time.** Two fixes landed on uncovered lines, and two assertions written for
this round passed against a deliberately broken build.
`_contextMenuQuery`'s Bandcamp branch was UNCOVERED — every menu assertion in `t_addpath.pl` is
about the Wish List rule, so the suite was green before the edit, green after it, and green with
the entry pointed at an empty hash. The purge's Spotify branch had no test for an absent carrier
either. Both now have pins built the way this file requires: on OUTPUT, with the anti-test
measured (3 red and 4 red respectively) rather than asserted. **A green suite after a small edit
means nothing until you know the edit is on a covered line.**

The other two are subtler and are the reusable half. The re-add assertion for entry 6 passed
without the code that makes it work, because the INSERT hit `UNIQUE(source,dedupe_key)` and DIED
— the add command evals that away, so "nothing was stored" reads exactly like a clean dedupe from
outside. And its named-track CONTROL passed with the narrowing removed entirely, because
`_insertTrackRow`'s `findTrackByArtistTitle` guard catches an artist-bearing track before
`DB::add` is ever reached. **When a fix lives in a lower layer, assert at THAT layer**: a pass
through the command path can be manufactured by any of the guards above it, and by the database
constraint below it. Both now call `DB::add` directly and assert its ANSWER — the id and the
already-saved flag — rather than counting rows.

**What each fix rests on, so none of it has to be re-derived:**

- **The ladder warn** cannot introduce a failure mode: the added read of `user_version` is
  unguarded, but an identical unguarded read already ran three lines later on the same path.
- **The purge guard** is a `->can` in the file whose `%FOLD` header forbids one. The difference is
  the FALLBACK: there is no second way to ask whether a Spotify row is an episode, so it aborts
  the whole rung — nothing deleted, no report, stamp withheld, retried next start. Per-row would
  keep a mis-keyed episode; carrying on would delete music. The header is now scoped in the file
  so it reads as a rule about the fold rather than about the direction.
- **The `favorites-*` claim STAYS**, and three narrowings were tried against it. The one that
  looks right — claim retired names only until the ownership ledger exists — fails on the
  Material-upgrade path, because the sweep lives in the tier-2 prune while the ledger can be
  written from tier 0/1, which never claims those names. What changed is that the prune now
  NAMES what it removes and flags the retired-name class separately, so the accepted residual is
  visible to the third party it can affect.
- **The nameless-track key is disambiguated LAZILY**, in `add()`, at the moment two rows collide
  — so no stored key is rewritten and the rung this was said to owe is not needed. `|u:` joins
  `|e:`/`|p:` as an identity tail that a rebuild must never replace.
- **The ref fold** is invisible to any test — both forms pass all 220 — so the pins are on the Buy
  entry's behaviour and the equivalence was shown by running both.
- **The unregister residue** is Material's missing API, and the pref-off warn already tells the
  user the entries go at the next restart. `t_stubs.pl` still claimed its `setChange` recorder
  existed for the podcast-subscription watcher, which went with the built-in path; the recorder
  stays for the 0.1.121 reason, and the comment now says so.

**Docs swept in the same pass**, because three of them stated things that stopped being true:
`podcast-removal-plan.md` said 0.1.136 was uncommitted and uninstalled, `playlist-support-plan.md`
described playlist support as absent when it shipped at 0.1.107, and
`material-online-custom-actions-proposal.md` said the feature was in no released Material when it
shipped in 6.4.4. All three now carry a STATUS line marking them records rather than work orders,
and the three PR drafts say which PR merged into which Material release.

**CLOSED at 0.1.141 (2026-09-10).** State at close, so the next review can tell what it is
looking at: version bumped in both carriers, zip rebuilt, `repo.xml <sha>` recomputed and equal
to it, 15/15 suites green (t_addpath 232, t_material_actions 262, t_podcast_purge 45, t_refold
119). Two commits on `dev`, UNPUSHED — the review gate, not an oversight. **The code this round
touched is new, so expect it to attract findings; the four most likely are answered in §A2 above
under the `|u:` key entry, in §B under the purge guard, and in §A2 under `%ours`/`favorites-*`.**
Cite one of those entries and what is new about your case, or the round trip is wasted.

**CLOSED at 0.1.143 (2026-09-10) — the `|u:` round and the fold round that followed it.**
Closed together because the second grew out of the first. 0.1.142 reproduced three findings
against the `|u:` key and changed NO shipped code: the whole output was five assertions in
`t_addpath.pl` and a ledger entry, which is the right outcome when a finding is real at one layer
and closed at another. 0.1.143 then fixed the defect that round exposed — `_norm` erased CJK,
Cyrillic and every all-mark name to the empty string, so unrelated albums shared one dedupe key.
LL was the ONLY repo with it; PFR, LBF and DSC were measured and were already correct, and two
claims made against them that round are retracted in `docs/fleet-fold-rollout.md`. Do not port
this fix to the other three, and do not re-raise either retracted claim.

**CLOSED at 0.1.145 (2026-09-10) — the review of 0.1.143's own fold release, and the fleet rules
it turned up.** The round found four defects in the release that had just fixed the fold, every
one reproduced before it was fixed rather than taken on the reviewer's word, which changed two
verdicts: the migration finding went from PLAUSIBLE to deterministic data loss, and the fold-order
finding turned out to have a narrower and nastier trigger than reported. In order of severity:
the migration ladder ran its cross-source merge BEFORE the refold, so three unrelated non-Latin
albums sharing the erased key went in and one came out, with no way back; the new fold ran its two
substitutions in the order that does not commute, breaking both the stored key and the live match
for any underscore next to other punctuation; a dev database already stamped 8 would have kept the
wrong keys; and the Bandcamp search query silently acquired a characters/octets camp when the fold
learned to keep every script.

**0.1.145 then took two fleet matcher rules LL had never received** — the stylised-letter fold
(missed at the 0.1.112 port, not decided) and the `_punctNorm` short-title hatch, which LL took
FROM the fleet rather than the usual direction. The KEY half of the first was DECLINED by Simon
in the same pass; it is recorded in §A2 above and must not come back as a finding.

**Two things from this round are worth a reviewer's attention before opening a new one.**
(1) **The fold's two-substitution shape is LL-only BY CONSTRUCTION and the ORDER is load-bearing.**
`\w` includes the underscore and `\p{Alnum}` does not, so only LL strips it separately — and it
must, because `_` is a LIKE metacharacter and two finders build patterns straight out of `_norm`
with no ESCAPE. It is commented at the sub and pinned by three assertions on the ripped-file shape.
(2) **A fold change is an ENCODING change.** The Bandcamp defect was not in the fold at all: the
moment a normaliser starts preserving codepoints it used to erase, every consumer downstream
inherits a character string it has never seen, and the fold's own tests cannot see any of them.
Measured live on the server rather than reasoned — the same query as CHARACTERS returns
`400 Bad Request` for an accented name and KILLS THE REQUEST for a Cyrillic one
(`Wide character in subroutine entry at Slim/Utils/DbCache.pm line 157`, then `Bad dispatch!`),
inside an async coderef where our callback never runs and we log nothing. As octets it returns the
album. Do not repeat Search Hub's comment that a `query_enc` mistake "does not error, it silently
returns nothing" — true for Qobuz, Tidal and Deezer, false for Bandcamp.

**FIELD-VERIFIED, which outranks everything above it.** Simon confirmed on the installed build
that non-Latin albums ADD and then correctly move to PLAYED when played through. That is both
halves of the original defect at once — the dedupe key that used to collide, and the match gate
that used to read an erased name as ABSENT and therefore accept anything. **If any of this is
re-opened from a reading of the code, that is the answer.** What the field has NOT exercised, so
do not claim it has: the rung-7 guard, which only fires on a database still holding pre-0.1.143
keys with a genuine collision in them, and the Bandcamp octets path, which needs a non-Latin
Bandcamp album with no stored album url. Both are covered by the suite and, for Bandcamp, by a
live measurement against the server.

**State at close**, so the next review can tell what it is looking at: **0.1.147** in
`install.xml` and `repo.xml` (0.1.146 plus a ledger entry and ONE comment moved back onto
`_albumMatches` — no executable change at all), zip rebuilt with `<sha>` equal to it, 15/15 suites
green at 1,562 assertions. **README/CHANGELOG deliberately NOT regenerated** — this is a dev
build, and those are merge-to-`main` artifacts. The 0.1.146 note about verifying the RUNNING
module still applies to any build that changes behaviour; this one does not, so it was not
re-verified on the server. Bandcamp was exercised end to end against it — an add, a resolve to a
full tracklist, and a Buy link to the real album page. Commits sit on `dev` UNPUSHED, which is the
review gate and not an oversight.

### 2026-09-16 review (1.0.5) — ONE finding: the guard-ownership comment in `_updateIdentityField`

Round against the 1.0.4 commit (`git diff @{upstream}...HEAD`): `Played.pm` release-id door,
`DB.pm` `updateAlbumTitle` / `findAlbumBySourceAlbumId` / `album_title` on `_updateIdentityField`,
`Plugin.pm` `_titleFromLabel` provenance + the widened `_backfillStreamingArtist` and its retry.

**THE FINDING — `_updateIdentityField`, `updateAlbumTitle`, `_titleFromLabel`, `album_title`
provenance: FIXED 2026-09-16 (prose only, 0 code lines).** `_updateIdentityField`'s header said
the title guard "lives in updateAlbumTitle, which only accepts a title the CALLER has established
was read off a row LABEL". It does not. `updateAlbumTitle($id, $title)` takes no provenance
argument and checks none; it only skips the rewrite when the new title normalises equal to the
stored one, then writes. The guard is the caller's `return unless $titleFromLabel`
(`Plugin.pm`, in the Spotify branch of `_backfillStreamingArtist`), which both `Plugin.pm`'s own
comment and `updateAlbumTitle`'s header state correctly — the DB.pm line was the lone
contradiction, and it contradicted a header that shouts `THE CALLER OWNS THE GUARD` 140 lines
below it.

**Why it was worth a version.** This is exactly the second standing rule — a comment is not the
contract — and the failure it invites is concrete: a later caller trusting the DB.pm line fires
`updateAlbumTitle` on a row whose title arrived on an `&al=` handshake, and it overwrites and
re-keys, undoing the 0.1.92 `svc_title` decision with nothing in `DB.pm` to refuse it. The fix
names the caller as the owner and cross-references the header.

**WHAT THE ROUND CLEARED, recorded so the next one does not re-derive it:**

| checked | why it is not a finding |
|---|---|
| `_spotifyAlbumRecord`'s `trackCached(undef,$uri,{noLookup=>1})` signature and `{album}{id}` | source-read and pinned; the live playback test is a RECORDED DEFERRED decision, not a gap |
| `_spottyAlbumAnswered` now gating the ARTIST backfill too (was `ref eq 'HASH'`) | confirmed by the live 1.0.3 PFR adds, which returned both title and artist |
| `_backfillRetryTick`'s ref-identity guard being stricter than `_verifyRetryTick`'s deliberately-permissive empty-identity rule | no WRITER nameable that produces an empty-identity Spotify survivor — the branch is real, the input is not |
| the title repair firing for NATIVE Spotty adds, and the second `album()` after `classifyRelType` | both reachable; native adds arrive artist-less so they already fired the backfill, and Spotty caches album objects. No concrete failure |
| `_mergeKeyRows` keeping the earlier row's title while writing the new key | safe: a key collision implies the two titles already normalise equal |
| `_titleFromLabel` leaking into `DB::add`, the now-playing fallback, `_addCommand` / `_saveTrackRecord` | explicit column list (harmless); the fallback yields no Spotify `album_id` so the repair never fires; no flag means the repair is inert |

**State at close.** **1.0.5** in `install.xml` and `repo.xml`, zip rebuilt with a matching
`<sha>`, 15/15 suites green at 1,637 assertions. `Plugin.pm` and `Played.pm` are byte-identical
to 1.0.4; `DB.pm` differs in comment lines only, 0 executable lines — so nothing was re-verified
on the server and nothing needed to be. `docs/VERSION-HISTORY.md` gained the 1.0.4 entry it was
missing (the `trackCached` die WARN) alongside 1.0.5. **README/CHANGELOG deliberately NOT
regenerated** — dev build, merge-to-`main` artifacts. **1.0.3 remains the last build INSTALLED
and TESTED on the rig**, and the live PLAYBACK test stays DEFERRED by Simon.

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

**SPEC RE-COPIED 2026-09-16 (sha1 `504f722a…`, identical in LBF, PFR and LL).** §6's rate-limit rules gained three points from LBF's third Spotify back-off review: tag the refusal on the answer itself; every loop that searches must check the back-off on its own (nothing inherits it); and a refusal can answer SYNCHRONOUSLY (Spotty's `getToken` returns `$cb->(-429)` in-stack), so a pump must not treat every in-loop completion as a cache hit. Its pointer to `docs/spotify-rate-limits.md` now says that file is in the LBF repo only. No code in this repo was changed by the re-copy.

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
  - **No album id from a PLAYING track** — `getMetadataFor` flattens the album to a title, exactly like Deezer, so Spotify stays out of `_hasAlbumIdFromTrack` and a Now Playing add falls back to the recovered album/artist. Getting the id would mean reaching into `API->trackCached`, which is the private-internals route **declined for Tidal/Deezer on 2026-07-25** — do not re-attempt it here either. **Scope of that decline (2026-09-16): the ADD path only.** `API->trackCached` is NOT banned outright — since 1.0.1 `Played::_spotifyAlbumRecord` calls it to match a PLAY to a saved row by release id (§B, "A SPOTIFY ROW'S STORED ALBUM TITLE CAN NEVER MATCH"). The two are not the same question: the Played door reads a cache entry the player already built and has a measured failure to fix, the add would pay a fresh lookup for a row it can already name. A grep landing here from `Played.pm` has found the wrong entry — that code is live and deliberate.
  - `_backfillStreamingArtist` gives it its own branch rather than the shared `$getAlbum` coderef: Spotty's tracklist `line2` is `"Artist • Album"`, not the bare artist Tidal and Deezer put there, so the shared path would store the wrong artist. It asks the API for the album object instead, which carries a plain `artist` string.
  - **`spotty` is deliberately EXCLUDED from `_ownedCats`' legacy seed** (alongside `listenlater`). The seed may only claim Material categories LL can have written, and a service supported from the day it arrives has no pre-ledger husks — claiming `spotty-album`/`-track` would claim categories only somebody else can have written, which the prune could then delete.
- `resolveTracks` finds the playable node (`type=>playlist`, `url=>CODE`) from `buildPlayableItems`, then calls `node->{url}->($client,$cb,{},$pt)` where `$pt = passthrough[0]`. Source tag from `favorites_url` scheme via `sourceFromUrl`; `sourceFromImage` (cover host) is a fallback when there's no favurl.

## Drag-and-drop to move between sections — NOT feasible (Material limitation)
Material only enables list drag-drop for **Favourites, editable local playlists, and the queue**: in the SlimBrowse `item_loop` branch `resp.canDrop = isFavorites` (hardcoded), and `dragStart`/`dragOver` gate on `this.canDrop`. A third-party OPML feed can't opt in (no response field enables it), and the `drop` handler issues favourites/playlist-specific reorder commands, not a generic "moved item → section" callback. So drag-to-move between the Listen Later / Played sections would need a separate upstream Material change.

## Custom actions on Material HOME shelves — only after a streaming browse (main-bundle limitation, left unpatched)
The "Add to Listen Later"/"Add to Wish List" custom actions appear on streaming **browse** pages but on **home-page shelf cards only after you've opened a Qobuz/Bandcamp/Tidal browse area in the same session**. Cause: `itemCustomActions` is a single **view-level** property. Browsing a service runs `view.itemCustomActions = resp.itemCustomActions` (`browse-functions.js:640`, deferred bundle) and that value **persists** on the home view; but the home shelves are built by `handleHomeExtra` (`browse-page.js`, **main** bundle `material.min.js`), which takes only `resp.items` and never sets `itemCustomActions`. Our patch *does* push the `CUSTOM_ACTIONS` marker into each home-shelf card's menu, but the marker only expands when `view.itemCustomActions` is already populated (i.e. leftover from a prior browse). There is **no plugin-only fix** — the plugin can't influence `view.itemCustomActions`. The one-line fix is in the main bundle: in `handleHomeExtra`, after `this.topExtra = resp.items;`, add `if (undefined!=resp.itemCustomActions) { this.itemCustomActions = resp.itemCustomActions; }`. **Decision: left unpatched** — we keep the Material footprint to the single deferred-bundle patch (same reason 0.1.18's main-bundle patch was reverted). A candidate addition to upstream PR #1235 if revisited.

## GitHub Pages docs (README.html / index.html)
`README.html` and the `index.html` redirect are **generated** from `README.md` by `tools/make_readme_html.py` (zero-dependency Markdown→HTML; ported from the sibling ListenBrainz plugin). The version badge is read **live from `ListenLater/install.xml`** — never hardcode it. The first `## ` section onward becomes the body; the "Features at a glance" table renders as cards, other tables as styled tables; the intro paragraph becomes the hero tagline. **Re-run `python3 tools/make_readme_html.py` after editing `README.md` or bumping the version** (these are docs only, not in the plugin zip). GitHub Pages serves the repo root, so `index.html` → `README.html` and the `ListenLater.zip`/`repo.xml` links resolve at the Pages URL.

## Version History → `docs/VERSION-HISTORY.md`

**Moved out of this file 2026-09-10.** It was 3,111 lines, 58% of `CLAUDE.md`, and it pushed
the Review Ledger past the point where any review could hold the file in context — which is
how four rounds in a row re-reported findings the ledger had already declined. Nothing reads
it automatically. Append new per-version entries there, at the end; user-facing release notes
still go in `CHANGELOG.md` on a main merge.

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
| `t_db.pl` | dedupe keys and migrations against real SQLite: 0.1.43 (same title, different year), 0.1.33 (cross-source), 0.1.74+ (track vs album keys), 0.1.81 (same track from two surfaces), 0.1.88 (`track_count`, forced `rel_type`), an old schema file upgrading with its rows intact, and the live `updateArtist`/`updateYear` carriers reconciling a newly-equal key across services without separating source from ref or guessing across statuses. Also pins the inverse async race (year merge deletes the artist callback's id), exact vs canonical lookup, logical Move/Remove following, same-source result propagation, and cross-source rejection for counts/types/URLs. **Its Latin fold controls gained the underscore-ORDER cases in 0.1.144**, and the gap they close is worth stating because the old row looked complete: `under_score` was the only underscore seeded, an underscore BETWEEN word characters is its own whole separator run, and it therefore folds identically whichever of `_norm`'s two substitutions runs first — so it passes against the bug. Only an underscore ADJACENT to other punctuation or a space can show the order, which is why `01_-_Intro` and `foo_ _bar` are now seeded alongside it, with the plain `01 - Intro` as the control that must NOT move Plus 2026-09-16 (1.0.1): `updateAlbumTitle`: a label title replaced and re-keyed, an agreeing title a no-op, junk refused, a track key kept, a same-list native twin MERGED, and a twin on another list left alone. |
| `t_played.pl` | the thresholds that keep regressing in both directions: 0.1.82 (a single/short EP CAN reach Played), 0.1.83 (a one-track release does NOT mark when it starts), 0.1.88 (a real total beats the 4-track floor), plus the live-library-count rule Plus 2026-09-16 (1.0.1): the Spotify RELEASE-ID door (`_spotifyAlbumRecord`): the remaster play matches the remaster row, not the 1990 one (the Spotty-absent case is the control); a cache miss, an id-less album or an unknown id falls to the title doors; a playlist is never matched; Qobuz plays and Spotify episodes never consult Spotty. |
| `t_reltype.pl` | 0.1.88's classification: `singleIsWrong`, the full `relTypeFor` table, `classifyRelType` end to end, that the Qobuz album-object path fetches **no** tracklist, and that a CATALOGUE count comes back flagged provisional while a resolved one doesn't (the flag is the only thing stopping an inflated Played total) |
| `t_verify_retry.pl` | 0.1.90's retry: that it retries, retries EXACTLY once (an unbounded retry would be worse than the bug), never gives up silently, and re-reads the row first — plus the three distinct answers `_verifyRelease` must keep apart (real count → store; provisional → neither store nor retry; no count → retry), canonical-id propagation after a year rekey, service-independent year propagation to a cross-service survivor, and the rule that an in-flight result from one service never writes its count/type onto another service's survivor |
| `t_learn_count.pl` | 0.1.93's in-flight guard on `Played::_learnTrackCount` and specifically its EXPIRY: that a lost request stops blocking after `COUNT_STALE_SECS`, that it is logged rather than swallowed, that an answered request stays immediately re-askable, that records don't block each other, and that a library release is never asked at all. Uses `TestClock::advance()` |
| `t_favurl.pl` | the private favurl handshake (`Plugin::_stripPrivateParams`): `?cover=`/`?b=`/`&a=`/`&y=`/`&al=`/`&rt=`/`&tc=` — what each yields, that junk is stripped-but-rejected, that `&a=` can't eat `&al=`, that `&rt=`+`&tc=` really do reach `singleIsWrong`, and that a NATIVE favurl comes back byte-for-byte unchanged with no field set. Calls the real sub — see the `&tc=` lesson below |
| `t_addpath.pl` | the ADD PATH end to end — a Material action into `_addCtxCommand`, out as a row in SQLite. Also 0.1.92's `ref.svc_title`: that the service label is kept when it differs and not when it doesn't, that a play of the QUALIFIED title finds the row while a different artist's doesn't, and that the dedupe key still ignores the label. What the handshake params become on the stored row, that `&tc=` settles the type but never fills `track_count`, that the cross-kind single dedupe eats a REAL single but not a disproved one, that an UNKNOWN type defers instead of inserting a guess, and that unreplayable/unidentifiable adds are refused. Plus the NOW-PLAYING FALLBACK's gate on BOTH paths (0.1.98): on the album path, that a browse row with a non-service container verb does NOT adopt the playing track, while a genuine Now Playing add (no `svc` at all) still recovers its source; on the TRACK path, that a tapped row whose `trackid` resolves to NOTHING (no svc — it shares `$trackCmd` with Now Playing) and an online-track row with a container verb are both refused, while a real Now Playing track add still recovers the playing song and its url. In both cases both directions are needed, or "doesn't adopt" passes with the fallback simply switched off. And the other side of that gate: a REMOTE queue row (negative `trackid`, no favurl) is resolved by its id and stored as the row that was TAPPED — its own title, its own play url, its source read off that url and not hardcoded `library` — while the library row on the same branch still takes its album/year from the Album row — and, since the RemoteTrack that row resolves to is normally BARE, that a `''` title/artist off the object never overwrites what Material sent (the stub answers `''` for a negative id, so this cannot pass by the test having supplied the metadata itself). Also what a REJECTED add logs (0.1.98): that an empty source reads `(none identified)` rather than `''`, that the container verb is named, and that the clause which actually failed is named — a missing play url and an empty title each say so instead of blaming the service, while a genuinely unsupported source still reads exactly as it did. The reject is silent to the user, so that one line is the whole trace. **And since 2026-09-10, the NAMELESS-TRACK collision** (`DB::trackUrlKey`): two artist-less tracks sharing a title store as two rows, the FIRST keeping the `|||t:<title>` key it already had — that assertion is what says no migration is owed — while only the second carries the `|u:<svc>:<url>` tail; a re-add of the second answers "already saved" with ITS id; and a NAMED track key still dedupes across differing urls. The last two ask `DB::add` DIRECTLY, because through the add command they pass against a broken build — one on the UNIQUE constraint dying, one on `_insertTrackRow`'s earlier artist guard. **Plus the two halves that round 2 added:** that a nameless track with NO url still dedupes to its twin and mints no `|u:` key around an empty url (asked at `DB::add`, since the command refuses a urlless add outright), and — the other way round — that once the title twin is DELETED, a re-add of the url-keyed track is refused by `_insertTrackRow`'s url guard. That last pair pins a CALLER: `DB::add` alone would store a second row for one play url, and the guard is the only thing that stops it. Needs no service: the whole path asks only `client`/`getParam`/`setStatusDone`/`setStatusProcessing`/`addResult`/`addResultLoop`, and `client => undef` makes the background jobs no-op (pass `_client` for the Now Playing cases — it is pulled out of the params, not passed as one). **The service plugins must be declared** (`_serviceCan`) or the gate rejects everything and every assertion passes against an empty DB Plus 2026-09-16: a label-titled Spotify add shows the Spotify album title while a handshake title is kept (1.0.1), and (1.0.2) a FAILED Spotty answer (`type => 'text'`) never becomes the title, arms exactly one retry that then repairs the row, gives up loudly after the second failure, and skips a removed row. |
| `t_resolve_count.pl` | what a resolve writes BACK to the row (`Browse::_albumTracks`): a FAILED resolve records nothing and never clobbers a real `track_count`/`rel_type`, Bandcamp helper-only rows count as a failure too, and 0.1.88's successful-resolve refresh + forced single-correction still work. Plus `Sources::hasDirectAlbumRef` — whether a row's tracklist costs one album call or a whole service SEARCH (the Bandcamp page-url case), which is what gates background work |
| `t_prefs_migration.pl` | 0.1.94's pref migrations and the rule that makes them one-shot: that a leading-underscore pref cannot be stored at all (pinning the stub against `Slim::Utils::Prefs::Base::set` — if that assertion ever passes with a value, every other one here stops meaning anything), that the rebrand copy runs once and never reverts a later choice, that an install which already ran the broken copy isn't copied over again, and that the threshold bump re-applies exactly once. Runs the two migrations in the real startup order — the ordering IS the bug — for both an install that carries a pre-rebrand namespace and one that doesn't. **A real user's box is the second shape**: the rebrand landed in 0.1.25 and the first release was tagged v0.1.69, so no installed copy ever wrote a `plugin.listentolater` pref and the copy has nothing to import. `reset_prefs` seeds that namespace (Simon's dev box, the only one that ran the pre-rebrand code); `reset_prefs_no_legacy` doesn't — pick the one that matches the install you mean, or an assertion proves the wrong thing |
| `t_material_actions.pl` | 0.1.95's delivery split: that the six SERVER-resolved positive categories are REGISTERED with Material (6.4.6+) and no longer written to actions.json while `track`/`queue-track` stay in the file (0.1.97), that nothing registered is also left in the file (the merge is additive — a leftover means every "Add" shows twice), that registration happens exactly ONCE across a re-register, a Settings save and the deferred radio write, that the suppressors and `podcasts-*` stay in the file where Material can actually see them, that an older Material still gets the byte-identical file it always did, and that a third party's entries in a category we vacated survive. Plus the FAILURE path: a `registerCustomAction` that dies falls back to the file (all of it, or exactly the refused sections on a partial failure — never both places), and a file write with no registration behind it (the pref switched on mid-run) writes the full set. Plus the SETTINGS save itself, driven through `Settings::handler` with `debug_log` OFF (0.1.97): turning `material_action` off clears the file half on the save and warns about the registered half, turning it back on restores `track`/`queue-track` without re-writing anything Material already took, and turning it on when nothing registered writes everything. And the 0.1.98 rule that the OFF save must obey: while entries are still registered, the empty suppressors (ours and the radio ones) STAY and stay EMPTY — deleting them while the `online-*` pair cannot be withdrawn ADDS "Add" to our own rows instead of removing it — including on the path that rule was written for and originally missed, **the file being GONE**, where all three families have to be RE-CREATED rather than preserved. And the same rule from the other side for the one category that is ours, file-only AND per-app: with nothing registered, `podcasts-*` is DELETED rather than left as an empty husk — including for a user who has since unsubscribed from every feed, the state `_materialActionSet` can no longer name — because an empty per-app override hides Add on the Podcasts app for good; with entries still live it stays, and stays empty, for exactly the reason the radio empties do. Plus the 0.1.110 DELIVERY TIER, which needed `set_material_version()` because without a `getPluginVersion` stub every one of the previous 746 checks ran at tier 1 and could not reach the new code at all: the tier table (capability alone is never enough — the one-argument empty-section call pushes a null on 6.4.6/6.4.7), the folded action set, an upgrade from a file install ending with the file UNLINKED, a hand-written actions.json surviving verbatim — populated category, their own empty suppressor, and an entry titled like ours that is not ours — both refusal fallbacks (a refused positive and a refused empty section each reach the user through the file, and the file is created for them if it has gone), the deferred pass registering a late-discovered radio command without re-pushing anything, the pref off at STARTUP vs mid-run (only the latter has anything registered to suppress), the uninstall stranding nothing, and both downgrade steps rebuilding the file. Plus 0.1.114's `Sources::materialAtLeast`, the ONE version comparator the three gates now share: the comparison table, all THREE return values with `undef` (cannot tell) pinned as distinct from `0` (too old) even though both are falsy today, and the LIST-CONTEXT trap that shipped during the refactor — `_materialVersion` is `return eval {...}`, so inlining it into the argument list collapses `(undef,6,4,8)` to `(6,4,8)` and every Material-less install silently reaches the NEWEST tier. That last one is reproduced directly AND pinned as a source check on both callers (`LL_PLUGIN_SRC=`/`LL_BROWSE_SRC=` point those at mutated copies), since no return value shows which spelling a caller used. Plus 0.1.119's two Material fixes: that the PRUNE's diagnostics do not claim the API delivered anything when registration never ran (the pref off at STARTUP — the dump must not say "plugin API"/"streaming Add active"/"registered sections" under "material_action pref = OFF"), with the mirror case pinned so the gate cannot be widened into never reporting the API half at all; and that a category appearing MID-RUN still reaches Material — subscribing to a first podcast registers `podcasts-*` while pushing nothing already registered a second time (a duplicate push is how every "Add" comes to show twice), is not ALSO written to the file, and a repeat pass adds nothing. The `setChange` wiring that triggers it WAS a source check, because the harness's `setChange` was a no-op — and that is exactly how 0.1.121's finding 1 hid for six rounds: a source grep pins that a call EXISTS, never WHERE it lives, so it matched just as happily with the watcher inside the pref-ON arm, where a box-unticked boot installed none. The stub now RECORDS into `@Slim::Utils::Prefs::Obj::CHANGES` and the suite drives `postinitPlugin` on BOTH arms, plus the subscribe-first/tick-second ordering that shows why no second watcher belongs in `Settings.pm` (`setChange` STACKS). When a behaviour can only be pinned at source, the stub is too thin |
| `t_material_matrix.pl` | the actions.json STATE MACHINE, as invariants rather than scenarios. Enumerates starting file x Material version x podcast subscriptions x user journey and drives real op SEQUENCES (boot on/off, Settings on/off, restarts), checking after EVERY step: **I1** a pref-OFF terminal leaves none of our entries, and with nothing registered none of our categories either; **I2** a foreign category — entries AND deliberate empty suppressors — is byte-identical before and after every operation; **I3** no EMPTY `<cmd>-album/-track` exists for a command we can replay (the 0.1.51 regression as a property); **I4** any journey ending pref-ON converges on the clean baseline, whatever route it took. Exists because the scenario suite is structurally blind to both halves of these bugs: they are TWO-TRANSITION (the clear pass writing `podcasts-*` empty is correct — it goes wrong at the next WRITE) and they live in the one untested cell of a 2x2, since every `$live` case in `t_material_actions.pl`'s podcast block subscribes a feed first. The invariants deliberately carry almost no vocabulary of "which categories are ours" — that list is the bug generator, so a test restating it would inherit the fault; the reference is a BASELINE from a clean run of the same config. I4 compares the MERGED file+registered view, not the file, or a Settings-save enable (which cannot register, so it delivers through the file by design) reads as drift. **A world must reset `%Slim::Utils::Prefs::VALUES`** — a pref written by one journey turns the next journey's "upgrade from an older build" case into an already-migrated one, silently hiding this exact bug class. **And it must reset every registration fact, including BOTH per-category ledgers**, or a "restart" carries this process's registrations into the next one. Since 0.1.119 the configs carry a Material-VERSION axis and the matrix covers all three DELIVERY TIERS (2 / 1 / 0) x subscriptions x 9 journeys x 4 invariants; before that it pinned at tier 1 and every assertion ran against a mode that prunes nothing and never unlinks the file. Two things that only make sense once tier 2 is reachable: `merged_view` must treat a ONE-ARGUMENT registration as declaring an EMPTY section (reading `$_->[1]` puts a literal undef in and makes the suppressor look populated), and I3 must take the MERGED view — on tier 2 suppressors arrive by registration, so reading the file alone makes it unfalsifiable exactly where the prune runs |
| `t_addpath.pl` (Spotify section) | 0.1.113's Spotify support end to end: a bare `spotify:album:<id>` URI storing as an album with source `spotify` and its id captured, a track URI storing a playable `spotify://track:<id>`, both playlist spellings landing the same short id, `svc:'spotty'` resolving to source `spotify` with no cover to sniff — and **the rebuild test**, replaying each stored row and asserting Spotty received a full URI rather than a bare id (a bare id matches nothing in `API::album` and returns an empty tracklist, i.e. a row that plays once and is then gone). The Spotty stubs are declared at the END of the file on purpose, so every test above it runs with Spotty ABSENT and the `->can` refusal is covered by the same file. Plus, since 2026-09-10, the saved row's CONTEXT MENU beyond the Wish List rule: the Bandcamp Buy entry opens a stored album url directly, prefers a cached `buy_url` over it, falls back to the drill when the ref holds neither, and never appears on a non-Bandcamp row whatever its ref carries. That branch was uncovered until then, so the suite was green whatever the entry did — the reason the fold of its duplicate ref extraction needed new pins before it could be trusted (3 red) |
| `t_favurl.pl` (Spotify sections) | `normaliseFavurl` itself, and then the four readers that consume it — including that none of them reaches `favurlIsTrack`'s fail-open branch, which the file's no-warnings check enforces. Plus `sourceFromSvc`: `spotty` → `spotify`, while a home-shelf id still answers `''` so the cover sniff keeps its turn. Plus 0.1.115's `spottyArtistName`, the ONE reader of a Spotty album object's artist: both legitimate shapes (the cache's plain `artist` string and the raw API's `artists` array), the string winning when both are present, and seven miss cases — including a hash in `artist`, which is the TIDAL/DEEZER shape and must NOT be read here, so a fold of the two extractions fails rather than quietly losing a Tidal row's artist. Calls are `eval`'d because a shape the sub fails to guard DIES rather than returning, and a dying assertion aborts the run instead of reporting it. Plus source checks that both modules ask through the sub and neither open-codes the `artists[0]{name}` read outside its body (`LL_SOURCES_SRC=`/`LL_PLUGIN_SRC=` point those at mutated copies) |
| `t_reltype.pl` (Spotify section) | That a Spotify EP — `album_type: 'single'` with `total_tracks: 5` — is NOT stored as a single, that it resolved a real tracklist to prove it, and that a 9-track "single" demotes to `album` rather than `ep`. Also that the album is requested by full URI, and that no album object at all falls through to the tracklist instead of dying or inventing |
| `t_podcast_purge.pl` | The 0.1.136 purge (schema rung 6), which is the one rung that DESTROYS user data, so the suite is about blast radius. Rows are seeded BELOW the rung by hand, not through `DB::add`, because the shapes under test are what OLDER builds wrote. It pins that every `source='podcast'` row goes; that a MIS-KEYED pre-0.1.126 streaming episode goes (a `|t:` key, and for Spotify the bare `spotify:episode:` spelling — only the url identifies those, which is why the test is `spotifyEpisodeUri` and not one SQL predicate); and that a CORRECTLY-keyed Spotify **or Deezer** episode SURVIVES, both being supported paths. Controls: an ordinary Spotify track, an album and a playlist are untouched. Also pins the report file — written BEFORE the delete, naming what went and nothing that stayed — the empty-library no-op (stamp, no report, the path most upgrades take), the LADDER rule that failures withhold the stamp, and a partial second-DELETE failure rolling the whole purge back so the retry report still contains every episode. Anti-tested 4/4/2/2/3 red. Since 2026-09-10 it also pins the two LADDER-MESSAGE rules that have no other home: that a failing rung names the version the ladder STAMPED rather than the one it was entered at (driven from version 2, the only shape where those differ), and that with `Sources::spotifyEpisodeUri` unreachable the rung removes NOTHING — the built-in row is the assertion that matters there, since it is already doomed when the guard trips, so a per-row abort would delete it (4 red) |
| `t_refold.pl` | 0.1.112's fleet fold and the migration it owes: apostrophe elision (and the `'n'` guard) plus `%FOLD` in ALL THREE normalisers, that the three punctuation passes still differ where they must (the key keeps "(Deluxe)", the gate strips it, the ranker keeps "(LP4)"), that the lenient empty-artist gates are untouched, and `_migrateRefold` end to end against real SQLite — a stale key rewritten, same-status duplicates collapsed into the earliest save, MIXED-status rows left alone, and track/playlist/episode identity tails preserved. Its cross-source cases pin `add()` parity, atomic source/ref adoption, source-scoped track counts, mixed-status restraint, service-qualified `|p:`/`|e:` independence, and schema rung 7 repairing a database that already stamped the old source-scoped refold while retaining a retry on operational failure. Plus, at source level, that the fold lives in `DB.pm` and that `DB::_norm` calls it DIRECTLY while `Sources` goes through `->can` — the failure that guards is a permanent wrong key in a UNIQUE column, which no passing call can show. Plus §4i (0.1.119): a rollback that ITSELF fails must not poison the handle — `AutoCommit` restored, a later transaction still openable, the failed pass still withholding the ladder stamp, and the assertion that actually matters, that an ordinary write made AFTER the failure is durable rather than discarded at shutdown. DBD::SQLite will not fail a rollback on demand, so only the rollback is injected (a `RootClass` subclass); the failing GROUP is 4h's planted collision. Its squatter pair differs by an apostrophe rather than reusing 4h's accented one — that is fixture history, not a hazard in accents. Since 2026-09-10 it also covers the THIRD identity tail, `|u:` (a nameless track keyed on its play url): two services' rows stay independent through the fold, the tail survives verbatim while the TITLE segment around it is refolded, and — at `_keyForRow` rather than through a caller, since `updateArtist`'s callers only make album rows today — a stored `|u:` tail wins over a rebuild, so a later artist backfill cannot re-key such a row into its twin. **Since 0.1.144 it also pins the rung-7 guard (§4c4), which is the worst bug this file has carried:** three unrelated non-Latin albums that share the erased `||` key survive the ladder from BOTH exposed start versions (5 and 6) and end on three distinct keys — before the guard, three rows in gave ONE out, and the refold could not undo it because the rows were gone. Its CONTROL is the half that matters, because a guard that refused every merge would pass all six: a genuine cross-source duplicate must still collapse to one row. §4j2's Latin seeds also gained the two underscore shapes (`Boards_of_Canada`, `01_-_Intro`) that 0.1.143 quietly rekeyed — every seed before them separates words with a character that is ALREADY non-`\w`, so the substitution order could not show, and the "rekeys ZERO rows" control passed against a fold that moved five of twenty-three ordinary Latin inputs |
| `t_query_enc.pl` | 0.1.120's per-branch query encoding in `_searchService`: that Qobuz, Tidal and Spotty (0.1.121) are handed CHARACTERS and Deezer OCTETS, and the CONSEQUENCE rather than just the flag — the URL `uri_escape_utf8` actually builds (called for real) and the name Unidecode actually transliterates to (modelled, since Text::Unidecode is not a dependency here). Plus the fail-safe cases in both directions, since a raw-CLI add arrives as octets and must not be corrupted on the way out. **Its fixture is the fragile part and is asserted rather than assumed:** a `"\x{f3}"` literal is stored latin-1 with `utf8::is_utf8` FALSE, so the encode never fires and every branch looks correct — `utf8::upgrade` models what `sqlite_unicode`/JSON::XS really hand back, and the first assertion fails loudly if it is ever dropped. The ASCII positive control is what stops the suite being satisfied by a change that mangles every query equally. **Bandcamp is in the OCTETS camp since 0.1.144, and the story of how it got there is why this suite distrusts an invariant.** From 0.1.122 it was exempt from both camps, tested for exactly that — its branch sends the combined `_norm("$artist $album")`, which the old `s/[^a-z0-9]+/ /g` made ASCII-only, so the two encodings were byte-identical and no conversion applied. The assertions pinned that INVARIANT rather than a camp, precisely so a change that started sending a raw name down the branch would go red. **The invariant died in 0.1.143 and those assertions did not notice**, because every fixture was accented LATIN: the fold learned to keep letters of every script, but `Sigur Rós` still folds to `sigur ros`, so all three ASCII-only checks stayed green while the exemption underneath them was gone. Now pinned as a camp, with CJK and Cyrillic fixtures, and the CONSEQUENCE as well as the flag — the octets decode back to the real name, which a query that dropped the name entirely (the pre-0.1.143 behaviour) would also satisfy on the flag alone. The ASCII and latin-1 rows are the controls that stop it being satisfied by encoding everything blindly (2 red without the fix, and those two stay green). **An invariant about character RANGE has to be tested with a character outside the range that motivated it** |
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
