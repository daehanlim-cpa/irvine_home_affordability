-- =============================================================================
-- vw_evidence_bundle.sql
-- The complete, structured evidence behind one parcel's score.
--
-- This view is the ONLY thing the narrative generator is allowed to see. It
-- cannot browse the warehouse, cannot recall Irvine facts from training, and
-- cannot invent a figure — if a number is not in this bundle, it must not appear
-- in the report. Groundedness scoring in AI Observability checks exactly that.
--
-- It is also the answer to "why did this parcel score what it scored?". Every
-- row here is a public record with a URL a buyer can go and read. That is the
-- difference between a defensible product and an opinion with a number on it.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;

CREATE OR REPLACE VIEW MART.VW_EVIDENCE_BUNDLE
COMMENT = 'Structured evidence for one parcel: the sole input to narrative generation and the audit trail for any score dispute.'
AS
WITH PILLAR_COVERAGE AS (
    SELECT
        ARRAY_AGG(CASE WHEN IS_ACTIVE THEN PILLAR_CODE END) AS ACTIVE_PILLARS,
        ARRAY_AGG(CASE WHEN NOT IS_ACTIVE THEN PILLAR_CODE END) AS INACTIVE_PILLARS
    FROM MART.REF_SCORE_WEIGHTS
),

LATEST_SENTIMENT AS (
    -- Pre-filter to the newest daily snapshot once, rather than re-evaluating a
    -- MAX() subquery inside the join for every parcel.
    -- Per-village max, matching the scorer. A global MAX meant a village whose
    -- last refresh lagged by a day was reported to the narrative as "not
    -- assessed" while its subscore was still in the composite — the report and
    -- the number disagreeing about the same parcel.
    SELECT *
    FROM MART.FCT_SENTIMENT_VILLAGE
    QUALIFY AS_OF_DATE = MAX(AS_OF_DATE) OVER (PARTITION BY VILLAGE_CODE)
),

TOP_PROJECTS AS (
    -- The projects that actually moved the number. Ordered by absolute
    -- contribution so the narrative discusses what matters, not what is nearest.
    SELECT
        APN,
        ARRAY_AGG(
            OBJECT_CONSTRUCT(
                'record_id', PROJECT_SOURCE || ':' || PROJECT_ID,
                'name', PROJECT_NAME,
                'description', LEFT(COALESCE(PROJECT_DESCRIPTION, ''), 400),
                'category', CATEGORY_LABEL,
                'phase', PROJECT_PHASE,
                'distance_meters', DISTANCE_METERS,
                'duration_months', DURATION_MONTHS,
                'start_date', START_DATE,
                'end_date', END_DATE,
                'impact_points', IMPACT_POINTS,
                'direction', DECODE(SIGN(IMPACT_SIGN), -1, 'negative', 1, 'positive', 'neutral')
            )
        ) WITHIN GROUP (ORDER BY ABS(IMPACT_POINTS) DESC) AS PROJECT_LIST
    FROM MART.FCT_PROJECT_IMPACT
    QUALIFY ROW_NUMBER() OVER (PARTITION BY APN ORDER BY ABS(IMPACT_POINTS) DESC) <= 12
    GROUP BY APN
)

SELECT
    PARCEL.APN,
    OBJECT_CONSTRUCT(
        'parcel', OBJECT_CONSTRUCT(
            'apn', PARCEL.APN,
            'address', PARCEL.ADDRESS_NORMALIZED,
            'zip', PARCEL.ZIP_CODE,
            'village', PARCEL.VILLAGE_NAME,
            'school_district', PARCEL.SCHOOL_DISTRICT,
            'era_built', PARCEL.ERA_BUILT,
            'year_built', PARCEL.YEAR_BUILT,
            'lot_sqft', PARCEL.LOT_SQFT,
            'zoning', PARCEL.ZONING_CODE,
            'data_as_of', PARCEL.PARCEL_AS_OF
        ),

        'construction', OBJECT_CONSTRUCT(
            'subscore', CONS.SUBSCORE,
            'projects_nearby', CONS.PROJECTS_NEARBY,
            'projects_active', CONS.PROJECTS_ACTIVE,
            'projects_pending', CONS.PROJECTS_PENDING,
            'projects_unclassified', CONS.PROJECTS_UNCLASSIFIED,
            'nearest_project_meters', CONS.NEAREST_PROJECT_METERS,
            'negative_points', CONS.NEGATIVE_POINTS,
            'positive_points', CONS.POSITIVE_POINTS,
            'projects', COALESCE(PROJ.PROJECT_LIST, ARRAY_CONSTRUCT()),
            'data_as_of', CONS.DATA_AS_OF
        ),

        'cost_burden', OBJECT_CONSTRUCT(
            'subscore', COST.SUBSCORE,
            'band', COST.BURDEN_BAND,
            'cfd_name', COST.CFD_NAME,
            'cfd_annual_tax', COST.CFD_ANNUAL_TAX,
            'cfd_years_remaining', COST.CFD_YEARS_REMAINING,
            'cfd_total_remaining_obligation', COST.CFD_REMAINING_OBLIGATION,
            'hoa_monthly', COST.HOA_DUES_MONTHLY,
            'total_annual_carry', COST.TOTAL_ANNUAL_CARRY,
            'tax_rate_area', COST.TAX_RATE_AREA,
            'village_typical_cfd', PARCEL.VILLAGE_TYPICAL_CFD,
            'village_deviation_note', COST.VILLAGE_DEVIATION_NOTE,
            'data_caveat', COST.DATA_CAVEAT,
            'data_as_of', COST.DATA_AS_OF
        ),

        'sentiment', OBJECT_CONSTRUCT(
            'subscore', SENT.SUBSCORE,
            'status', COALESCE(SENT.DATA_STATUS, 'INSUFFICIENT_DATA'),
            'document_count', COALESCE(SENT.DOCUMENT_COUNT, 0),
            'source_count', COALESCE(SENT.SOURCE_COUNT, 0),
            'themes', SENT.TOP_THEMES,
            'scope', 'village-level; community discussion is about villages, not individual addresses',
            'data_as_of', SENT.AS_OF_DATE
        ),

        -- Stated in the bundle so the narrative can describe its own limits
        -- rather than implying completeness the data does not have.
        'coverage', OBJECT_CONSTRUCT(
            'active_pillars', COVERAGE.ACTIVE_PILLARS,
            'inactive_pillars', COVERAGE.INACTIVE_PILLARS,
            'note', 'Inactive pillars are not yet fed by data. Their weight is redistributed across active pillars, and the report must not imply they were assessed.'
        )
    ) AS EVIDENCE
FROM MART.DIM_PARCEL AS PARCEL
CROSS JOIN PILLAR_COVERAGE AS COVERAGE
LEFT JOIN MART.FCT_CONSTRUCTION_SUBSCORE AS CONS ON PARCEL.APN = CONS.APN
LEFT JOIN TOP_PROJECTS AS PROJ ON PARCEL.APN = PROJ.APN
LEFT JOIN MART.FCT_COST_BURDEN AS COST ON PARCEL.APN = COST.APN
LEFT JOIN LATEST_SENTIMENT AS SENT ON PARCEL.VILLAGE_CODE = SENT.VILLAGE_CODE;

GRANT SELECT ON VIEW MART.VW_EVIDENCE_BUNDLE TO ROLE IHA_APP;
