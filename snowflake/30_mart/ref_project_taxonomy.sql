-- =============================================================================
-- ref_project_taxonomy.sql
-- The severity lookup. THE most important table in this platform.
--
-- Cortex classifies a project into CATEGORY_CODE. This table turns that category
-- into a number. The LLM never produces the number itself, which is what makes
-- every score reproducible, auditable, and tunable by UPDATE rather than deploy.
--
-- IMPACT_SIGN encodes the judgement that construction is not uniformly bad. A
-- new elementary school 400 feet away is "major construction" and it is good
-- news; a three-year arterial widening at the same distance is not. Scoring both
-- as a penalty would produce numbers no Irvine buyer would believe.
--
-- SEVERITY is 0..1, the disruption or benefit magnitude before distance decay.
-- Anchors, so future edits stay on the same scale:
--     1.00  changes whether you would live there (asphalt plant, waste facility)
--     0.80  materially degrades or improves daily life for years
--     0.50  noticeable, bounded
--     0.20  background
--
-- Tuning: UPDATE a row, re-run tests/test_scoring.sql, commit. Weight and
-- severity changes are reviewable in the diff, which is the point.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;

CREATE TABLE IF NOT EXISTS MART.REF_PROJECT_TAXONOMY (
    CATEGORY_CODE VARCHAR NOT NULL PRIMARY KEY,
    CATEGORY_LABEL VARCHAR NOT NULL,
    IMPACT_SIGN NUMBER(2, 0) NOT NULL,   -- -1 harmful, 0 neutral, +1 beneficial
    SEVERITY NUMBER(4, 3) NOT NULL,   -- 0..1 magnitude before distance decay
    RATIONALE VARCHAR NOT NULL,
    UPDATED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE()
)
COMMENT = 'Maps an AI_CLASSIFY category to a deterministic signed severity. The LLM picks the category; this table supplies every number.';

MERGE INTO MART.REF_PROJECT_TAXONOMY AS TGT
USING (
    SELECT * FROM VALUES
    -- ---------------------------------------------------------- harmful
    (
        'ASPHALT_CONCRETE_PLANT', 'Asphalt or concrete batch plant', -1, 1.000,
        'Persistent odour and VOC emissions. The All American Asphalt site drew 800+ AQMD complaints and a suit by 2,000+ homeowners; the City now requires buyer disclosure nearby. Nothing else on this list changes a purchase decision more.'
    ),
    (
        'WASTE_FACILITY', 'Waste transfer or processing facility', -1, 1.000,
        'Odour, heavy truck traffic, and vector concerns. Effectively disqualifying at close range.'
    ),
    (
        'INDUSTRIAL', 'Industrial facility or manufacturing', -1, 0.950,
        'Noise, truck movements, emissions. Rare adjacent to Irvine residential, and significant where present.'
    ),
    (
        'ROAD_WIDENING', 'Arterial widening or major roadway reconstruction', -1, 0.900,
        'Multi-year lane closures, night work, dust, and a permanently busier road afterwards. The archetypal long-duration disruption.'
    ),
    (
        'BRIDGE_CONSTRUCTION', 'Bridge or grade separation', -1, 0.850,
        'Long duration, heavy equipment, sustained detours.'
    ),
    (
        'HIGH_RISE_RESIDENTIAL', 'High-rise residential (8+ storeys)', -1, 0.800,
        'Multi-year build, then permanent density, traffic, and view/privacy change. Most relevant in the Irvine Business Complex.'
    ),
    (
        'MID_RISE_RESIDENTIAL', 'Mid-rise residential (4-7 storeys)', -1, 0.550,
        'Meaningful build disruption and added density, at lower magnitude than high-rise.'
    ),
    (
        'PARKING_STRUCTURE', 'Parking structure', -1, 0.500,
        'Build disruption plus concentrated traffic and light spill afterwards.'
    ),
    (
        'SEWER_STORM_DRAIN', 'Sewer or storm drain works', -1, 0.500,
        'Trenching closes streets and is noisy, but is bounded and ends cleanly.'
    ),
    (
        'COMMERCIAL_RETAIL', 'Commercial or retail development', -1, 0.450,
        'Construction traffic, then delivery and customer traffic. Partly offset by amenity value, which the positive categories capture separately.'
    ),
    (
        'UTILITY_INFRASTRUCTURE', 'Utility installation or upgrade', -1, 0.400,
        'Lane closures and noise, typically weeks rather than years.'
    ),
    (
        'TRANSIT_STATION', 'Transit station or transit centre', -1, 0.350,
        'Construction disruption and later activity, materially offset by access. Net-negative but small.'
    ),
    (
        'ROAD_RESURFACING', 'Road resurfacing or slurry seal', -1, 0.300,
        'Days of noise and access interruption. Routine maintenance.'
    ),
    (
        'SCHOOL_EXPANSION', 'Expansion of an existing school', -1, 0.300,
        'Build noise and additional peak-hour traffic. Distinct from a NEW school, which is a net amenity.'
    ),
    (
        'TRAFFIC_SIGNAL', 'Traffic signal or intersection improvement', -1, 0.200,
        'Brief, localised. Usually improves safety afterwards.'
    ),

    -- -------------------------------------------------------- beneficial
    (
        'OPEN_SPACE_PRESERVATION', 'Open space or habitat preservation', 1, 0.800,
        'Permanently forecloses development on adjacent land. In a built-out city this is the strongest durable positive available.'
    ),
    (
        'PARK_NEW', 'New park', 1, 0.700,
        'Amenity value and protection from future development on the parcel. Central to how Irvine villages are valued.'
    ),
    (
        'SCHOOL_NEW', 'New school', 1, 0.600,
        'Strong amenity in a district where school assignment drives demand. Offsets its own construction disruption within a few years.'
    ),
    (
        'TRAIL_BIKEWAY', 'Trail or bikeway', 1, 0.500,
        'Connectivity to the trail network, a defining Irvine amenity.'
    ),
    (
        'COMMUNITY_CENTER', 'Community centre or recreation facility', 1, 0.500,
        'Amenity value; modest added local traffic.'
    ),
    (
        'LIBRARY', 'Library or civic facility', 1, 0.450,
        'Amenity with low traffic impact.'
    ),
    (
        'PARK_IMPROVEMENT', 'Park renovation or improvement', 1, 0.400,
        'Short disruption, lasting benefit.'
    ),
    (
        'STREETSCAPE_BEAUTIFICATION', 'Streetscape or landscape improvement', 1, 0.300,
        'Minor disruption, modest lasting benefit.'
    ),

    -- ----------------------------------------------------------- neutral
    (
        'MAINTENANCE_ROUTINE', 'Routine maintenance', 0, 0.100,
        'Ordinary upkeep. Reported for completeness, scored at effectively zero.'
    ),
    (
        'STUDY_PLANNING', 'Study, plan, or design phase only', 0, 0.050,
        'No ground disturbance. May become a real project later, which the phase factor handles.'
    ),
    (
        'UNCLASSIFIED', 'Could not be classified', 0, 0.200,
        'AI_CLASSIFY returned nothing usable. Scored neutral and surfaced for human review rather than guessed at — a wrong guess here is worse than an admitted gap.')
        AS SRC (CATEGORY_CODE, CATEGORY_LABEL, IMPACT_SIGN, SEVERITY, RATIONALE)
) AS SRC
    ON TGT.CATEGORY_CODE = SRC.CATEGORY_CODE
WHEN MATCHED THEN
    UPDATE SET
        TGT.CATEGORY_LABEL = SRC.CATEGORY_LABEL,
        TGT.IMPACT_SIGN = SRC.IMPACT_SIGN,
        TGT.SEVERITY = SRC.SEVERITY,
        TGT.RATIONALE = SRC.RATIONALE,
        TGT.UPDATED_AT = SYSDATE()
WHEN NOT MATCHED THEN INSERT
    (CATEGORY_CODE, CATEGORY_LABEL, IMPACT_SIGN, SEVERITY, RATIONALE)
VALUES
(SRC.CATEGORY_CODE, SRC.CATEGORY_LABEL, SRC.IMPACT_SIGN, SRC.SEVERITY, SRC.RATIONALE);

GRANT SELECT ON TABLE MART.REF_PROJECT_TAXONOMY TO ROLE IHA_APP;
GRANT SELECT ON TABLE MART.REF_PROJECT_TAXONOMY TO ROLE IHA_ANALYST;
