-- =============================================================================
-- stg_address_points.sql
-- Typed, deduplicated view over RAW.R_IRVINE_ADDRESS_POINTS.
--
-- This is the geocoder. An address string resolves to a parcel here, which is
-- what makes parcel-level Mello-Roos possible without a paid geocoding API.
--
-- FIELD NAMES: ArcGIS layers do not publish a stable schema, and the exact
-- attribute names are not knowable until the first ingest lands. The COALESCE
-- chains below cover the common variants Esri/Irvine deployments use. After the
-- first run, inspect:
--     SELECT DISTINCT f.value:properties FROM RAW.R_IRVINE_ADDRESS_POINTS,
--     LATERAL FLATTEN(_PAYLOAD:features) f LIMIT 5;
-- and collapse each chain to the single real field. Leaving the chains in place
-- costs nothing but hides drift, so collapse them.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA STAGE;

CREATE OR REPLACE VIEW STAGE.STG_ADDRESS_POINTS
COMMENT = 'One row per Irvine address point, latest ingest wins. Geocoding source for parcel resolution.'
AS
WITH FLATTENED AS (
    SELECT
        RAW_SRC._INGESTED_AT,
        RAW_SRC._BATCH_ID,
        FEAT.VALUE:properties AS PROPS,
        FEAT.VALUE:geometry AS GEOM
    FROM RAW.R_IRVINE_ADDRESS_POINTS AS RAW_SRC,
        LATERAL FLATTEN(INPUT => RAW_SRC._PAYLOAD:features) AS FEAT
),

TYPED AS (
    SELECT
        -- Assessor parcel number: the join key to everything in the cost pillar.
        UPPER(TRIM(COALESCE(
            PROPS:APN::VARCHAR,
            PROPS:APN_NUM::VARCHAR,
            PROPS:ParcelAPN::VARCHAR,
            PROPS:PARCEL_APN::VARCHAR
        ))) AS APN,

        TRY_TO_NUMBER(COALESCE(
            PROPS:HouseNumber::VARCHAR,
            PROPS:HOUSE_NUM::VARCHAR,
            PROPS:AddressNumber::VARCHAR,
            PROPS:STREETNUM::VARCHAR
        )) AS HOUSE_NUMBER,

        UPPER(TRIM(COALESCE(
            PROPS:StreetName::VARCHAR,
            PROPS:STREET_NAME::VARCHAR,
            PROPS:STREETNAME::VARCHAR
        ))) AS STREET_NAME,

        UPPER(TRIM(COALESCE(
            PROPS:StreetType::VARCHAR,
            PROPS:STREET_TYPE::VARCHAR,
            PROPS:SUFFIX::VARCHAR
        ))) AS STREET_TYPE,

        UPPER(TRIM(COALESCE(
            PROPS:UnitNumber::VARCHAR,
            PROPS:UNIT::VARCHAR
        ))) AS UNIT_NUMBER,

        TRIM(COALESCE(
            PROPS:ZIP::VARCHAR,
            PROPS:ZIPCODE::VARCHAR,
            PROPS:PostalCode::VARCHAR
        )) AS ZIP_CODE,

        UPPER(TRIM(COALESCE(
            PROPS:Village::VARCHAR,
            PROPS:VILLAGE::VARCHAR,
            PROPS:PlanningArea::VARCHAR,
            PROPS:NEIGHBORHOOD::VARCHAR
        ))) AS VILLAGE_RAW,

        -- GeoJSON point coordinates are [lon, lat].
        TRY_TO_DOUBLE(GEOM:coordinates[0]::VARCHAR) AS LONGITUDE,
        TRY_TO_DOUBLE(GEOM:coordinates[1]::VARCHAR) AS LATITUDE,
        _INGESTED_AT,
        _BATCH_ID
    FROM FLATTENED
)

SELECT
    APN,
    HOUSE_NUMBER,
    STREET_NAME,
    STREET_TYPE,
    UNIT_NUMBER,
    ZIP_CODE,
    VILLAGE_RAW,
    LONGITUDE,
    LATITUDE,
    -- Materialised as GEOGRAPHY so ST_DWITHIN proximity joins in the
    -- construction pillar can use it directly.
    ST_MAKEPOINT(LONGITUDE, LATITUDE) AS GEOM_POINT,
    -- Normalised form the address matcher compares against.
    HOUSE_NUMBER || ' ' || STREET_NAME || COALESCE(' ' || STREET_TYPE, '') AS ADDRESS_NORMALIZED,
    _INGESTED_AT AS INGESTED_AT
FROM TYPED
WHERE
    LONGITUDE IS NOT NULL
    AND LATITUDE IS NOT NULL
    AND HOUSE_NUMBER IS NOT NULL
    AND STREET_NAME IS NOT NULL
-- Latest ingest wins per address. RAW is append-only, so every historical
-- version is still there if a value ever needs to be explained.
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY HOUSE_NUMBER, STREET_NAME, COALESCE(UNIT_NUMBER, '')
    ORDER BY _INGESTED_AT DESC
) = 1;
