-- =============================================================================
-- 07_budgets_resource_monitors.sql
-- Cost controls. Three independent layers, because any one of them can be
-- circumvented by a mistake elsewhere.
--
--   Layer 1  Resource monitors  — hard credit ceiling on warehouse compute.
--                                 Suspends. Blunt but unbypassable.
--   Layer 2  Budget             — spend tracking with notification on the
--                                 serverless/AI side that resource monitors do
--                                 NOT cover. Cortex is serverless: a resource
--                                 monitor on a warehouse will not stop it.
--   Layer 3  Alert -> kill switch — flips OPS.FEATURE_FLAGS to degrade
--                                 narrative generation to templated summaries
--                                 when daily Cortex credits breach a threshold.
--                                 This is the layer that actually saves you,
--                                 because it acts in minutes without a deploy.
--
-- Layer 2 is the one people skip, and it is the one that matters: a documented
-- case exists of a single Cortex query costing $5K. A warehouse resource
-- monitor would not have caught it.
--
-- Tune the quotas below to your risk tolerance before running.
-- =============================================================================

-- noqa: disable=LT01,LT02
-- Layout rules are disabled for this file only. sqlfluff's Snowflake dialect
-- cannot parse CREATE TAG ... ALLOWED_VALUES, masking-policy `->` bodies, or
-- RESOURCE MONITOR ... TRIGGERS, so every line inside those statements draws a
-- spurious indent finding. All other rules (capitalisation, semicolons,
-- references, structure) remain active here.

USE ROLE ACCOUNTADMIN;

-- -----------------------------------------------------------------------------
-- Layer 1: warehouse credit ceilings
-- -----------------------------------------------------------------------------

CREATE OR REPLACE RESOURCE MONITOR RM_IHA_APP
    WITH CREDIT_QUOTA = 25
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 60 PERCENT DO NOTIFY
        ON 85 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND
        ON 110 PERCENT DO SUSPEND_IMMEDIATE;

CREATE OR REPLACE RESOURCE MONITOR RM_IHA_INGEST
    WITH CREDIT_QUOTA = 50
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND
        ON 120 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE IHA_WH_XS     SET RESOURCE_MONITOR = RM_IHA_APP;
ALTER WAREHOUSE IHA_WH_INGEST SET RESOURCE_MONITOR = RM_IHA_INGEST;

GRANT MONITOR ON RESOURCE MONITOR RM_IHA_APP    TO ROLE IHA_ADMIN;
GRANT MONITOR ON RESOURCE MONITOR RM_IHA_INGEST TO ROLE IHA_ADMIN;

-- -----------------------------------------------------------------------------
-- Layer 2: budget covering serverless / AI services spend
--
-- Resource monitors track warehouse credits only. Cortex AI functions bill as
-- serverless AI services and are invisible to them. This budget is the only
-- thing watching that line.
--
-- NOTE: verify the budget API shape against your account on first run — the
-- Budgets interface has changed across releases. If CREATE ... BUDGET is
-- unavailable, Layer 3 below still provides enforcement.
-- -----------------------------------------------------------------------------

USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA OPS;

CREATE OR REPLACE SNOWFLAKE.CORE.BUDGET BUDGET_IHA_AI()
    COMMENT = 'Tracks AI services + warehouse spend for the platform. Notifies; enforcement is Layer 3.';

-- Monthly ceiling in credits. Start conservative; raise once per-lead cost is
-- measured against real traffic rather than estimated.
CALL BUDGET_IHA_AI!SET_SPENDING_LIMIT(75);

-- Replace with the Snowflake usernames that should receive budget alerts.
-- CALL BUDGET_IHA_AI!SET_NOTIFICATION_USERS(ARRAY_CONSTRUCT('YOUR_SNOWFLAKE_USER'));

-- SYSTEM$REFERENCE requires the privilege being delegated as its 4th argument.
-- Without APPLYBUDGET the reference carries no rights and the budget silently
-- monitors nothing — the failure mode is a budget that never reports.
CALL BUDGET_IHA_AI!ADD_RESOURCE(SYSTEM$REFERENCE('WAREHOUSE', 'IHA_WH_XS', 'SESSION', 'APPLYBUDGET'));
CALL BUDGET_IHA_AI!ADD_RESOURCE(SYSTEM$REFERENCE('WAREHOUSE', 'IHA_WH_INGEST', 'SESSION', 'APPLYBUDGET'));
CALL BUDGET_IHA_AI!ADD_RESOURCE(SYSTEM$REFERENCE('DATABASE', 'IRVINE_HOME_ANALYSIS', 'SESSION', 'APPLYBUDGET'));

-- -----------------------------------------------------------------------------
-- Layer 3: the enforcement that actually acts — daily Cortex spend circuit
-- breaker. Defined here; the flag table and the alert body live in
-- snowflake/70_ops/. Wiring order is: 70_ops creates OPS.FEATURE_FLAGS, then
-- the alert below is resumed.
-- -----------------------------------------------------------------------------

-- Thresholds, kept as data so tuning them is an UPDATE and not a redeploy.
CREATE TABLE IF NOT EXISTS OPS.COST_THRESHOLDS (
    THRESHOLD_NAME  VARCHAR PRIMARY KEY,
    CREDIT_LIMIT    NUMBER(12, 4),
    WINDOW_HOURS    NUMBER(6, 0),
    ACTION          VARCHAR,
    UPDATED_AT      TIMESTAMP_NTZ DEFAULT SYSDATE(),
    NOTES           VARCHAR
);

MERGE INTO OPS.COST_THRESHOLDS AS TGT
USING (
    SELECT * FROM VALUES
        ('DAILY_CORTEX_WARN',  2.0000, 24, 'NOTIFY',
         'Daily Cortex credits above this are worth a look but not an outage.'),
        ('DAILY_CORTEX_TRIP',  6.0000, 24, 'DISABLE_LIVE_NARRATIVE',
         'Flips OPS.FEATURE_FLAGS.LIVE_NARRATIVE to FALSE. Reports still render from cached/templated summaries.'),
        ('HOURLY_CORTEX_TRIP', 1.5000,  1, 'DISABLE_LIVE_NARRATIVE',
         'Catches a runaway loop far faster than the daily figure can.'),
        ('PER_REQUEST_TOKENS', 6000.0000, 0, 'REJECT',
         'Hard ceiling on tokens for one narrative generation. Guards against an oversized evidence bundle.')
    AS SRC (THRESHOLD_NAME, CREDIT_LIMIT, WINDOW_HOURS, ACTION, NOTES)
) AS SRC
ON TGT.THRESHOLD_NAME = SRC.THRESHOLD_NAME
WHEN NOT MATCHED THEN INSERT (THRESHOLD_NAME, CREDIT_LIMIT, WINDOW_HOURS, ACTION, NOTES)
    VALUES (SRC.THRESHOLD_NAME, SRC.CREDIT_LIMIT, SRC.WINDOW_HOURS, SRC.ACTION, SRC.NOTES);

-- Owned by IHA_ADMIN, not ACCOUNTADMIN: the premise is that tuning a threshold
-- is an UPDATE by the team that runs the platform, and the Layer-3 alert reads
-- these rows as IHA_ENGINEER.
GRANT OWNERSHIP ON TABLE OPS.COST_THRESHOLDS TO ROLE IHA_ADMIN COPY CURRENT GRANTS;
GRANT SELECT, INSERT, UPDATE ON TABLE OPS.COST_THRESHOLDS TO ROLE IHA_ENGINEER;
GRANT SELECT ON TABLE OPS.COST_THRESHOLDS TO ROLE IHA_APP;
