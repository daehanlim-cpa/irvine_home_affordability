-- =============================================================================
-- 02_roles_grants.sql
-- Role model and grants.
--
--   IHA_ADMIN     owns objects, manages governance policies and budgets
--   IHA_ENGINEER  builds and deploys pipelines; can read PII
--   IHA_APP       runtime role for Streamlit / the analyze entrypoint;
--                 deliberately cannot read lead email in the clear
--   IHA_ANALYST   read-only on MART for tuning weights; no PII, no APP writes
--
-- The separation that matters: IHA_APP is the role a public-facing surface runs
-- as, so it gets the narrowest possible grant set. It can write a lead and read
-- marts. It cannot read another lead's email, alter a weight, or drop anything.
-- =============================================================================

USE ROLE USERADMIN;

CREATE ROLE IF NOT EXISTS IHA_ADMIN COMMENT = 'Owns Irvine Home Analysis objects; manages governance and budgets.';
CREATE ROLE IF NOT EXISTS IHA_ENGINEER COMMENT = 'Builds and deploys pipelines. May read unmasked PII.';
CREATE ROLE IF NOT EXISTS IHA_APP COMMENT = 'Runtime role for the public app surface. Least privilege; PII masked.';
CREATE ROLE IF NOT EXISTS IHA_ANALYST COMMENT = 'Read-only on MART for scoring analysis. No PII.';

USE ROLE SECURITYADMIN;

GRANT ROLE IHA_ENGINEER TO ROLE IHA_ADMIN;
GRANT ROLE IHA_ANALYST TO ROLE IHA_ENGINEER;
GRANT ROLE IHA_ADMIN TO ROLE SYSADMIN;

USE ROLE ACCOUNTADMIN;

-- Cortex access. CORTEX_MODELS_ALLOWLIST is deprecated, so model governance is
-- role grants here plus pinned model names in MART.REF_CORTEX_MODELS.
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE IHA_ENGINEER;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE IHA_APP;

-- Account usage for cost attribution (OPS.VW_CORTEX_SPEND).
-- The Cortex probe and the spend views run as IHA_ENGINEER, so the reader
-- roles must reach that far down. Granting only to IHA_ADMIN left every
-- cost-telemetry check failing: role inheritance runs the other way.
GRANT DATABASE ROLE SNOWFLAKE.USAGE_VIEWER TO ROLE IHA_ADMIN;
GRANT DATABASE ROLE SNOWFLAKE.USAGE_VIEWER TO ROLE IHA_ENGINEER;

-- VW_SCORE_PROVENANCE reads ACCOUNT_USAGE.TAG_REFERENCES, which USAGE_VIEWER
-- does not cover.
GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE IHA_ADMIN;
GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE IHA_ENGINEER;

GRANT USAGE ON WAREHOUSE IHA_WH_XS TO ROLE IHA_APP;
GRANT USAGE ON WAREHOUSE IHA_WH_XS TO ROLE IHA_ANALYST;
GRANT USAGE ON WAREHOUSE IHA_WH_XS TO ROLE IHA_ENGINEER;
GRANT USAGE ON WAREHOUSE IHA_WH_INGEST TO ROLE IHA_ENGINEER;
GRANT OPERATE ON WAREHOUSE IHA_WH_INGEST TO ROLE IHA_ENGINEER;

-- Ownership of a database does NOT cascade to its schemas. Without the second
-- statement, the GRANT ALL ON SCHEMA calls below fail on a fresh deploy because
-- IHA_ADMIN does not yet own the schemas SYSADMIN created in 01.
GRANT OWNERSHIP ON DATABASE IRVINE_HOME_ANALYSIS TO ROLE IHA_ADMIN COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL SCHEMAS IN DATABASE IRVINE_HOME_ANALYSIS TO ROLE IHA_ADMIN COPY CURRENT GRANTS;

USE ROLE IHA_ADMIN;
USE DATABASE IRVINE_HOME_ANALYSIS;

GRANT USAGE ON DATABASE IRVINE_HOME_ANALYSIS TO ROLE IHA_ENGINEER;
GRANT USAGE ON DATABASE IRVINE_HOME_ANALYSIS TO ROLE IHA_APP;
GRANT USAGE ON DATABASE IRVINE_HOME_ANALYSIS TO ROLE IHA_ANALYST;

-- Engineer: full control of the pipeline schemas.
GRANT ALL ON SCHEMA RAW TO ROLE IHA_ENGINEER;
GRANT ALL ON SCHEMA STAGE TO ROLE IHA_ENGINEER;
GRANT ALL ON SCHEMA MART TO ROLE IHA_ENGINEER;
GRANT ALL ON SCHEMA OPS TO ROLE IHA_ENGINEER;
GRANT ALL ON SCHEMA APP TO ROLE IHA_ENGINEER;
GRANT ALL ON SCHEMA MART_DEV TO ROLE IHA_ENGINEER;

-- App: read marts, execute the entrypoint, append to leads and ops logs.
-- Note there is no UPDATE or DELETE on APP.LEADS, and no write of any kind to
-- MART — a compromised app surface cannot rewrite history or retune the model.
GRANT USAGE ON SCHEMA MART TO ROLE IHA_APP;
GRANT USAGE ON SCHEMA APP TO ROLE IHA_APP;
GRANT USAGE ON SCHEMA OPS TO ROLE IHA_APP;
GRANT SELECT ON ALL TABLES IN SCHEMA MART TO ROLE IHA_APP;
GRANT SELECT ON FUTURE TABLES IN SCHEMA MART TO ROLE IHA_APP;
GRANT SELECT ON ALL VIEWS IN SCHEMA MART TO ROLE IHA_APP;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA MART TO ROLE IHA_APP;

-- Analyst: read-only on MART, and nothing else.
GRANT USAGE ON SCHEMA MART TO ROLE IHA_ANALYST;
GRANT SELECT ON ALL TABLES IN SCHEMA MART TO ROLE IHA_ANALYST;
GRANT SELECT ON FUTURE TABLES IN SCHEMA MART TO ROLE IHA_ANALYST;
GRANT SELECT ON ALL VIEWS IN SCHEMA MART TO ROLE IHA_ANALYST;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA MART TO ROLE IHA_ANALYST;
