-- =============================================================================
-- dim_village.sql
-- Irvine's master-planned villages.
--
-- Villages are how Irvine is actually discussed. Nobody posts about a parcel;
-- they post about Woodbridge or Portola Springs. So sentiment aggregates here
-- even though facts resolve to the parcel, and a ZIP-only query degrades to a
-- village-level report rather than failing.
--
-- ERA_BUILT is not decoration. It is the single best predictor of Mello-Roos
-- exposure: villages platted before CFD financing became standard practice
-- generally carry none. That is a hypothesis the parcel data confirms or
-- refutes per parcel — never a substitute for it, because adjacent phases of one
-- village can differ by thousands a year.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;

CREATE TABLE IF NOT EXISTS MART.DIM_VILLAGE (
    VILLAGE_CODE VARCHAR NOT NULL PRIMARY KEY,
    VILLAGE_NAME VARCHAR NOT NULL,
    ERA_BUILT VARCHAR NOT NULL,   -- decade or range the village was developed
    TYPICAL_CFD VARCHAR NOT NULL,   -- NONE | LOW | MODERATE | HIGH  (prior only)
    SCHOOL_DISTRICT VARCHAR,                  -- IUSD | TUSD | SPLIT
    ALIASES ARRAY,                    -- spellings seen in source data / user input
    NOTES VARCHAR,
    UPDATED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE()
)
COMMENT = 'Irvine master-planned villages. Unit of sentiment aggregation and the ZIP-query fallback. TYPICAL_CFD is a prior, never a substitute for parcel-level CFD data.';

MERGE INTO MART.DIM_VILLAGE AS TGT
USING (
    SELECT * FROM VALUES
    -- --------------------------------------------- older, generally no CFD
    (
        'WOODBRIDGE', 'Woodbridge', '1970s-1980s', 'NONE', 'IUSD',
        ARRAY_CONSTRUCT('WOODBRIDGE', 'WOOD BRIDGE'),
        'Two man-made lakes. Predates CFD financing; parcels typically carry no Mello-Roos, which is a meaningful cost advantage over newer villages.'
    ),
    (
        'NORTHWOOD', 'Northwood', '1970s-1990s', 'NONE', 'IUSD',
        ARRAY_CONSTRUCT('NORTHWOOD', 'NORTH WOOD'),
        'Mature trees, established. Generally no Mello-Roos. Northwood High School serves much of the area.'
    ),
    (
        'TURTLE_ROCK', 'Turtle Rock', '1970s-1980s', 'NONE', 'IUSD',
        ARRAY_CONSTRUCT('TURTLE ROCK', 'TURTLEROCK'),
        'Hillside, adjacent to UCI. Older stock, generally no CFD.'
    ),
    (
        'UNIVERSITY_PARK', 'University Park', '1960s-1970s', 'NONE', 'IUSD',
        ARRAY_CONSTRUCT('UNIVERSITY PARK', 'UNIV PARK'),
        'One of Irvine''s first villages. No Mello-Roos in most of it.'
    ),
    (
        'EL_CAMINO_REAL', 'El Camino Real', '1970s', 'NONE', 'IUSD',
        ARRAY_CONSTRUCT('EL CAMINO REAL'), 'Early village, central location.'
    ),
    (
        'CULVERDALE', 'Culverdale', '1970s', 'NONE', 'IUSD',
        ARRAY_CONSTRUCT('CULVERDALE'), 'Small early village.'
    ),
    (
        'RANCHO_SAN_JOAQUIN', 'Rancho San Joaquin', '1970s', 'NONE', 'IUSD',
        ARRAY_CONSTRUCT('RANCHO SAN JOAQUIN', 'RSJ'), 'Golf-adjacent, older stock.'
    ),
    (
        'WALNUT_VILLAGE', 'Walnut Village', '1970s-1980s', 'NONE', 'IUSD',
        ARRAY_CONSTRUCT('WALNUT VILLAGE', 'WALNUT'), 'Central, established.'
    ),
    (
        'COLLEGE_PARK', 'College Park', '1970s', 'NONE', 'IUSD',
        ARRAY_CONSTRUCT('COLLEGE PARK'), 'Compact early village.'
    ),

    -- ------------------------------------------------------ transitional
    (
        'WESTPARK', 'Westpark', '1980s-1990s', 'LOW', 'IUSD',
        ARRAY_CONSTRUCT('WESTPARK', 'WEST PARK'), 'Some phases carry modest assessments.'
    ),
    (
        'OAK_CREEK', 'Oak Creek', '1990s', 'LOW', 'IUSD',
        ARRAY_CONSTRUCT('OAK CREEK', 'OAKCREEK'), 'Golf-adjacent. Generally light CFD exposure.'
    ),
    (
        'NORTHPARK', 'Northpark', '1990s-2000s', 'MODERATE', 'IUSD',
        ARRAY_CONSTRUCT('NORTHPARK', 'NORTH PARK', 'NORTHPARK SQUARE'), 'Gated. Moderate assessments.'
    ),
    (
        'WEST_IRVINE', 'West Irvine', '1990s-2000s', 'MODERATE', 'TUSD',
        ARRAY_CONSTRUCT('WEST IRVINE'),
        'Served by Tustin Unified rather than Irvine Unified — a distinction that matters a great deal to buyers and is easy to miss.'
    ),
    (
        'LOWER_PETERS_CANYON', 'Lower Peters Canyon', '1990s-2000s', 'MODERATE', 'TUSD',
        ARRAY_CONSTRUCT('LOWER PETERS CANYON', 'PETERS CANYON'), 'TUSD attendance area.'
    ),
    (
        'COLUMBUS_GROVE', 'Columbus Grove', '2000s', 'HIGH', 'TUSD',
        ARRAY_CONSTRUCT('COLUMBUS GROVE'), 'Former MCAS Tustin land. TUSD; notable CFD.'
    ),

    -- ------------------------------------------- newer, CFD-heavy villages
    (
        'QUAIL_HILL', 'Quail Hill', '2000s', 'MODERATE', 'IUSD',
        ARRAY_CONSTRUCT('QUAIL HILL', 'QUAILHILL'), 'Hillside, trail access.'
    ),
    (
        'WOODBURY', 'Woodbury', '2000s', 'HIGH', 'IUSD',
        ARRAY_CONSTRUCT('WOODBURY', 'WOODBURY EAST'), 'Substantial Mello-Roos typical.'
    ),
    (
        'PORTOLA_SPRINGS', 'Portola Springs', '2000s-2010s', 'HIGH', 'IUSD',
        ARRAY_CONSTRUCT('PORTOLA SPRINGS', 'PORTOLA'),
        'Among the highest CFD burdens in the city. Verify per parcel: adjacent phases differ materially.'
    ),
    (
        'STONEGATE', 'Stonegate', '2010s', 'HIGH', 'IUSD',
        ARRAY_CONSTRUCT('STONEGATE', 'STONE GATE'), 'High CFD. Within the asphalt-plant complaint radius.'
    ),
    (
        'CYPRESS_VILLAGE', 'Cypress Village', '2010s', 'HIGH', 'IUSD',
        ARRAY_CONSTRUCT('CYPRESS VILLAGE', 'CYPRESS'), 'High CFD typical.'
    ),
    (
        'EASTWOOD_VILLAGE', 'Eastwood Village', '2010s', 'HIGH', 'IUSD',
        ARRAY_CONSTRUCT('EASTWOOD VILLAGE', 'EASTWOOD'), 'High CFD. Within the asphalt-plant complaint radius.'
    ),
    (
        'ORCHARD_HILLS', 'Orchard Hills', '2010s', 'HIGH', 'IUSD',
        ARRAY_CONSTRUCT('ORCHARD HILLS', 'ORCHARD HILL'),
        'Premium hillside, avocado groves. Also the village at the centre of the All American Asphalt odour dispute — the environment pillar should dominate its score for parcels near the plant.'
    ),
    (
        'GREAT_PARK', 'Great Park Neighborhoods', '2010s-2020s', 'HIGH', 'IUSD',
        ARRAY_CONSTRUCT(
            'GREAT PARK', 'BEACON PARK', 'CADENCE PARK', 'PAVILION PARK',
            'PARASOL PARK', 'RISE', 'SOLIS PARK', 'NOVEL PARK'
        ),
        'Newest large development on the former El Toro base. Highest CFD burdens in Irvine and ongoing construction — the village where this product has the most to say.'
    ),
    (
        'LAGUNA_ALTURA', 'Laguna Altura', '2010s', 'HIGH', 'IUSD',
        ARRAY_CONSTRUCT('LAGUNA ALTURA'), 'Gated, near the 133. High CFD.'
    ),
    (
        'TURTLE_RIDGE', 'Turtle Ridge', '2000s', 'MODERATE', 'IUSD',
        ARRAY_CONSTRUCT('TURTLE RIDGE'), 'Hillside, premium.'
    ),
    (
        'SHADY_CANYON', 'Shady Canyon', '2000s', 'MODERATE', 'IUSD',
        ARRAY_CONSTRUCT('SHADY CANYON'), 'Guard-gated luxury enclave.'
    ),
    (
        'LOS_OLIVOS', 'Los Olivos', '2000s-2010s', 'HIGH', 'IUSD',
        ARRAY_CONSTRUCT('LOS OLIVOS'), 'Apartment-heavy, near the Great Park.'
    ),

    -- -------------------------------------------------- non-village areas
    (
        'IBC', 'Irvine Business Complex', '1980s-2020s', 'MODERATE', 'SPLIT',
        ARRAY_CONSTRUCT('IBC', 'IRVINE BUSINESS COMPLEX', 'CENTRAL PARK WEST'),
        'High-density mixed use near John Wayne Airport. The part of Irvine most exposed to aircraft noise contours and high-rise development.'
    ),
    (
        'UNKNOWN', 'Unknown / outside village boundaries', 'n/a', 'NONE', NULL,
        ARRAY_CONSTRUCT('UNKNOWN'),
        'Fallback when a parcel does not resolve to a village. Reports say so rather than guessing.')
        AS SRC (VILLAGE_CODE, VILLAGE_NAME, ERA_BUILT, TYPICAL_CFD, SCHOOL_DISTRICT, ALIASES, NOTES)
) AS SRC
    ON TGT.VILLAGE_CODE = SRC.VILLAGE_CODE
WHEN MATCHED THEN
    UPDATE SET
        TGT.VILLAGE_NAME = SRC.VILLAGE_NAME, TGT.ERA_BUILT = SRC.ERA_BUILT,
        TGT.TYPICAL_CFD = SRC.TYPICAL_CFD, TGT.SCHOOL_DISTRICT = SRC.SCHOOL_DISTRICT,
        TGT.ALIASES = SRC.ALIASES, TGT.NOTES = SRC.NOTES, TGT.UPDATED_AT = SYSDATE()
WHEN NOT MATCHED THEN INSERT
    (VILLAGE_CODE, VILLAGE_NAME, ERA_BUILT, TYPICAL_CFD, SCHOOL_DISTRICT, ALIASES, NOTES)
VALUES
(
    SRC.VILLAGE_CODE, SRC.VILLAGE_NAME, SRC.ERA_BUILT, SRC.TYPICAL_CFD,
    SRC.SCHOOL_DISTRICT, SRC.ALIASES, SRC.NOTES
);

GRANT SELECT ON TABLE MART.DIM_VILLAGE TO ROLE IHA_APP;
GRANT SELECT ON TABLE MART.DIM_VILLAGE TO ROLE IHA_ANALYST;
