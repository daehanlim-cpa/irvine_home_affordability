-- =============================================================================
-- fct_project_impact.sql
-- The construction pillar. Heaviest weight in the model at 0.32.
--
--     impact = sign x severity x exp(-d / decay) x phase_factor x duration_factor
--
-- Every term on the right is either a measured distance or a config-table
-- lookup. Cortex contributes exactly one thing: the CATEGORY_CODE that selects
-- the sign and severity row. It never produces a number. That is what makes this
-- reproducible — score the same parcel twice and the arithmetic is identical.
--
-- Positive and negative aggregates are capped SEPARATELY and asymmetrically.
-- Summing them into one figure would let three new parks cancel an asphalt
-- plant, which is not how anyone actually evaluates a home.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;

-- -----------------------------------------------------------------------------
-- Per parcel-project pair. This is the evidence table: every row is a specific
-- project at a measured distance with a traceable contribution, which is what
-- the narrative cites and what a sceptical buyer can go and verify.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW MART.FCT_PROJECT_IMPACT
COMMENT = 'One row per parcel-project pair within the distance clip, with its signed point contribution. The evidence behind the construction pillar.'
AS
WITH PARAMS AS (
    SELECT
        MAX(CASE WHEN PARAM_NAME = 'DISTANCE_DECAY_METERS' THEN PARAM_VALUE END) AS DECAY_M,
        MAX(CASE WHEN PARAM_NAME = 'DISTANCE_CLIP_METERS' THEN PARAM_VALUE END) AS CLIP_M,
        MAX(CASE WHEN PARAM_NAME = 'PHASE_FACTOR_ACTIVE' THEN PARAM_VALUE END) AS PF_ACTIVE,
        MAX(CASE WHEN PARAM_NAME = 'PHASE_FACTOR_APPROVED' THEN PARAM_VALUE END) AS PF_APPROVED,
        MAX(CASE WHEN PARAM_NAME = 'PHASE_FACTOR_PENDING' THEN PARAM_VALUE END) AS PF_PENDING,
        MAX(CASE WHEN PARAM_NAME = 'PHASE_FACTOR_COMPLETE' THEN PARAM_VALUE END) AS PF_COMPLETE,
        MAX(CASE WHEN PARAM_NAME = 'PHASE_FACTOR_UNKNOWN' THEN PARAM_VALUE END) AS PF_UNKNOWN,
        MAX(CASE WHEN PARAM_NAME = 'DURATION_FACTOR_MAX' THEN PARAM_VALUE END) AS DUR_MAX,
        MAX(CASE WHEN PARAM_NAME = 'DURATION_REFERENCE_MONTHS' THEN PARAM_VALUE END) AS DUR_REF,
        MAX(CASE WHEN PARAM_NAME = 'IMPACT_POINT_SCALE' THEN PARAM_VALUE END) AS POINT_SCALE
    FROM MART.REF_SCORING_PARAMS
),

-- Projects joined to their Cortex-assigned category and the severity that
-- category maps to. A project that failed classification lands on UNCLASSIFIED,
-- which scores neutral and is surfaced rather than guessed at.
CLASSIFIED AS (
    SELECT
        PROJ.PROJECT_SOURCE,
        PROJ.PROJECT_ID,
        PROJ.PROJECT_NAME,
        PROJ.PROJECT_DESCRIPTION,
        PROJ.PROJECT_PHASE,
        PROJ.START_DATE,
        PROJ.END_DATE,
        PROJ.DURATION_MONTHS,
        PROJ.GEOM_PROJECT,
        PROJ.INGESTED_AT,
        COALESCE(CLS.CATEGORY_CODE, 'UNCLASSIFIED') AS CATEGORY_CODE,
        CLS.CLASSIFIER_CONFIDENCE,
        TAX.CATEGORY_LABEL,
        TAX.IMPACT_SIGN,
        TAX.SEVERITY,
        TAX.RATIONALE AS CATEGORY_RATIONALE
    FROM STAGE.STG_PROJECTS AS PROJ
    LEFT JOIN MART.PROJECT_CLASSIFICATION AS CLS
        ON
            PROJ.PROJECT_SOURCE = CLS.PROJECT_SOURCE
            AND PROJ.PROJECT_ID = CLS.PROJECT_ID
    INNER JOIN MART.REF_PROJECT_TAXONOMY AS TAX
        ON COALESCE(CLS.CATEGORY_CODE, 'UNCLASSIFIED') = TAX.CATEGORY_CODE
)

SELECT
    PARCEL.APN,
    PARCEL.VILLAGE_CODE,
    PROJ.PROJECT_SOURCE,
    PROJ.PROJECT_ID,
    PROJ.PROJECT_NAME,
    PROJ.PROJECT_DESCRIPTION,
    PROJ.CATEGORY_CODE,
    PROJ.CATEGORY_LABEL,
    PROJ.CATEGORY_RATIONALE,
    PROJ.CLASSIFIER_CONFIDENCE,
    PROJ.PROJECT_PHASE,
    PROJ.START_DATE,
    PROJ.END_DATE,
    PROJ.DURATION_MONTHS,
    PROJ.IMPACT_SIGN,
    PROJ.SEVERITY,
    ROUND(ST_DISTANCE(PARCEL.GEOM_POINT, PROJ.GEOM_PROJECT), 1) AS DISTANCE_METERS,

    -- Distance decay. Exponential rather than linear because disruption falls
    -- off sharply: a project two streets away is far less than half the problem
    -- of one next door.
    EXP(-1 * ST_DISTANCE(PARCEL.GEOM_POINT, PROJ.GEOM_PROJECT) / PARAMS.DECAY_M) AS DISTANCE_DECAY,

    CASE PROJ.PROJECT_PHASE
        WHEN 'ACTIVE' THEN PARAMS.PF_ACTIVE
        WHEN 'APPROVED' THEN PARAMS.PF_APPROVED
        WHEN 'PENDING' THEN PARAMS.PF_PENDING
        WHEN 'COMPLETE' THEN PARAMS.PF_COMPLETE
        ELSE PARAMS.PF_UNKNOWN
    END AS PHASE_FACTOR,

    -- Duration scales impact but is capped: a decade-long programme is worse
    -- than an 18-month one, though not proportionally so.
    LEAST(
        COALESCE(PROJ.DURATION_MONTHS, PARAMS.DUR_REF) / PARAMS.DUR_REF,
        PARAMS.DUR_MAX
    ) AS DURATION_FACTOR,

    -- The contribution, in score points. Signed: negative harms, positive helps.
    ROUND(
        PROJ.IMPACT_SIGN
        * PROJ.SEVERITY
        * EXP(-1 * ST_DISTANCE(PARCEL.GEOM_POINT, PROJ.GEOM_PROJECT) / PARAMS.DECAY_M)
        * CASE PROJ.PROJECT_PHASE
            WHEN 'ACTIVE' THEN PARAMS.PF_ACTIVE
            WHEN 'APPROVED' THEN PARAMS.PF_APPROVED
            WHEN 'PENDING' THEN PARAMS.PF_PENDING
            WHEN 'COMPLETE' THEN PARAMS.PF_COMPLETE
            ELSE PARAMS.PF_UNKNOWN
        END
        * LEAST(COALESCE(PROJ.DURATION_MONTHS, PARAMS.DUR_REF) / PARAMS.DUR_REF, PARAMS.DUR_MAX)
        * PARAMS.POINT_SCALE,
        2
    ) AS IMPACT_POINTS,

    PROJ.INGESTED_AT AS PROJECT_AS_OF
FROM MART.DIM_PARCEL AS PARCEL
CROSS JOIN PARAMS
INNER JOIN CLASSIFIED AS PROJ
-- ST_DWITHIN rather than a filter on ST_DISTANCE: it is the form Snowflake
    -- can optimise, and this join is parcel-count x project-count without it.
    ON ST_DWITHIN(PARCEL.GEOM_POINT, PROJ.GEOM_PROJECT, PARAMS.CLIP_M)
WHERE PARCEL.GEOM_POINT IS NOT NULL;

-- -----------------------------------------------------------------------------
-- Per-parcel rollup: the construction subscore, 0..100.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW MART.FCT_CONSTRUCTION_SUBSCORE
COMMENT = 'Construction pillar subscore (0-100) per parcel, with the counts a narrative needs to explain it.'
AS
WITH CAPS AS (
    SELECT
        MAX(CASE WHEN PARAM_NAME = 'NEGATIVE_IMPACT_CAP' THEN PARAM_VALUE END) AS NEG_CAP,
        MAX(CASE WHEN PARAM_NAME = 'POSITIVE_IMPACT_CAP' THEN PARAM_VALUE END) AS POS_CAP
    FROM MART.REF_SCORING_PARAMS
),

-- Every parcel must appear, including those with no nearby projects. A LEFT
-- JOIN from DIM_PARCEL rather than a GROUP BY over the impact rows: without it
-- a quiet parcel produces no row, the 0.32 construction pillar is treated as
-- "not assessed", and the score silently rests on the remaining pillars — the
-- opposite of the truth, since no nearby construction is a GOOD result.
AGGREGATED AS (
    SELECT
        PARCEL.APN,
        PARCEL.VILLAGE_CODE,
        COALESCE(SUM(CASE WHEN IMP.IMPACT_POINTS < 0 THEN ABS(IMP.IMPACT_POINTS) ELSE 0 END), 0) AS RAW_NEGATIVE,
        COALESCE(SUM(CASE WHEN IMP.IMPACT_POINTS > 0 THEN IMP.IMPACT_POINTS ELSE 0 END), 0) AS RAW_POSITIVE,
        COUNT(IMP.PROJECT_ID) AS PROJECTS_NEARBY,
        COUNT_IF(IMP.IMPACT_SIGN < 0) AS PROJECTS_NEGATIVE,
        COUNT_IF(IMP.IMPACT_SIGN > 0) AS PROJECTS_POSITIVE,
        COUNT_IF(IMP.PROJECT_PHASE = 'ACTIVE') AS PROJECTS_ACTIVE,
        COUNT_IF(IMP.PROJECT_PHASE = 'PENDING') AS PROJECTS_PENDING,
        COUNT_IF(IMP.CATEGORY_CODE = 'UNCLASSIFIED') AS PROJECTS_UNCLASSIFIED,
        MIN(IMP.DISTANCE_METERS) AS NEAREST_PROJECT_METERS,
        MAX(IMP.PROJECT_AS_OF) AS DATA_AS_OF
    FROM MART.DIM_PARCEL AS PARCEL
    LEFT JOIN MART.FCT_PROJECT_IMPACT AS IMP ON PARCEL.APN = IMP.APN
    GROUP BY PARCEL.APN, PARCEL.VILLAGE_CODE
)

SELECT
    AGG.APN,
    AGG.VILLAGE_CODE,
    LEAST(AGG.RAW_NEGATIVE, CAPS.NEG_CAP) AS NEGATIVE_POINTS,
    LEAST(AGG.RAW_POSITIVE, CAPS.POS_CAP) AS POSITIVE_POINTS,
    -- Start at 100, subtract capped harm, add capped benefit, clamp to 0..100.
    GREATEST(
        LEAST(
            100 - LEAST(AGG.RAW_NEGATIVE, CAPS.NEG_CAP) + LEAST(AGG.RAW_POSITIVE, CAPS.POS_CAP),
            100
        ),
        0
    ) AS SUBSCORE,
    AGG.PROJECTS_NEARBY,
    AGG.PROJECTS_NEGATIVE,
    AGG.PROJECTS_POSITIVE,
    AGG.PROJECTS_ACTIVE,
    AGG.PROJECTS_PENDING,
    AGG.PROJECTS_UNCLASSIFIED,
    AGG.NEAREST_PROJECT_METERS,
    AGG.DATA_AS_OF
FROM AGGREGATED AS AGG
CROSS JOIN CAPS;

GRANT SELECT ON VIEW MART.FCT_PROJECT_IMPACT TO ROLE IHA_APP;
GRANT SELECT ON VIEW MART.FCT_CONSTRUCTION_SUBSCORE TO ROLE IHA_APP;
