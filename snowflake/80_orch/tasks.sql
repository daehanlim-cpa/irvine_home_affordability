-- =============================================================================
-- tasks.sql
-- Scheduled orchestration.
--
-- Cadence follows how fast each source actually changes, not convenience.
-- Parcels and CFD assignments change with the annual assessment roll; projects
-- move weekly; civic minutes and news arrive daily. Polling a monthly source
-- hourly would spend money to learn nothing.
--
-- All tasks are created SUSPENDED. Scheduling ingestion before the first manual
-- run has been inspected is how a rate-limit breach or a runaway bill happens
-- while nobody is watching.
-- =============================================================================

-- noqa: disable=LT01,LT02
-- Layout rules are disabled for this file only. sqlfluff's Snowflake dialect
-- cannot parse CREATE TASK bodies (the AS <statement> clause, WHEN predicates,
-- and BEGIN...END blocks), so every line inside a task draws a spurious indent
-- finding. All other rules remain active here.

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA OPS;

-- -----------------------------------------------------------------------------
-- Root task: nothing runs unless the ingest budget allows it. Chaining the DAG
-- beneath a cost check means an overspend stops the pipeline rather than being
-- discovered afterwards.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TASK OPS.T_INGEST_ROOT
    WAREHOUSE = IHA_WH_INGEST
    SCHEDULE = 'USING CRON 0 4 * * * America/Los_Angeles'
    COMMENT = 'Daily ingest DAG root, 4am Pacific. Halts the DAG when spend thresholds are already breached.'
AS
    SELECT CASE
        WHEN EXISTS (
            SELECT 1 FROM OPS.VW_SPEND_VS_THRESHOLD
            WHERE IS_BREACHED = TRUE
        )
            THEN SYSTEM$ABORT_SESSION(CURRENT_SESSION())
        ELSE 1
    END;

-- -----------------------------------------------------------------------------
-- Weekly: projects. The construction pillar is the heaviest weight, so this is
-- the feed whose staleness matters most.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TASK OPS.T_INGEST_CIP_PROJECTS
    WAREHOUSE = IHA_WH_INGEST
    AFTER OPS.T_INGEST_ROOT
    -- Previously gated on a stream that was never created, which would have
    -- blocked the whole downstream DAG. Day-of-week alone is sufficient.
    WHEN DAYOFWEEK(CURRENT_DATE()) = 1
    COMMENT = 'Capital improvement projects, weekly (Mondays).'
AS
    CALL RAW.SP_INGEST_ARCGIS(
        'irvine_cip_projects',
        'https://gis.cityofirvine.org/arcgis/rest/services/CIP/FeatureServer',
        0, 'RAW.R_IRVINE_CIP_PROJECTS', 1000, 2.0, 300, 30,
        SYSTEM$GET_SECRET_STRING('OPS.SEC_CRAWLER_CONTACT')
    );

CREATE OR REPLACE TASK OPS.T_INGEST_DEV_PROJECTS
    WAREHOUSE = IHA_WH_INGEST
    AFTER OPS.T_INGEST_ROOT
    COMMENT = 'Development applications and entitlements, weekly.'
AS
    CALL RAW.SP_INGEST_ARCGIS(
        'irvine_development_projects',
        'https://gis.cityofirvine.org/arcgis/rest/services/DevelopmentProjects/FeatureServer',
        0, 'RAW.R_IRVINE_DEV_PROJECTS', 1000, 2.0, 300, 30,
        SYSTEM$GET_SECRET_STRING('OPS.SEC_CRAWLER_CONTACT')
    );

-- -----------------------------------------------------------------------------
-- Monthly: parcels and address points. These follow the assessment roll.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TASK OPS.T_INGEST_PARCELS
    WAREHOUSE = IHA_WH_INGEST
    SCHEDULE = 'USING CRON 0 3 2 * * America/Los_Angeles'
    COMMENT = 'Parcels and CFD assignments, monthly on the 2nd. Aligned to the annual roll release cadence.'
AS
    CALL RAW.SP_INGEST_ARCGIS(
        'irvine_parcels_cfd',
        'https://gis.cityofirvine.org/arcgis/rest/services/ParcelClariti/FeatureServer',
        0, 'RAW.R_IRVINE_PARCELS_CFD', 2000, 2.0, 500, 30,
        SYSTEM$GET_SECRET_STRING('OPS.SEC_CRAWLER_CONTACT')
    );

CREATE OR REPLACE TASK OPS.T_INGEST_ADDRESS_POINTS
    WAREHOUSE = IHA_WH_INGEST
    SCHEDULE = 'USING CRON 30 3 2 * * America/Los_Angeles'
    COMMENT = 'Address points (the geocoder), monthly.'
AS
    CALL RAW.SP_INGEST_ARCGIS(
        'irvine_address_points',
        -- NOT layer 0: that is the parcel polygon layer, and pointing the
        -- geocoder at it loads polygons into the address-point table, after
        -- which every address resolves to NOT_FOUND. The real layer id must be
        -- confirmed against the service directory on first deploy — see
        -- docs/data_sources.md "Outstanding verification".
        'https://gis.cityofirvine.org/arcgis/rest/services/ParcelClariti/FeatureServer',
        1, 'RAW.R_IRVINE_ADDRESS_POINTS', 2000, 2.0, 500, 30,
        SYSTEM$GET_SECRET_STRING('OPS.SEC_CRAWLER_CONTACT')
    );

-- -----------------------------------------------------------------------------
-- Downstream: classify, then refresh sentiment. Both run after ingest so a
-- user request never triggers either.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TASK OPS.T_CLASSIFY_PROJECTS
    WAREHOUSE = IHA_WH_INGEST
    AFTER OPS.T_INGEST_CIP_PROJECTS, OPS.T_INGEST_DEV_PROJECTS
    COMMENT = 'Cortex classification of new or changed projects. Cached on text hash, so unchanged projects cost nothing.'
AS
    CALL MART.SP_CLASSIFY_PROJECTS();

CREATE OR REPLACE TASK OPS.T_REFRESH_SENTIMENT
    WAREHOUSE = IHA_WH_INGEST
    AFTER OPS.T_CLASSIFY_PROJECTS
    COMMENT = 'Daily village sentiment refresh. Caching here is what keeps the sentiment pillar off the per-request path.'
AS
    CALL MART.SP_REFRESH_SENTIMENT();

-- -----------------------------------------------------------------------------
-- Retention. CCPA compliance is a scheduled job, not a promise in a policy
-- document.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TASK OPS.T_ENFORCE_RETENTION
    WAREHOUSE = IHA_WH_XS
    SCHEDULE = 'USING CRON 0 5 * * * America/Los_Angeles'
    COMMENT = 'Purges leads past the retention window and prunes operational logs.'
AS
BEGIN
    -- Leads older than 24 months, and anything with an honoured deletion request.
    DELETE FROM APP.LEADS
    WHERE CREATED_AT < DATEADD('month', -24, SYSDATE())
        OR DELETED_AT IS NOT NULL;

    -- Operational logs are kept long enough to investigate an incident, no longer.
    DELETE FROM OPS.API_CALL_LOG WHERE CALLED_AT < DATEADD('day', -90, SYSDATE());
    DELETE FROM OPS.CORTEX_AUDIT_LOG WHERE CALLED_AT < DATEADD('month', -12, SYSDATE());
END;

-- -----------------------------------------------------------------------------
-- Everything starts suspended, deliberately.
--
-- Resume in this order, only after a manual run of each has been inspected:
--   ALTER TASK OPS.T_REFRESH_SENTIMENT RESUME;
--   ALTER TASK OPS.T_CLASSIFY_PROJECTS RESUME;
--   ALTER TASK OPS.T_INGEST_CIP_PROJECTS RESUME;
--   ALTER TASK OPS.T_INGEST_DEV_PROJECTS RESUME;
--   ALTER TASK OPS.T_INGEST_ROOT RESUME;          -- root last: children first
--   ALTER TASK OPS.T_INGEST_PARCELS RESUME;
--   ALTER TASK OPS.T_INGEST_ADDRESS_POINTS RESUME;
--   ALTER TASK OPS.T_ENFORCE_RETENTION RESUME;
-- -----------------------------------------------------------------------------
