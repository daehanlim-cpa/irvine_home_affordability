---
name: add-data-source
description: Onboard a new data source into the Irvine Home Analysis Platform — compliance record, source registry entry, RAW table, STAGE view, freshness check, and schedule. Use when adding any new feed (GIS layer, RSS, forum, API) to ingest/sources.yaml.
---

# Adding a data source

The most-repeated workflow in this project. Follow it in order — step 1 gates
everything else, and `scripts/verify.sh` will fail if it is skipped.

## 1. Compliance first (blocking)

No source ships without this. Record in `docs/data_sources.md`:

- **robots.txt** — fetch it, read it, record the verdict. Not "assume public
  data is fine": the policy is uniform so there is no category of fetch that
  skips the check.
- **Terms of service** — read them. Note anything limiting commercial use.
- **Licence** — public record, API terms, or fair-use excerpt.
- **PII** — what personal data the source carries and how it is dropped.
  Author, speaker, byline, and username are **never** stored.

If the source cannot clear this, add it to the `excluded:` block in
`ingest/sources.yaml` **with a revisit trigger**, and stop. Reasoning that is
not written down gets re-litigated.

## 2. Registry entry

Add to `ingest/sources.yaml`. Required fields (the gate enforces them):
`name`, `kind`, `url`, `rate_limit_rps`, `daily_call_cap`, `compliance`.

Set the rate limit from the source's own `Crawl-delay` if it declares one, and
never above the tier default. These are public agency servers running on public
money.

## 3. RAW table

Add to `snowflake/10_raw/tables_raw.sql`, copying the provenance contract
exactly: `_SOURCE_NAME`, `_SOURCE_URL`, `_INGESTED_AT`, `_PAYLOAD_HASH`,
`_BATCH_ID`, `_PAYLOAD`. Append-only. Never transform here.

## 4. Adapter (non-ArcGIS only)

ArcGIS feature services need no code — `RAW.SP_INGEST_ARCGIS` is generic.

Anything else: subclass `SentimentAdapter` in `ingest/adapters/`. Inherit the
robots gate, rate limiting, and User-Agent rather than reimplementing them —
`scripts/hooks/post_edit.sh` accepts inheritance and rejects a fetcher that has
neither.

Implement `parse()` and `collect()` only.

## 5. STAGE view

Typed, deduped on `_PAYLOAD_HASH`, `GEOGRAPHY` materialised, latest ingest wins
via `QUALIFY ROW_NUMBER()`.

For a sentiment source, add a UNION branch to `stg_sentiment_documents.sql`
rather than a new pipeline.

Use `COALESCE` chains across likely field names on the first pass, then
**collapse them to the real field** once the first ingest reveals it. Leaving
the chains in hides drift.

## 6. Credibility weight (sentiment only)

Add to `MART.REF_SENTIMENT_SOURCES` with `IS_ENABLED = FALSE` and
`COMPLIANCE_STATUS = 'PENDING_ROBOTS_CHECK'`. Enable only after step 1 clears —
`MART.VW_SENTIMENT_COMPLIANCE_GUARD` fails the gate otherwise.

## 7. Schedule

Add a task in `snowflake/80_orch/tasks.sql`, **suspended**. Cadence matches how
fast the source actually changes: parcels monthly, projects weekly, news daily.
Polling a monthly source hourly spends money to learn nothing.

## 8. Verify

```bash
scripts/verify.sh --fast     # registry, lint, hooks, tests
scripts/verify.sh            # full, including Snowflake
```

Then run the ingest once **by hand** and inspect `RAW.INGEST_RUNS` before
resuming the task.
