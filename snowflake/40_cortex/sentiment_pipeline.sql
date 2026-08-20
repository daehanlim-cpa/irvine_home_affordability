-- =============================================================================
-- sentiment_pipeline.sql
-- The 10% sentiment pillar: AI_FILTER -> quality screen -> AI_SENTIMENT ->
-- AI_AGG, blended by source credibility and cached per village per day.
--
-- Cached DAILY, per village, never per request. A user asking about a Woodbridge
-- address triggers zero sentiment Cortex calls; they read a row computed once
-- that morning across all of Woodbridge. Without this the pillar would dominate
-- per-request cost for the least reliable 10% of the score.
--
-- Two screens run before anything is scored:
--
--   Relevance   AI_FILTER drops documents not about living conditions in an
--               identifiable Irvine village. Forums are mostly off-topic.
--
--   Quality     Documents referencing protected characteristics are excluded
--               from scoring and logged. Neighbourhood forums carry prejudiced
--               content, and a "neighbourhood quality" score must not launder
--               it into a number. Exclusions are auditable, not silent.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;
USE WAREHOUSE IHA_WH_INGEST;

CREATE TABLE IF NOT EXISTS MART.SENTIMENT_DOCUMENT (
    DOCUMENT_ID VARCHAR(64) NOT NULL PRIMARY KEY,   -- hash of source + url + text
    SOURCE_NAME VARCHAR NOT NULL,
    VILLAGE_CODE VARCHAR NOT NULL,
    DOCUMENT_URL VARCHAR,
    PUBLISHED_AT TIMESTAMP_NTZ,
    DOCUMENT_TEXT VARCHAR,
    IS_RELEVANT BOOLEAN,
    EXCLUSION_REASON VARCHAR,                              -- NULL when scored
    SENTIMENT_SCORE NUMBER(4, 3),                         -- -1..1
    MODEL_NAME VARCHAR,
    PROCESSED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE()
)
COMMENT = 'One row per sentiment document. Author names are never stored. EXCLUSION_REASON records why a document was dropped, so screening is auditable.';

-- -----------------------------------------------------------------------------
-- Daily rollup per village. This is what the scorer reads.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS MART.FCT_SENTIMENT_VILLAGE (
    VILLAGE_CODE VARCHAR NOT NULL,
    AS_OF_DATE DATE NOT NULL,
    SUBSCORE NUMBER(6, 2),                        -- 0..100, NULL when insufficient
    WEIGHTED_SENTIMENT NUMBER(5, 4),                       -- -1..1 before rescaling
    DOCUMENT_COUNT NUMBER(8, 0) NOT NULL,
    SOURCE_COUNT NUMBER(4, 0) NOT NULL,
    EXCLUDED_COUNT NUMBER(8, 0) NOT NULL,
    TOP_THEMES VARCHAR,                             -- AI_AGG summary, descriptive only
    DATA_STATUS VARCHAR NOT NULL,              -- SCORED | INSUFFICIENT_DATA
    COMPUTED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    PRIMARY KEY (VILLAGE_CODE, AS_OF_DATE)
)
COMMENT = 'Daily village sentiment. Cached: a user request reads this, never triggers Cortex. INSUFFICIENT_DATA redistributes the pillar weight rather than reporting noise.';

CREATE OR REPLACE PROCEDURE MART.SP_REFRESH_SENTIMENT()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Daily sentiment refresh: relevance filter, protected-class screen, per-document scoring, credibility-weighted village rollup.'
AS
$$
DECLARE
    filter_model VARCHAR;
    score_model VARCHAR;
    theme_model VARCHAR;
    min_docs INTEGER;
    villages_scored INTEGER DEFAULT 0;
BEGIN
    SELECT MODEL_NAME INTO :filter_model FROM MART.REF_CORTEX_MODELS WHERE TASK_NAME = 'SENTIMENT_FILTER';
    SELECT MODEL_NAME INTO :score_model  FROM MART.REF_CORTEX_MODELS WHERE TASK_NAME = 'SENTIMENT_SCORE';
    SELECT MODEL_NAME INTO :theme_model  FROM MART.REF_CORTEX_MODELS WHERE TASK_NAME = 'SENTIMENT_THEMES';
    SELECT PARAM_VALUE INTO :min_docs FROM MART.REF_SCORING_PARAMS WHERE PARAM_NAME = 'SENTIMENT_MIN_DOCUMENTS';

    ALTER SESSION SET QUERY_TAG = 'iha_pillar=sentiment;iha_task=refresh_sentiment';

    -- --- 1. relevance + quality screen, scored only for new documents --------
    MERGE INTO MART.SENTIMENT_DOCUMENT AS TGT
    USING (
        SELECT
            RAW_DOC.DOCUMENT_ID,
            RAW_DOC.SOURCE_NAME,
            RAW_DOC.VILLAGE_CODE,
            RAW_DOC.DOCUMENT_URL,
            RAW_DOC.PUBLISHED_AT,
            RAW_DOC.DOCUMENT_TEXT,
            AI_FILTER(
                'Is this text about living conditions, development, traffic, noise, schools, '
                || 'or community life in a specific Irvine, California neighbourhood? Text: '
                || RAW_DOC.DOCUMENT_TEXT
            ) AS IS_RELEVANT,
            -- Protected-class screen. Excluded content is recorded, not deleted:
            -- an unexplained gap in the audit trail is its own problem.
            AI_CLASSIFY(
                RAW_DOC.DOCUMENT_TEXT,
                ['REFERENCES_PROTECTED_CHARACTERISTICS', 'NO_PROTECTED_CHARACTERISTICS']
            ):labels[0]::VARCHAR AS PROTECTED_CLASS_FLAG
        FROM STAGE.STG_SENTIMENT_DOCUMENTS AS RAW_DOC
        LEFT JOIN MART.SENTIMENT_DOCUMENT AS EXISTING
            ON RAW_DOC.DOCUMENT_ID = EXISTING.DOCUMENT_ID
        WHERE EXISTING.DOCUMENT_ID IS NULL
          AND RAW_DOC.DOCUMENT_TEXT IS NOT NULL
          AND LENGTH(TRIM(RAW_DOC.DOCUMENT_TEXT)) > 40
    ) AS SRC
    ON TGT.DOCUMENT_ID = SRC.DOCUMENT_ID
    WHEN NOT MATCHED THEN INSERT
        (DOCUMENT_ID, SOURCE_NAME, VILLAGE_CODE, DOCUMENT_URL, PUBLISHED_AT,
         DOCUMENT_TEXT, IS_RELEVANT, EXCLUSION_REASON, SENTIMENT_SCORE, MODEL_NAME)
    VALUES
        (SRC.DOCUMENT_ID, SRC.SOURCE_NAME, SRC.VILLAGE_CODE, SRC.DOCUMENT_URL,
         SRC.PUBLISHED_AT, SRC.DOCUMENT_TEXT, SRC.IS_RELEVANT,
         CASE
             WHEN SRC.PROTECTED_CLASS_FLAG = 'REFERENCES_PROTECTED_CHARACTERISTICS'
                 THEN 'protected_characteristics_screen'
             WHEN NOT SRC.IS_RELEVANT THEN 'not_relevant_to_irvine_housing'
         END,
         NULL, :filter_model);

    -- --- 2. score the documents that survived both screens -------------------
    UPDATE MART.SENTIMENT_DOCUMENT
    SET SENTIMENT_SCORE = AI_SENTIMENT(DOCUMENT_TEXT):categories[0]:sentiment::NUMBER(4, 3),
        MODEL_NAME = :score_model,
        PROCESSED_AT = SYSDATE()
    WHERE SENTIMENT_SCORE IS NULL
      AND EXCLUSION_REASON IS NULL
      AND IS_RELEVANT = TRUE;

    -- --- 3. credibility-weighted village rollup ------------------------------
    MERGE INTO MART.FCT_SENTIMENT_VILLAGE AS TGT
    USING (
        WITH SCORED AS (
            SELECT
                DOC.VILLAGE_CODE,
                DOC.SOURCE_NAME,
                DOC.SENTIMENT_SCORE,
                DOC.DOCUMENT_TEXT,
                SRC_REF.CREDIBILITY_WEIGHT
            FROM MART.SENTIMENT_DOCUMENT AS DOC
            INNER JOIN MART.REF_SENTIMENT_SOURCES AS SRC_REF
                ON DOC.SOURCE_NAME = SRC_REF.SOURCE_NAME
            WHERE DOC.SENTIMENT_SCORE IS NOT NULL
              AND DOC.EXCLUSION_REASON IS NULL
              AND SRC_REF.IS_ENABLED = TRUE
              -- Sentiment ages badly: a complaint about construction that
              -- finished two years ago says nothing about buying today.
              AND DOC.PUBLISHED_AT >= DATEADD('month', -18, SYSDATE())
        ),

        EXCLUDED AS (
            SELECT VILLAGE_CODE, COUNT(*) AS EXCLUDED_COUNT
            FROM MART.SENTIMENT_DOCUMENT
            WHERE EXCLUSION_REASON IS NOT NULL
            GROUP BY VILLAGE_CODE
        ),

        ROLLED AS (
            SELECT
                SCORED.VILLAGE_CODE,
                -- Weighted mean: a Planning Commission transcript counts for
                -- more than an anonymous comment, and the blend renormalises
                -- over whichever sources actually returned documents.
                SUM(SCORED.SENTIMENT_SCORE * SCORED.CREDIBILITY_WEIGHT)
                    / NULLIF(SUM(SCORED.CREDIBILITY_WEIGHT), 0) AS WEIGHTED_SENTIMENT,
                COUNT(*) AS DOCUMENT_COUNT,
                COUNT(DISTINCT SCORED.SOURCE_NAME) AS SOURCE_COUNT,
                AI_AGG(
                    SCORED.DOCUMENT_TEXT,
                    'Summarise the recurring themes residents raise about this neighbourhood in three '
                    || 'short sentences. Describe only what the documents say. Do not rate, score, or '
                    || 'recommend anything.'
                ) AS TOP_THEMES
            FROM SCORED
            GROUP BY SCORED.VILLAGE_CODE
        )

        SELECT
            ROLLED.VILLAGE_CODE,
            CURRENT_DATE() AS AS_OF_DATE,
            ROLLED.WEIGHTED_SENTIMENT,
            ROLLED.DOCUMENT_COUNT,
            ROLLED.SOURCE_COUNT,
            COALESCE(EXCLUDED.EXCLUDED_COUNT, 0) AS EXCLUDED_COUNT,
            ROLLED.TOP_THEMES,
            CASE WHEN ROLLED.DOCUMENT_COUNT >= :min_docs THEN 'SCORED' ELSE 'INSUFFICIENT_DATA' END AS DATA_STATUS,
            -- Rescale -1..1 to 0..100 only when there is enough evidence to
            -- justify a number at all.
            CASE
                WHEN ROLLED.DOCUMENT_COUNT >= :min_docs
                    THEN ROUND((ROLLED.WEIGHTED_SENTIMENT + 1) * 50, 2)
            END AS SUBSCORE
        FROM ROLLED
        LEFT JOIN EXCLUDED ON ROLLED.VILLAGE_CODE = EXCLUDED.VILLAGE_CODE
    ) AS SRC
    ON TGT.VILLAGE_CODE = SRC.VILLAGE_CODE AND TGT.AS_OF_DATE = SRC.AS_OF_DATE
    WHEN MATCHED THEN UPDATE SET
        TGT.SUBSCORE = SRC.SUBSCORE, TGT.WEIGHTED_SENTIMENT = SRC.WEIGHTED_SENTIMENT,
        TGT.DOCUMENT_COUNT = SRC.DOCUMENT_COUNT, TGT.SOURCE_COUNT = SRC.SOURCE_COUNT,
        TGT.EXCLUDED_COUNT = SRC.EXCLUDED_COUNT, TGT.TOP_THEMES = SRC.TOP_THEMES,
        TGT.DATA_STATUS = SRC.DATA_STATUS, TGT.COMPUTED_AT = SYSDATE()
    WHEN NOT MATCHED THEN INSERT
        (VILLAGE_CODE, AS_OF_DATE, SUBSCORE, WEIGHTED_SENTIMENT, DOCUMENT_COUNT,
         SOURCE_COUNT, EXCLUDED_COUNT, TOP_THEMES, DATA_STATUS)
    VALUES
        (SRC.VILLAGE_CODE, SRC.AS_OF_DATE, SRC.SUBSCORE, SRC.WEIGHTED_SENTIMENT,
         SRC.DOCUMENT_COUNT, SRC.SOURCE_COUNT, SRC.EXCLUDED_COUNT, SRC.TOP_THEMES, SRC.DATA_STATUS);

    villages_scored := SQLROWCOUNT;
    ALTER SESSION UNSET QUERY_TAG;

    RETURN 'refreshed sentiment for ' || :villages_scored || ' village(s)';
END;
$$;

GRANT SELECT ON TABLE MART.FCT_SENTIMENT_VILLAGE TO ROLE IHA_APP;
GRANT SELECT ON TABLE MART.SENTIMENT_DOCUMENT TO ROLE IHA_ANALYST;
