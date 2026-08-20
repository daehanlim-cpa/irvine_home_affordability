-- =============================================================================
-- 06_governance_tags_policies.sql
-- Horizon Catalog governance: object tags, masking policies, classification.
--
-- Two things are being protected here.
--
-- 1. Lead PII. Leads are California consumer data (CCPA/CPRA). Email is masked
--    for every role except ADMIN/ENGINEER, and crucially that includes IHA_APP
--    — the role the public surface runs as. A compromised app cannot enumerate
--    the mailing list.
--
-- 2. Scoring provenance. Every column that feeds a score carries a SCORE_INPUT
--    tag, so "what drove this number?" is answerable from the catalog rather
--    than by reading SQL. That matters the first time a buyer disputes a score.
-- =============================================================================

-- noqa: disable=LT01,LT02
-- Layout rules are disabled for this file only. sqlfluff's Snowflake dialect
-- cannot parse CREATE TAG ... ALLOWED_VALUES, masking-policy `->` bodies, or
-- RESOURCE MONITOR ... TRIGGERS, so every line inside those statements draws a
-- spurious indent finding. All other rules (capitalisation, semicolons,
-- references, structure) remain active here.

USE ROLE IHA_ADMIN;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;

-- -----------------------------------------------------------------------------
-- Tags
-- -----------------------------------------------------------------------------

CREATE TAG IF NOT EXISTS PII_CATEGORY
    ALLOWED_VALUES 'EMAIL', 'IP_ADDRESS', 'NAME', 'ADDRESS_QUERIED', 'NONE'
    COMMENT = 'Classifies personal data for CCPA handling and masking policy attachment.';

CREATE TAG IF NOT EXISTS SOURCE_TIER
    ALLOWED_VALUES 'A_CIVIC', 'B_JOURNALISM', 'C_FORUM', 'D_REVIEW', 'GOV_GIS'
    COMMENT = 'Provenance tier. Drives sentiment credibility weighting and tells a reader how much to trust a column.';

CREATE TAG IF NOT EXISTS SCORE_INPUT
    ALLOWED_VALUES 'CONSTRUCTION', 'COST_BURDEN', 'ENVIRONMENT', 'SCHOOLS', 'SAFETY', 'NEIGHBORHOOD', 'SENTIMENT'
    COMMENT = 'Marks a column as feeding a specific scoring pillar. Makes score provenance queryable from the catalog.';

-- -----------------------------------------------------------------------------
-- Masking policies
-- -----------------------------------------------------------------------------

-- A tag carries at most ONE masking policy per data type. Email and IP are both
-- VARCHAR, so two policies cannot both attach to PII_CATEGORY — the second is
-- silently ignored and IP columns end up email-masked. One policy that branches
-- on the tag value is the only shape that works.
CREATE OR REPLACE MASKING POLICY MASK_PII_VARCHAR AS (VAL VARCHAR) RETURNS VARCHAR ->
    CASE
        WHEN CURRENT_ROLE() IN ('IHA_ADMIN', 'IHA_ENGINEER', 'ACCOUNTADMIN')
            THEN VAL
        WHEN VAL IS NULL
            THEN NULL
        -- Preserve the domain so aggregate analysis still works, hide identity.
        WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('IRVINE_HOME_ANALYSIS.MART.PII_CATEGORY') = 'EMAIL'
            THEN '***@' || SPLIT_PART(VAL, '@', 2)
        -- /24 keeps rate-limit analysis possible without identifying a household.
        WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('IRVINE_HOME_ANALYSIS.MART.PII_CATEGORY') = 'IP_ADDRESS'
            THEN REGEXP_REPLACE(VAL, '[0-9]{1,3}$', '0')
        -- The queried address is the user's prospective home: coarsen to the street.
        WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('IRVINE_HOME_ANALYSIS.MART.PII_CATEGORY') = 'ADDRESS_QUERIED'
            THEN REGEXP_REPLACE(VAL, '^[0-9]+', '###')
        WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('IRVINE_HOME_ANALYSIS.MART.PII_CATEGORY') = 'NONE'
            THEN VAL
        ELSE '***'
    END
    COMMENT = 'Single VARCHAR PII policy for the PII_CATEGORY tag. Branches on tag value; unmasked only for ADMIN/ENGINEER.';


-- Tag-based attachment: any column tagged PII_CATEGORY='EMAIL' is masked
-- automatically, including columns added later. Policy follows the data.
ALTER TAG PII_CATEGORY SET MASKING POLICY MASK_PII_VARCHAR;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------

GRANT APPLY ON TAG PII_CATEGORY TO ROLE IHA_ENGINEER;
GRANT APPLY ON TAG SOURCE_TIER  TO ROLE IHA_ENGINEER;
GRANT APPLY ON TAG SCORE_INPUT  TO ROLE IHA_ENGINEER;

-- -----------------------------------------------------------------------------
-- Provenance query: which columns feed which pillar?
-- Answers a score dispute from the catalog instead of from source code.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW MART.VW_SCORE_PROVENANCE
    COMMENT = 'Every column tagged as a scoring input, with its pillar and source tier. The audit trail for "why did this parcel score what it scored?".'
AS
SELECT
    TAG_REFS.OBJECT_DATABASE AS DB_NAME,
    TAG_REFS.OBJECT_SCHEMA   AS SCHEMA_NAME,
    TAG_REFS.OBJECT_NAME     AS TABLE_NAME,
    TAG_REFS.COLUMN_NAME     AS COLUMN_NAME,
    MAX(CASE WHEN TAG_REFS.TAG_NAME = 'SCORE_INPUT' THEN TAG_REFS.TAG_VALUE END) AS PILLAR,
    MAX(CASE WHEN TAG_REFS.TAG_NAME = 'SOURCE_TIER' THEN TAG_REFS.TAG_VALUE END) AS SOURCE_TIER
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES AS TAG_REFS
WHERE TAG_REFS.OBJECT_DATABASE = 'IRVINE_HOME_ANALYSIS'
  AND TAG_REFS.TAG_NAME IN ('SCORE_INPUT', 'SOURCE_TIER')
GROUP BY 1, 2, 3, 4;
