---
name: add-score-pillar
description: Add or retune a scoring pillar in the Irvine Home Analysis Platform using the config-table pattern. Use when activating a Phase 2 pillar, adding a taxonomy category, or changing weights or severities.
---

# Adding or retuning a scoring pillar

## The invariant

**The LLM assigns categories. Config tables assign numbers.**

If you are about to write `AI_COMPLETE(... 'rate this 1-10' ...)`, stop.
Classify into a closed taxonomy and look the number up. Everything below depends
on that: reproducibility, auditability, and being able to tune without a deploy.

## Retuning an existing pillar

1. `UPDATE` the row in `MART.REF_SCORE_WEIGHTS`, `REF_SCORING_PARAMS`, or
   `REF_PROJECT_TAXONOMY`
2. Run `scripts/verify.sh`
3. `MART.VW_WEIGHT_INTEGRITY` must still show the 90/10 split
4. Golden-address invariants must still hold — especially that pre-CFD villages
   score better on cost than CFD-heavy ones
5. Commit. The diff shows exactly what moved, which is the point.

No SQL logic changes. If you find yourself editing scoring logic to change a
number, the number was in the wrong place.

## Activating a Phase 2 pillar

1. **Data first** — the source must be ingested and staged (`add-data-source`)
2. **Fact view** in `snowflake/30_mart/fct_<pillar>.sql` returning `APN` and a
   `SUBSCORE` in 0..100, plus the counts a narrative needs to explain it
3. **Add a branch** to `PILLAR_SCORES` in `50_scoring/proc_score_parcel.sql` —
   return `NULL` when data is missing so the weight redistributes rather than
   the parcel being penalised for our gap
4. **Evidence** — add a section to `MART.VW_EVIDENCE_BUNDLE`. If it is not in
   the bundle the narrative cannot mention it, by design
5. **Flip** `IS_ACTIVE = TRUE` and rebalance weights so the objective pillars
   still sum to 0.90
6. **Golden addresses** — add an expectation to
   `tests/fixtures/golden_addresses.yaml`

## Adding a taxonomy category

Rising `UNCLASSIFIED` share in `MART.VW_CLASSIFICATION_HEALTH` means the
taxonomy no longer covers what Irvine is building. Add the category rather than
letting projects score neutral.

Insert into `MART.REF_PROJECT_TAXONOMY` with `IMPACT_SIGN`, `SEVERITY`, and a
`RATIONALE` that would satisfy someone disputing the score. Severity anchors:

| Severity | Meaning |
|---|---|
| 1.00 | Changes whether you would live there (asphalt plant, waste facility) |
| 0.80 | Materially degrades or improves daily life for years |
| 0.50 | Noticeable, bounded |
| 0.20 | Background |

The classification SQL reads categories from the table, so it needs no change.

## Things to get right

- **Construction is not uniformly bad.** A new school nearby is major
  construction and good news. Score sign as well as magnitude.
- **Cap positive and negative separately.** Netting them lets three parks cancel
  an asphalt plant.
- **Missing data is not a bad score.** Return `NULL`, redistribute, and say so.
- **Never aggregate cost burden above the parcel.** Mello-Roos differs between
  adjacent phases of one tract.
