-- =============================================================================
-- 04_external_access.sql
-- Secrets and external access integrations.
--
-- Secrets are created here with placeholder values so the objects exist and can
-- be granted; real values are set by an operator with ALTER SECRET. Never put a
-- live credential in this file — it is committed to a PUBLIC repository.
--
-- Two integrations, mirroring the network rules: government feeds need no
-- credentials at all, so keeping them on a separate, secretless integration
-- means the tier that runs most often carries no credential exposure.
-- =============================================================================

USE ROLE IHA_ADMIN;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA OPS;

-- -----------------------------------------------------------------------------
-- Secrets. Set real values out of band:
--   ALTER SECRET SEC_YOUTUBE_API_KEY SET SECRET_STRING = '<key>';
-- -----------------------------------------------------------------------------

CREATE SECRET IF NOT EXISTS SEC_YOUTUBE_API_KEY
    TYPE = GENERIC_STRING
    SECRET_STRING = 'PLACEHOLDER_SET_VIA_ALTER_SECRET'
    COMMENT = 'YouTube Data API key. Tier C sentiment. Set with ALTER SECRET.';

CREATE SECRET IF NOT EXISTS SEC_GOOGLE_PLACES_API_KEY
    TYPE = GENERIC_STRING
    SECRET_STRING = 'PLACEHOLDER_SET_VIA_ALTER_SECRET'
    COMMENT = 'Google Places API key. Tier D reviews. Set with ALTER SECRET.';

CREATE SECRET IF NOT EXISTS SEC_CENSUS_API_KEY
    TYPE = GENERIC_STRING
    SECRET_STRING = 'PLACEHOLDER_SET_VIA_ALTER_SECRET'
    COMMENT = 'US Census API key for ACS block-group pulls. Set with ALTER SECRET.';

-- Not a credential: the contact address embedded in every outbound User-Agent so
-- site owners can reach a human. Stored as a secret purely to keep it out of the
-- repository, since it is a personal email.
CREATE SECRET IF NOT EXISTS SEC_CRAWLER_CONTACT
    TYPE = GENERIC_STRING
    SECRET_STRING = 'PLACEHOLDER_SET_VIA_ALTER_SECRET'
    COMMENT = 'Contact email advertised in the crawler User-Agent. Required before any Tier B/C/D fetch.';

-- -----------------------------------------------------------------------------
-- Integrations
-- -----------------------------------------------------------------------------

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION EAI_GOV_SOURCES
    ALLOWED_NETWORK_RULES = (NR_GOV_GIS)
    ENABLED = TRUE
    COMMENT = 'Government/civic feeds. No secrets attached: these are open records requiring no authentication.';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION EAI_SENTIMENT_SOURCES
    ALLOWED_NETWORK_RULES = (NR_NEWS_RSS, NR_COMMUNITY)
    ALLOWED_AUTHENTICATION_SECRETS = (
        SEC_YOUTUBE_API_KEY,
        SEC_GOOGLE_PLACES_API_KEY,
        SEC_CRAWLER_CONTACT
    )
    ENABLED = TRUE
    COMMENT = 'Sentiment sources: news RSS, forums, review APIs. Revoke by disabling this integration alone; government ingest is unaffected.';

GRANT USAGE ON INTEGRATION EAI_GOV_SOURCES       TO ROLE IHA_ENGINEER;
GRANT USAGE ON INTEGRATION EAI_SENTIMENT_SOURCES TO ROLE IHA_ENGINEER;

GRANT READ ON SECRET SEC_YOUTUBE_API_KEY       TO ROLE IHA_ENGINEER;
GRANT READ ON SECRET SEC_GOOGLE_PLACES_API_KEY TO ROLE IHA_ENGINEER;
GRANT READ ON SECRET SEC_CENSUS_API_KEY        TO ROLE IHA_ENGINEER;
GRANT READ ON SECRET SEC_CRAWLER_CONTACT       TO ROLE IHA_ENGINEER;
