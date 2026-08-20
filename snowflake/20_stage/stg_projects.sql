-- =============================================================================
-- stg_projects.sql
-- Unified view of construction and development activity: city capital projects
-- and private development applications in one shape.
--
-- Unioning them here rather than downstream means the construction pillar has a
-- single input and the signed-impact maths is written once. A new project
-- source becomes another UNION branch, not another scoring path.
--
-- PROJECT_PHASE drives the phase factor in the impact formula. Pending projects
-- score at half weight because they may never break ground — but they are
-- included, because "approved five-storey mixed-use across the street" is
-- exactly what a buyer wants to know before closing.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA STAGE;

CREATE OR REPLACE VIEW STAGE.STG_PROJECTS
COMMENT = 'Capital improvement and private development projects in one shape. Input to the construction pillar (weight 0.32).'
AS
WITH CIP AS (
    SELECT
        'CIP' AS PROJECT_SOURCE,
        FEAT.VALUE:properties AS PROPS,
        FEAT.VALUE:geometry AS GEOM,
        RAW_SRC._INGESTED_AT
    FROM RAW.R_IRVINE_CIP_PROJECTS AS RAW_SRC,
        LATERAL FLATTEN(INPUT => RAW_SRC._PAYLOAD:features) AS FEAT
),

DEV AS (
    SELECT
        'DEVELOPMENT' AS PROJECT_SOURCE,
        FEAT.VALUE:properties AS PROPS,
        FEAT.VALUE:geometry AS GEOM,
        RAW_SRC._INGESTED_AT
    FROM RAW.R_IRVINE_DEV_PROJECTS AS RAW_SRC,
        LATERAL FLATTEN(INPUT => RAW_SRC._PAYLOAD:features) AS FEAT
),

COMBINED AS (
    SELECT * FROM CIP
    UNION ALL
    SELECT * FROM DEV
),

TYPED AS (
    SELECT
        PROJECT_SOURCE,
        TRIM(COALESCE(
            PROPS:ProjectID::VARCHAR, PROPS:PROJECT_ID::VARCHAR,
            PROPS:CaseNumber::VARCHAR, PROPS:OBJECTID::VARCHAR
        )) AS PROJECT_ID,

        TRIM(COALESCE(
            PROPS:ProjectName::VARCHAR, PROPS:PROJECT_NAME::VARCHAR,
            PROPS:Title::VARCHAR, PROPS:NAME::VARCHAR
        )) AS PROJECT_NAME,

        TRIM(COALESCE(
            PROPS:Description::VARCHAR, PROPS:DESCRIPTION::VARCHAR,
            PROPS:ProjectDescription::VARCHAR, PROPS:Scope::VARCHAR
        )) AS PROJECT_DESCRIPTION,

        UPPER(TRIM(COALESCE(
            PROPS:Status::VARCHAR, PROPS:STATUS::VARCHAR,
            PROPS:ProjectStatus::VARCHAR, PROPS:Phase::VARCHAR
        ))) AS STATUS_RAW,

        TRY_TO_DATE(COALESCE(
            PROPS:StartDate::VARCHAR, PROPS:START_DATE::VARCHAR,
            PROPS:ConstructionStart::VARCHAR
        )) AS START_DATE,

        TRY_TO_DATE(COALESCE(
            PROPS:EndDate::VARCHAR, PROPS:END_DATE::VARCHAR,
            PROPS:CompletionDate::VARCHAR, PROPS:EstCompletion::VARCHAR
        )) AS END_DATE,

        TO_GEOGRAPHY(GEOM, TRUE) AS GEOM_PROJECT,
        _INGESTED_AT
    FROM COMBINED
)

SELECT
    PROJECT_SOURCE,
    PROJECT_ID,
    PROJECT_NAME,
    PROJECT_DESCRIPTION,
    STATUS_RAW,
    START_DATE,
    END_DATE,

    -- Normalised phase. Feeds PHASE_FACTOR in MART.REF_PROJECT_TAXONOMY.
    CASE
        WHEN STATUS_RAW ILIKE '%COMPLETE%' OR STATUS_RAW ILIKE '%CLOSED%' THEN 'COMPLETE'
        WHEN
            STATUS_RAW ILIKE '%CONSTRUCT%' OR STATUS_RAW ILIKE '%ACTIVE%'
            OR STATUS_RAW ILIKE '%PROGRESS%' OR STATUS_RAW ILIKE '%UNDERWAY%' THEN 'ACTIVE'
        WHEN
            STATUS_RAW ILIKE '%APPROV%' OR STATUS_RAW ILIKE '%ENTITL%'
            OR STATUS_RAW ILIKE '%DESIGN%' OR STATUS_RAW ILIKE '%BID%' THEN 'APPROVED'
        WHEN
            STATUS_RAW ILIKE '%PEND%' OR STATUS_RAW ILIKE '%PROPOS%'
            OR STATUS_RAW ILIKE '%REVIEW%' OR STATUS_RAW ILIKE '%SUBMIT%' THEN 'PENDING'
        ELSE 'UNKNOWN'
    END AS PROJECT_PHASE,

    -- Duration in months, used by the duration factor. A three-year arterial
    -- widening and a six-week signal upgrade are not the same disruption.
    CASE
        WHEN START_DATE IS NOT NULL AND END_DATE IS NOT NULL
            THEN GREATEST(DATEDIFF('month', START_DATE, END_DATE), 0)
    END AS DURATION_MONTHS,

    -- Text handed to AI_CLASSIFY. Concatenated once here so classification has
    -- a single, stable input and its cache key does not shift.
    TRIM(COALESCE(PROJECT_NAME, '') || ' — ' || COALESCE(PROJECT_DESCRIPTION, '')) AS CLASSIFY_TEXT,

    GEOM_PROJECT,
    _INGESTED_AT AS INGESTED_AT
FROM TYPED
WHERE
    PROJECT_ID IS NOT NULL
    AND GEOM_PROJECT IS NOT NULL
    -- Long-finished work is not a buyer's concern; the window is forward-looking.
    AND (END_DATE IS NULL OR END_DATE >= DATEADD('year', -3, SYSDATE()))
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY PROJECT_SOURCE, PROJECT_ID ORDER BY _INGESTED_AT DESC
) = 1;
