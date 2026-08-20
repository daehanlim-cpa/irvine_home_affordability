-- =============================================================================
-- proc_ingest_arcgis.sql
-- Registers the paginated ArcGIS reader as a Snowflake Python stored procedure.
--
-- The handler body lives in proc_ingest_arcgis.py so it can be linted and
-- unit-tested as code (see tests/test_ingest.py) rather than reviewed as a
-- string inside DDL. Deploy by staging that file, or paste its contents in
-- place of the IMPORTS clause if you are not using a stage.
--
-- Runs under EAI_GOV_SOURCES: government feeds need no credentials, so this
-- procedure carries no secret grant at all.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA RAW;

CREATE STAGE IF NOT EXISTS RAW.INGEST_CODE
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Handler code for ingest stored procedures. PUT proc_ingest_arcgis.py here before creating the procedure.';

-- Deploy step, run from the repo root:
--   snow stage copy snowflake/10_raw/proc_ingest_arcgis.py @IRVINE_HOME_ANALYSIS.RAW.INGEST_CODE

CREATE OR REPLACE PROCEDURE RAW.SP_INGEST_ARCGIS(
    SOURCE_NAME VARCHAR,
    SERVICE_URL VARCHAR,
    LAYER_ID INTEGER,
    RAW_TABLE VARCHAR,
    PAGE_SIZE INTEGER,
    RATE_LIMIT_RPS FLOAT,
    DAILY_CALL_CAP INTEGER,
    TIMEOUT_SECONDS INTEGER,
    CONTACT_EMAIL VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
IMPORTS = ('@IRVINE_HOME_ANALYSIS.RAW.INGEST_CODE/proc_ingest_arcgis.py')
HANDLER = 'proc_ingest_arcgis.main'
EXTERNAL_ACCESS_INTEGRATIONS = (EAI_GOV_SOURCES)
COMMENT = 'Paginated ArcGIS REST reader. Enforces token-bucket rate limiting, a daily call cap, a circuit breaker, and a robots.txt gate. Idempotent on payload hash.'
EXECUTE AS OWNER;

GRANT USAGE ON PROCEDURE RAW.SP_INGEST_ARCGIS(
    VARCHAR, VARCHAR, INTEGER, VARCHAR, INTEGER, FLOAT, INTEGER, INTEGER, VARCHAR
) TO ROLE IHA_ENGINEER;

-- -----------------------------------------------------------------------------
-- Example invocations, matching ingest/sources.yaml. The registry is the source
-- of truth for these arguments; 80_orch/tasks.sql schedules them.
--
-- CALL RAW.SP_INGEST_ARCGIS(
--     'irvine_address_points',
--     'https://gis.cityofirvine.org/arcgis/rest/services/ParcelClariti/FeatureServer',
--     0, 'RAW.R_IRVINE_ADDRESS_POINTS', 2000, 2.0, 500, 30, 'you@example.com');
-- -----------------------------------------------------------------------------
