-- =============================================================================
-- classify_projects.sql
-- Cortex classification of construction and development projects.
--
-- This is the ONLY place an LLM touches the construction pillar, and it produces
-- exactly one thing: a CATEGORY_CODE from a fixed list. Every number that
-- follows comes from MART.REF_PROJECT_TAXONOMY.
--
-- Two properties this design buys, both load-bearing:
--
--   Reproducibility  Temperature 0 and a closed category list mean the same
--                    project classifies identically on every run, so the same
--                    parcel scores identically. A buyer can be told the number
--                    will not drift under them.
--
--   Cost             Classification happens ONCE per project at ingest, not per
--                    user request. A parcel with 40 nearby projects costs zero
--                    Cortex calls to score. This is the single biggest reason
--                    per-lead cost stays in pennies.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;
USE WAREHOUSE IHA_WH_INGEST;

CREATE TABLE IF NOT EXISTS MART.PROJECT_CLASSIFICATION (
    PROJECT_SOURCE VARCHAR NOT NULL,
    PROJECT_ID VARCHAR NOT NULL,
    CATEGORY_CODE VARCHAR NOT NULL,
    CLASSIFIER_CONFIDENCE NUMBER(4, 3),
    CLASSIFIED_TEXT_HASH VARCHAR(64) NOT NULL,   -- reclassify only when the text changes
    MODEL_NAME VARCHAR NOT NULL,
    CLASSIFIED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    PRIMARY KEY (PROJECT_SOURCE, PROJECT_ID)
)
COMMENT = 'Cortex-assigned taxonomy per project. Cached on text hash so a project is classified once, not once per request.';

-- -----------------------------------------------------------------------------
-- Classify only what is new or changed.
--
-- The text-hash comparison is the cost control: re-running this daily over an
-- unchanged project list costs nothing, because nothing matches the WHERE.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE MART.SP_CLASSIFY_PROJECTS()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Classifies unclassified or changed projects into the fixed taxonomy. Idempotent; safe to run on a schedule.'
AS
$$
DECLARE
    model_name VARCHAR;
    rows_classified INTEGER DEFAULT 0;
BEGIN
    -- Model comes from config, never a literal, so a model change is one
    -- reviewed row rather than a scattered edit.
    SELECT MODEL_NAME INTO :model_name
    FROM MART.REF_CORTEX_MODELS WHERE TASK_NAME = 'CLASSIFY_PROJECT';

    -- Tag the work so its credits are attributable in OPS.VW_CORTEX_SPEND.
    ALTER SESSION SET QUERY_TAG = 'iha_pillar=construction;iha_task=classify_projects';

    MERGE INTO MART.PROJECT_CLASSIFICATION AS TGT
    USING (
        WITH PENDING AS (
            SELECT
                PROJ.PROJECT_SOURCE,
                PROJ.PROJECT_ID,
                PROJ.CLASSIFY_TEXT,
                SHA2(PROJ.CLASSIFY_TEXT, 256) AS TEXT_HASH
            FROM STAGE.STG_PROJECTS AS PROJ
            LEFT JOIN MART.PROJECT_CLASSIFICATION AS EXISTING
                ON PROJ.PROJECT_SOURCE = EXISTING.PROJECT_SOURCE
                AND PROJ.PROJECT_ID = EXISTING.PROJECT_ID
            WHERE PROJ.CLASSIFY_TEXT IS NOT NULL
              AND LENGTH(TRIM(PROJ.CLASSIFY_TEXT)) > 3
              AND (
                    EXISTING.PROJECT_ID IS NULL
                    OR EXISTING.CLASSIFIED_TEXT_HASH <> SHA2(PROJ.CLASSIFY_TEXT, 256)
                  )
        )
        SELECT
            PENDING.PROJECT_SOURCE,
            PENDING.PROJECT_ID,
            PENDING.TEXT_HASH,
            -- AI_CLASSIFY against the closed list from the taxonomy table. The
            -- categories are read from config rather than hardcoded here, so
            -- adding a category is a single INSERT and this SQL never changes.
            AI_CLASSIFY(
                PENDING.CLASSIFY_TEXT,
                (SELECT ARRAY_AGG(CATEGORY_CODE) FROM MART.REF_PROJECT_TAXONOMY
                 WHERE CATEGORY_CODE <> 'UNCLASSIFIED')
            ) AS CLASSIFICATION
        FROM PENDING
    ) AS SRC
    ON TGT.PROJECT_SOURCE = SRC.PROJECT_SOURCE AND TGT.PROJECT_ID = SRC.PROJECT_ID
    WHEN MATCHED THEN UPDATE SET
        TGT.CATEGORY_CODE = COALESCE(SRC.CLASSIFICATION:labels[0]::VARCHAR, 'UNCLASSIFIED'),
        TGT.CLASSIFIED_TEXT_HASH = SRC.TEXT_HASH,
        TGT.MODEL_NAME = :model_name,
        TGT.CLASSIFIED_AT = SYSDATE()
    WHEN NOT MATCHED THEN INSERT
        (PROJECT_SOURCE, PROJECT_ID, CATEGORY_CODE, CLASSIFIED_TEXT_HASH, MODEL_NAME)
    VALUES
        (SRC.PROJECT_SOURCE, SRC.PROJECT_ID,
         COALESCE(SRC.CLASSIFICATION:labels[0]::VARCHAR, 'UNCLASSIFIED'),
         SRC.TEXT_HASH, :model_name);

    rows_classified := SQLROWCOUNT;
    ALTER SESSION UNSET QUERY_TAG;

    RETURN 'classified ' || :rows_classified || ' project(s) with ' || :model_name;
END;
$$;

-- -----------------------------------------------------------------------------
-- Classification health. A rising UNCLASSIFIED share means the taxonomy no
-- longer covers what Irvine is building — a signal to add a category, not to
-- let projects quietly score neutral.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW MART.VW_CLASSIFICATION_HEALTH
COMMENT = 'Share of projects that failed classification. A rising share means the taxonomy needs a new category.'
AS
SELECT
    COUNT(*) AS TOTAL_PROJECTS,
    COUNT_IF(CATEGORY_CODE = 'UNCLASSIFIED') AS UNCLASSIFIED_COUNT,
    ROUND(100.0 * COUNT_IF(CATEGORY_CODE = 'UNCLASSIFIED') / NULLIF(COUNT(*), 0), 2) AS UNCLASSIFIED_PCT,
    CASE
        WHEN COUNT(*) = 0 THEN 'SKIP'
        WHEN 100.0 * COUNT_IF(CATEGORY_CODE = 'UNCLASSIFIED') / COUNT(*) > 15 THEN 'FAIL'
        ELSE 'PASS'
    END AS STATUS,
    'Unclassified share above 15% means the taxonomy is missing categories for what is actually being built.' AS DETAIL
FROM MART.PROJECT_CLASSIFICATION;

GRANT SELECT ON TABLE MART.PROJECT_CLASSIFICATION TO ROLE IHA_APP;
GRANT SELECT ON VIEW MART.VW_CLASSIFICATION_HEALTH TO ROLE IHA_ANALYST;
