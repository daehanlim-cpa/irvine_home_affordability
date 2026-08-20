-- =============================================================================
-- ref_sentiment_sources.sql
-- Trust tiers and credibility weights for the 10% sentiment pillar.
--
-- Sentiment is a weighted blend, not an average. A resident testifying on the
-- record at a Planning Commission hearing about the specific project next to a
-- parcel is not equivalent to an anonymous YouTube comment, and the model should
-- not pretend otherwise.
--
-- Weights are relative within the blend and renormalise over whatever sources
-- are enabled and actually returned documents. Disabling a source — because its
-- robots.txt disallows crawling, or its ToS changes — degrades the blend
-- gracefully instead of breaking the product. No single source is load-bearing.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;

CREATE TABLE IF NOT EXISTS MART.REF_SENTIMENT_SOURCES (
    SOURCE_NAME VARCHAR NOT NULL PRIMARY KEY,
    TIER VARCHAR NOT NULL,   -- A_CIVIC | B_JOURNALISM | C_FORUM | D_REVIEW
    CREDIBILITY_WEIGHT NUMBER(4, 3) NOT NULL,   -- relative weight within the blend
    IS_ENABLED BOOLEAN NOT NULL,
    COMPLIANCE_STATUS VARCHAR NOT NULL,   -- CLEARED | PENDING_ROBOTS_CHECK | BLOCKED | N_A_OFFICIAL_API
    RATIONALE VARCHAR,
    UPDATED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE()
)
COMMENT = 'Credibility weighting for sentiment sources. Blend renormalises over enabled sources that returned documents.';

-- Every source ships DISABLED. The compliance guard treats enabled-but-pending
-- as a FAIL, so seeding anything enabled would mean a fresh deploy could never
-- pass its own gate. Enable a source only after recording its robots.txt and
-- ToS position in docs/data_sources.md and setting COMPLIANCE_STATUS='CLEARED'.

MERGE INTO MART.REF_SENTIMENT_SOURCES AS TGT
USING (
    SELECT *
    FROM
        VALUES
        (
            'irvine_granicus_minutes', 'A_CIVIC', 1.000, FALSE, 'PENDING_ROBOTS_CHECK',
            'Council and Planning Commission minutes. Residents on the record about specific projects, with names, dates, and agenda items. Highest credibility available and effectively unmined by competitors.'
        ),
        (
            'aqmd_complaints', 'A_CIVIC', 0.950, FALSE, 'PENDING_ROBOTS_CHECK',
            'Quantified regulatory complaints. 800+ against the asphalt plant is a fact, not an opinion. Phase 2.'
        ),
        (
            'irvine_code_enforcement', 'A_CIVIC', 0.900, FALSE, 'PENDING_ROBOTS_CHECK',
            'Official case records, already a GIS layer. Phase 2.'
        ),
        (
            'voice_of_oc', 'B_JOURNALISM', 0.850, FALSE, 'PENDING_ROBOTS_CHECK',
            'Nonprofit investigative outlet with a strong OC government record. Edited and accountable.'
        ),
        (
            'northwood_howler', 'B_JOURNALISM', 0.700, FALSE, 'PENDING_ROBOTS_CHECK',
            'Student paper that broke the All American Asphalt story. Hyperlocal reporting routinely beats regional outlets at neighbourhood scale. Phase 2.'
        ),
        (
            'irvine_watchdog', 'B_JOURNALISM', 0.650, FALSE, 'PENDING_ROBOTS_CHECK',
            'Resident-run civic watchdog. Valuable and explicitly advocacy — weighted below neutral reporting. Phase 2.'
        ),
        (
            'patch_irvine', 'B_JOURNALISM', 0.600, FALSE, 'PENDING_ROBOTS_CHECK',
            'Local news aggregation, variable depth. Phase 2.'
        ),
        (
            'talkirvine', 'C_FORUM', 0.450, FALSE, 'PENDING_ROBOTS_CHECK',
            'Dedicated homeowner forum, unusually on-topic. Self-selected and unverified, hence mid weight. Disabled until robots.txt and ToS are verified.'
        ),
        (
            'city_data_forum', 'C_FORUM', 0.350, FALSE, 'PENDING_ROBOTS_CHECK',
            'Long-lived village threads. Older content and more drift. Phase 2.'
        ),
        (
            'youtube_neighborhood_tours', 'C_FORUM', 0.300, FALSE, 'N_A_OFFICIAL_API',
            'Comments on neighbourhood tour videos. Candid and unmined; anonymous and unverifiable, hence low weight. Phase 2.'
        ),
        (
            'google_places_reviews', 'D_REVIEW', 0.250, FALSE, 'N_A_OFFICIAL_API',
            'Reviews of parks, schools, and centres. Structured but capped at five per place. Phase 2.'
        ),
        (
            'apartment_reviews', 'D_REVIEW', 0.250, FALSE, 'PENDING_ROBOTS_CHECK',
            'Renters in a village complain about precisely what buyers care about: construction noise, traffic, management. Indirect signal, low weight. Phase 2.'
        ),
        (
            'yelp_local', 'D_REVIEW', 0.200, FALSE, 'N_A_OFFICIAL_API',
            'Amenity-quality proxy. Three review excerpts per business is thin. Phase 2.')
            AS SRC (SOURCE_NAME, TIER, CREDIBILITY_WEIGHT, IS_ENABLED, COMPLIANCE_STATUS, RATIONALE)
) AS SRC
    ON TGT.SOURCE_NAME = SRC.SOURCE_NAME
WHEN MATCHED THEN
    UPDATE SET
        TGT.TIER = SRC.TIER, TGT.CREDIBILITY_WEIGHT = SRC.CREDIBILITY_WEIGHT,
        TGT.IS_ENABLED = SRC.IS_ENABLED, TGT.COMPLIANCE_STATUS = SRC.COMPLIANCE_STATUS,
        TGT.RATIONALE = SRC.RATIONALE, TGT.UPDATED_AT = SYSDATE()
WHEN NOT MATCHED THEN INSERT
    (SOURCE_NAME, TIER, CREDIBILITY_WEIGHT, IS_ENABLED, COMPLIANCE_STATUS, RATIONALE)
VALUES
(
    SRC.SOURCE_NAME, SRC.TIER, SRC.CREDIBILITY_WEIGHT, SRC.IS_ENABLED,
    SRC.COMPLIANCE_STATUS, SRC.RATIONALE
);

-- A source may not be enabled until its compliance position is recorded. This
-- is the database-level counterpart to the hook that checks crawler code, and it
-- catches the case the hook cannot see: a source switched on by an UPDATE.
CREATE OR REPLACE VIEW MART.VW_SENTIMENT_COMPLIANCE_GUARD
COMMENT = 'Flags any enabled sentiment source whose compliance check has not cleared. FAIL rows block the verification gate.'
AS
SELECT
    SOURCE_NAME,
    TIER,
    COMPLIANCE_STATUS,
    'FAIL' AS STATUS,
    'Source is enabled but compliance status is ' || COMPLIANCE_STATUS
    || '. Record the robots.txt and ToS position in docs/data_sources.md and set COMPLIANCE_STATUS to CLEARED before enabling.' AS DETAIL
FROM MART.REF_SENTIMENT_SOURCES
WHERE
    IS_ENABLED = TRUE
    AND COMPLIANCE_STATUS NOT IN ('CLEARED', 'N_A_OFFICIAL_API');

GRANT SELECT ON TABLE MART.REF_SENTIMENT_SOURCES TO ROLE IHA_APP;
GRANT SELECT ON TABLE MART.REF_SENTIMENT_SOURCES TO ROLE IHA_ANALYST;
