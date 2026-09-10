# Fleet fold state after LL 0.1.143 — what is actually outstanding

**Status 2026-09-10.** LL 0.1.143 fixed a non-Latin fold defect. The obvious next step looked
like porting it to the other four repos. **That is not the work.** Measured against the shipped
source of each repo, PFR, LBF and DSC were already correct. LL was the outlier, and the fix
brought it UP to the fleet, it did not diverge from it.

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

### 1. LL's matcher never received the fleet's stylised-letter fold — LL work, ACTIVE

Pre-existing, not caused by 0.1.143. `Sources::_norm` in LL has no leetspeak table, so:

| input | fleet | LL today |
|---|---|---|
| `P!nk` | `pink` | `p nk` |
| `Ke$ha` | `kesha` | `ke ha` |
| `$uicideboy$` | `suicideboys` | `uicideboy` |
| `Layo & Bushwacka!` | `layo bushwacka` | `layo bushwacka` |

The consequence is the one PFR 0.7.8 already recorded: `_albumMatches`' artist gate rejects
every candidate and the page reads as no match. LL's DB key must NOT adopt this — a key is an
identity and `P!nk` is not `Pink` for dedupe purposes. **Matcher only.**

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

### 3. LL still has no `_punctNorm` escape hatch — LL work

PFR, LBF and DSC all handle a one-character or all-paren title (`( )` by Sigur Rós) through
`_punctNorm` on the raw title, gated on a MANDATORY artist check. LL has none, so `length
$albumNorm < 2` rejects those outright. **LL taking FROM the fleet**, the reverse of the usual
direction.

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
- that LL keeps `!!!` where the fleet folds it to `iii`
- that LL lacks the leetspeak table
- that LL has no `_punctNorm`
- that `_asciiNorm` still uses `[^a-z0-9]` in any repo
- that DSC or Search Hub were left unchanged

All five are recorded decisions. Re-raise only with a real failing case.
