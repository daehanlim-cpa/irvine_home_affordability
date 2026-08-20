-- =============================================================================
-- dim_parcel.sql
-- One row per Irvine parcel: geometry, cost attributes, village, and the
-- normalised address strings the geocoder matches against.
--
-- This is the spine. Every pillar joins to it, and the address a user types
-- resolves here before anything else happens.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;

CREATE OR REPLACE VIEW MART.DIM_PARCEL
COMMENT = 'One row per parcel with address, geometry, village, and cost attributes. The join spine for every scoring pillar.'
AS
WITH VILLAGE_LOOKUP AS (
    -- Source data spells village names inconsistently, so match through the
    -- alias array rather than on the literal string.
    SELECT
        VIL.VILLAGE_CODE,
        VIL.VILLAGE_NAME,
        VIL.TYPICAL_CFD,
        VIL.SCHOOL_DISTRICT,
        VIL.ERA_BUILT,
        UPPER(TRIM(ALIAS.VALUE::VARCHAR)) AS ALIAS_UPPER
    FROM MART.DIM_VILLAGE AS VIL,
        LATERAL FLATTEN(INPUT => VIL.ALIASES) AS ALIAS
),

ADDRESSES AS (
    -- A parcel can carry several address points (corner lots, duplexes). Keep
    -- the lowest house number as the canonical display address; all points
    -- remain matchable through STG_ADDRESS_POINTS.
    SELECT
        APN,
        ADDRESS_NORMALIZED,
        HOUSE_NUMBER,
        STREET_NAME,
        STREET_TYPE,
        ZIP_CODE,
        VILLAGE_RAW,
        GEOM_POINT,
        COUNT(*) OVER (PARTITION BY APN) AS ADDRESS_POINT_COUNT
    FROM STAGE.STG_ADDRESS_POINTS
    QUALIFY ROW_NUMBER() OVER (PARTITION BY APN ORDER BY HOUSE_NUMBER, UNIT_NUMBER) = 1
)

SELECT
    PARCEL.APN,
    ADDR.ADDRESS_NORMALIZED,
    ADDR.HOUSE_NUMBER,
    ADDR.STREET_NAME,
    ADDR.STREET_TYPE,
    ADDR.ZIP_CODE,
    ADDR.ADDRESS_POINT_COUNT,
    COALESCE(VIL.VILLAGE_CODE, 'UNKNOWN') AS VILLAGE_CODE,
    COALESCE(VIL.VILLAGE_NAME, 'Unknown') AS VILLAGE_NAME,
    VIL.SCHOOL_DISTRICT,
    VIL.ERA_BUILT,
    VIL.TYPICAL_CFD AS VILLAGE_TYPICAL_CFD,
    PARCEL.ZONING_CODE,
    PARCEL.LOT_SQFT,
    PARCEL.YEAR_BUILT,
    PARCEL.CFD_NAME,
    PARCEL.CFD_ANNUAL_TAX,
    PARCEL.CFD_YEARS_REMAINING,
    PARCEL.CFD_REMAINING_OBLIGATION,
    PARCEL.TAX_RATE_AREA,
    PARCEL.HOA_DUES_MONTHLY,
    -- Prefer the address point for proximity maths; fall back to the parcel
    -- centroid when a parcel carries no address point.
    COALESCE(ADDR.GEOM_POINT, PARCEL.GEOM_CENTROID) AS GEOM_POINT,
    PARCEL.GEOM_PARCEL,
    PARCEL.INGESTED_AT AS PARCEL_AS_OF
FROM STAGE.STG_PARCELS_CFD AS PARCEL
LEFT JOIN ADDRESSES AS ADDR
    ON PARCEL.APN = ADDR.APN
LEFT JOIN VILLAGE_LOOKUP AS VIL
    ON UPPER(TRIM(COALESCE(PARCEL.VILLAGE_RAW, ADDR.VILLAGE_RAW))) = VIL.ALIAS_UPPER;

GRANT SELECT ON VIEW MART.DIM_PARCEL TO ROLE IHA_APP;
GRANT SELECT ON VIEW MART.DIM_PARCEL TO ROLE IHA_ANALYST;
