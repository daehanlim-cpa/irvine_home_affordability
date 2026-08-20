-- =============================================================================
-- stg_parcels_cfd.sql
-- Parcel geometry and Community Facilities District (Mello-Roos) membership.
--
-- The cost pillar's differentiator. CFD burden varies between adjacent phases of
-- the same tract — two visually identical homes a block apart can differ by
-- thousands a year — so this must never be aggregated above the parcel.
--
-- Owner-name attributes, if the layer carries them, are deliberately NOT
-- selected. This product analyses property, not people.
--
-- See stg_address_points.sql on collapsing the COALESCE chains after first run.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA STAGE;

CREATE OR REPLACE VIEW STAGE.STG_PARCELS_CFD
COMMENT = 'One row per parcel with CFD/Mello-Roos burden and remaining term. Parcel-level by design; never aggregate cost burden upward.'
AS
WITH FLATTENED AS (
    SELECT
        RAW_SRC._INGESTED_AT,
        FEAT.VALUE:properties AS PROPS,
        FEAT.VALUE:geometry AS GEOM
    FROM RAW.R_IRVINE_PARCELS_CFD AS RAW_SRC,
        LATERAL FLATTEN(INPUT => RAW_SRC._PAYLOAD:features) AS FEAT
),

TYPED AS (
    SELECT
        UPPER(TRIM(COALESCE(
            PROPS:APN::VARCHAR, PROPS:APN_NUM::VARCHAR, PROPS:ParcelAPN::VARCHAR
        ))) AS APN,

        UPPER(TRIM(COALESCE(
            PROPS:Village::VARCHAR, PROPS:VILLAGE::VARCHAR, PROPS:PlanningArea::VARCHAR
        ))) AS VILLAGE_RAW,

        UPPER(TRIM(COALESCE(
            PROPS:ZoneCode::VARCHAR, PROPS:ZONING::VARCHAR, PROPS:ZONE::VARCHAR
        ))) AS ZONING_CODE,

        TRY_TO_NUMBER(COALESCE(
            PROPS:LotSizeSqFt::VARCHAR, PROPS:LOT_SQFT::VARCHAR, PROPS:SHAPE_Area::VARCHAR
        )) AS LOT_SQFT,

        TRY_TO_NUMBER(COALESCE(
            PROPS:YearBuilt::VARCHAR, PROPS:YEAR_BUILT::VARCHAR
        )) AS YEAR_BUILT,

        -- CFD membership. A parcel may belong to more than one district; the
        -- layer typically exposes the primary. Absence means no Mello-Roos,
        -- which is itself a strong positive signal in older villages such as
        -- Woodbridge, Northwood, and Turtle Rock.
        TRIM(COALESCE(
            PROPS:CFD::VARCHAR, PROPS:CFD_NAME::VARCHAR,
            PROPS:CFD_NUMBER::VARCHAR, PROPS:IUSD_CFD::VARCHAR
        )) AS CFD_NAME,

        TRY_TO_DECIMAL(COALESCE(
            PROPS:CFD_AnnualTax::VARCHAR, PROPS:SPECIAL_TAX::VARCHAR,
            PROPS:CFD_TAX::VARCHAR
        ), 12, 2) AS CFD_ANNUAL_TAX,

        -- The field almost nobody surfaces, and the one that most changes a
        -- purchase decision: a special tax with 3 years left and one with 28
        -- are entirely different propositions at the same annual figure.
        TRY_TO_NUMBER(COALESCE(
            PROPS:CFD_MaturityYear::VARCHAR, PROPS:CFD_END_YEAR::VARCHAR,
            PROPS:MATURITY_YEAR::VARCHAR
        )) AS CFD_MATURITY_YEAR,

        TRIM(COALESCE(
            PROPS:TaxRateArea::VARCHAR, PROPS:TRA::VARCHAR
        )) AS TAX_RATE_AREA,

        TRY_TO_DECIMAL(COALESCE(
            PROPS:HOA_Dues_Monthly::VARCHAR, PROPS:HOA_DUES::VARCHAR
        ), 10, 2) AS HOA_DUES_MONTHLY,

        TO_GEOGRAPHY(GEOM, TRUE) AS GEOM_PARCEL,
        _INGESTED_AT
    FROM FLATTENED
)

SELECT
    APN,
    VILLAGE_RAW,
    ZONING_CODE,
    LOT_SQFT,
    YEAR_BUILT,
    CFD_NAME,
    -- NOT coalesced to zero. "No special tax recorded" and "the layer did not
    -- publish a figure" are different claims, and telling a buyer there is no
    -- Mello-Roos when we simply do not know is the most damaging thing this
    -- product could say. The band logic below distinguishes them.
    CFD_ANNUAL_TAX,
    CFD_NAME IS NOT NULL AND CFD_ANNUAL_TAX IS NULL AS CFD_AMOUNT_UNKNOWN,
    CFD_MATURITY_YEAR,
    CASE
        WHEN CFD_MATURITY_YEAR IS NULL THEN NULL
        ELSE GREATEST(CFD_MATURITY_YEAR - YEAR(SYSDATE()), 0)
    END AS CFD_YEARS_REMAINING,
    -- Total remaining obligation. The number a buyer actually needs, and one no
    -- listing site computes.
    CASE
        WHEN CFD_MATURITY_YEAR IS NULL OR CFD_ANNUAL_TAX IS NULL THEN NULL
        ELSE CFD_ANNUAL_TAX * GREATEST(CFD_MATURITY_YEAR - YEAR(SYSDATE()), 0)
    END AS CFD_REMAINING_OBLIGATION,
    TAX_RATE_AREA,
    COALESCE(HOA_DUES_MONTHLY, 0) AS HOA_DUES_MONTHLY,
    GEOM_PARCEL,
    ST_CENTROID(GEOM_PARCEL) AS GEOM_CENTROID,
    _INGESTED_AT AS INGESTED_AT
FROM TYPED
WHERE APN IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY APN ORDER BY _INGESTED_AT DESC) = 1;
