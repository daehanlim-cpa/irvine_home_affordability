-- =============================================================================
-- proc_score_parcel.sql
-- The composite scorer. Pure SQL arithmetic over MART views and config tables.
--
-- No Cortex call appears anywhere in this file. That is the point: scoring the
-- same parcel twice on the same data produces byte-identical output, which is
-- what lets a number be defended to a buyer and regression-tested in CI.
--
-- Weight redistribution: pillars that are inactive, or that returned
-- INSUFFICIENT_DATA, are dropped and the remaining weights renormalise. A
-- village with no forum chatter does not score 0 on sentiment — it scores on
-- the pillars that have evidence, and the report says which those were.
-- Treating missing data as a bad result would be the single easiest way to make
-- this product quietly wrong.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;

CREATE TABLE IF NOT EXISTS MART.SCORE_HISTORY (
    APN VARCHAR NOT NULL,
    SCORED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    COMPOSITE_SCORE NUMBER(6, 2) NOT NULL,
    PILLAR_SCORES VARIANT NOT NULL,
    WEIGHTS_USED VARIANT NOT NULL,
    PILLARS_OMITTED ARRAY,
    EVIDENCE_HASH VARCHAR(64) NOT NULL,
    SCORER_VERSION VARCHAR NOT NULL,
    PRIMARY KEY (APN, SCORED_AT)
)
COMMENT = 'Every score ever produced, with the weights and evidence hash behind it. Lets a re-run show what changed and why, and answers a disputed score months later.';

CREATE OR REPLACE VIEW MART.VW_PARCEL_SCORE
COMMENT = 'Composite score per parcel with pillar breakdown. Deterministic: no LLM output enters the arithmetic.'
AS
WITH ACTIVE_WEIGHTS AS (
    SELECT
        PILLAR_CODE,
        PILLAR_LABEL,
        WEIGHT,
        DISPLAY_ORDER
    FROM MART.REF_SCORE_WEIGHTS
    WHERE IS_ACTIVE = TRUE
),

-- Each active pillar's subscore per parcel, in one shape so redistribution can
-- be expressed once instead of per pillar.
PILLAR_SCORES AS (
    SELECT
        PARCEL.APN,
        'CONSTRUCTION' AS PILLAR_CODE,
        CONS.SUBSCORE
    FROM MART.DIM_PARCEL AS PARCEL
    LEFT JOIN MART.FCT_CONSTRUCTION_SUBSCORE AS CONS ON PARCEL.APN = CONS.APN

    UNION ALL

    SELECT
        PARCEL.APN,
        'COST_BURDEN' AS PILLAR_CODE,
        COST.SUBSCORE
    FROM MART.DIM_PARCEL AS PARCEL
    LEFT JOIN MART.FCT_COST_BURDEN AS COST ON PARCEL.APN = COST.APN

    UNION ALL

    SELECT
        PARCEL.APN,
        'SENTIMENT' AS PILLAR_CODE,
        -- NULL when the village lacks enough documents; the weight then
        -- redistributes rather than the parcel being penalised for our gap.
        CASE WHEN SENT.DATA_STATUS = 'SCORED' THEN SENT.SUBSCORE END AS SUBSCORE
    FROM MART.DIM_PARCEL AS PARCEL
    LEFT JOIN MART.FCT_SENTIMENT_VILLAGE AS SENT
        ON PARCEL.VILLAGE_CODE = SENT.VILLAGE_CODE
    QUALIFY
        SENT.AS_OF_DATE IS NULL
        OR SENT.AS_OF_DATE = MAX(SENT.AS_OF_DATE) OVER (PARTITION BY PARCEL.APN)
),

SCORED AS (
    SELECT
        PILLARS.APN,
        PILLARS.PILLAR_CODE,
        WEIGHTS.PILLAR_LABEL,
        WEIGHTS.DISPLAY_ORDER,
        PILLARS.SUBSCORE,
        WEIGHTS.WEIGHT AS NOMINAL_WEIGHT,
        -- Renormalise across the pillars that actually produced a subscore.
        WEIGHTS.WEIGHT / NULLIF(
            SUM(CASE WHEN PILLARS.SUBSCORE IS NOT NULL THEN WEIGHTS.WEIGHT ELSE 0 END)
                OVER (PARTITION BY PILLARS.APN),
            0
        ) AS EFFECTIVE_WEIGHT
    FROM PILLAR_SCORES AS PILLARS
    INNER JOIN ACTIVE_WEIGHTS AS WEIGHTS ON PILLARS.PILLAR_CODE = WEIGHTS.PILLAR_CODE
)

SELECT
    APN,
    ROUND(
        SUM(CASE WHEN SUBSCORE IS NOT NULL THEN SUBSCORE * EFFECTIVE_WEIGHT ELSE 0 END),
        2
    ) AS COMPOSITE_SCORE,
    OBJECT_AGG(
        PILLAR_CODE,
        OBJECT_CONSTRUCT(
            'label', PILLAR_LABEL,
            'subscore', SUBSCORE,
            'nominal_weight', NOMINAL_WEIGHT,
            'effective_weight', ROUND(EFFECTIVE_WEIGHT, 4),
            'contribution', ROUND(COALESCE(SUBSCORE, 0) * COALESCE(EFFECTIVE_WEIGHT, 0), 2)
        )::VARIANT
    ) AS PILLAR_SCORES,
    ARRAY_AGG(CASE WHEN SUBSCORE IS NULL THEN PILLAR_CODE END) AS PILLARS_OMITTED,
    COUNT_IF(SUBSCORE IS NOT NULL) AS PILLARS_SCORED,
    -- A score built on one pillar is not the same claim as one built on three.
    -- Surfacing this stops the report implying more certainty than it has.
    CASE
        WHEN COUNT_IF(SUBSCORE IS NOT NULL) = 0 THEN 'NO_DATA'
        WHEN COUNT_IF(SUBSCORE IS NOT NULL) = 1 THEN 'LOW_CONFIDENCE'
        WHEN COUNT_IF(SUBSCORE IS NOT NULL) = 2 THEN 'MODERATE_CONFIDENCE'
        ELSE 'FULL_COVERAGE'
    END AS CONFIDENCE_LEVEL
FROM SCORED
GROUP BY APN;

-- -----------------------------------------------------------------------------
-- Snapshot a parcel's score into history. Called by the analyze entrypoint so
-- every score shown to a user is recorded with the evidence that produced it.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE MART.SP_SNAPSHOT_SCORE(TARGET_APN VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Records a parcel score with its weights and an evidence hash, so a later dispute can be reconstructed exactly.'
AS
$$
BEGIN
    INSERT INTO MART.SCORE_HISTORY
        (APN, COMPOSITE_SCORE, PILLAR_SCORES, WEIGHTS_USED, PILLARS_OMITTED,
         EVIDENCE_HASH, SCORER_VERSION)
    SELECT
        SCORE.APN,
        SCORE.COMPOSITE_SCORE,
        SCORE.PILLAR_SCORES,
        (SELECT OBJECT_AGG(PILLAR_CODE, WEIGHT::VARIANT) FROM MART.REF_SCORE_WEIGHTS),
        SCORE.PILLARS_OMITTED,
        SHA2(TO_VARCHAR(BUNDLE.EVIDENCE), 256),
        'scorer-v1'
    FROM MART.VW_PARCEL_SCORE AS SCORE
    INNER JOIN MART.VW_EVIDENCE_BUNDLE AS BUNDLE ON SCORE.APN = BUNDLE.APN
    WHERE SCORE.APN = :TARGET_APN;

    RETURN 'snapshotted ' || :TARGET_APN;
END;
$$;

GRANT SELECT ON VIEW MART.VW_PARCEL_SCORE TO ROLE IHA_APP;
GRANT SELECT ON TABLE MART.SCORE_HISTORY TO ROLE IHA_APP;
