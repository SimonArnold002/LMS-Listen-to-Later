# Fleet fold state after LL 0.1.144 — what is actually outstanding

**Status 2026-09-10.** LL 0.1.143 fixed a non-Latin fold defect. The obvious next step looked
like porting it to the other four repos. **That is not the work.** Measured against the shipped
source of each repo, PFR, LBF and DSC were already correct. LL was the outlier, and the fix
brought it UP to the fleet, it did not diverge from it.

**0.1.144 then corrected three defects in that fold release, and TWO of them change what this
doc says.** (a) 0.1.143's new pass ran its two substitutions in the order that does not commute,
so an underscore next to other punctuation produced a doubled separator and `01_-_Intro` keyed
`01   intro`. Fixed in both LL carriers; **the measured table below is unaffected**, because
every row in it is non-Latin or has no underscore, which is exactly why the suite missed it.
(b) **The refold rung now stamps `user_version` 9**, so the stylised-letter fold in item 1 below
would be rung **10**, not 9. That number was already written into this doc and is corrected in
place. The third defect (a migration ordering bug that DELETED non-Latin rows) is LL-internal
and does not touch the fleet. See the 0.1.144 entry in LL's `CLAUDE.md`.

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
   keys. The collision needs an all-symbol name AND a missing recording MBID.

---

## What IS outstanding

### 1. The stylised-letter fold — MATCHER HALF DONE (0.1.145). The KEY half is still open.

**0.1.145 took the fleet block verbatim into `Sources::_punctPass`**, which `_norm` and
`_normStrict` share, so the gate and the ranker fold identically as 0.1.112 requires. P!nk/Pink,
Ke$ha/Kesha and $uicideboy$/Suicideboys now match. Live check: the Bandcamp query text changes
(`&` becomes " and ") and recall is unaffected — the same album returned the same hit count in
both spellings over jsonrpc. Pinned in `t_refold.pl` §3d, anti-tested per rule: the `$`/`@`
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

**BOTH LL normalisers need it, and the key half owes a RUNG.** `P!nk` and `Pink` currently key
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
`_migrateCrossSourceIdentity` — ask the CURRENT fold before deleting — already covers it, and
must not be removed as redundant when this rung lands.

**Also introduced by 0.1.143 and to be settled with the above:** LL's punctuation fallback keeps
the raw marks (`!!!` → `!!!`) where the fleet folds them to letters (`!!!` → `iii`). For the DB
key, keeping the marks is right. For the matcher it is a divergence, and the fleet's rule is the
one to adopt.

### 2. An all-symbol name with no fold mapping still erases — ALL FOUR repos

`†††` (Crosses) normalises to `''` in PFR, LBF and DSC. `!!!` and `+/-` survive only because
their marks have leetspeak mappings. A name of daggers, runes or emoji has none, so it erases
and the strict artist gate then rejects everything, i.e. a miss.

Low severity everywhere. LL 0.1.143 already covers it, via the raw-mark fallback. The fleet fix
is to extend the all-marks fallback to keep the marks when nothing maps.

### 3. The `_punctNorm` escape hatch — CLOSED (0.1.145)

LL rejected any title normalising under two characters, so Sigur Rós's `( )` and a
one-character CJK title could never match from any source. Ported verbatim from the fleet, with
the same MANDATORY artist gate on that path — a match that thin cannot stand on the title alone,
and it is the one place LL is NOT lenient. `_punctNorm` now reports IN SYNC across all five
copies. Pinned in `t_refold.pl` §3e; removing the branch turns 2 red while the 0.1.66 leniency
control stays green. **LL took this FROM the fleet**, the reverse of the usual direction.

---

## Per-repo worksheet

### PFR — ACTIVE
- **Non-Latin: nothing to do.** Verified correct.
- Item 2 only, the `†††` residue in `_norm`'s all-marks fallback. Optional.
- Its `tools/t_matchersync.pl` is the fleet's drift gate. If item 1 lands in LL, extend that
  suite's fixtures rather than writing a new one.
- Any change here needs a cache bump. Nothing is in a UNIQUE column, so no migration.

### LBF — ACTIVE
- **Non-Latin: nothing to do.** Verified correct, cache key included.
- Item 2 only. Optional.
- If `_norm` is ever touched here, bump EVERY cache layer, not just the inner one:
  `lbf:pl:resolved` wraps `lbf:track`. `DB::KEY_VERSIONS` is the one place to edit.

### DSC — ON HOLD
No development until the rest of the fleet's outstanding work is complete. Verified correct for
non-Latin, so nothing is waiting on it. Item 2 applies whenever it resumes.

### Search Hub — ON HOLD
No development. Same standing as DSC. Its `Text.pm` was never checked against items 1 to 3, so
assume nothing about it until work resumes.

---

## For reviewers — the divergence below is DELIBERATE

Between 0.1.143 and the completion of item 1, **LL's `Sources::_norm` is intentionally not in
sync with PFR/LBF/DSC.** It is AHEAD on script preservation and BEHIND on stylised letters.
Two repos are frozen, so the fleet cannot be brought level in one pass.

Do not report as a finding:
- that LL's `_norm` body looks unchanged while its fold moved — the fold is in `_punctPass`,
  which is pinned SEPARATELY in `matcher_sync_check.py` since 0.1.145. Before that the check
  reported LL's `_norm` "variant OK" while the whole pass had changed underneath it
- that LL keeps `†††` where the fleet folds to `''` — LL's all-marks fallback is BETTER here
- that LL's dedupe KEY has no stylised-letter rules while its matcher does. Deliberate: the
  matcher owes nothing, the key owes a rung (see below)
- that `_asciiNorm` still uses `[^a-z0-9]` in any repo
- that DSC or Search Hub were left unchanged
- that LL's pass is TWO substitutions (`_` then `[^\w]`) where the fleet's is one `\p{Alnum}`
  class. That shape is LL-only by construction: `\w` includes the underscore and `\p{Alnum}`
  does not, so only LL has to strip it separately — and it must, because `_` is a LIKE
  metacharacter and two finders build patterns straight out of `_norm` with no ESCAPE. **The
  ORDER is the load-bearing part** and is what 0.1.144 fixed; it is commented at the sub.

All six are recorded decisions. Re-raise only with a real failing case.
