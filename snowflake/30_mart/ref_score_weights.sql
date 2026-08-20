-- =============================================================================
-- ref_score_weights.sql
-- Pillar weights and the scoring parameters that shape the maths.
--
-- Everything tunable about the model lives here. Retuning is an UPDATE plus a
-- test run, never a code change — which means an analyst can adjust the model
-- and the diff shows exactly what moved.
--
-- The 90/10 split the business is built on is enforced by a check below, not
-- merely intended: objective pillars sum to 0.90, sentiment is 0.10.
--
-- Pillars not yet implemented sit at weight 0. Turning one on in Phase 2 is an
-- UPDATE and a redistribution, with no change to the scorer.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;

CREATE TABLE IF NOT EXISTS MART.REF_SCORE_WEIGHTS (
    PILLAR_CODE VARCHAR NOT NULL PRIMARY KEY,
    PILLAR_LABEL VARCHAR NOT NULL,
    WEIGHT NUMBER(5, 4) NOT NULL,
    IS_OBJECTIVE BOOLEAN NOT NULL,   -- TRUE = part of the 90% government-data half
    IS_ACTIVE BOOLEAN NOT NULL,   -- FALSE = built but not yet fed by data
    DISPLAY_ORDER NUMBER(3, 0) NOT NULL,
    RATIONALE VARCHAR,
    UPDATED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE()
)
COMMENT = 'Pillar weights. Objective pillars sum to 0.90, sentiment 0.10. Change a weight here, never in scoring logic.';

MERGE INTO MART.REF_SCORE_WEIGHTS AS TGT
USING (
    SELECT *
    FROM
        VALUES
        (
            'CONSTRUCTION', 'Construction & Development Impact', 0.3200, TRUE, TRUE, 1,
            'Heaviest weight: the client brief identifies major construction as the dominant factor, and it is the most under-served question a buyer has.'
        ),
        (
            'COST_BURDEN', 'Cost Burden', 0.2000, TRUE, TRUE, 2,
            'Mello-Roos/CFD, HOA dues, tax rate area. Varies parcel to parcel and is invisible on listing sites — the strongest differentiator available.'
        ),
        (
            'ENVIRONMENT', 'Environment & Nuisance', 0.1600, TRUE, FALSE, 3,
            'JWA CNEL contours, AQMD violations, freeway and toll-road proximity, flood zone. Phase 2.'
        ),
        (
            'SCHOOLS', 'Schools & Amenities', 0.1200, TRUE, FALSE, 4,
            'IUSD vs. TUSD attendance boundary, parks, trails, community centres. The district split matters enormously to Irvine buyers. Phase 2.'
        ),
        (
            'SAFETY', 'Safety', 0.0600, TRUE, FALSE, 5,
            'Irvine PD incident data, aggregated to village. Included at client direction; see docs/compliance.md. Phase 2.'
        ),
        (
            'NEIGHBORHOOD', 'Neighborhood Context', 0.0400, TRUE, FALSE, 6,
            'Census ACS block-group context. Included at client direction; see docs/compliance.md. Phase 2.'
        ),
        (
            'SENTIMENT', 'Community Sentiment', 0.1000, FALSE, TRUE, 7,
            'Trust-weighted blend across civic, journalism, forum, and review tiers. Held to exactly 10% per the business model.')
            AS SRC (PILLAR_CODE, PILLAR_LABEL, WEIGHT, IS_OBJECTIVE, IS_ACTIVE, DISPLAY_ORDER, RATIONALE)
) AS SRC
    ON TGT.PILLAR_CODE = SRC.PILLAR_CODE
WHEN MATCHED THEN
    UPDATE SET
        TGT.PILLAR_LABEL = SRC.PILLAR_LABEL, TGT.WEIGHT = SRC.WEIGHT,
        TGT.IS_OBJECTIVE = SRC.IS_OBJECTIVE, TGT.IS_ACTIVE = SRC.IS_ACTIVE,
        TGT.DISPLAY_ORDER = SRC.DISPLAY_ORDER, TGT.RATIONALE = SRC.RATIONALE,
        TGT.UPDATED_AT = SYSDATE()
WHEN NOT MATCHED THEN INSERT
    (PILLAR_CODE, PILLAR_LABEL, WEIGHT, IS_OBJECTIVE, IS_ACTIVE, DISPLAY_ORDER, RATIONALE)
VALUES
(
    SRC.PILLAR_CODE, SRC.PILLAR_LABEL, SRC.WEIGHT, SRC.IS_OBJECTIVE,
    SRC.IS_ACTIVE, SRC.DISPLAY_ORDER, SRC.RATIONALE
);

-- -----------------------------------------------------------------------------
-- Scoring parameters: the constants in the impact formula. Config, not code, so
-- the decay distance can be tuned against real Irvine addresses without a deploy.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS MART.REF_SCORING_PARAMS (
    PARAM_NAME VARCHAR NOT NULL PRIMARY KEY,
    PARAM_VALUE NUMBER(12, 4) NOT NULL,
    UNIT VARCHAR,
    RATIONALE VARCHAR,
    UPDATED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE()
)
COMMENT = 'Constants in the scoring formulas. Tunable without touching scoring logic.';

MERGE INTO MART.REF_SCORING_PARAMS AS TGT
USING (
    SELECT *
    FROM
        VALUES
        (
            'DISTANCE_DECAY_METERS', 400.0000, 'metres',
            'e-folding distance for project impact. At 400m a project retains ~37% of its severity; at 800m ~14%. Chosen so an impact roughly matches what is audible and visible from a typical Irvine lot.'
        ),
        (
            'DISTANCE_CLIP_METERS', 1600.0000, 'metres',
            'Beyond one mile a project is not this parcel''s concern. Also bounds the proximity join.'
        ),
        ('PHASE_FACTOR_ACTIVE', 1.0000, 'multiplier', 'Happening now.'),
        ('PHASE_FACTOR_APPROVED', 0.8000, 'multiplier', 'Approved and funded; highly likely to proceed.'),
        (
            'PHASE_FACTOR_PENDING', 0.5000, 'multiplier',
            'Applied for but not approved. Half weight because it may never break ground — but included, because a buyer wants to know what has been filed.'
        ),
        (
            'PHASE_FACTOR_COMPLETE', 0.2000, 'multiplier',
            'Recently finished. Retains a little weight as evidence of area churn.'
        ),
        (
            'PHASE_FACTOR_UNKNOWN', 0.6000, 'multiplier',
            'Status unparseable. Between approved and pending; surfaced for review.'
        ),
        (
            'DURATION_FACTOR_MAX', 1.5000, 'multiplier',
            'Ceiling on the duration multiplier so one very long project cannot dominate a score outright.'
        ),
        (
            'DURATION_REFERENCE_MONTHS', 18.0000, 'months',
            'Duration scoring reference. An 18-month project scores 1.0; longer scales up to DURATION_FACTOR_MAX.'
        ),
        (
            'NEGATIVE_IMPACT_CAP', 60.0000, 'points',
            'Maximum points the construction pillar can lose. Prevents a cluster of small projects from zeroing a score that a human would not call unliveable.'
        ),
        (
            'POSITIVE_IMPACT_CAP', 25.0000, 'points',
            'Maximum points gained from beneficial projects. Deliberately below the negative cap: new parks do not cancel an asphalt plant, and the asymmetry is the honest reading.'
        ),
        (
            'SENTIMENT_MIN_DOCUMENTS', 3.0000, 'count',
            'Below this many documents for a village, the sentiment pillar returns INSUFFICIENT_DATA and its weight redistributes rather than reporting noise as signal.'
        ),
        (
            'CFD_HIGH_ANNUAL_THRESHOLD', 3000.0000, 'USD/year',
            'Annual special tax above which the cost pillar treats burden as materially high. Great Park and Portola Springs parcels commonly exceed this.'
        ),
        (
            'IMPACT_POINT_SCALE', 40.0000, 'points',
            'Converts a raw impact (0..1.5 after severity, decay, phase, and duration) into score points. At 40, a maximum-severity active project at zero distance costs 40 points before the duration factor, reaching the 60-point negative cap only for very long projects.'
        ),
        (
            'SCORE_CACHE_HOURS', 24.0000, 'hours',
            'How long a parcel score is reused before recomputation. The dominant per-request cost control.')
            AS SRC (PARAM_NAME, PARAM_VALUE, UNIT, RATIONALE)
) AS SRC
    ON TGT.PARAM_NAME = SRC.PARAM_NAME
WHEN MATCHED THEN
    UPDATE SET
        TGT.PARAM_VALUE = SRC.PARAM_VALUE, TGT.UNIT = SRC.UNIT,
        TGT.RATIONALE = SRC.RATIONALE, TGT.UPDATED_AT = SYSDATE()
WHEN NOT MATCHED THEN
    INSERT (PARAM_NAME, PARAM_VALUE, UNIT, RATIONALE)
    VALUES (SRC.PARAM_NAME, SRC.PARAM_VALUE, SRC.UNIT, SRC.RATIONALE);

GRANT SELECT ON TABLE MART.REF_SCORE_WEIGHTS TO ROLE IHA_APP;
GRANT SELECT ON TABLE MART.REF_SCORING_PARAMS TO ROLE IHA_APP;
GRANT SELECT ON TABLE MART.REF_SCORE_WEIGHTS TO ROLE IHA_ANALYST;
GRANT SELECT ON TABLE MART.REF_SCORING_PARAMS TO ROLE IHA_ANALYST;

-- -----------------------------------------------------------------------------
-- The 90/10 split is a business commitment, so it is checked rather than
-- assumed. This view is asserted by tests/test_scoring.sql; a weight edit that
-- breaks the split fails the gate instead of silently shipping.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW MART.VW_WEIGHT_INTEGRITY
COMMENT = 'Asserts objective weights sum to 0.90 and sentiment to 0.10. Any row with STATUS = FAIL blocks the verification gate.'
AS
WITH SUMS AS (
    SELECT
        SUM(CASE WHEN IS_OBJECTIVE THEN WEIGHT ELSE 0 END) AS OBJECTIVE_SUM,
        SUM(CASE WHEN NOT IS_OBJECTIVE THEN WEIGHT ELSE 0 END) AS SENTIMENT_SUM,
        SUM(WEIGHT) AS TOTAL_SUM
    FROM MART.REF_SCORE_WEIGHTS
)

SELECT
    'objective_weights_sum_to_0.90' AS CHECK_NAME,
    CASE WHEN ABS(OBJECTIVE_SUM - 0.90) < 0.0001 THEN 'PASS' ELSE 'FAIL' END AS STATUS,
    'actual=' || TO_VARCHAR(OBJECTIVE_SUM) AS DETAIL
FROM SUMS
UNION ALL
SELECT
    'sentiment_weight_is_0.10' AS CHECK_NAME,
    CASE WHEN ABS(SENTIMENT_SUM - 0.10) < 0.0001 THEN 'PASS' ELSE 'FAIL' END AS STATUS,
    'actual=' || TO_VARCHAR(SENTIMENT_SUM) AS DETAIL
FROM SUMS
UNION ALL
SELECT
    'weights_sum_to_1.00' AS CHECK_NAME,
    CASE WHEN ABS(TOTAL_SUM - 1.00) < 0.0001 THEN 'PASS' ELSE 'FAIL' END AS STATUS,
    'actual=' || TO_VARCHAR(TOTAL_SUM) AS DETAIL
FROM SUMS;
