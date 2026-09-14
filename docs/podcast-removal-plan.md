# Podcast support — remove the built-in path, keep streaming episodes

> **STATUS: DONE — shipped on `dev` at 0.1.136 (commit `2d55662`), and every follow-up
> through 0.1.140 is committed and pushed. Nothing here is outstanding.** The two phases this
> plan left open were closed by later builds, not by this one: the carrier and comment sweep in
> 0.1.137–0.1.140, and the cross-source identity rung (schema 7) that the purge rung sits above.
> Phases 1, 3 and 4 were done and green when it was written: 15 suites, 1,300 assertions.
> The suite has grown since (t_podcast_purge 33 → 45), so do not read those counts as current.
>
> **Read this as a RECORD, not a work order.** A review round has already thrown out finished
> work by citing this plan for the state it described mid-build. The banner at the top of
> CLAUDE.md's Review Ledger is the authority on what the removal means today.
> What the build found that this plan did not predict is recorded in
> "Deviations from the plan" at the end.
>
> **PURGE VERIFIED ON REAL DATA (2026-09-05, 0.1.136 installed manually).** Built-in
> Podcasts-app rows removed; Spotify episode, Deezer episode and an ordinary Spotify track
> all survived. That exercises every branch of the purge decision on live rows, including
> the Deezer KEEP rule that deviation 7 below records as having been wrong.

## Context

Podcast support has produced a new defect in almost every release that touched it
(0.1.122 → 0.1.135), including one where the fix for a regression re-opened the same
regression one line above itself. A `/code-review` surfaced two more; investigating those
surfaced five the review had missed.

The question that should have been asked first — *does a podcast episode fit Listen
Later?* — was not asked, and a rebuild was planned instead. Asked properly, the answer
splits:

**The built-in Podcasts-app path does not fit.** Measured against LL's model (save an
album, browse a list of albums, move to Played when most of it is heard, Wish List
alongside):

- Not an album: `kind='track'`, `artist => undef`, show bent into `album_title`. Three of
  five sort modes are wrong — artist-sort files every episode first, year-sort drops them
  in the NULL bucket, album-sort orders them by show.
- The Wish List does not apply at all — `_wishListable` returns 0 for every episode,
  enforced in four places. A third of the plugin's feature surface is switched off.
- It duplicates a record the Podcast plugin already keeps, worse. LL marks played at 90%
  of duration (`Played.pm:40`), or 60s with no duration, and **never reads** the Podcast
  plugin's per-episode resume position — three comments acknowledge it exists, no code
  consults it. Two disagreeing records; LL's is the worse one.
- It has no identity. That is the entire reason `Podcast.pm` is 441 lines. Measured: 351
  of 360 *Tech Won't Save Us* episodes share one image; ~1,120 of *The Daily*'s 2,968.

**Streaming episodes do fit.** `spotify://episode:<id>` and `deezerpodcast://<id>` are
durable identifiers. They are ordinary tracks with a URL, already url-keyed via
`DB::episodeKey`, and need no resolver, feed parser, cache, or budget. Every expensive
thing in this subsystem exists for the other path.

**Decision (Simon, 2026-09-05): remove the built-in path, keep streaming episodes.**

The deciding argument is provability. Removal can be proved *before* committing — run the
suite, assert the branches are gone, test the purge against a real SQLite DB. A rebuild
cannot: it depended on a spike that had not run, an `$ITEMID` that is not sent today
(`$podcastCmd`, `Plugin.pm:890`), and a server API I never confirmed exists.

---

## Proof protocol — nothing enters the repo unproven

This is the part that is different from every previous round, and it is not negotiable:

1. Every change is made first on a **scratch copy** outside the repo.
2. `sh tools/t_all.sh` must be green on the scratch copy (baseline today: 16 suites,
   1,347 assertions).
3. Every removal gets an **anti-test**: put the removed thing back, confirm the assertion
   guarding its absence goes red, and record the count — the house convention already used
   throughout `tools/`.
4. Only then is the change applied to `dev`.

No step is "adjust as we go". If a step cannot be proved on the scratch copy, it stops and
comes back for a decision rather than being worked around.

---

## Manifest — exactly what goes and what stays

Verified against `dev` @ 0.1.135. 130 podcast-conditional references exist across the four
shared modules (Plugin.pm 90, Sources.pm 28, Browse.pm 7, DB.pm 5); roughly 115 belong to
the built-in path.

### Removed

| what | where |
|---|---|
| the whole module | `ListenLater/Podcast.pm` (441 lines) |
| the add path | `_savePodcastEpisode` (`Plugin.pm:2305-2385`) |
| the `kind:podcast` dispatch | `Plugin.pm:3084-3086` |
| the last-resort fallback | `Plugin.pm:3291-3296` |
| the Material command + role | `$podcastCmd` / `$podcastBase` (`Plugin.pm:890`, `908`), `%roleTitle` podcast entry (`~998`) |
| the category pair (writing only — see Risks) | `%fileCats` podcast entries (`Plugin.pm:968-971`) |
| the subscription watcher | `Plugin.pm:378-384` (`setChange` on `plugin.podcast:feeds`) |
| the `podcasts` seed | `_ownedCats` (`Plugin.pm:779`) |
| diagnostics | `_dumpMaterialState` podcast branches (`1556-1558`, `1605-1633`, `1641-1670`) |
| replay capability | `Sources::_hasPodcastHandler` + the `'podcast'` arm of `_serviceCan` (`Sources.pm:1380`) |
| the `podcast` arm | `Sources::isPodcastEpisode` (`Sources.pm:1440-1446`) — source `podcast` no longer exists |
| the guard it existed for | `$isStreamingEpisode`'s `($source ne 'podcast')` clause (`Plugin.pm:2470`) |
| suites | `tools/t_podcast_resolve.pl`, `tools/t_podcast_enc.pl` |

### Kept — streaming episodes, unchanged in behaviour

`Sources::spotifyEpisodeUri`, `stripEpisodeDatePrefix`, `sourceLabel`,
`unsupportedContainer` (still refuses `show:`/`podcast:`/`mix:` containers),
`favurlIsTrack`'s episode arms, `DB::episodeKey` and `_keyForRow`'s `|e:` branch,
`_wishListable` / `_redirectWishList` / `_contextMenuQuery` / `_moveCommand` enforcement,
`Browse::_isPodcast` + glyph + `PLUGIN_LL_TYPE_PODCAST`, `_fillFromPlayingMeta` and its
duration gate.

**F9's invariant must survive the consolidation**: `_canClassifyTrack` is safe only because
no episode source appears in its list, and the 0.1.126 early return that used to divert
episodes was removed in 0.1.127. Carry it forward explicitly and assert it.

---

## Phase 1 — prove the removal on a scratch copy

Apply the manifest, run `t_all.sh`, and resolve every failure. Expect `t_addpath.pl` and
`t_material_actions.pl` to fail where they assert built-in behaviour — those assertions are
removed **with a recorded red count**, not silently deleted.

Add the assertions that guard the absence:

- `assert_answered` over **all five** sites that finish a request — `Plugin.pm:3163`
  (`_addCtxCommand`: no reject, no count) and `_finishAlbumAdd` (`3413`, `3456`, which never
  report a count on either completion path). `_removeCommand`/`_moveCommand` are correct as
  they stand — count is not their contract. **This survives the removal and must be fixed
  here**, since `_addCtxCommand` is shared and is not being deleted.
- a grep-level assertion that `Plugins::ListenLater::Podcast` is referenced nowhere.
- `isPodcastEpisode('podcast', undef)` is now false; `('spotify', 'spotify://episode:x')`
  and the bare `spotify:episode:x` spelling remain true (`t_favurl.pl` already covers the
  spellings).

## Phase 2 — apply to `dev`

Only after Phase 1 is green. Version bump, caches cleared per house rule.

## Phase 3 — purge, with a report

Slot one rung into the existing `_migrate` ladder (`DB.pm:72`) as schema version 6, reusing
the stamp-only-on-success pattern proved at rung 5 (`DB.pm:182-190`). `albums` is a single
table with no foreign keys (`DB.pm:85-96`), so a delete has no cascade surface.

Rows removed:

- `source = 'podcast'` — all of them. This path is gone.
- Streaming episode rows whose key is **not** `|e:`-shaped. `git log -S` dates
  `spotifyEpisodeUri`, `episodeKey` and the `episode` flag to one commit, `49b8902`
  (0.1.126). Before it, Spotify episodes were stored **as ordinary music tracks** —
  `Sources.pm:1436` says so — with a `|t:` key and no `|e:` segment. Those rows are
  mis-keyed and only the URL identifies them, so this step selects `source='spotify'` rows
  in Perl, decodes `ref_json`, and tests `Sources::spotifyEpisodeUri($ref->{url})` rather
  than restating the rule in SQL. Streaming support has never shipped, so the population is
  dev boxes only.

Correctly-keyed streaming episode rows are **kept** — that path is supported.

**The report** is written before the DELETE, and every selected DELETE is committed in one
transaction, so a failed later delete rolls the earlier ones back and the retry reports the
same complete set:
`<cachedir>/listenlater-removed-podcasts.txt`, beside the DB via the same
`preferences('server')->get('cachedir')` that `DB::_path` (`DB.pm:30`) uses. One line per
row: list, show, episode title, play url, date added. Same lines to `log.txt`. No Settings
or browse UI — it is a one-time event and the file answers it.

## Phase 4 — ledger and memory

The ledger will otherwise fight this: a review pass has already thrown out work by citing
it. Add a banner under `## Review Ledger` (`CLAUDE.md:6`) recording that built-in podcast
support was **removed**, not rebuilt, and tag the entries that assume it exists —
`CLAUDE.md:25` (Identity), `:1574` (the 13-site adapter list), `:4349` (`$ITEMID`), `:4357`
(the 0.1.132 audit residue), `DB.pm:659-672`.

Record in §D so they are never re-reported as findings: the warm-sweep thaw is **1.6 ms**
(waste, not a stall), and the resolve walk was synchronous across cached feeds by design.

Write a `project` memory — the ledger only reaches sessions that read `CLAUDE.md`; memory
reaches every new session: *built-in podcast support removed 0.1.136; streaming episodes
kept and url-keyed; old rows purged with a report, not migrated.*

---

## Risks

**The Material category husk — the one real hazard.** `podcasts-album` / `podcasts-track`
were *written* into a shared `actions.json`. Deleting the code that writes them does not
delete what is already on disk; the ledger already documents this failure mode at
`Plugin.pm:677-681`, where 0.1.103 left husks for users with no subscriptions. So the
**clearing** machinery must be kept while the **writing** is removed: `@fileOnlySup`
(`Plugin.pm:648`), the `%ours` entries in `_pruneMaterialActions` (`Plugin.pm:1456-1459`),
and the `_ownedCats` claim must continue to name `podcasts-*` so the prune can remove what
past builds wrote. Removing those alongside the writer would strand an "Add" on every
podcast row with no code behind it. Assert this explicitly — it is the single most likely
way this change bites.

**Order matters**: the purge (Phase 3) must land in the same release as the removal, or a
stored `podcast://` row survives with no `_serviceCan` arm to replay it.

---

## Verification

**Locally**: `sh tools/t_all.sh` green on the scratch copy before `dev` is touched, and
green again after. Each removed assertion's red count recorded in the suite's anti-test
block. Purge tested against the real `File::Temp` SQLite DB `t_addpath.pl` already uses:
seed built-in, mis-keyed streaming, correctly-keyed streaming, album, track and playlist
rows; assert the first two are gone, the last four untouched, the report lists exactly what
was removed, and a failed DELETE leaves `user_version` at 5.

**On the server**, after a manual zip install: confirm the Podcasts app no longer offers
"Add to Listen Later"; confirm no husk remains in `actions.json`; confirm a Spotify episode
and a Deezer episode still add, render as `❝ Podcast · <show> · Spotify`, refuse the Wish
List, and move to Played after playing past the mark; confirm the removal report file
exists and matches what vanished from the list.


---

## Deviations from the plan — what building it actually found

Recorded because the plan is the artefact the next session reads, and three of these were
not predicted by it.

1. **The plan's own risk was the right one, but the test guarding it was vacuous.** With
   nothing writing `podcasts-*` any more, the existing "leaves no husk" assertions passed
   trivially. The test now seeds a populated pair straight into `actions.json` as a
   pre-0.1.136 build left it. Anti-test: 4 red.

2. **A dead Add button, not predicted.** Removing the populated override exposed the
   generic `online-*` pair on Podcasts-app rows — it stored nothing, but rendered. Closed
   by making `podcasts-*` an EMPTY suppressor via `@KNOWN_RADIO_CMDS`, the same rule
   already applied to unsupported radio commands. Proven at **all three tiers** (0/1 write
   the file, 2 registers; `_writeMaterialActions` returns early at tier 2, so the first
   version of this test proved nothing about 6.4.8+). Anti-test: 6 red, two per tier.

3. **A real bug introduced by the purge rung, caught by `t_refold.pl`.** `_migrate` reads
   `user_version` once at entry, so rung 6 stamped 6 even when rung 5 had deliberately
   withheld its stamp to retry — carrying the schema past a migration that never ran. Rung
   6 now re-reads the live version and waits. Anti-test: 2 red.

4. **My own purge test was vacuous too**, in the same shape as (1): it called
   `_purgeRemovedPodcasts` directly and set the version itself, so the stamping rule was
   never under test and breaking it measured 0 red. It now drives `_migrate`.

5. **Predicted anti-test counts were wrong.** Written as 2/1/1; measured 4/4/2/2. The house
   rule is measured, not asserted — the header now carries the measured values.

7. **The purge had the Deezer rule WRONG, and the test agreed with it.** The implementation
   deleted every `deezerpodcast` row unconditionally, contradicting this plan's own
   "correctly-keyed streaming episode rows are kept" — Deezer is a supported streaming path.
   The suite asserted `'the Deezer episode is gone'`, because code and test were written from
   the same wrong assumption; no anti-test could catch it, since both sides agreed. Found only
   when Simon asked which example rows to add. Corrected to key on the `|e:` tail: correctly
   keyed Spotify AND Deezer episodes survive, mis-keyed pre-0.1.126 rows go. Anti-test: 3 red.
   **This is the strongest argument in this document for verifying against real data rather
   than a green suite.**

8. **A retry could erase part of the recovery report.** Deletes were individually committed:
   if episode A was removed and episode B failed, schema version 5 correctly caused a retry,
   but that retry truncated the report and rewrote it from only B — losing the only record of
   A. The purge is now one transaction and fails closed if it cannot begin one. The regression
   injects failure on the second DELETE, proves both rows remain, then proves the successful
   retry still reports both.

6. **Integration surface was far smaller than the branch count implied.** 130
   podcast-conditional references across four modules, but only **5** cross-module calls
   into `Podcast.pm`. Most of the 130 serve the streaming path or shared predicates that stay.

## Outstanding

Nothing functional. Verified end to end on the server, 2026-09-05, 0.1.136 installed
manually: the purge removed the built-in rows and kept both streaming episode sources, and
a Podcasts-app row now renders **no Add at all** — the suppression confirmed visually, which
is the half no test can prove (the suite verifies what is written and registered, not what
Material draws).
- `repo.xml` sha and the zip are not rebuilt; per ledger §A that is the normal state on `dev`.
- Nothing is committed.
