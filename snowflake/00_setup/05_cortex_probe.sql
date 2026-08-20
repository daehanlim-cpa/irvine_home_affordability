-- =============================================================================
-- 05_cortex_probe.sql
-- RUN THIS FIRST, BEFORE ANYTHING DEPENDS ON CORTEX.
--
-- Reports, per capability, whether it actually resolves in this account and
-- region. Cortex function availability is region-gated, Data Metric Functions
-- need Enterprise Edition, and CORTEX_MODELS_ALLOWLIST is deprecated — none of
-- which is discoverable from documentation alone. This probe answers it for
-- YOUR account.
--
-- Emits one row per capability with STATUS in (PASS, FAIL, SKIP).
-- scripts/verify.sh greps for FAIL, so keep that token exact.
--
-- Cost: a handful of single-token Cortex calls. Cents, not dollars.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA OPS;
USE WAREHOUSE IHA_WH_XS;

CREATE TABLE IF NOT EXISTS OPS.CAPABILITY_PROBE (
    PROBED_AT TIMESTAMP_NTZ DEFAULT SYSDATE(),
    CHECK_NAME VARCHAR,
    STATUS VARCHAR,
    DETAIL VARCHAR
);

DELETE FROM OPS.CAPABILITY_PROBE
WHERE PROBED_AT < DATEADD('day', -90, SYSDATE());

EXECUTE IMMEDIATE $$
DECLARE
    RUN_ID VARCHAR DEFAULT UUID_STRING();
BEGIN
    -- ---------------------------------------------------------------- context
    BEGIN
        LET ctx VARCHAR := (
            SELECT 'region=' || CURRENT_REGION()
                || ' account=' || CURRENT_ACCOUNT()
                || ' version=' || CURRENT_VERSION()
        );
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('context', 'PASS', :ctx);
    EXCEPTION WHEN OTHER THEN
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('context', 'FAIL', :SQLERRM);
    END;

    -- ------------------------------------------------------------ AI_COMPLETE
    BEGIN
        LET r VARCHAR := (SELECT LEFT(AI_COMPLETE('claude-4-sonnet', 'Reply with the single word OK.'), 40));
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('AI_COMPLETE', 'PASS', :r);
    EXCEPTION WHEN OTHER THEN
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('AI_COMPLETE', 'FAIL', :SQLERRM);
    END;

    -- ------------------------------------------------------------ AI_CLASSIFY
    -- The single most important function in this platform: it assigns the
    -- project taxonomy that the deterministic severity lookup keys on.
    BEGIN
        LET r VARCHAR := (
            SELECT TO_VARCHAR(
                AI_CLASSIFY('Widening of Culver Drive between Walnut and Irvine Center Drive',
                            ['ROAD_WIDENING', 'SCHOOL_NEW', 'PARK_IMPROVEMENT'])
            )
        );
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('AI_CLASSIFY', 'PASS', :r);
    EXCEPTION WHEN OTHER THEN
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('AI_CLASSIFY', 'FAIL', :SQLERRM);
    END;

    -- ----------------------------------------------------------- AI_SENTIMENT
    BEGIN
        LET r VARCHAR := (
            SELECT TO_VARCHAR(AI_SENTIMENT('The construction noise on Sand Canyon has been relentless for two years.'))
        );
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('AI_SENTIMENT', 'PASS', :r);
    EXCEPTION WHEN OTHER THEN
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('AI_SENTIMENT', 'FAIL', :SQLERRM);
    END;

    -- -------------------------------------------------------------- AI_FILTER
    BEGIN
        LET r VARCHAR := (SELECT TO_VARCHAR(AI_FILTER('Is this text about a residential neighbourhood? Text: Woodbridge lake homes')));
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('AI_FILTER', 'PASS', :r);
    EXCEPTION WHEN OTHER THEN
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('AI_FILTER', 'FAIL', :SQLERRM);
    END;

    -- --------------------------------------------------------------- AI_EMBED
    BEGIN
        LET r INTEGER := (SELECT ARRAY_SIZE(AI_EMBED('snowflake-arctic-embed-m-v1.5', 'Portola Springs')));
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('AI_EMBED', 'PASS', 'dimensions=' || :r);
    EXCEPTION WHEN OTHER THEN
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('AI_EMBED', 'FAIL', :SQLERRM);
    END;

    -- ------------------------------------------------------------- geospatial
    -- ST_DWITHIN drives every proximity join in the construction pillar.
    BEGIN
        LET r VARCHAR := (
            SELECT TO_VARCHAR(ST_DWITHIN(
                TO_GEOGRAPHY('POINT(-117.7947 33.6846)'),   -- Irvine Civic Center
                TO_GEOGRAPHY('POINT(-117.7500 33.7000)'),
                5000
            ))
        );
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('geospatial', 'PASS', 'ST_DWITHIN=' || :r);
    EXCEPTION WHEN OTHER THEN
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('geospatial', 'FAIL', :SQLERRM);
    END;

    -- ------------------------------------------- Data Metric Functions (Ent.)
    -- Freshness monitoring depends on these. On Standard Edition they are
    -- absent and OPS falls back to a scheduled staleness task instead — which
    -- is why this reports SKIP, not FAIL.
    BEGIN
        -- Built-in DMFs live in SNOWFLAKE.CORE and are NOT listed in
        -- INFORMATION_SCHEMA.FUNCTIONS, so querying that view reports every
        -- account as Standard. SHOW + RESULT_SCAN is the reliable probe.
        SHOW DATA METRIC FUNCTIONS IN SCHEMA SNOWFLAKE.CORE;
        LET n INTEGER := (SELECT COUNT(*) FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
        IF (n > 0) THEN
            INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
            VALUES ('data_metric_functions', 'PASS', 'Enterprise DMFs available (' || :n || ' built-ins visible)');
        ELSE
            INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
            VALUES ('data_metric_functions', 'SKIP', 'No built-in DMFs visible — likely Standard Edition. OPS freshness task will be used instead. See CLAUDE.md > Learnings.');
        END IF;
    EXCEPTION WHEN OTHER THEN
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('data_metric_functions', 'SKIP', 'Could not enumerate DMFs: ' || :SQLERRM);
    END;

    -- --------------------------------------------- Cortex cost telemetry view
    -- Without this, per-pillar cost attribution is impossible and the budget
    -- controls are blind. Note ~5min latency before rows appear.
    BEGIN
        LET n INTEGER := (
            SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
            WHERE START_TIME > DATEADD('day', -7, SYSDATE())
        );
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('cortex_usage_history', 'PASS', 'readable; ' || :n || ' rows in last 7d');
    EXCEPTION WHEN OTHER THEN
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('cortex_usage_history', 'FAIL',
                'Cannot read CORTEX_AI_FUNCTIONS_USAGE_HISTORY — cost attribution and budget alerts will not work. Grant SNOWFLAKE.USAGE_VIEWER. ' || :SQLERRM);
    END;

    -- --------------------------------------------- external access integration
    BEGIN
        LET n INTEGER := (
            SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.INTEGRATIONS
            WHERE INTEGRATION_NAME IN ('EAI_GOV_SOURCES', 'EAI_SENTIMENT_SOURCES') AND DELETED IS NULL
        );
        IF (n >= 2) THEN
            INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
            VALUES ('external_access', 'PASS', 'both integrations present');
        ELSE
            INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
            VALUES ('external_access', 'FAIL', 'expected 2 integrations, found ' || :n || '. Run 04_external_access.sql.');
        END IF;
    EXCEPTION WHEN OTHER THEN
        INSERT INTO OPS.CAPABILITY_PROBE (CHECK_NAME, STATUS, DETAIL)
        VALUES ('external_access', 'SKIP', 'ACCOUNT_USAGE.INTEGRATIONS not readable: ' || :SQLERRM);
    END;

    RETURN 'probe complete';
END;
$$;

-- Result. Any FAIL row blocks the gate in scripts/verify.sh.
SELECT
    CHECK_NAME,
    STATUS,
    DETAIL
FROM OPS.CAPABILITY_PROBE
WHERE PROBED_AT >= DATEADD('minute', -10, SYSDATE())
ORDER BY
    CASE STATUS WHEN 'FAIL' THEN 1 WHEN 'SKIP' THEN 2 ELSE 3 END,
    CHECK_NAME;
