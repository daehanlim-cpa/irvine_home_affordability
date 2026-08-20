-- =============================================================================
-- app_tables.sql
-- Lead capture, request quota, and address resolution.
--
-- Leads are California consumer data (CCPA/CPRA). Three things follow, and all
-- three are implemented rather than promised:
--   - email carries the PII_CATEGORY tag, so the masking policy applies
--     automatically, including to IHA_APP, the role the public site runs as
--   - consent timestamp and source are recorded at capture, not inferred later
--   - a retention window is defined and enforced by a task, because "we'll
--     delete it eventually" is not a retention policy
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA APP;

CREATE TABLE IF NOT EXISTS APP.LEADS (
    LEAD_ID VARCHAR(36) NOT NULL DEFAULT UUID_STRING(),
    CREATED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    EMAIL_ADDRESS VARCHAR NOT NULL,
    ADDRESS_QUERIED VARCHAR NOT NULL,
    RESOLVED_APN VARCHAR,
    RESOLVED_VILLAGE VARCHAR,
    MATCH_CONFIDENCE VARCHAR,
    -- Consent is a record, not an assumption: what they agreed to, when, and
    -- from where.
    CONSENT_AT TIMESTAMP_NTZ NOT NULL,
    CONSENT_TEXT VARCHAR NOT NULL,
    SOURCE_CHANNEL VARCHAR,
    CLIENT_IP VARCHAR,
    USER_AGENT VARCHAR,
    DELETED_AT TIMESTAMP_NTZ,             -- CCPA deletion request honoured
    PRIMARY KEY (LEAD_ID)
)
COMMENT = 'Captured leads. EMAIL and CLIENT_IP are masked for every role except ADMIN/ENGINEER. Retention enforced by OPS task.';

-- Tag-driven masking. Because the policy attaches to the TAG rather than the
-- column, any column tagged later is protected without anyone remembering to
-- apply a policy.
ALTER TABLE APP.LEADS MODIFY COLUMN EMAIL_ADDRESS SET TAG MART.PII_CATEGORY = 'EMAIL';
ALTER TABLE APP.LEADS MODIFY COLUMN CLIENT_IP SET TAG MART.PII_CATEGORY = 'IP_ADDRESS';
ALTER TABLE APP.LEADS MODIFY COLUMN ADDRESS_QUERIED SET TAG MART.PII_CATEGORY = 'ADDRESS_QUERIED';

-- -----------------------------------------------------------------------------
-- Request quota. The public address bar is a button that spends money on LLM
-- inference, so it is rate limited per identity and globally.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS APP.REQUEST_QUOTA (
    QUOTA_KEY VARCHAR NOT NULL,   -- email or IP
    QUOTA_TYPE VARCHAR NOT NULL,   -- EMAIL | IP | GLOBAL
    WINDOW_START TIMESTAMP_NTZ NOT NULL,
    REQUEST_COUNT NUMBER(8, 0) NOT NULL DEFAULT 0,
    PRIMARY KEY (QUOTA_KEY, QUOTA_TYPE, WINDOW_START)
)
COMMENT = 'Per-email, per-IP, and global request counters. Breaching serves a cached report rather than erroring.';

CREATE TABLE IF NOT EXISTS APP.QUOTA_LIMITS (
    QUOTA_TYPE VARCHAR NOT NULL PRIMARY KEY,
    MAX_REQUESTS NUMBER(8, 0) NOT NULL,
    WINDOW_HOURS NUMBER(6, 0) NOT NULL,
    RATIONALE VARCHAR
)
COMMENT = 'Quota limits. Tunable without a deploy.';

MERGE INTO APP.QUOTA_LIMITS AS TGT
USING (
    SELECT *
    FROM
        VALUES
        ('EMAIL', 10, 24, 'A genuine buyer researches a handful of homes a day. Ten is generous; beyond it is scraping.'),
        ('IP', 25, 24, 'Households share an IP, and an agent may run several for clients. Above 25 a day is automation.'),
        ('GLOBAL', 2000, 24, 'Whole-platform ceiling. Sized so a bad day costs a known, survivable amount rather than an open-ended one.')
            AS SRC (QUOTA_TYPE, MAX_REQUESTS, WINDOW_HOURS, RATIONALE)
) AS SRC
    ON TGT.QUOTA_TYPE = SRC.QUOTA_TYPE
WHEN NOT MATCHED THEN
    INSERT (QUOTA_TYPE, MAX_REQUESTS, WINDOW_HOURS, RATIONALE)
    VALUES (SRC.QUOTA_TYPE, SRC.MAX_REQUESTS, SRC.WINDOW_HOURS, SRC.RATIONALE);

GRANT SELECT, INSERT ON TABLE APP.LEADS TO ROLE IHA_APP;
GRANT SELECT, INSERT, UPDATE ON TABLE APP.REQUEST_QUOTA TO ROLE IHA_APP;
GRANT SELECT ON TABLE APP.QUOTA_LIMITS TO ROLE IHA_APP;
