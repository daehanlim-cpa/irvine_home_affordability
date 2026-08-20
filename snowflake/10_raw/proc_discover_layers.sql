-- =============================================================================
-- proc_discover_layers.sql
-- Turn ArcGIS layer IDs from a guess into a fact.
--
-- Run this after 00_setup/04 and before any ingest. It reports the layers each
-- service actually contains, so the registry can name the right one instead of
-- assuming layer 0 — an assumption that, for the geocoder, makes every address
-- resolve to NOT_FOUND with the cause three layers upstream of the symptom.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA RAW;
USE WAREHOUSE IHA_WH_XS;

CREATE OR REPLACE PROCEDURE RAW.SP_DISCOVER_LAYERS(SERVICE_URL VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
IMPORTS = ('@IRVINE_HOME_ANALYSIS.RAW.INGEST_CODE/proc_discover_layers.py')
HANDLER = 'proc_discover_layers.main'
EXTERNAL_ACCESS_INTEGRATIONS = (EAI_GOV_SOURCES)
COMMENT = 'Lists the layers in an ArcGIS service. Run before ingest so layer IDs are read rather than assumed.'
EXECUTE AS OWNER;

GRANT USAGE ON PROCEDURE RAW.SP_DISCOVER_LAYERS(VARCHAR) TO ROLE IHA_ENGINEER;

-- Discover every service the registry depends on, in one pass.
SELECT
    SVC.SERVICE_NAME,
    RAW.SP_DISCOVER_LAYERS(SVC.SERVICE_URL) AS LAYERS
FROM (
    SELECT *
    FROM
        VALUES
        ('parcels_cfd', 'https://gis.cityofirvine.org/arcgis/rest/services/ParcelClariti/FeatureServer'),
        ('cip_projects', 'https://gis.cityofirvine.org/arcgis/rest/services/CIP/MapServer'),
        ('road_construction', 'https://gis.cityofirvine.org/arcgis/rest/services/RoadConstruction_ProEdit1/FeatureServer'),
        ('gp_construction', 'https://gis.cityofirvine.org/arcgis/rest/services/GPConstruction/MapServer'),
        ('hoa_data', 'https://gis.cityofirvine.org/arcgis/rest/services/HOADataEditor/FeatureServer'),
        ('code_enforcement', 'https://gis.cityofirvine.org/arcgis/rest/services/Code_Enforcement_Cases/FeatureServer'),
        ('building_xy', 'https://gis.cityofirvine.org/arcgis/rest/services/Building_XY/MapServer'),
        ('geocoder', 'https://gis.cityofirvine.org/arcgis/rest/services/Composite/GeocodeServer')
            AS SVC (SERVICE_NAME, SERVICE_URL)
) AS SVC;
