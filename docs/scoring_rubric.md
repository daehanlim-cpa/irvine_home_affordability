# Scoring rubric

Published deliberately. A score that cannot be explained is a score that cannot
be trusted, and a buyer who disagrees with a weight should be able to see the
weight.

## The rule everything follows from

**The LLM assigns categories. Config tables assign numbers.**

Cortex classifies a project into a fixed taxonomy. A deterministic lookup maps
that category to a signed severity. All arithmetic is SQL.

Consequences, each of which is a product requirement rather than a nicety:

- Score the same parcel twice, get the identical number.
- Every point traces to a row with a URL a buyer can go and read.
- Tuning the model is an `UPDATE`, not a deploy.
- The whole thing is regression-testable.

## Pillars and weights

| Pillar | Weight | Active | Inputs |
|---|---|---|---|
| Construction & Development | 0.32 | yes | CIP projects, development applications, entitlements |
| Cost Burden | 0.20 | yes | CFD/Mello-Roos, remaining term, HOA, tax rate area |
| Environment & Nuisance | 0.16 | Phase 2 | CNEL contours, AQMD, freeway/toll proximity, flood |
| Schools & Amenities | 0.12 | Phase 2 | IUSD vs. TUSD boundary, parks, trails |
| Safety | 0.06 | Phase 2 | Irvine PD incidents, village-level |
| Neighborhood Context | 0.04 | Phase 2 | Census ACS block-group |
| **Objective subtotal** | **0.90** | | |
| Community Sentiment | 0.10 | yes | Trust-weighted blend, village-level |

Enforced by `MART.VW_WEIGHT_INTEGRITY`: a weight edit that breaks the 90/10
split fails the gate rather than shipping.

## Weight redistribution

Pillars that are inactive, or that returned `INSUFFICIENT_DATA`, are dropped and
the remaining weights renormalise.

A village with no forum chatter does **not** score 0 on sentiment. It scores on
the pillars that have evidence, and the report says which those were. Treating
missing data as a bad result is the easiest way to make a product like this
quietly wrong.

`CONFIDENCE_LEVEL` (`NO_DATA` / `LOW` / `MODERATE` / `FULL_COVERAGE`) travels
with every score so a two-pillar answer is never mistaken for a six-pillar one.

## Construction impact

```
impact = sign × severity × exp(−d/400m) × phase_factor × duration_factor × 40
```

- **sign, severity** — from `REF_PROJECT_TAXONOMY`, keyed on the Cortex category
- **exp(−d/400m)** — exponential decay, clipped at 1600m. Disruption falls off
  sharply; a project two streets away is far less than half the problem of one
  next door
- **phase_factor** — active 1.0, approved 0.8, pending 0.5, complete 0.2
- **duration_factor** — scaled against an 18-month reference, capped at 1.5

Positive and negative aggregates are capped **separately and asymmetrically**:
60 points of possible harm against 25 of possible benefit. Netting them into one
figure would let three new parks cancel an asphalt plant, which is not how anyone
evaluates a home.

Construction is not uniformly bad. A new elementary school 400 feet away is major
construction and it is good news; a three-year arterial widening at the same
distance is not. 15 categories score negative, 8 positive, 3 neutral.

## Cost burden

The differentiator. Mello-Roos varies **parcel by parcel** — adjacent phases of
one tract can differ by thousands a year — so it is never aggregated above the
parcel.

Two components:

- **Annual burden** (up to 55 points deducted) — CFD plus HOA against the
  high-burden threshold
- **Remaining term** (up to 25 points) — because a $4,000/yr tax with 3 years
  left is a $12,000 problem and the same $4,000/yr with 28 years left is a
  $112,000 problem. Presented as an identical monthly figure, those are wildly
  different purchases, and no listing site distinguishes them.

The report also flags where a parcel **contradicts its village's typical
pattern** — no CFD in a village that usually has one, or vice versa. That line is
often the most useful sentence in the whole report.

## Sentiment

Weighted blend across four trust tiers, cached daily per village, never computed
per request. Below three documents the pillar returns `INSUFFICIENT_DATA` and its
weight redistributes.

Documents referencing protected characteristics are excluded from scoring and the
exclusion is recorded.

## Tuning

1. `UPDATE` the weight, severity, or parameter
2. Run `scripts/verify.sh`
3. Golden-address invariants must still hold — in particular, pre-CFD villages
   must still score better on cost than CFD-heavy ones
4. Commit; the diff shows exactly what moved
