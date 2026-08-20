-- =============================================================================
-- stg_sentiment_documents.sql
-- One shape for every sentiment source: civic minutes, news, forum posts.
--
-- Unifying here means the sentiment pipeline is written once and a new source
-- becomes another UNION branch rather than another scoring path.
--
-- PII: no author, speaker, or commenter names cross this boundary. Granicus
-- minutes name the residents who spoke; news carries bylines; forums carry
-- usernames. None of it is needed to score how a neighbourhood is discussed, and
-- storing it would turn a housing-analysis product into a database of people's
-- opinions attached to their names. Text, URL, date, and village only.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA STAGE;

CREATE OR REPLACE VIEW STAGE.STG_SENTIMENT_DOCUMENTS
COMMENT = 'Unified sentiment document shape across civic, journalism, and forum sources. Author identities are deliberately absent.'
AS
WITH CIVIC AS (
    SELECT
        RAW_SRC._SOURCE_NAME AS SOURCE_NAME,
        DOC.VALUE:statement_text::VARCHAR AS DOCUMENT_TEXT,
        DOC.VALUE:url::VARCHAR AS DOCUMENT_URL,
        TRY_TO_TIMESTAMP_NTZ(DOC.VALUE:meeting_date::VARCHAR) AS PUBLISHED_AT,
        UPPER(TRIM(DOC.VALUE:village::VARCHAR)) AS VILLAGE_RAW
    FROM RAW.R_CIVIC_MINUTES AS RAW_SRC,
        LATERAL FLATTEN(INPUT => RAW_SRC._PAYLOAD:documents) AS DOC
),

NEWS AS (
    SELECT
        RAW_SRC._SOURCE_NAME AS SOURCE_NAME,
        -- Headline plus summary only. Full article text is neither stored nor
        -- redistributed; the report links back to the publisher.
        TRIM(COALESCE(DOC.VALUE:title::VARCHAR, '') || '. ' || COALESCE(DOC.VALUE:summary::VARCHAR, '')) AS DOCUMENT_TEXT,
        DOC.VALUE:link::VARCHAR AS DOCUMENT_URL,
        TRY_TO_TIMESTAMP_NTZ(DOC.VALUE:published::VARCHAR) AS PUBLISHED_AT,
        UPPER(TRIM(DOC.VALUE:village::VARCHAR)) AS VILLAGE_RAW
    FROM RAW.R_NEWS_ARTICLES AS RAW_SRC,
        LATERAL FLATTEN(INPUT => RAW_SRC._PAYLOAD:items) AS DOC
),

FORUM AS (
    SELECT
        RAW_SRC._SOURCE_NAME AS SOURCE_NAME,
        DOC.VALUE:post_text::VARCHAR AS DOCUMENT_TEXT,
        DOC.VALUE:thread_url::VARCHAR AS DOCUMENT_URL,
        TRY_TO_TIMESTAMP_NTZ(DOC.VALUE:posted_at::VARCHAR) AS PUBLISHED_AT,
        UPPER(TRIM(DOC.VALUE:village::VARCHAR)) AS VILLAGE_RAW
    FROM RAW.R_FORUM_POSTS AS RAW_SRC,
        LATERAL FLATTEN(INPUT => RAW_SRC._PAYLOAD:posts) AS DOC
),

COMBINED AS (
    SELECT * FROM CIVIC
    UNION ALL
    SELECT * FROM NEWS
    UNION ALL
    SELECT * FROM FORUM
),

VILLAGE_LOOKUP AS (
    SELECT
        VIL.VILLAGE_CODE,
        UPPER(TRIM(ALIAS.VALUE::VARCHAR)) AS ALIAS_UPPER
    FROM MART.DIM_VILLAGE AS VIL,
        LATERAL FLATTEN(INPUT => VIL.ALIASES) AS ALIAS
)

SELECT
    -- Stable id across runs so re-ingesting the same document does not re-score
    -- it. Cortex calls are the expensive part; this is what stops them repeating.
    SHA2(COMBINED.SOURCE_NAME || '|' || COALESCE(COMBINED.DOCUMENT_URL, '') || '|' || COMBINED.DOCUMENT_TEXT, 256) AS DOCUMENT_ID,
    COMBINED.SOURCE_NAME,
    COALESCE(VIL.VILLAGE_CODE, 'UNKNOWN') AS VILLAGE_CODE,
    COMBINED.DOCUMENT_URL,
    COMBINED.PUBLISHED_AT,
    COMBINED.DOCUMENT_TEXT
FROM COMBINED
LEFT JOIN VILLAGE_LOOKUP AS VIL
    ON COMBINED.VILLAGE_RAW = VIL.ALIAS_UPPER
WHERE
    COMBINED.DOCUMENT_TEXT IS NOT NULL
    AND LENGTH(TRIM(COMBINED.DOCUMENT_TEXT)) > 40
    -- A document that cannot be tied to a village cannot inform a village score.
    AND VIL.VILLAGE_CODE IS NOT NULL;
