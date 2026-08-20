-- =============================================================================
-- ref_cortex_models.sql
-- Pinned model names per task.
--
-- CORTEX_MODELS_ALLOWLIST is deprecated, so model governance is two things:
-- role grants on SNOWFLAKE.CORTEX_USER (see 00_setup/02_roles_grants.sql), and
-- this table. Every Cortex call reads its model name from here rather than
-- hardcoding one, so swapping a model is a reviewed, single-row change with a
-- date attached — not a scattered find-and-replace.
--
-- This matters more than it looks: a silent model change alters every score the
-- platform produces. Making it a diff means the change is visible.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;

CREATE TABLE IF NOT EXISTS MART.REF_CORTEX_MODELS (
    TASK_NAME VARCHAR NOT NULL PRIMARY KEY,
    MODEL_NAME VARCHAR NOT NULL,
    MAX_TOKENS NUMBER(8, 0),
    TEMPERATURE NUMBER(3, 2),
    RATIONALE VARCHAR,
    PINNED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE()
)
COMMENT = 'Pinned Cortex model per task. Changing a model changes every score, so it is a reviewed single-row edit.';

MERGE INTO MART.REF_CORTEX_MODELS AS TGT
USING (
    SELECT *
    FROM
        VALUES
        (
            'CLASSIFY_PROJECT', 'claude-4-sonnet', 512, 0.00,
            'Assigns the project taxonomy that the severity lookup keys on. Temperature 0 because the same project must classify identically on every run — score reproducibility depends on it.'
        ),
        (
            'SENTIMENT_FILTER', 'claude-4-sonnet', 256, 0.00,
            'AI_FILTER relevance gate on sentiment documents. Deterministic.'
        ),
        (
            'SENTIMENT_SCORE', 'claude-4-sonnet', 256, 0.00,
            'Per-document sentiment. Deterministic.'
        ),
        (
            'SENTIMENT_THEMES', 'claude-4-sonnet', 1024, 0.20,
            'AI_AGG theme summarisation per village. Slight temperature aids readable prose; output is descriptive text, never a number.'
        ),
        (
            'NARRATIVE', 'claude-4-5-sonnet', 2048, 0.30,
            'The buyer-facing brief. Strictly grounded in the evidence bundle. Modest temperature for readable prose; every figure it cites must already exist in the bundle, which AI Observability groundedness verifies.'
        ),
        (
            'EMBED_DOCUMENTS', 'snowflake-arctic-embed-m-v1.5', NULL, NULL,
            'Embeddings backing the Cortex Search service over civic minutes and news.')
            AS SRC (TASK_NAME, MODEL_NAME, MAX_TOKENS, TEMPERATURE, RATIONALE)
) AS SRC
    ON TGT.TASK_NAME = SRC.TASK_NAME
WHEN MATCHED THEN
    UPDATE SET
        TGT.MODEL_NAME = SRC.MODEL_NAME, TGT.MAX_TOKENS = SRC.MAX_TOKENS,
        TGT.TEMPERATURE = SRC.TEMPERATURE, TGT.RATIONALE = SRC.RATIONALE,
        TGT.PINNED_AT = SYSDATE()
WHEN NOT MATCHED THEN
    INSERT (TASK_NAME, MODEL_NAME, MAX_TOKENS, TEMPERATURE, RATIONALE)
    VALUES (SRC.TASK_NAME, SRC.MODEL_NAME, SRC.MAX_TOKENS, SRC.TEMPERATURE, SRC.RATIONALE);

GRANT SELECT ON TABLE MART.REF_CORTEX_MODELS TO ROLE IHA_APP;
