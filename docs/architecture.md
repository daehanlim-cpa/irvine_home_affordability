# Architecture

## Shape

```
Irvine ArcGIS ──┐
OC / State GIS ─┤
Granicus       ─┼──► RAW ──► STAGE ──► MART ──► APP ──► Streamlit
News RSS       ─┤   VARIANT   typed    dims,    leads,
Forums         ─┘  append-    dedup,   facts,   quota,
                    only    GEOGRAPHY  config   entrypoint

                   OPS: call log, feature flags, spend, audit, retention
```

Everything runs inside Snowflake. External feeds are pulled by Python stored
procedures over an External Access Integration — no external orchestrator, no
separate ETL tier, no second system to secure.

## Layers

| Layer | Rule | Why |
|---|---|---|
| `RAW` | Append-only VARIANT. Provenance on every row. Never transformed. | ArcGIS schemas change without notice. Upstream drift then breaks a STAGE view — visible and fixable — rather than silently corrupting history or losing data we cannot re-fetch. Everything is replayable. |
| `STAGE` | Typed views, deduped on payload hash, `GEOGRAPHY` materialised | The blast radius for schema drift. |
| `MART` | Dims, facts, `REF_*` config. Scoring reads only from here. | Config tables are where all tuning lives. |
| `APP` | Lead capture, quota, the single entrypoint | One procedure so controls cannot be called out of order or skipped. |
| `OPS` | Call log, flags, spend, audit, retention | Load-bearing, not telemetry: the daily cap is enforced by counting rows in `API_CALL_LOG`, and the kill switch is a row in `FEATURE_FLAGS`. |

## Request path

`APP.SP_ANALYZE_ADDRESS` in fixed order:

1. **Funnel switch** — `ACCEPT_NEW_LEADS`
2. **Quota** — per email and per IP, checked *before* any spend
3. **Resolve** — address points are the geocoder; exact → fuzzy (street only,
   house number always exact) → village fallback, labelled
4. **Capture lead** — with consent timestamp
5. **Score** — deterministic SQL, no LLM
6. **Narrate** — the only per-request Cortex call, cached on evidence hash

## Two warehouses

`IHA_WH_XS` (app) and `IHA_WH_INGEST` (batch), separated so a backfill never
queues behind a user request, and so per-pillar cost attribution stays legible.

## Cost model

The public address bar is a button that spends money on LLM inference. A single
Cortex query has been documented costing $5K.

**Structural controls** (worth more than any monitor):
- Projects classified **once at ingest**, cached on text hash. A parcel with 40
  nearby projects costs zero Cortex calls to score.
- Village sentiment cached **daily**. A user request reads a row.
- Narratives cached on **evidence hash**. Unchanged evidence reuses the text.

Per-request Cortex work is therefore one narrative generation, ~2–4k tokens.

**Enforcement layers**, in ascending order of usefulness:
1. Resource monitors — warehouse credits only; cannot see Cortex
2. Budget on AI services — sees serverless spend, notifies
3. **Alert → kill switch** — flips `LIVE_NARRATIVE` to FALSE within ten minutes,
   degrading to templated summaries with no deploy. This is the layer that
   actually saves money, because it acts without anyone being awake.

Plus ingest-side token buckets, per-source daily caps, and a circuit breaker.

## Determinism

No Cortex call appears anywhere in `50_scoring/`. The LLM contributes exactly one
thing to a score: the `CATEGORY_CODE` that selects a severity row, produced at
temperature 0 against a closed list.

`SP_TEST_REPRODUCIBILITY` scores each golden parcel twice and asserts the
composites are identical.

## Grounding

Three overlapping controls, because a fabricated number in a document advising a
$1.6M purchase is the worst failure this system can have:

1. The narrative sees **only** `MART.VW_EVIDENCE_BUNDLE` and must cite record IDs
2. A numeric backstop asserts every number in the prose appears in the bundle
3. AI Observability scores groundedness; below 0.90 the gate fails

## Deployment order

`snowflake/**/*.sql` in directory-then-filename order. The numbering is the
dependency order.

`00_setup/05_cortex_probe.sql` runs first among things that matter — it reports
what Cortex, geospatial, DMF, and cost telemetry actually resolve in the account
before anything depends on them.

All tasks are created **suspended**. Scheduling ingestion before a manual run has
been inspected is how a rate-limit breach or a runaway bill happens while nobody
is watching.

## Where this goes next

**Phase 2** — remaining objective sources and sentiment tiers, turned on by
`UPDATE` to `REF_SCORE_WEIGHTS`. The scorer does not change.

**Phase 3** — Next.js on the Snowflake SQL API, SEO village pages, transactional
email, score history so a re-run shows what changed.
