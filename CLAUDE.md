# CLAUDE.md — Irvine Home Analysis Platform

Buyer enters an Irvine address → gets a scored, evidence-backed assessment of whether it's a
good long-term buy. 90% public government data, 10% community sentiment. Snowflake + Cortex
backend, Streamlit front end.

## The invariant everything follows from

**The LLM assigns categories. Config tables assign numbers.**

Cortex never emits a score, weight, distance, or dollar figure. It classifies into a fixed
taxonomy; a deterministic lookup table maps that category to a signed severity. All
arithmetic is SQL. This is what makes scores reproducible, auditable, and tunable without a
code change — and defensible to someone spending $1.6M.

If you are about to write `AI_COMPLETE(... 'rate this from 1-10' ...)`, stop. Classify into
a taxonomy and look the number up.

## Architecture

`RAW` → `STAGE` → `MART` → `APP`, with `OPS` cross-cutting.

| Layer | Rule |
|---|---|
| `RAW` | Append-only VARIANT. Every row carries `_source_url`, `_ingested_at`, `_payload_hash`. Never transform here. |
| `STAGE` | Typed views, deduped on `_payload_hash`, `GEOGRAPHY` columns. Schema drift breaks *here*, not in ingestion. |
| `MART` | Dims, facts, and `REF_*` config tables. Scoring reads only from here. |
| `APP` | Lead capture, request quota, the `PROC_ANALYZE_ADDRESS` entrypoint. |
| `OPS` | API call log, feature flags, Cortex spend, DMFs, alerts. |

Scoring weights live in `MART.REF_SCORE_WEIGHTS`. Changing a weight is an `UPDATE`, never an
edit to SQL logic. Pillars not yet built sit at weight 0.

## Hard constraints (enforced by hooks in `.claude/settings.json`)

1. Push only to `claude/irvine-home-analysis-platform-9gvily`.
2. No `DROP DATABASE` / `DROP SCHEMA` / `TRUNCATE` outside `*_DEV`.
3. No secrets in the repo — credentials come from Snowflake `SECRET` objects, never literals.
4. `scripts/verify.sh` must be green before commit.
5. Any crawler file must reference `robots` — crawl politeness is enforced, not trusted.

## Non-negotiables that hooks can't check

- **No source ships without a compliance record** in `docs/data_sources.md`: robots.txt
  check, ToS read, license note, revisit trigger if excluded.
- **Never store forum/comment usernames.** Text, URL, timestamp, village tag only.
- **Cortex runs at ingest, not per request.** Classify projects once; cache village sentiment
  daily. Per-request Cortex work is exactly one grounded narrative. A single Cortex query has
  been documented costing $5K — treat the public address bar as a button that spends money.
- **Narrative sees only the evidence bundle.** It must cite record IDs and state nothing
  absent from the bundle. Groundedness is threshold-gated in `verify.sh`.

## Conventions

- SQL: uppercase keywords, snake_case identifiers, one statement per logical unit,
  `CREATE OR REPLACE` for idempotency. Files run in filename order within a directory.
- Every `CREATE` names its schema explicitly. No reliance on session context.
- Python stored procs: `runtime_version = '3.11'`, handler named `main`, external access via
  named integration — never inline URLs.
- New data source → use the `add-data-source` skill. New pillar → `add-score-pillar`.

## Commands

```bash
scripts/verify.sh            # full pre-push gate — must be green to commit
scripts/verify.sh --fast     # local checks only (syntax, hooks, secrets, SQL lint).
                             # Skips all Snowflake checks: no Cortex spend, but
                             # also no score or groundedness verification.
```

Snowflake objects deploy by running `snowflake/**/*.sql` in directory-then-filename order.
No credentials live in this repo; set them in your own environment.

## Review discipline

`/code-review` runs as a **separate invocation with fresh context** before every commit —
reviewing your own work in the same context is proofreading, not review. `/security-review`
additionally before any push touching `APP.LEADS`, secrets, or auth. Findings get fixed or
explicitly waived with a written reason.

## Learnings

Keep this section curated. **Adding an entry means pruning a stale one.** A CLAUDE.md that
sprawls stops being read.

**Guard design** (both learned from guards blocking real work, or failing to block):
- Guards **fail closed**. Unparseable payload or missing `jq` denies. A guard that allows
  what it cannot evaluate is not a guard.
- Guards **analyse the command, not the payload text**. Heredoc bodies and file contents are
  data. Writing a doc that says "git push origin main" is not a push; a fixture naming
  `DROP SCHEMA` is not a drop. Match on execution, not mention — and strip heredocs first.
- A test fixture must not trip the repo's own secret scan. Build sensitive literals by
  concatenation at runtime so the pattern never appears in the file.

**Scoring correctness** (each found by review, each would have shipped silently):
- A pillar with **no rows is not a missing pillar**. Aggregate from `DIM_PARCEL`
  with a LEFT JOIN — a parcel with no nearby projects should score 100 on
  construction, not drop the 0.32 weight as "not assessed".
- **Never `COALESCE` an unpublished figure to zero.** "No Mello-Roos recorded"
  and "the layer published no amount" are different claims, and telling a buyer
  the first when the truth is the second is the worst error this product can make.
- A gate check must **SELECT its assertion**. Pointing one at a file that only
  creates objects passes vacuously — green while asserting nothing.
- Quota limits must **default when the config row is missing**. A NULL limit makes
  the comparison NULL, the branch never fires, and rate limiting silently vanishes.
- PII redaction needs **span-level** decisions, not word-level. Deciding "is this
  a place?" per word let a calendar word excuse a real surname; deciding per span
  keeps "Sand Canyon" and drops "Susan May".

**Snowflake gotchas** (each cost a broken deploy):
- `GRANT OWNERSHIP ON DATABASE` does **not** cascade to schemas. Grant
  `ON ALL SCHEMAS IN DATABASE` too, or the next `GRANT ... ON SCHEMA` fails.
- A tag carries **one masking policy per data type**. Two VARCHAR policies on one tag means
  the second is ignored. Use one policy that branches on `SYSTEM$GET_TAG_ON_CURRENT_COLUMN`.
- Built-in DMFs are **not** in `INFORMATION_SCHEMA.FUNCTIONS`. Probe with
  `SHOW DATA METRIC FUNCTIONS IN SCHEMA SNOWFLAKE.CORE` + `RESULT_SCAN`.
- `SYSTEM$REFERENCE` needs the delegated privilege as its 4th arg (`'APPLYBUDGET'`), or the
  budget silently monitors nothing.
- Database roles do not inherit upward: granting `USAGE_VIEWER` to `IHA_ADMIN` does nothing
  for `IHA_ENGINEER`. Grant to the role that actually runs the query.
- `CORTEX_MODELS_ALLOWLIST` is **deprecated**; govern via `SNOWFLAKE.CORTEX_USER` grants
  plus pinned names in `MART.REF_CORTEX_MODELS`.
- Data Metric Functions need **Enterprise Edition**. `05_cortex_probe.sql` reports it; on
  Standard, freshness falls back to a scheduled task writing to `OPS`.
- Mello-Roos/CFD varies **parcel by parcel**, not by village — adjacent phases of one tract
  differ by thousands/yr. Never aggregate cost burden above the parcel.
- Reddit is excluded on **economics**, not policy: commercial use needs approval (2–4 wks,
  not guaranteed) at ~$12k/mo. Revisit at scale.
- `CORTEX_AI_FUNCTIONS_USAGE_HISTORY` has ~5min latency — cost checks reading it immediately
  after a query see nothing. Poll with backoff.
- `URL`, `USAGE`, `TASK`, `QUERIES`, `CACHE`, `EMAIL`, `PROJECTS`, `TOKEN` are **reserved**
  in the Snowflake dialect. Name columns around them.
