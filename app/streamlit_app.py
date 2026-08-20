"""Irvine Home Analysis — Streamlit in Snowflake.

The buyer-facing surface. Deliberately thin: every control that matters (quota,
consent capture, scoring, narrative caching) lives in APP.SP_ANALYZE_ADDRESS, so
this file cannot skip one by accident and a future web front end inherits the
same guarantees by calling the same procedure.

Three presentation decisions carry weight beyond aesthetics:

  Omitted pillars are shown, not hidden. A score built on two pillars is a
  different claim from one built on six, and a reader who is not told that will
  reasonably assume everything was checked.

  Evidence is one click away from every score. The product's whole argument is
  that these numbers trace to public records; burying the records would undercut
  it.

  Disclaimers are attached to the report, not to a footer nobody reads.

Deploy:
    snow streamlit deploy --replace   (see snowflake/60_app/)
"""

from __future__ import annotations

import json

import streamlit as st
from snowflake.snowpark.context import get_active_session

CONSENT_TEXT = (
    "I agree to receive my property analysis by email and understand this report "
    "summarises public records. It is not an appraisal, not investment advice, and "
    "not a substitute for a title report or inspection."
)

# Bands are labels for a continuous score, not thresholds with legal meaning.
# Deliberately avoids "good"/"bad": the report describes findings, and the reader
# decides what matters to them.
SCORE_BANDS = [
    (80, "Few concerns found in the public record", "#1a7f5a"),
    (65, "Some factors worth reviewing", "#2f6f9f"),
    (50, "Several factors worth reviewing closely", "#b8860b"),
    (0, "Significant factors found — review carefully", "#a33"),
]


def band_for(score: float) -> tuple[str, str]:
    for threshold, label, color in SCORE_BANDS:
        if score >= threshold:
            return label, color
    return SCORE_BANDS[-1][1], SCORE_BANDS[-1][2]


def _client_identity() -> tuple[str, str]:
    """Best available per-visitor identifier, with its kind.

    Streamlit in Snowflake does not surface the client IP. A stable per-session
    id is the closest honest substitute: it separates concurrent visitors, which
    an empty string does not, while not pretending to be an IP address.
    """
    try:
        from streamlit.runtime.scriptrunner import get_script_run_ctx

        ctx = get_script_run_ctx()
        if ctx is not None and getattr(ctx, "session_id", None):
            return str(ctx.session_id), "session"
    except Exception:  # noqa: BLE001 - identity is best-effort, never fatal
        pass

    # No identifier available. Return a unique value rather than a shared
    # constant: sharing one bucket would throttle unrelated users together.
    import uuid

    return f"anon-{uuid.uuid4()}", "unavailable"


def render_header() -> None:
    st.title("Is this a good long-term home?")
    st.caption(
        "Enter an Irvine address. We check city and county public records — capital "
        "projects, development applications, Mello-Roos special taxes — and community "
        "discussion, then show you what we found and where we found it."
    )


def render_score(result: dict) -> None:
    score = float(result.get("composite_score") or 0)
    label, color = band_for(score)

    left, right = st.columns([1, 2])
    with left:
        st.markdown(
            f"<div style='font-size:4rem;font-weight:700;color:{color};line-height:1'>"
            f"{score:.0f}</div><div style='color:#666'>out of 100</div>",
            unsafe_allow_html=True,
        )
    with right:
        st.subheader(label)
        st.write(f"**{result.get('matched_address', '')}** · {result.get('village', '')}")
        if result.get("match_confidence") == "FUZZY":
            st.info(
                "We matched this to the closest address on file. Confirm the street name "
                "below is the one you meant."
            )

    # Coverage honesty, surfaced rather than buried. A reader who is not told
    # which pillars were skipped will assume all of them were assessed.
    confidence = result.get("confidence_level")
    omitted = [p for p in (result.get("pillars_omitted") or []) if p]
    if confidence in ("LOW_CONFIDENCE", "MODERATE_CONFIDENCE") or omitted:
        st.warning(
            "**This score does not cover everything.** "
            + (
                f"Not assessed: {', '.join(p.replace('_', ' ').title() for p in omitted)}. "
                if omitted
                else ""
            )
            + "Those factors were not measured, which is not the same as finding them fine."
        )


def render_pillars(result: dict) -> None:
    pillars = result.get("pillars") or {}
    if not pillars:
        return

    st.subheader("How the score breaks down")
    for code, detail in sorted(
        pillars.items(), key=lambda kv: -(kv[1].get("effective_weight") or 0)
    ):
        subscore = detail.get("subscore")
        label = detail.get("label", code)
        weight = detail.get("effective_weight") or 0

        if subscore is None:
            st.write(f"**{label}** — not assessed")
            st.caption("No data for this pillar; its weight was redistributed across the others.")
            continue

        st.write(f"**{label}** — {float(subscore):.0f}/100 · {weight:.0%} of this score")
        st.progress(min(max(float(subscore) / 100, 0.0), 1.0))


def render_narrative(result: dict) -> None:
    narrative = result.get("narrative")
    if narrative:
        st.subheader("What this means")
        st.write(narrative)


def render_evidence(result: dict) -> None:
    """Every figure traces to a record. Hiding that would undercut the product."""
    evidence = result.get("evidence") or {}
    if not evidence:
        return

    st.subheader("The records behind this")

    construction = evidence.get("construction") or {}
    projects = construction.get("projects") or []
    if projects:
        with st.expander(f"Construction and development — {len(projects)} nearby project(s)"):
            for proj in projects:
                direction = proj.get("direction")
                marker = {"negative": "▼", "positive": "▲"}.get(direction, "•")
                st.markdown(
                    f"{marker} **{proj.get('name', 'Unnamed project')}** "
                    f"({proj.get('category', 'uncategorised')})  \n"
                    f"{proj.get('distance_meters', '?')} m away · {proj.get('phase', 'unknown phase')}"
                    + (
                        f" · {proj.get('duration_months')} months"
                        if proj.get("duration_months")
                        else ""
                    )
                    + f"  \n_Record: {proj.get('record_id')}_"
                )
                if proj.get("description"):
                    st.caption(proj["description"])

    cost = evidence.get("cost_burden") or {}
    if cost:
        with st.expander("Cost burden — Mello-Roos, HOA, tax rate area"):
            annual = cost.get("cfd_annual_tax") or 0
            years = cost.get("cfd_years_remaining")
            total = cost.get("cfd_total_remaining_obligation")

            if annual:
                st.metric("Mello-Roos special tax", f"${float(annual):,.0f}/year")
                # The figure no listing site shows, and the one that most changes
                # what the purchase actually costs.
                if years is not None and total is not None:
                    st.metric(
                        f"Remaining over {int(years)} years", f"${float(total):,.0f}"
                    )
                    st.caption(
                        "The annual figure is what most listings mention. The total "
                        "remaining obligation is what you actually commit to."
                    )
            elif cost.get("band") == "CFD_AMOUNT_UNKNOWN":
                # Never render this case as good news. The parcel is inside a
                # district; we simply do not have the amount.
                st.warning(
                    "This parcel is inside a Community Facilities District, but the "
                    "amount is not published in the parcel record. Confirm with the "
                    "County — do not assume there is no Mello-Roos."
                )
            else:
                st.success("No Mello-Roos special tax recorded for this parcel.")

            if cost.get("hoa_monthly"):
                st.write(f"HOA dues: ${float(cost['hoa_monthly']):,.0f}/month")
            if cost.get("village_deviation_note"):
                st.info(cost["village_deviation_note"])
            if cost.get("data_caveat"):
                st.warning(cost["data_caveat"])

    sentiment = evidence.get("sentiment") or {}
    if sentiment:
        with st.expander("Community discussion"):
            if sentiment.get("status") == "SCORED":
                st.write(
                    f"Based on {sentiment.get('document_count')} documents across "
                    f"{sentiment.get('source_count')} sources."
                )
                if sentiment.get("themes"):
                    st.write(sentiment["themes"])
                st.caption(sentiment.get("scope", ""))
            else:
                st.write(
                    "Not enough recent discussion about this village to report reliably, "
                    "so this pillar was not scored."
                )


def main() -> None:
    st.set_page_config(page_title="Irvine Home Analysis", page_icon="🏡", layout="centered")
    session = get_active_session()
    render_header()

    with st.form("analyze"):
        address = st.text_input(
            "Irvine address", placeholder="e.g. 100 Sunset Cove, Irvine CA 92620"
        )
        email = st.text_input("Your email", placeholder="you@example.com")
        consent = st.checkbox(CONSENT_TEXT)
        submitted = st.form_submit_button("Analyse this home")

    if not submitted:
        return

    if not address.strip():
        st.error("Enter an Irvine address to analyse.")
        return
    if "@" not in email or "." not in email.split("@")[-1]:
        st.error("Enter a valid email address so we can send your report.")
        return
    if not consent:
        st.error("Please confirm the consent checkbox to continue.")
        return

    # Streamlit in Snowflake does not expose the client IP directly. Passing an
    # empty string put every visitor in ONE quota bucket, so the 26th user of the
    # day was refused — a rate limit that punishes real traffic while doing
    # nothing about abuse. Fall back to a per-session identifier, which at least
    # separates users, and record which it is so the quota table is honest about
    # what it is counting.
    client_id, client_kind = _client_identity()

    with st.spinner("Checking public records…"):
        rows = session.sql(
            "CALL APP.SP_ANALYZE_ADDRESS(?, ?, ?, ?, ?)",
            params=[
                address.strip(),
                email.strip().lower(),
                CONSENT_TEXT,
                client_id,
                f"streamlit-in-snowflake;identity={client_kind}",
            ],
        ).collect()

    if not rows:
        st.error("Something went wrong running the analysis. Please try again.")
        return

    result = json.loads(rows[0][0]) if isinstance(rows[0][0], str) else rows[0][0]
    status = result.get("status")

    if status == "QUOTA_EXCEEDED":
        st.warning(result.get("message"))
        return
    if status == "UNAVAILABLE":
        st.warning(result.get("message"))
        return
    if status == "NOT_FOUND":
        st.error(result.get("message"))
        return
    if status == "VILLAGE_LEVEL":
        st.info(result.get("message"))
        sentiment = result.get("sentiment") or {}
        if sentiment.get("themes"):
            st.subheader(f"About {result.get('village', 'this village')}")
            st.write(sentiment["themes"])
        return

    render_score(result)
    render_pillars(result)
    render_narrative(result)
    render_evidence(result)

    st.divider()
    st.caption(result.get("disclaimer", ""))


if __name__ == "__main__":
    main()
