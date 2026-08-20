-- =============================================================================
-- seed_golden_addresses.sql
--
-- GENERATED FILE — do not edit by hand.
-- Source: tests/fixtures/golden_addresses.yaml
-- Regenerate: python3 scripts/gen_golden_seed.py
--
-- Loads the regression fixtures and resolves each to a parcel. Resolution
-- happens here rather than being hard-coded, so the seed exercises the same
-- geocoder the product uses: if address matching regresses, these rows stop
-- resolving and the golden tests report it.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;

MERGE INTO MART.GOLDEN_ADDRESSES AS TGT
USING (
    SELECT *
    FROM
        VALUES
        ('woodbridge_no_cfd', '11 Bayview, Irvine, CA 92614', 'WOODBRIDGE', PARSE_JSON('{"cost_burden_band": ["NO_SPECIAL_ASSESSMENTS", "HOA_ONLY"], "cfd_annual_tax_max": 500, "cost_subscore_min": 75}'), 'Woodbridge was platted in the 1970s-80s, before CFD financing became standard. Parcels there should carry no Mello-Roos, which is the single clearest cost-pillar signal available.'),
        ('great_park_high_cfd', '136 Charlie, Irvine, CA 92618', 'GREAT_PARK', PARSE_JSON('{"cost_burden_band": ["MODERATE_CFD", "HIGH_CFD"], "cfd_annual_tax_min": 1500, "cfd_years_remaining_min": 5, "construction_projects_min": 1}'), 'Newest large development, on the former El Toro base. Should show a substantial special tax with a long remaining term, and active nearby construction. If this parcel shows no CFD, the parcel feed is wrong.'),
        ('orchard_hills_environment', '68 Copper Mine, Irvine, CA 92602', 'ORCHARD_HILLS', PARSE_JSON('{"cost_burden_band": ["MODERATE_CFD", "HIGH_CFD"], "_pending_phase_2": {"environment_top_finding_contains": "asphalt"}}'), 'The village at the centre of the All American Asphalt odour dispute — 800+ AQMD complaints, litigation by 2,000+ homeowners, and a City-mandated buyer disclosure. Once Phase 2 lands AQMD data, this address must surface that as a top negative finding. Until then the assertion is only that the parcel resolves and scores; the environment expectation is marked pending so the test does not silently pass for the wrong reason.'),
        ('northwood_established', '17 Ensueno W, Irvine, CA 92620', 'NORTHWOOD', PARSE_JSON('{"cost_burden_band": ["NO_SPECIAL_ASSESSMENTS", "HOA_ONLY", "LOW_CFD"], "cost_subscore_min": 70}'), 'Established 1970s-90s village, mature, generally no Mello-Roos. Should score well on cost and show little active construction — the profile of a settled neighbourhood.'),
        ('portola_springs_high_cfd', '194 Firefly, Irvine, CA 92618', 'PORTOLA_SPRINGS', PARSE_JSON('{"cost_burden_band": ["MODERATE_CFD", "HIGH_CFD"], "cfd_annual_tax_min": 1500}'), 'Among the highest CFD burdens in the city. Included alongside Great Park so the cost pillar is exercised on two independent high-burden villages rather than one.')
            AS SRC (GOLDEN_ID, RAW_ADDRESS, VILLAGE_EXPECTED, EXPECTATIONS, RATIONALE)
) AS SRC
    ON TGT.GOLDEN_ID = SRC.GOLDEN_ID
WHEN MATCHED THEN
    UPDATE SET
        TGT.RAW_ADDRESS = SRC.RAW_ADDRESS,
        TGT.VILLAGE_EXPECTED = SRC.VILLAGE_EXPECTED,
        TGT.EXPECTATIONS = SRC.EXPECTATIONS,
        TGT.RATIONALE = SRC.RATIONALE
WHEN NOT MATCHED THEN INSERT
    (GOLDEN_ID, RAW_ADDRESS, VILLAGE_EXPECTED, EXPECTATIONS, RATIONALE)
VALUES
(
    SRC.GOLDEN_ID, SRC.RAW_ADDRESS, SRC.VILLAGE_EXPECTED,
    SRC.EXPECTATIONS, SRC.RATIONALE
);

-- Resolve each fixture to a parcel using the product's own resolver. A fixture
-- that fails to resolve leaves APN NULL, and tests/test_scoring.sql reports
-- that as a FAIL on "resolves:<id>" rather than skipping quietly.
UPDATE MART.GOLDEN_ADDRESSES AS GOLD
SET APN = RESOLVED.APN
FROM (
    SELECT
        SRC.GOLDEN_ID,
        RES.APN
    FROM MART.GOLDEN_ADDRESSES AS SRC,
        LATERAL TABLE(APP.FN_RESOLVE_ADDRESS(SRC.RAW_ADDRESS)) AS RES
    WHERE RES.MATCH_CONFIDENCE IN ('EXACT', 'FUZZY')
) AS RESOLVED
WHERE GOLD.GOLDEN_ID = RESOLVED.GOLDEN_ID;

-- Report what landed, so a deploy shows resolution health immediately.
SELECT
    GOLDEN_ID,
    RAW_ADDRESS,
    VILLAGE_EXPECTED,
    COALESCE(APN, '<unresolved>') AS APN,
    IFF(APN IS NULL, 'FAIL', 'PASS') AS STATUS,
    'Golden fixture must resolve to a parcel for its assertions to run.' AS DETAIL
FROM MART.GOLDEN_ADDRESSES
ORDER BY GOLDEN_ID;
