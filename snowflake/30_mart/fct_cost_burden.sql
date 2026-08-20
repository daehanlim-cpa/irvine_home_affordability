-- =============================================================================
-- fct_cost_burden.sql
-- The cost pillar (weight 0.20) — the strongest differentiator this product has.
--
-- Mello-Roos/CFD burden varies parcel by parcel. Two visually identical homes a
-- block apart in the same village can differ by thousands a year, and no listing
-- site surfaces it. Neither does any site surface the number that actually
-- matters: how many years are LEFT to pay.
--
-- A $4,000/yr special tax with 3 years remaining is a $12,000 problem. The same
-- $4,000/yr with 28 years remaining is a $112,000 problem. Presented as an
-- identical monthly figure, those are wildly different purchases. Scoring the
-- remaining obligation rather than the annual payment is the whole point.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;

CREATE OR REPLACE VIEW MART.FCT_COST_BURDEN
COMMENT = 'Cost pillar (0-100) per parcel: CFD special tax, remaining term and total obligation, HOA dues. Parcel-level by design.'
AS
WITH PARAMS AS (
    SELECT MAX(CASE WHEN PARAM_NAME = 'CFD_HIGH_ANNUAL_THRESHOLD' THEN PARAM_VALUE END) AS CFD_HIGH
    FROM MART.REF_SCORING_PARAMS
),

BASE AS (
    SELECT
        PARCEL.APN,
        PARCEL.VILLAGE_CODE,
        PARCEL.VILLAGE_TYPICAL_CFD,
        PARCEL.CFD_NAME,
        PARCEL.CFD_ANNUAL_TAX,
        PARCEL.CFD_AMOUNT_UNKNOWN,
        PARCEL.CFD_YEARS_REMAINING,
        PARCEL.CFD_REMAINING_OBLIGATION,
        PARCEL.TAX_RATE_AREA,
        PARCEL.HOA_DUES_MONTHLY,
        PARCEL.HOA_DUES_MONTHLY * 12 AS HOA_ANNUAL,
        COALESCE(PARCEL.CFD_ANNUAL_TAX, 0) + (PARCEL.HOA_DUES_MONTHLY * 12) AS TOTAL_ANNUAL_CARRY,
        PARCEL.PARCEL_AS_OF,
        PARAMS.CFD_HIGH
    FROM MART.DIM_PARCEL AS PARCEL
    CROSS JOIN PARAMS
),

SCORED AS (
    SELECT
        BASE.*,

        -- Annual burden component, 0..55 points of deduction. Scaled against the
        -- high-burden threshold, so a parcel at the threshold loses roughly half
        -- of what the maximum-burden parcel does.
        LEAST(
            (BASE.TOTAL_ANNUAL_CARRY / NULLIF(BASE.CFD_HIGH, 0)) * 27.5,
            55
        ) AS ANNUAL_BURDEN_POINTS,

        -- Remaining-term component, 0..25 points. A CFD close to maturity is a
        -- far smaller liability than the same annual figure with decades to run,
        -- and this is where that shows up.
        CASE
            WHEN BASE.CFD_AMOUNT_UNKNOWN THEN 12.5   -- district exists, amount unpublished
            WHEN COALESCE(BASE.CFD_ANNUAL_TAX, 0) = 0 THEN 0
            WHEN BASE.CFD_YEARS_REMAINING IS NULL THEN 12.5   -- unknown term: mid penalty, flagged below
            ELSE LEAST(BASE.CFD_YEARS_REMAINING / 30.0, 1.0) * 25
        END AS TERM_POINTS
    FROM BASE
)

SELECT
    APN,
    VILLAGE_CODE,
    CFD_NAME,
    CFD_ANNUAL_TAX,
    CFD_AMOUNT_UNKNOWN,
    CFD_YEARS_REMAINING,
    CFD_REMAINING_OBLIGATION,
    TAX_RATE_AREA,
    HOA_DUES_MONTHLY,
    HOA_ANNUAL,
    TOTAL_ANNUAL_CARRY,
    ROUND(ANNUAL_BURDEN_POINTS, 2) AS ANNUAL_BURDEN_POINTS,
    ROUND(TERM_POINTS, 2) AS TERM_POINTS,
    GREATEST(LEAST(100 - ANNUAL_BURDEN_POINTS - TERM_POINTS, 100), 0) AS SUBSCORE,

    -- Plain-language band for the report. Buyers reason in categories; the
    -- number is for the model.
    CASE
        -- UNKNOWN comes first: claiming "no Mello-Roos" when the record simply
        -- did not publish a figure is the most damaging error available here.
        WHEN CFD_AMOUNT_UNKNOWN THEN 'CFD_AMOUNT_UNKNOWN'
        WHEN CFD_ANNUAL_TAX = 0 AND HOA_DUES_MONTHLY = 0 THEN 'NO_SPECIAL_ASSESSMENTS'
        WHEN CFD_ANNUAL_TAX = 0 THEN 'HOA_ONLY'
        WHEN CFD_ANNUAL_TAX < 1500 THEN 'LOW_CFD'
        WHEN CFD_ANNUAL_TAX < CFD_HIGH THEN 'MODERATE_CFD'
        ELSE 'HIGH_CFD'
    END AS BURDEN_BAND,

    -- Flags the narrative must disclose rather than paper over.
    CASE
        WHEN CFD_AMOUNT_UNKNOWN
            THEN 'This parcel is inside a Community Facilities District but the parcel record does not publish the annual amount. Do NOT read this as no Mello-Roos. Confirm with the Orange County Treasurer-Tax Collector.'
        WHEN CFD_ANNUAL_TAX > 0 AND CFD_YEARS_REMAINING IS NULL
            THEN 'CFD maturity year unavailable in the parcel record — total remaining obligation could not be computed. Verify with the Orange County Treasurer-Tax Collector before relying on this figure.'
    END AS DATA_CAVEAT,

    -- Where a parcel contradicts its village's typical pattern, say so: it is
    -- often the single most surprising and useful line in the whole report.
    CASE
        WHEN VILLAGE_TYPICAL_CFD = 'NONE' AND COALESCE(CFD_ANNUAL_TAX, 0) > 1000
            THEN 'This parcel carries a special tax although its village typically has none — confirm the district and phase.'
        WHEN VILLAGE_TYPICAL_CFD = 'HIGH' AND CFD_ANNUAL_TAX = 0 AND NOT CFD_AMOUNT_UNKNOWN
            THEN 'This parcel appears to carry no special tax although its village typically does — an unusual cost advantage worth confirming.'
    END AS VILLAGE_DEVIATION_NOTE,

    PARCEL_AS_OF AS DATA_AS_OF
FROM SCORED;

GRANT SELECT ON VIEW MART.FCT_COST_BURDEN TO ROLE IHA_APP;
GRANT SELECT ON VIEW MART.FCT_COST_BURDEN TO ROLE IHA_ANALYST;
