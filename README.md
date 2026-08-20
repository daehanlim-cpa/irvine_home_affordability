# Irvine Home Analysis Platform

Enter an Irvine address. Get a scored, evidence-backed assessment of whether it's a good
long-term home to buy — built on public records, not opinions.

## Why this exists

Irvine is a master-planned city where the things that actually degrade a homeowner's
experience over a decade are all matters of public record:

- A three-year arterial widening approved two blocks away
- An asphalt plant upwind with 800+ AQMD odor complaints against it
- A $4,800/yr Mello-Roos special tax with 26 years left to run, which the listing didn't mention
- A 65 CNEL flight path the seller has no obligation to volunteer

The City, County, and State publish all of it as machine-readable GIS. **No consumer portal
joins any of it to a specific parcel.** That join is the product.

## What makes the score trustworthy

**The LLM assigns categories. Config tables assign numbers.**

Cortex classifies a project into a fixed taxonomy (`ROAD_WIDENING`, `SCHOOL_NEW`,
`HIGH_RISE_RESIDENTIAL`, …). A deterministic lookup maps that category to a signed severity.
All arithmetic is SQL.

The consequence: score the same parcel twice, get the identical number. Every point traces to
a row you can go read yourself. Weights are a table, so tuning the model is an `UPDATE`, not a
deploy. This is what lets a number be defended to someone about to spend $1.6M.

The written narrative is held to the same standard — it sees only an evidence bundle of the
rows that produced the score, must cite record IDs, and its groundedness is scored by
Snowflake AI Observability and threshold-gated in CI.

## Scoring model

| Pillar | Weight |
|---|---|
| Construction & Development Impact | 0.32 |
| Cost Burden (CFD/Mello-Roos, HOA, tax rate area) | 0.20 |
| Environment & Nuisance (CNEL, AQMD, freeway, flood) | 0.16 |
| Schools & Amenities (IUSD vs. TUSD boundary, parks) | 0.12 |
| Safety | 0.06 |
| Neighborhood Context | 0.04 |
| **Objective subtotal** | **0.90** |
| Community Sentiment (trust-weighted blend) | 0.10 |

Sentiment is not one forum — it's a weighted blend across four trust tiers, from Granicus
planning-commission transcripts (residents testifying on the record about the specific project
next to your parcel) down to review-site excerpts. See [`docs/data_sources.md`](docs/data_sources.md).

## Architecture

```
Irvine / OC / State GIS ──┐
Granicus civic minutes  ──┼──► RAW ──► STAGE ──► MART ──► APP ──► Streamlit
Local news RSS          ──┤    (VARIANT) (typed,  (dims,   (leads,
Forums, reviews         ──┘              GEOGRAPHY) facts,   quota,
                                                   config)  entrypoint)
                                              OPS: spend, flags, DMFs, audit
```

Everything runs inside Snowflake. External feeds are pulled by Python stored procedures over
an External Access Integration — no external orchestrator, no separate ETL tier.

## Layout

| Path | Contents |
|---|---|
| `snowflake/00_setup` | Databases, roles, network rules, external access, Cortex probe, governance policies, budgets |
| `snowflake/10_raw` → `80_orch` | RAW tables and ingest procs, staging, marts, Cortex pipelines, scoring, app, ops, tasks |
| `ingest/` | `sources.yaml` registry and per-source adapters |
| `app/` | Streamlit in Snowflake |
| `docs/` | Data sources & compliance, scoring rubric, architecture |
| `tests/` | Golden-address regression fixtures and scoring tests |

## Getting started

```bash
cp .env.example .env          # fill in; .env is gitignored
```

Deploy `snowflake/**/*.sql` in directory-then-filename order — the numbering is the
dependency order, and `05_cortex_probe.sql` needs the database, roles, warehouse, and
integrations that `01`–`04` create.

Once `00_setup/01`–`04` are in place, run **`00_setup/05_cortex_probe.sql`** before building
anything on top of Cortex. It reports which AI functions actually resolve in your region,
whether your edition supports Data Metric Functions, and whether cost telemetry is readable
— none of which is knowable from documentation alone. Any `FAIL` row blocks the verification
gate until resolved.

```bash
scripts/verify.sh             # full pre-push gate (all checks)
scripts/verify.sh --fast      # local checks only: syntax, hooks, secrets, SQL lint.
                              # Skips every Snowflake check — no Cortex spend, but
                              # also no score or groundedness verification.
```

## Cost posture

The public address bar is a button that spends money on LLM inference. Controls are layered:
token-bucket rate limits per source host, a Snowflake Budget on `AI_SERVICES` with automated
action, per-pillar spend attribution via query tags, per-email/IP request quotas, and a
feature-flag kill switch that degrades to templated summaries without a deploy.

The structural control matters more than any monitor: **Cortex runs at ingest, not per
request.** Projects are classified once; village sentiment is cached daily. Per-request work is
a single narrative generation.

## Disclaimers

Not an appraisal, not investment advice, and not a substitute for a title report or
inspection. All figures must be verified with the County before close. Every pillar displays
its data as-of date. See [`docs/compliance.md`](docs/compliance.md).
