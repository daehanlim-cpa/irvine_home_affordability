# Data sources

Every source carries a compliance record before it ships: robots.txt position,
terms of service, licence, and PII handling. `scripts/verify.sh` fails if
`ingest/sources.yaml` contains a source without one, and
`MART.VW_SENTIMENT_COMPLIANCE_GUARD` fails the gate if a source is *enabled* in
the database while its compliance status is still pending.

That second check exists because the first can be bypassed by an `UPDATE`.

---

## The 90%: government and public records

| Source | What it provides | Cadence | Status |
|---|---|---|---|
| Irvine ArcGIS — address points | Address → parcel. The geocoder. | Monthly | Phase 1 |
| Irvine ArcGIS — parcels + CFD | Parcel geometry, Mello-Roos district, special tax | Monthly | Phase 1 |
| Irvine ArcGIS — CIP projects | City capital projects | Weekly | Phase 1 |
| Irvine ArcGIS — development projects | Private development, pending applications | Weekly | Phase 1 |
| Orange County OCPW open GIS | County parcel and boundary layers | Monthly | Phase 2 |
| JWA noise contours | 60/65/70/75 CNEL exposure | Annual | Phase 2 |
| SCAQMD complaints | Air-quality complaints and violations | Weekly | Phase 2 |
| FEMA flood hazard | Flood zone | Annual | Phase 2 |
| Irvine PD ArcGIS Hub | Incident data, aggregated to village | Weekly | Phase 2 |
| US Census ACS | Block-group context | Annual | Phase 2 |

All are public records published for reuse. None require authentication, none
are scraped, and the adapters still consult robots.txt for every host as a
matter of uniform policy rather than making a category of fetch that skips it.

**Owner names are never selected**, even where a parcel layer exposes them. This
product analyses property, not people.

---

## The 10%: community sentiment, trust-tiered

Sentiment is a weighted blend, not an average. A resident testifying on the
record at a Planning Commission hearing about the specific project next to a
parcel is not equivalent to an anonymous review, and the model does not pretend
otherwise. Weights live in `MART.REF_SENTIMENT_SOURCES` and renormalise across
whichever sources are enabled and actually returned documents.

### Tier A — civic record (weight 0.90–1.00)

| Source | Weight | Compliance |
|---|---|---|
| **Granicus council & planning commission minutes** | 1.00 | Public records under the Ralph M. Brown Act. Rate limited to 1 req/5s. **Speaker names stripped before storage.** |
| AQMD complaint records | 0.95 | Public regulatory records. Phase 2. |
| Irvine code enforcement cases | 0.90 | Already a public GIS layer. Phase 2. |

Granicus is the highest-value sentiment source available in Irvine and is
effectively unmined. It is simultaneously community sentiment and construction
intelligence: residents describe, on the record, what a specific development is
doing to their street.

### Tier B — local journalism (0.60–0.85)

| Source | Weight | Compliance |
|---|---|---|
| Voice of OC | 0.85 | Public RSS. Headline, link, date, summary only — never full article text. |
| The Northwood Howler | 0.70 | Student paper that broke the All American Asphalt story. Bylines never stored (some authors are minors). Phase 2. |
| Irvine Watchdog | 0.65 | Explicitly advocacy; weighted below neutral reporting. Phase 2. |
| Patch Irvine | 0.60 | Phase 2. |

### Tier C — community forums (0.30–0.45)

| Source | Weight | Compliance |
|---|---|---|
| TalkIrvine | 0.45 | **Disabled pending robots.txt and ToS verification.** |
| City-Data forum | 0.35 | Disabled pending verification. Phase 2. |
| YouTube neighbourhood tours | 0.30 | Official Data API. Commenter display names discarded on ingest. Phase 2. |

### Tier D — review platforms (0.20–0.25)

Google Places, apartment review sites, Yelp. All Phase 2. Structured but thin —
Places caps at five reviews per location, Yelp at three excerpts.

### PII rule across every sentiment source

No author, speaker, byline, or username is stored. `SentimentDocument` has no
author field at all — absence by design rather than by remembering to leave it
blank — and `tests/test_adapters.py` asserts it.

Granicus name-stripping is **place-aware**: "Sarah Whitfield" is redacted,
"Sand Canyon" and "Orchard Hills" are not. Over-redaction is its own failure
mode, since a complaint about construction noise is worthless once the street
name is gone.

---

## Deliberately excluded

Recorded with the condition that would reopen each decision, so the reasoning
survives the person who made it.

| Source | Why excluded | Revisit when |
|---|---|---|
| **Reddit** | Commercial use requires written approval (2–4 week review, not guaranteed) at roughly $12k/month. Excluded on **economics**, not policy. | Revenue makes a five-figure data licence rational, or a small-business tier appears. |
| **Nextdoor** | ToS prohibits scraping; no API path for this use. | A public API with permitting terms. |
| **Facebook groups** | Private groups; collection prohibited and consent absent. | Not foreseeable. |
| **X/Twitter** | API pricing disproportionate to the signal available for one city. | Pricing changes materially. |
| **Zillow / Redfin listings** | ToS prohibits scraping. Also unnecessary — the product's value is the public-record join those sites do not perform. | A licensed MLS/IDX feed via a brokerage. |

---

## Crawl discipline

Applies to every non-API source, enforced in `ingest/adapters/base.py`:

- **robots.txt consulted before the first request to a host**, cached per host,
  and **fail-closed**: if robots.txt cannot be retrieved, we do not fetch. Only a
  genuine 404 (its documented meaning: no restrictions) is treated as permissive.
- **The site's own `Crawl-delay` wins** whenever it asks for longer than our
  default.
- **User-Agent advertises a reachable contact address.** An adapter refuses to
  construct without one — a crawler nobody can contact is not a polite crawler.
- **Daily call cap per source**, enforced against `OPS.API_CALL_LOG` before each
  request, so a bug in a paging loop cannot become an incident.
- **Nothing behind a login, ever.**

`scripts/hooks/post_edit.sh` checks mechanically that any module which actually
fetches either implements the robots gate or inherits it from `SentimentAdapter`.
Intent is not enforceable; a grep is.

---

## Outstanding verification

These are real gates, not formalities. The sandbox this repository was authored
in had restricted egress, so the following could not be checked at authoring
time and must be confirmed before the relevant source is enabled:

- [ ] `talkirvine.com/robots.txt` — fetch, read, and record the verdict here
- [ ] `city-data.com/robots.txt` — same
- [ ] TalkIrvine terms of service — read and record
- [ ] Confirm the exact ArcGIS layer IDs for each Irvine service (the registry
      currently assumes layer 0; the first ingest run will reveal the truth)
- [ ] Confirm the Granicus `view_id` for Planning Commission vs. City Council

If a source fails its gate, set `IS_ENABLED = FALSE` in
`MART.REF_SENTIMENT_SOURCES`. The blend renormalises and the product still
ships — no single source is load-bearing.
