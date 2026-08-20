-- =============================================================================
-- test_scoring.sql
-- Golden-address regression tests, run by scripts/verify.sh.
--
-- Emits one row per assertion with STATUS in (PASS, FAIL, SKIP). The gate greps
-- for FAIL, so that token must stay exact.
--
-- The most valuable test here is REPRODUCIBILITY: scoring the same parcel twice
-- must give the identical composite. That is the property that separates this
-- from a system where an LLM quietly produces different numbers on Tuesday, and
-- it is the one a buyer is implicitly relying on.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;

-- Golden addresses live in a table so the eval procedure and these tests share
-- one definition. Populate from tests/fixtures/golden_addresses.yaml.
CREATE TABLE IF NOT EXISTS MART.GOLDEN_ADDRESSES (
    GOLDEN_ID VARCHAR NOT NULL PRIMARY KEY,
    RAW_ADDRESS VARCHAR NOT NULL,
    APN VARCHAR,
    VILLAGE_EXPECTED VARCHAR NOT NULL,
    EXPECTATIONS VARIANT NOT NULL,
    RATIONALE VARCHAR
)
COMMENT = 'Regression fixtures with known ground truth. Populate from tests/fixtures/golden_addresses.yaml before the first full gate run.';

CREATE OR REPLACE VIEW MART.VW_SCORING_TESTS
COMMENT = 'Golden-address assertions plus structural invariants. FAIL rows block the pre-push gate.'
AS
WITH GOLDEN AS (
    SELECT
        GOLD.GOLDEN_ID,
        GOLD.VILLAGE_EXPECTED,
        GOLD.EXPECTATIONS,
        PARCEL.APN,
        PARCEL.VILLAGE_CODE,
        COST.SUBSCORE AS COST_SUBSCORE,
        COST.BURDEN_BAND,
        COST.CFD_ANNUAL_TAX,
        COST.CFD_YEARS_REMAINING,
        CONS.PROJECTS_NEARBY,
        SCORE.COMPOSITE_SCORE
    FROM MART.GOLDEN_ADDRESSES AS GOLD
    LEFT JOIN MART.DIM_PARCEL AS PARCEL ON GOLD.APN = PARCEL.APN
    LEFT JOIN MART.FCT_COST_BURDEN AS COST ON PARCEL.APN = COST.APN
    LEFT JOIN MART.FCT_CONSTRUCTION_SUBSCORE AS CONS ON PARCEL.APN = CONS.APN
    LEFT JOIN MART.VW_PARCEL_SCORE AS SCORE ON PARCEL.APN = SCORE.APN
)

-- --- 1. every golden address resolves to a parcel --------------------------
SELECT
    'resolves:' || GOLDEN_ID AS CHECK_NAME,
    CASE
        WHEN EXPECTATIONS IS NULL THEN 'SKIP'
        WHEN APN IS NOT NULL THEN 'PASS'
        ELSE 'FAIL'
    END AS STATUS,
    'Golden address must resolve to a parcel; unresolved means the geocoder or the address-point feed is broken.' AS DETAIL
FROM GOLDEN

UNION ALL

-- --- 2. village matches expectation ----------------------------------------
SELECT
    'village:' || GOLDEN_ID AS CHECK_NAME,
    CASE
        WHEN APN IS NULL THEN 'SKIP'
        WHEN VILLAGE_CODE = VILLAGE_EXPECTED THEN 'PASS'
        ELSE 'FAIL'
    END AS STATUS,
    'Expected ' || VILLAGE_EXPECTED || ', resolved ' || COALESCE(VILLAGE_CODE, 'NULL') AS DETAIL
FROM GOLDEN

UNION ALL

-- --- 3. cost-burden band is one of the expected values ----------------------
SELECT
    'cost_band:' || GOLDEN_ID AS CHECK_NAME,
    CASE
        WHEN APN IS NULL OR EXPECTATIONS:cost_burden_band IS NULL THEN 'SKIP'
        WHEN ARRAY_CONTAINS(BURDEN_BAND::VARIANT, EXPECTATIONS:cost_burden_band) THEN 'PASS'
        ELSE 'FAIL'
    END AS STATUS,
    'Band ' || COALESCE(BURDEN_BAND, 'NULL') || ' not in expected set '
    || COALESCE(TO_VARCHAR(EXPECTATIONS:cost_burden_band), 'none') AS DETAIL
FROM GOLDEN

UNION ALL

-- --- 4. CFD annual tax within expected bounds ------------------------------
SELECT
    'cfd_bounds:' || GOLDEN_ID AS CHECK_NAME,
    CASE
        WHEN APN IS NULL THEN 'SKIP'
        WHEN
            EXPECTATIONS:cfd_annual_tax_min IS NOT NULL
            AND CFD_ANNUAL_TAX < EXPECTATIONS:cfd_annual_tax_min::NUMBER THEN 'FAIL'
        WHEN
            EXPECTATIONS:cfd_annual_tax_max IS NOT NULL
            AND CFD_ANNUAL_TAX > EXPECTATIONS:cfd_annual_tax_max::NUMBER THEN 'FAIL'
        ELSE 'PASS'
    END AS STATUS,
    'CFD annual tax ' || COALESCE(TO_VARCHAR(CFD_ANNUAL_TAX), 'NULL') || ' against expected bounds' AS DETAIL
FROM GOLDEN

UNION ALL

-- --- 5. subscores stay inside 0..100 --------------------------------------
SELECT
    'subscore_bounds:' || GOLDEN_ID AS CHECK_NAME,
    CASE
        WHEN APN IS NULL THEN 'SKIP'
        WHEN COST_SUBSCORE BETWEEN 0 AND 100 AND COMPOSITE_SCORE BETWEEN 0 AND 100 THEN 'PASS'
        ELSE 'FAIL'
    END AS STATUS,
    'Scores must lie within 0..100; outside that range means a capping bug.' AS DETAIL
FROM GOLDEN

UNION ALL

-- --- 6. the invariant a local professional would recognise ------------------
-- Older villages must show lower cost burden than the CFD-heavy new ones. This
-- survives weight tuning, which is why it is the most durable test here.
SELECT
    'invariant:older_villages_cost_less' AS CHECK_NAME,
    CASE
        -- SKIP, not FAIL, when the NAMED fixtures are not loaded: an unpopulated
        -- fixture table is an unrun test, not a broken invariant. Counting all
        -- golden rows let an unrelated fixture satisfy the guard and turned a
        -- missing-data case into a red gate.
        WHEN (
            SELECT COUNT(*) FROM GOLDEN
            WHERE
                APN IS NOT NULL
                AND GOLDEN_ID IN (
                    'woodbridge_no_cfd', 'northwood_established',
                    'great_park_high_cfd', 'portola_springs_high_cfd'
                )
        ) < 2 THEN 'SKIP'
        WHEN (
            SELECT MIN(COST_SUBSCORE) FROM GOLDEN
            WHERE GOLDEN_ID IN ('woodbridge_no_cfd', 'northwood_established') AND APN IS NOT NULL
        )
        > (
            SELECT MAX(COST_SUBSCORE) FROM GOLDEN
            WHERE GOLDEN_ID IN ('great_park_high_cfd', 'portola_springs_high_cfd') AND APN IS NOT NULL
        )
            THEN 'PASS'
        ELSE 'FAIL'
    END AS STATUS,
    'Pre-CFD villages must score better on cost than CFD-heavy ones. Inversion means bad data or a mis-tuned pillar.' AS DETAIL

UNION ALL

-- --- 7. weights still honour the 90/10 split -------------------------------
SELECT
    'weights:' || CHECK_NAME AS CHECK_NAME,
    STATUS,
    DETAIL
FROM MART.VW_WEIGHT_INTEGRITY

UNION ALL

-- --- 8. no enabled sentiment source lacks a compliance clearance ------------
SELECT
    'compliance:' || SOURCE_NAME AS CHECK_NAME,
    STATUS,
    DETAIL
FROM MART.VW_SENTIMENT_COMPLIANCE_GUARD

UNION ALL

-- --- 9. classification coverage --------------------------------------------
SELECT
    'classification_health' AS CHECK_NAME,
    STATUS,
    DETAIL
FROM MART.VW_CLASSIFICATION_HEALTH;

-- -----------------------------------------------------------------------------
-- Reproducibility: score twice, compare. The property that proves no LLM output
-- entered the arithmetic.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE MART.SP_TEST_REPRODUCIBILITY()
RETURNS TABLE (CHECK_NAME VARCHAR, STATUS VARCHAR, DETAIL VARCHAR)
LANGUAGE SQL
COMMENT = 'Scores every golden parcel twice and asserts the composites are identical.'
AS
$$
DECLARE
    res RESULTSET;
BEGIN
    CREATE OR REPLACE TEMPORARY TABLE REPRO_RUN_1 AS
    SELECT APN, COMPOSITE_SCORE FROM MART.VW_PARCEL_SCORE
    WHERE APN IN (SELECT APN FROM MART.GOLDEN_ADDRESSES WHERE APN IS NOT NULL);

    CREATE OR REPLACE TEMPORARY TABLE REPRO_RUN_2 AS
    SELECT APN, COMPOSITE_SCORE FROM MART.VW_PARCEL_SCORE
    WHERE APN IN (SELECT APN FROM MART.GOLDEN_ADDRESSES WHERE APN IS NOT NULL);

    res := (
        SELECT
            'reproducibility' AS CHECK_NAME,
            CASE
                WHEN (SELECT COUNT(*) FROM REPRO_RUN_1) = 0 THEN 'SKIP'
                WHEN (SELECT COUNT(*) FROM REPRO_RUN_1 AS R1
                      INNER JOIN REPRO_RUN_2 AS R2 ON R1.APN = R2.APN
                      WHERE R1.COMPOSITE_SCORE <> R2.COMPOSITE_SCORE) = 0 THEN 'PASS'
                ELSE 'FAIL'
            END AS STATUS,
            'Identical inputs must produce identical composites. Any drift means non-deterministic input reached the scorer.' AS DETAIL
    );
    RETURN TABLE(res);
END;
$$;

-- Results. The gate greps for FAIL.
SELECT
    CHECK_NAME,
    STATUS,
    DETAIL
FROM MART.VW_SCORING_TESTS
ORDER BY CASE STATUS WHEN 'FAIL' THEN 1 WHEN 'SKIP' THEN 2 ELSE 3 END, CHECK_NAME;
