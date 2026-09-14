# Fleet fold rollout — CLOSED. A record, not a work order.

> **STATUS: CLOSED 2026-09-10. Nothing in this document is outstanding in any repo.**
> Items 1 and 3 shipped in LL 0.1.145. Item 1's key half was DECLINED, and item 2 — the last
> fleet-wide item, the `†††` residue — had its `_norm` port DECLINED unbuilt: the matcher port
> that motivated this whole document is no longer needed, because LL came into line and the
> other repos were never out of it. **LBF separately BUILT the track-path half of item 2**, in
> single-copy subs that carry no fleet obligation; see item 2, which now holds two verdicts. **Do not open work from this file.** It is kept for the
> measurements, the two retracted claims, and the reviewer list at the end, all of which stay
> live. Each repo's own ledger carries the closure under §A.

## How it stood while it was open

**Status 2026-09-10.** LL 0.1.143 fixed a non-Latin fold defect. The obvious next step looked
like porting it to the other four repos. **That is not the work.** Measured against the shipped
source of each repo, PFR, LBF and DSC were already correct. LL was the outlier, and the fix
brought it UP to the fleet, it did not diverge from it.

**0.1.145 then closed items 1 and 3 below**, taking the fleet's stylised-letter block and the
`_punctNorm` short-title hatch into LL's matcher. Item 1's KEY half was DECLINED in the same pass,
so the only fold work still open fleet-wide is item 2. The `†††` residue.

**0.1.144 then corrected four defects in that fold release, and THREE of them change what this
doc says.** (a) 0.1.143's new pass ran its two substitutions in the order that does not commute,
so an underscore next to other punctuation produced a doubled separator and `01_-_Intro` keyed
`01   intro`. Fixed in both LL carriers; **the measured table below is unaffected**, because
every row in it is non-Latin or has no underscore, which is exactly why the suite missed it.
(b) **The refold rung now stamps `user_version` 9**, so the next stored-key change to land, whatever
it turns out to be, is rung **10**. This doc used to attach that number to the stylised-letter fold
in item 1; 0.1.145 declined that rung, so **10 is simply the next free rung and is not spoken for**.
Check the ladder in `DB::_migrate` before quoting a number — the last draft of this line was stale
within a day. **The one defect that does NOT change this doc** is the migration ordering bug that
DELETED non-Latin rows: LL-internal, and the fleet ladder is untouched by it. See the 0.1.144 entry in LL's `CLAUDE.md`.

**(c) A FOLD CHANGE IS AN ENCODING CHANGE, and that belongs in this doc rather than LL's.** The
last of the four was not in the fold at all: LL's Bandcamp search query is built from `_norm`, and
until 0.1.143 that pass returned ASCII by construction, so the branch was deliberately
exempt from the fleet's characters/octets split. 0.1.143 ended the exemption by teaching the fold
to keep every script — without touching, or even looking at, the code downstream of it. **The
general form is the part to carry forward: the moment a normaliser starts preserving codepoints
it used to erase, every consumer of its output inherits a character string it has never seen, and
the fold's own tests cannot see any of them.** Items 1 and 2 below are both changes of exactly
that kind.

MEASURED on the live server 2026-09-10, same query in both spellings through Bandcamp's own
search, because the failure mode is worse than the "silently returns nothing" this doc's
predecessors assumed:

| query | as CHARACTERS | as OCTETS |
|---|---|---|
| `kristin hersh sugar on blackstone` | 4 hits | 4 hits, identical |
| `sigur rós von` | `Unknown error: 400 Bad Request` | 7 hits |
| `Кино группа крови` | **request dies**, `Wide character in subroutine entry at Slim/Utils/DbCache.pm line 157`, then `Bad dispatch!` | 18 hits, exact album found |

Bandcamp caches its search on the query string, and `DbCache->set` dies on a wide character. The
die lands inside an async coderef under `Slim::Plugin::OPMLBased`, so **the caller's callback
never runs and the caller logs nothing** — it presents as a hang, not an error. **Do not repeat
the claim in Search Hub's `Adapters.pm` header that a `query_enc` mistake "does not error, it
silently returns nothing"** — that holds for Qobuz, Tidal and Deezer, not for Bandcamp.

This doc records what was verified, what is genuinely left, and what a review must not flag.

---

## What was measured, not assumed

All three repos' `_norm` was extracted from the shipped source with the same `grab` technique
`PFR/tools/t_matchersync.pl` uses, and run directly:

| input | PFR | LBF | DSC | LL (before 0.1.143) | LL (after) |
|---|---|---|---|---|---|
| 米津玄師 | `米津玄師` | `米津玄師` | `米津玄師` | `''` | `米津玄師` |
| 아이유 | `아이유` | `아이유` | `아이유` | `''` | `아이유` |
| Кино | `кино` | `кино` | `кино` | `''` | `кино` |
| Sigur Rós | `sigur ros` | `sigur ros` | `sigur ros` | `sigur ros` | `sigur ros` |
| `!!!` | `iii` | `iii` | `iii` | `''` | `!!!` |
| `+/-` | `and` | `and` | `and` | `''` | `+/-` |
| `†††` | `''` | `''` | `''` | `''` | `†††` |

Two different CJK artists correctly fail to match in PFR, LBF and DSC.

**The `[^a-z0-9]` pass I first found in those three repos is inside `_asciiNorm`**, a
deliberately ASCII-only helper. Their real `_norm` uses `\p{Alnum}` on a DECODED string, which
matches every script. LBF's own comment records the decode being added for exactly this reason.
Do not "fix" `_asciiNorm` — being ASCII is its job.

### Two claims from the 2026-09-10 session that were WRONG and are retracted here

1. **"The same `[^a-z0-9]` fold sits in five repos as the shared matcher."** No. Only LL had it
   in the live normaliser. The grep that produced this hit `_asciiNorm` in the other repos.
2. **"LBF's track cache key collides for non-Latin tracks."** No. `Browse.pm:8306` keys on
   `($recMbid || _norm($query))`, and since LBF's `_norm` preserves the script, the query is
   non-empty. Verified: 米津玄師/Lemon, 中島みゆき/歌姫 and Кино/Группа крови all produce distinct
   keys. The collision needs an all-symbol name AND a missing recording MBID. **Re-checked at the
CONSUMING end 2026-09-10, which the original retraction did not do:** distinct keys are only half
the question, because a key holding a wide character also has to survive `DbCache->set`. It does —
`Browse.pm` runs `utf8::encode($key) if utf8::is_utf8($key)` on the line after it builds it, and
DSC's `_artImgKey` does the same for `dsc:svcartimg:`. Those are the fleet's only two cache keys
built out of `_norm`.

---

## The three items, and how each one ended

### 1. The stylised-letter fold — MATCHER HALF DONE (0.1.145), KEY half DECLINED. Nothing open.

**0.1.145 took the fleet block verbatim into `Sources::_punctPass`**, which `_norm` and
`_normStrict` share, so the gate and the ranker fold identically as 0.1.112 requires. P!nk/Pink,
Ke$ha/Kesha and $uicideboy$/Suicideboys now match. Live check: the Bandcamp query text changes
(`&` becomes " and ") and recall is unaffected — the same album returned the same hit count in
both spellings over jsonrpc. **That result is ASCII-only and says nothing about which spelling to
send** — the two spellings of an ASCII query are the same bytes. For non-ASCII they are emphatically
not the same, and one of them kills the request: see (c) in the status block. Pinned in `t_refold.pl` §3d, anti-tested per rule: the `$`/`@`
lines 5 red, the `!` branch 3, the `&`/`+` line 2, and no cross-coverage between them.

**THE KEY HALF IS DECLINED — Simon, 2026-09-10. This is a scope decision, not a cost one.**

> "if any service has one variant over another we should not try to merge them they should be
> two entries. No user will add same album from different service its just not going to happen
> in real usage. We add what the service gives us."

So `P!nk` and `Pink` add twice, and that is CORRECT for this plugin. LL stores what a service
handed it; a spelling variant is that service's rendering of the release, not a duplicate to be
reconciled. The cross-service re-add that folding would fix is not a real usage pattern.

**Already the behaviour — nothing to build.** Verified against 0.1.145: `p nk|funhouse|2008`
against `pink|funhouse|2008`, two rows. The measured case that prompted this is
`-ii- – Ars Erotica`, where Bandcamp renders it `Ars Erotica : Volume I` and Deezer renders it
`Ars Erotica, Vol. I` — keys `ii|ars erotica volume i|` and `ii|ars erotica vol i|2026`. Two
entries, which is the wanted outcome.

**The matcher not linking those two is ALSO accepted**, and for the same reason: LBF carries one
streaming match plus a separate Bandcamp link, and those were never expected to agree. Do not
"fix" `volume` against `vol` on the strength of this pair.

**DO NOT GENERALISE THIS TO THE FLEET. Discography is the opposite case** — it folds variants
precisely so one artist's albums line up across sources, which is its whole job. The decline is
LL-only and follows from LL storing what it was given rather than reconciling a catalogue.

Original diagnosis kept, because the MATCHER half of it was real and shipped:

| input | fleet | LL today |
|---|---|---|
| `P!nk` | `pink` | `p nk` |
| `Ke$ha` | `kesha` | `ke ha` |
| `$uicideboy$` | `suicideboys` | `uicideboy` |
| `Layo & Bushwacka!` | `layo bushwacka` | `layo bushwacka` |

The consequence is the one PFR 0.7.8 already recorded: `_albumMatches`' artist gate rejects
every candidate and the page reads as no match. Measured in LL 2026-09-10: `P!nk` vs `Pink`,
`Ke$ha` vs `Kesha` and `$uicideboy$` vs `Suicideboys` ALL fail to match. `Wham!` and `Panic!`
already work, because LL strips a decorative `!` as punctuation and the fleet's word-boundary
rule agrees there — **the divergence is only for a mark standing in for a LETTER.**

**IT WAS MISSED, NOT DECIDED.** An earlier draft of this doc said the DB key must not adopt it
because "`P!nk` is not `Pink` for dedupe purposes". **That is wrong and is withdrawn** — it is
the same class as `Jane's Addiction` / `Janes Addiction`, which 0.1.112 DID fold into one key,
with a migration. The rule landed 2026-07-21 as PFR 0.7.8 across the four full matcher copies
(LBF, PFR, DSC, SH); LL was not in the matcher sync until 0.1.112 on 2026-09-02, and that port
was scoped to the THREE Discography-origin rules — it took two and skipped the compound-word
collapse with a stated reason. The stylised fold is a fourth rule of different origin and date
and appears in the 0.1.112 entry neither as taken nor as skipped. Nothing ever weighed it for LL.

**SUPERSEDED BY THE DECLINE ABOVE — kept because the reasoning is still correct, only the
conclusion changed.** What follows is the case for folding the KEY, written before Simon ruled on
it. It is accurate about the cost; it is simply no longer work. Do not act on it, and do not
re-derive it as a new finding: two rows for two spellings is now the specified behaviour.

**BOTH LL normalisers would need it, and the key half would owe a RUNG.** `P!nk` and `Pink` key
`p nk` and `pink`, so the same album from two services is TWO ROWS. Folding them is a stored-key
change, i.e. **rung 10** (rung 9 is the refold, since 0.1.144 — an earlier draft of this line
said 9 and was stale within a day, so check the ladder in `DB::_migrate` before quoting a
number), exactly as the apostrophe rule was rung 5. Unlike 0.1.143's fold this is NOT a pure
split — it MERGES keys — so `_migrateRefold`'s collision path is live and its mixed-status
policy applies. That is the real cost, and the reason to plan it rather than drop it in.

**AND IT INHERITS 0.1.144's LADDER LESSON, which is the cheaper half to get right.** Rung 7
deletes rows that share a STORED key, and 0.1.143 ran it BEFORE its own refold — so on a
database still holding old-fold keys it merged unrelated albums away before the refold could
split them. A merging fold makes the mirror mistake reachable: rows this rule brings TOGETHER
must not be settled by a pass that ran against the older spelling. The guard now in
`_migrateCrossSourceIdentity` — ask the CURRENT fold before deleting — already covers it.
**This half OUTLIVES the decline and is the reason to keep reading the paragraph above.** It is a
precondition on ANY future merging fold in this repo, not on the cancelled rung, so the guard must
not be removed as redundant just because nothing is queued behind it today.

**The `!!!` divergence this doc used to list here is CLOSED (0.1.145).** LL's matcher now folds
`!!!` → `iii` like the fleet, because the rule arrived with the rest of the stylised-letter block.
The all-marks fallback survives underneath it and now fires only for a name with NO mapping at all
(`†††`), which is item 2 and is a variant BETTER than the fleet's, not drift. The DB key keeps the
raw marks, which was right then and is right now.

### 2. An all-symbol name with no fold mapping still erases — `_norm` DECLINED; LBF's TRACK path BUILT (2026-09-10)

**The `_norm` port is closed without being built** (Simon). The analysis below stands and the
decision on top of it is that the port is not needed. **But "it is a MISS, not a wrong answer"
is true of the ALBUM path only, and the same session measured that it is FALSE on LBF's TRACK
path** — so this item ended as two verdicts, not one. Keep them apart.

**DECLINED, fleet-wide: extending the all-marks fallback into `_norm`.** Prototyped and measured
against LBF's shipped code. On the normaliser it is a clean split — 67 names byte-identical, 10
rescued from empty, 0 moved, all 32 suites still green. Run through `_albumMatches` it flips four
cases and only one flip is wanted, because it moves an all-marks artist OUT of the lenient
empty-artist branch and INTO the strict artist gate: a release MusicBrainz credits to `†††` that
Qobuz spells "Crosses" goes MATCH → **reject**.

**AND THAT IS WHY LL HAVING THE FALLBACK IS NOT EVIDENCE THE FLEET SHOULD — the gates run
opposite ways.** LL's `_artistMatch` returns 1 when either side is empty and its `_albumMatches`
returns 1 outright on an empty artist, so an erased name there is a TOTAL free pass and the
fallback can only tighten it. The fleet's `_artistMatch` returns 0 on an empty side and its
empty-artist branch already demands an exact title, so the free pass is narrow and the fallback
converts working matches into rejections. LL also replays a SAVED item back to the same source,
so both spellings agree by construction, where PFR and LBF exist to match a MusicBrainz or
Pitchfork credit against a differently-spelled service catalogue. **Same code, opposite effect.**

**BUILT, and LBF-local: the TRACK path.** `_trackMatches` never received the item-3 hatch —
it is single-copy LBF, so no fleet sync could drag it along and PFR's copy of `t_matchersync.pl`
never exercised it. There the erasure was NOT merely a miss: `_findPlayableTrack` refused to
search at all and answered `undef`, which LBF reads as INCONCLUSIVE, so the track burned all
three rungs of `MISS_RETRY_SCHEDULE` **without one request ever being made** and then settled as
a durable no-match — reaching the Created-for-You playlists, the follow feed, Trending Tracks and
both DSTM mixers. The per-track cache key and `_relKey` also collapsed every such name onto one
shared string. Fixed with `_punctNorm`, no `_norm` edit, **no fleet obligation and no cache
bump**. Pinned in LBF `t_matchersync.pl` §4b/§4c, anti-tested five ways (3/2/1/1/1 red).

Re-raise the `_norm` half ONLY by naming a real artist that actually failed.

`†††` (Crosses) normalises to `''` in PFR, LBF and DSC. `!!!` and `+/-` survive only because
their marks have leetspeak mappings. A name of daggers, runes or emoji has none, so it erases
and the strict artist gate then rejects everything, i.e. a miss.

Low severity everywhere. LL 0.1.143 already covers it, via the raw-mark fallback. The fleet fix
is to extend the all-marks fallback to keep the marks when nothing maps.

**It carries (c)'s precondition, and "low severity, optional" is exactly why someone will land it
without looking.** Today `_norm('†††')` is `''` in PFR, LBF and DSC. After the fix it is `†††` —
three codepoints above 255, in a value that currently cannot contain one. That is the same step
0.1.143 took, so the question to answer before landing it is (c)'s: what consumes this output.
**Answered 2026-09-10 for all four repos, and nothing is blocking.** The two cache keys built from
`_norm` both encode already (see retraction 2). Every outbound search picks its spelling per
adapter from the `query_enc` table — DSC `Sources.pm` 897/1029/1252, LBF `Browse.pm` 7264/8455,
PFR `Browse.pm` 3470, SH `Search.pm` 144 — so a newly wide `_norm` result is converted at the call
site whichever camp the service is in. Re-run that check rather than trusting this paragraph if
any of those sites has moved; it is four greps and it is the difference between an empty result
and a request that never comes back.

### 3. The `_punctNorm` escape hatch — CLOSED (0.1.145)

LL rejected any title normalising under two characters, so Sigur Rós's `( )` and a
one-character CJK title could never match from any source. Ported verbatim from the fleet, with
the same MANDATORY artist gate on that path — a match that thin cannot stand on the title alone,
and it is the one place LL is NOT lenient. `_punctNorm` now reports IN SYNC across all five
copies. Pinned in `t_refold.pl` §3e; removing the branch turns 2 red while the 0.1.66 leniency
control stays green. **LL took this FROM the fleet**, the reverse of the usual direction.

---

## Per-repo worksheet

### PFR — NOTHING OUTSTANDING
- **Non-Latin: nothing to do.** Verified correct.
- Item 2 was its only entry and is DECLINED unbuilt. Nothing is waiting on this repo.
- **Correcting this line, which sent the 0.1.145 port to the wrong place:** `tools/t_matchersync.pl`
  is PFR's OWN suite and reads only PFR's `Browse.pm`. The CROSS-REPO drift gate is
  `matcher_sync_check.py`, which lives in the LBF repo and hashes each sub in every copy.
- Item 1's matcher half landed in LL at 0.1.145 and was pinned there — LL's `t_refold.pl` §3d for
  the behaviour, `matcher_sync_check.py` for the drift. **That check had a hole worth knowing
  about, and it had TWO halves — the 0.1.145 pass closed only one:** LL's `_norm` delegates its
  punctuation pass to `_punctPass`, which was never hashed, so the whole pass changed underneath a
  check still reporting `_norm` "variant OK". `_punctPass` was pinned then. **`foldLatin` was not,
  and that is where LL keeps the diacritic strip, the `%FOLD` application loop and BOTH apostrophe
  rules — fleet rule 1.** Measured 2026-09-10: deleting the apostrophe elision from `foldLatin`
  moved none of `LLDB::_norm`, `%FOLD`, `LL::_norm` or `LL::_punctPass`, and the check **exited
  0**. `foldLatin` and `Sources::_fold` are pinned now, anti-tested one red each.
  **When a sub delegates, pin the delegate — and check whether it delegates more than once.**
- Any change here needs a cache bump. Nothing is in a UNIQUE column, so no migration.

### LBF — NOTHING OUTSTANDING
- **Non-Latin: nothing to do.** Verified correct, cache key included.
- Item 2's `_norm` half is DECLINED unbuilt. **Its TRACK half was BUILT** (`_trackMatches` +
  `_findPlayableTrack` + `_findLocalTrack` + two identity keys) — LBF-local subs, so this
  created no obligation for PFR or DSC and triggered no sync. Nothing is waiting on this repo.
- If `_norm` is ever touched here, bump EVERY cache layer, not just the inner one:
  `lbf:pl:resolved` wraps `lbf:track`. `DB::KEY_VERSIONS` is the one place to edit.

### DSC — ON HOLD
No development. Verified correct for non-Latin, so nothing is waiting on it. Item 2 would have
been its only entry and is DECLINED unbuilt, so **there is nothing here to pick up when it
resumes** — the hold is not deferring fold work, because none is left.

### Search Hub — ON HOLD
No development. Same standing as DSC. Its `Text.pm` was never checked against items 1 to 3 and now
never needs to be, since all three are closed. If work ever resumes here, check it against the
SHIPPED fold in PFR or LBF rather than against this document.

---

## For reviewers — the divergence below is DELIBERATE

**LL's `Sources::_norm` is intentionally not in sync with PFR/LBF/DSC**, and since 0.1.145 the
reason has changed: it is no longer BEHIND on anything. It took the stylised letters and
`_punctNorm` verbatim. What remains is that LL strips bracketed qualifiers for its fuzzy gate,
that its gates are LENIENT where the fleet's are strict, and that it keeps an all-marks fallback
the fleet deliberately does not have. Two repos are also frozen, so the fleet could not have been
brought level in one pass regardless.

Do not report as a finding:
- that LL's `_norm` body looks unchanged while its fold moved — the fold is in `_punctPass`,
  which is pinned SEPARATELY in `matcher_sync_check.py` since 0.1.145. Before that the check
  reported LL's `_norm` "variant OK" while the whole pass had changed underneath it
- that LL keeps `†††` where the fleet folds to `''`. **LL's all-marks fallback is better FOR LL
  and measured as a NET LOSS for the fleet — do not read this line as a port waiting to happen,
  which is how it read before 2026-09-10.** LL's gates treat an empty name as ABSENT and wave it
  through, so the fallback can only tighten them; the fleet's strict artist gate turns the same
  fallback into rejections of releases whose service spelling differs from the MusicBrainz credit
  (`†††` vs "Crosses"). Measured through `_albumMatches`: four flips, one of them wanted. See
  item 2
- that LL's dedupe KEY has no stylised-letter rules while its matcher does. Deliberate, and
  DECLINED rather than pending: LL stores what a service handed it, so two spellings are two
  entries by design. See item 1
- that `_asciiNorm` still uses `[^a-z0-9]` in any repo
- that DSC or Search Hub were left unchanged
- that LL encodes the Bandcamp query inline in `_searchService` while LBF pins the same function
  through a `query_enc => 'bytes'` table entry. Both send octets, which is the part that matters;
  LL has one Bandcamp call site and no adapter table to hang it on
- that LL's pass is TWO substitutions (`_` then `[^\w]`) where the fleet's is one `\p{Alnum}`
  class. That shape is LL-only by construction: `\w` includes the underscore and `\p{Alnum}`
  does not, so only LL has to strip it separately — and it must, because `_` is a LIKE
  metacharacter and two finders build patterns straight out of `_norm` with no ESCAPE. **The
  ORDER is the load-bearing part** and is what 0.1.144 fixed; it is commented at the sub.

All six are recorded decisions. Re-raise only with a real failing case.
