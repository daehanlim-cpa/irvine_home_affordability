# Compliance, disclaimers, and legal posture

## What this product is, and is not

It summarises public records for a specific parcel and presents them with a
score. It is **not** an appraisal, **not** investment advice, **not** a
substitute for a title report, inspection, or the seller's disclosure package,
and **not** a prediction of price.

Every report carries that language, attached to the report itself rather than a
footer nobody reads (`APP.SP_ANALYZE_ADDRESS` returns it as a field, and the
Streamlit app renders it).

Every pillar displays its data as-of date, and any pillar that was not assessed
is named explicitly. Implying that an unassessed factor was checked and found
fine is treated as a worse failure than omitting it — `COVERAGE_HONESTY` is the
strictest of the three evaluation thresholds at 0.95.

## Fair Housing — the open item

Crime and demographic data are included in this build at the client's explicit
direction, over a recommendation to exclude them.

The recommendation was made because a "neighbourhood quality" score that
incorporates demographics or crime can function as a proxy for steering under
the Fair Housing Act — the exposure sits on the **output**, not the inputs.
Redfin withdrew its crime layer for related reasons.

The client considered that and decided to include both. Three things limit the
exposure in the implementation:

1. **Official sources only.** Irvine PD's own ArcGIS Hub and US Census ACS —
   consistent with the "trusted government data" premise, not third-party
   aggregators.
2. **Config-gated.** Both sit in `MART.REF_SCORE_WEIGHTS` at `IS_ACTIVE = FALSE`
   with weights of 0.06 and 0.04. They can be zeroed or disabled by `UPDATE`,
   with no code change and no redeploy.
3. **Village-level only.** Crime is aggregated to village and never joined to a
   specific parcel.

Separately, and regardless of that decision, the sentiment pipeline screens
documents referencing protected characteristics out of scoring
(`MART.SP_REFRESH_SENTIMENT`), recording the exclusion rather than deleting it.
Neighbourhood forums carry prejudiced content, and a score that laundered it
into a number would be indefensible independent of any statute.

**Open action: have a real estate attorney review the public-facing report
before launch.** That review is inexpensive relative to the risk, and it is the
one item on this page that code cannot close.

## Privacy — CCPA/CPRA

Leads are California consumer data.

| Control | Where |
|---|---|
| Email masked for all roles except ADMIN/ENGINEER — including `IHA_APP`, the role the public site runs as | `MART.MASK_PII_VARCHAR` via the `PII_CATEGORY` tag |
| IP truncated to /24 for non-privileged roles | same policy, branching on tag value |
| Queried address coarsened to street for non-privileged roles | same policy |
| Consent text and timestamp recorded at capture | `APP.LEADS.CONSENT_AT`, `CONSENT_TEXT` |
| 24-month retention, enforced on a schedule | `OPS.T_ENFORCE_RETENTION` |
| Deletion requests honoured | `APP.LEADS.DELETED_AT`, purged by the same task |

Masking attaches to the **tag**, not the column, so a column tagged later is
protected without anyone remembering to apply a policy.

**Before the funnel goes public:** publish a privacy policy, provide a deletion
request path, and confirm the consent text matches what the form actually says.

## Third-party content

- No author, speaker, byline, or username is stored from any sentiment source.
  `SentimentDocument` has no author field at all.
- News is stored as headline, link, date, and summary only. Full article text is
  never stored or redistributed; reports link back to the publisher.
- Crawl discipline and per-source terms are recorded in
  [`data_sources.md`](data_sources.md).

## AI governance

| Concern | Control |
|---|---|
| Fabricated figures | Narrative sees only the evidence bundle; numeric backstop plus AI Observability groundedness at 0.90, blocking |
| Harmful output | Cortex Guard enabled on narrative generation |
| Silent model change | Models pinned in `MART.REF_CORTEX_MODELS`; a change is one reviewed row |
| Score disputes | `OPS.CORTEX_AUDIT_LOG` retains prompt, response, model, and tokens; `MART.SCORE_HISTORY` retains the weights and evidence hash behind every score shown |
| Non-reproducible scores | No LLM output enters the arithmetic; `SP_TEST_REPRODUCIBILITY` asserts it |

## Standing disclaimer text

> This report summarises public records. It is not an appraisal, not investment
> advice, and not a substitute for a title report or inspection. Verify all
> figures with Orange County before closing.
