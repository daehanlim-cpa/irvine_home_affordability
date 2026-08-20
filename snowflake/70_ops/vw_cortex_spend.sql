-- =============================================================================
-- vw_cortex_spend.sql
-- Per-pillar Cortex cost attribution and the circuit breaker that acts on it.
--
-- Resource monitors watch warehouse credits and cannot see Cortex, which bills
-- as serverless AI services. This is the only view of that spend, and query tags
-- are what make it attributable: without them you learn the bill grew but not
-- which pillar grew it.
--
-- CORTEX_AI_FUNCTIONS_USAGE_HISTORY has roughly five minutes of latency. Do not
-- write checks that read it immediately after a query and expect rows.
-- =============================================================================

USE ROLE IHA_ADMIN;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA OPS;

CREATE OR REPLACE VIEW OPS.VW_CORTEX_SPEND
COMMENT = 'Cortex credit consumption by pillar and task, derived from query tags. The only visibility into serverless AI spend.'
AS
SELECT
    DATE_TRUNC('hour', AI_USE.START_TIME) AS USAGE_HOUR,
    AI_USE.FUNCTION_NAME,
    AI_USE.MODEL_NAME,
    -- Query tags are set as 'iha_pillar=x;iha_task=y' by every procedure that
    -- calls Cortex, which is what makes per-pillar attribution possible at all.
    COALESCE(REGEXP_SUBSTR(QRY.QUERY_TAG, 'iha_pillar=([a-z_]+)', 1, 1, 'e', 1), 'untagged') AS PILLAR,
    COALESCE(REGEXP_SUBSTR(QRY.QUERY_TAG, 'iha_task=([a-z_]+)', 1, 1, 'e', 1), 'untagged') AS TASK_NAME,
    SUM(AI_USE.TOKENS) AS TOKENS,
    SUM(AI_USE.TOKEN_CREDITS) AS CREDITS,
    COUNT(*) AS CALL_COUNT
FROM SNOWFLAKE.ACCOUNT_AI_USE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY AS AI_USE
LEFT JOIN SNOWFLAKE.ACCOUNT_AI_USE.QUERY_HISTORY AS QRY
    ON AI_USE.QUERY_ID = QRY.QUERY_ID
WHERE AI_USE.START_TIME >= DATEADD('day', -30, SYSDATE())
GROUP BY 1, 2, 3, 4, 5;

-- -----------------------------------------------------------------------------
-- Spend against the configured thresholds. The alert below reads this.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW OPS.VW_SPEND_VS_THRESHOLD
COMMENT = 'Current Cortex spend against OPS.COST_THRESHOLDS. Drives the circuit breaker.'
AS
WITH WINDOWS AS (
    SELECT
        THRESHOLD_NAME,
        CREDIT_LIMIT,
        WINDOW_HOURS,
        ACTION
    FROM OPS.COST_THRESHOLDS
    WHERE WINDOW_HOURS > 0
),

SPEND AS (
    SELECT
        WINDOWS.THRESHOLD_NAME,
        WINDOWS.CREDIT_LIMIT,
        WINDOWS.WINDOW_HOURS,
        WINDOWS.ACTION,
        COALESCE(SUM(AI_USE.TOKEN_CREDITS), 0) AS CREDITS_USED
    FROM WINDOWS
    LEFT JOIN SNOWFLAKE.ACCOUNT_AI_USE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY AS AI_USE
        ON AI_USE.START_TIME >= DATEADD('hour', -1 * WINDOWS.WINDOW_HOURS, SYSDATE())
    GROUP BY 1, 2, 3, 4
)

SELECT
    THRESHOLD_NAME,
    CREDIT_LIMIT,
    WINDOW_HOURS,
    ACTION,
    ROUND(CREDITS_USED, 4) AS CREDITS_USED,
    ROUND(100.0 * CREDITS_USED / NULLIF(CREDIT_LIMIT, 0), 1) AS PCT_OF_LIMIT,
    CREDITS_USED >= CREDIT_LIMIT AS IS_BREACHED
FROM SPEND;

-- -----------------------------------------------------------------------------
-- The circuit breaker. This is the control that actually saves money, because
-- it acts in minutes without anyone being awake.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE ALERT OPS.ALERT_CORTEX_SPEND_BREACH
    WAREHOUSE = IHA_WH_XS
    SCHEDULE = '10 MINUTE'
    IF (EXISTS (
        SELECT 1 FROM OPS.VW_SPEND_VS_THRESHOLD
        WHERE IS_BREACHED = TRUE AND ACTION = 'DISABLE_LIVE_NARRATIVE'
    ))
    THEN
        UPDATE OPS.FEATURE_FLAGS
        SET FLAG_VALUE = FALSE,
            CHANGED_AT = SYSDATE(),
            CHANGED_BY = 'ALERT_CORTEX_SPEND_BREACH',
            REASON = 'Cortex spend threshold breached; narratives degraded to templated summaries. Investigate OPS.VW_CORTEX_SPEND, then re-enable manually.'
        WHERE FLAG_NAME = 'LIVE_NARRATIVE' AND FLAG_VALUE = TRUE;

-- Deliberately created suspended: enabling a breaker before the thresholds have
-- been reviewed against real traffic would be its own kind of surprise.
-- Enable with: ALTER ALERT OPS.ALERT_CORTEX_SPEND_BREACH RESUME;

GRANT SELECT ON VIEW OPS.VW_CORTEX_SPEND TO ROLE IHA_ANALYST;
GRANT SELECT ON VIEW OPS.VW_SPEND_VS_THRESHOLD TO ROLE IHA_APP;
