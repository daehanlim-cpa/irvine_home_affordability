-- =============================================================================
-- ops_tables.sql
-- The operational control plane: outbound call log, feature flags, audit.
--
-- These tables are what make the cost and compliance claims elsewhere real
-- rather than aspirational. The daily call cap is enforced by counting rows in
-- API_CALL_LOG; the kill switch is a row in FEATURE_FLAGS; a disputed score is
-- reconstructed from CORTEX_AUDIT_LOG.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA OPS;

-- -----------------------------------------------------------------------------
-- Every outbound HTTP call. Read by the ingest procedure before each request to
-- enforce the per-source daily cap, so this table is load-bearing, not telemetry.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS OPS.API_CALL_LOG (
    CALLED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    BATCH_ID VARCHAR(36),
    SOURCE_NAME VARCHAR NOT NULL,
    REQUEST_URL VARCHAR NOT NULL,
    HTTP_STATUS NUMBER(5, 0),
    LATENCY_MS NUMBER(10, 0),
    BYTES_RETURNED NUMBER(12, 0),
    ERROR_MESSAGE VARCHAR
)
COMMENT = 'Every outbound HTTP request. Enforces the per-source daily cap and evidences crawl politeness if a site owner ever asks.';

-- -----------------------------------------------------------------------------
-- Feature flags. The kill switch lives here: an alert flips LIVE_NARRATIVE to
-- FALSE when Cortex spend trips a threshold, and reports degrade to templated
-- summaries within minutes, with no deploy.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS OPS.FEATURE_FLAGS (
    FLAG_NAME VARCHAR NOT NULL PRIMARY KEY,
    FLAG_VALUE BOOLEAN NOT NULL,
    CHANGED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    CHANGED_BY VARCHAR NOT NULL DEFAULT CURRENT_USER(),
    REASON VARCHAR
)
COMMENT = 'Runtime switches. Flipped by cost alerts or by hand; read on every request.';

MERGE INTO OPS.FEATURE_FLAGS AS TGT
USING (
    SELECT *
    FROM
        VALUES
        (
            'LIVE_NARRATIVE', TRUE,
            'Generate narratives with Cortex. When FALSE, reports fall back to templated summaries — degraded, not broken.'
        ),
        (
            'SENTIMENT_PILLAR', TRUE,
            'Include the sentiment pillar. Set FALSE to drop it and redistribute its weight, e.g. if a source must be pulled.'
        ),
        (
            'ACCEPT_NEW_LEADS', TRUE,
            'Accept lead submissions. Set FALSE to close the funnel without taking the site down.')
            AS SRC (FLAG_NAME, FLAG_VALUE, REASON)
) AS SRC
    ON TGT.FLAG_NAME = SRC.FLAG_NAME
WHEN NOT MATCHED THEN
    INSERT (FLAG_NAME, FLAG_VALUE, REASON)
    VALUES (SRC.FLAG_NAME, SRC.FLAG_VALUE, SRC.REASON);

-- -----------------------------------------------------------------------------
-- Cortex audit. Prompt, response, model, and token counts for every call.
--
-- The reason to keep this: if a buyer ever disputes what the report told them,
-- the exact prompt and exact response are recoverable. Without it the answer is
-- "the model said something, we don't know what".
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS OPS.CORTEX_AUDIT_LOG (
    CALLED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    TASK_NAME VARCHAR NOT NULL,
    MODEL_NAME VARCHAR NOT NULL,
    TARGET_KEY VARCHAR,                    -- APN, village, or project id
    PROMPT_HASH VARCHAR(64),
    PROMPT_TEXT VARCHAR,
    RESPONSE_TEXT VARCHAR,
    TOKENS_IN NUMBER(10, 0),
    TOKENS_OUT NUMBER(10, 0),
    QUERY_ID VARCHAR
)
COMMENT = 'Full prompt/response audit for Cortex calls. Retained so any score or narrative can be reconstructed exactly.';

GRANT INSERT ON TABLE OPS.API_CALL_LOG TO ROLE IHA_APP;
GRANT SELECT ON TABLE OPS.FEATURE_FLAGS TO ROLE IHA_APP;
GRANT INSERT ON TABLE OPS.CORTEX_AUDIT_LOG TO ROLE IHA_APP;
