-- =============================================================================
-- tables_raw.sql
-- Append-only landing tables.
--
-- Three rules hold everywhere in RAW:
--
--   1. Nothing is transformed here. The payload lands as VARIANT exactly as the
--      source returned it.
--   2. Every row carries provenance: where it came from, when, and a hash of the
--      payload. Idempotency and replay both key on that hash.
--   3. Nothing is ever updated or deleted. Upstream schema drift then breaks a
--      STAGE view — a visible, fixable failure — rather than silently corrupting
--      history or losing data we cannot re-fetch.
--
-- ArcGIS layer schemas change without notice. This layering is the reason that
-- is an inconvenience rather than an incident.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA RAW;

-- -----------------------------------------------------------------------------
-- Shared provenance columns, repeated per table rather than inherited: RAW
-- tables are meant to be readable in isolation, years later, by someone
-- reconstructing where a number came from.
--
--   _SOURCE_NAME   registry key in ingest/sources.yaml
--   _SOURCE_URL    exact URL fetched, including paging parameters
--   _INGESTED_AT   when we landed it
--   _PAYLOAD_HASH  SHA2 of the payload; dedup and replay key
--   _BATCH_ID      one ingest run, for tracing a bad batch back to its log rows
--   _PAYLOAD       the response, untouched
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS RAW.R_IRVINE_ADDRESS_POINTS (
    _SOURCE_NAME VARCHAR NOT NULL,
    _SOURCE_URL VARCHAR NOT NULL,
    _INGESTED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    _PAYLOAD_HASH VARCHAR(64) NOT NULL,
    _BATCH_ID VARCHAR(36) NOT NULL,
    _PAYLOAD VARIANT NOT NULL
)
COMMENT = 'Irvine address points. The geocoder: address string -> parcel. Append-only.';

CREATE TABLE IF NOT EXISTS RAW.R_IRVINE_PARCELS_CFD (
    _SOURCE_NAME VARCHAR NOT NULL,
    _SOURCE_URL VARCHAR NOT NULL,
    _INGESTED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    _PAYLOAD_HASH VARCHAR(64) NOT NULL,
    _BATCH_ID VARCHAR(36) NOT NULL,
    _PAYLOAD VARIANT NOT NULL
)
COMMENT = 'Parcel geometry and Community Facilities District membership. Drives the cost pillar. Append-only.';

CREATE TABLE IF NOT EXISTS RAW.R_IRVINE_CIP_PROJECTS (
    _SOURCE_NAME VARCHAR NOT NULL,
    _SOURCE_URL VARCHAR NOT NULL,
    _INGESTED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    _PAYLOAD_HASH VARCHAR(64) NOT NULL,
    _BATCH_ID VARCHAR(36) NOT NULL,
    _PAYLOAD VARIANT NOT NULL
)
COMMENT = 'Capital improvement projects. Primary construction-pillar input. Append-only.';

CREATE TABLE IF NOT EXISTS RAW.R_IRVINE_DEV_PROJECTS (
    _SOURCE_NAME VARCHAR NOT NULL,
    _SOURCE_URL VARCHAR NOT NULL,
    _INGESTED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    _PAYLOAD_HASH VARCHAR(64) NOT NULL,
    _BATCH_ID VARCHAR(36) NOT NULL,
    _PAYLOAD VARIANT NOT NULL
)
COMMENT = 'Approved and pending private development. Forward-looking construction signal. Append-only.';

-- Civic minutes and news carry a text body rather than a feature payload, but
-- keep the identical provenance contract so replay and dedup work the same way.
CREATE TABLE IF NOT EXISTS RAW.R_CIVIC_MINUTES (
    _SOURCE_NAME VARCHAR NOT NULL,
    _SOURCE_URL VARCHAR NOT NULL,
    _INGESTED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    _PAYLOAD_HASH VARCHAR(64) NOT NULL,
    _BATCH_ID VARCHAR(36) NOT NULL,
    _PAYLOAD VARIANT NOT NULL
)
COMMENT = 'Council and Planning Commission agendas/minutes from Granicus. Speaker names are NOT retained; see ingest/adapters/granicus.py. Append-only.';

CREATE TABLE IF NOT EXISTS RAW.R_NEWS_ARTICLES (
    _SOURCE_NAME VARCHAR NOT NULL,
    _SOURCE_URL VARCHAR NOT NULL,
    _INGESTED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    _PAYLOAD_HASH VARCHAR(64) NOT NULL,
    _BATCH_ID VARCHAR(36) NOT NULL,
    _PAYLOAD VARIANT NOT NULL
)
COMMENT = 'Local journalism RSS. Headline, link, date, summary only — never full article text. Append-only.';

CREATE TABLE IF NOT EXISTS RAW.R_FORUM_POSTS (
    _SOURCE_NAME VARCHAR NOT NULL,
    _SOURCE_URL VARCHAR NOT NULL,
    _INGESTED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    _PAYLOAD_HASH VARCHAR(64) NOT NULL,
    _BATCH_ID VARCHAR(36) NOT NULL,
    _PAYLOAD VARIANT NOT NULL
)
COMMENT = 'Community forum posts. Usernames are NEVER stored: text, thread URL, timestamp, village tag only. Append-only.';

-- -----------------------------------------------------------------------------
-- Ingest run ledger. One row per source per run: what was attempted, what
-- landed, and why it stopped. Without this, a source that quietly returns zero
-- rows for a month looks identical to a source with nothing new to report.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS RAW.INGEST_RUNS (
    BATCH_ID VARCHAR(36) NOT NULL,
    SOURCE_NAME VARCHAR NOT NULL,
    STARTED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    FINISHED_AT TIMESTAMP_NTZ,
    STATUS VARCHAR NOT NULL,   -- RUNNING | SUCCESS | FAILED | BLOCKED_BY_ROBOTS | CAP_REACHED | CIRCUIT_OPEN
    PAGES_FETCHED NUMBER(10, 0) DEFAULT 0,
    ROWS_LANDED NUMBER(12, 0) DEFAULT 0,
    ROWS_DUPLICATE NUMBER(12, 0) DEFAULT 0,
    HTTP_CALLS NUMBER(10, 0) DEFAULT 0,
    ERROR_MESSAGE VARCHAR
)
COMMENT = 'One row per ingest run. Distinguishes "nothing new" from "silently broken" — a distinction that otherwise takes weeks to notice.';

GRANT SELECT ON ALL TABLES IN SCHEMA RAW TO ROLE IHA_ANALYST;
