-- =============================================================================
-- 01_databases_schemas.sql
-- Database, schemas, and warehouses for the Irvine Home Analysis Platform.
--
-- Layering (see CLAUDE.md):
--   RAW   append-only VARIANT landing, never transformed in place
--   STAGE typed, deduped, GEOGRAPHY — schema drift breaks here, not in ingest
--   MART  dims, facts, and REF_* config tables; scoring reads only from here
--   APP   lead capture, request quota, the analyze entrypoint
--   OPS   API call log, feature flags, Cortex spend, DMFs, audit
--
-- Run as a role that can create databases (ACCOUNTADMIN or equivalent).
-- =============================================================================

-- SYSADMIN owns the database until 02_roles_grants.sql transfers ownership to
-- IHA_ADMIN. Named explicitly rather than relying on whatever role the session
-- happens to be using.
USE ROLE SYSADMIN;

CREATE DATABASE IF NOT EXISTS IRVINE_HOME_ANALYSIS
COMMENT = 'Parcel-level buy-quality analysis for Irvine, CA. 90% public government data, 10% community sentiment.';

USE DATABASE IRVINE_HOME_ANALYSIS;

CREATE SCHEMA IF NOT EXISTS RAW
COMMENT = 'Append-only landing. VARIANT payloads with _source_url, _ingested_at, _payload_hash. Never transform here.';

CREATE SCHEMA IF NOT EXISTS STAGE
COMMENT = 'Typed, deduped views over RAW. GEOGRAPHY columns materialise here. Upstream schema drift surfaces here as a broken view, not as lost data.';

CREATE SCHEMA IF NOT EXISTS MART
COMMENT = 'Dimensions, facts, and REF_* configuration tables. The scoring layer reads only from MART.';

CREATE SCHEMA IF NOT EXISTS APP
COMMENT = 'Application surface: lead capture, request quota, PROC_ANALYZE_ADDRESS.';

CREATE SCHEMA IF NOT EXISTS OPS
COMMENT = 'Operational control plane: outbound call log, feature flags, Cortex spend attribution, data quality, audit.';

-- Development mirror. The PreToolUse hook only permits destructive DDL against
-- objects whose name carries a _DEV suffix, so experiments belong here.
CREATE SCHEMA IF NOT EXISTS MART_DEV
COMMENT = 'Scratch schema for scoring experiments. Safe to drop.';

-- -----------------------------------------------------------------------------
-- Warehouses
--
-- Two, deliberately. Ingest and Cortex classification are bursty batch work;
-- the app path is small, latency-sensitive, and must never be blocked behind a
-- backfill. Separating them also makes per-pillar cost attribution legible in
-- CORTEX_AI_FUNCTIONS_USAGE_HISTORY.
-- -----------------------------------------------------------------------------

CREATE WAREHOUSE IF NOT EXISTS IHA_WH_XS
WAREHOUSE_SIZE = 'XSMALL'
AUTO_SUSPEND = 60
AUTO_RESUME = TRUE
INITIALLY_SUSPENDED = TRUE
COMMENT = 'Interactive/app queries. 60s auto-suspend: the app path is short and idle time is pure waste.';

CREATE WAREHOUSE IF NOT EXISTS IHA_WH_INGEST
WAREHOUSE_SIZE = 'XSMALL'
AUTO_SUSPEND = 120
AUTO_RESUME = TRUE
INITIALLY_SUSPENDED = TRUE
STATEMENT_TIMEOUT_IN_SECONDS = 3600
COMMENT = 'Ingest and Cortex classification batches. Kept separate so a backfill never queues behind a user request.';
