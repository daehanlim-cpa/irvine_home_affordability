-- =============================================================================
-- 03_network_rules.sql
-- Egress network rules — the allowlist of hosts this platform may contact.
--
-- One rule per trust tier rather than one rule for everything, so that
-- revoking a tier (say, if a forum's ToS changes) is a single ALTER and does
-- not disturb the government feeds.
--
-- Every host here must have a corresponding compliance record in
-- docs/data_sources.md: robots.txt check, ToS read, licence note.
-- =============================================================================

USE ROLE IHA_ADMIN;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA OPS;

-- Tier A: government and civic sources. The 90%.
CREATE OR REPLACE NETWORK RULE NR_GOV_GIS
MODE = EGRESS
TYPE = HOST_PORT
VALUE_LIST = (
    'gis.cityofirvine.org:443',              -- Irvine ArcGIS REST: parcels, address points, zoning, CIP
    'services.arcgis.com:443',               -- Irvine ArcGIS Online hosted feature services
    'www.arcgis.com:443',                    -- item/service discovery
    'data-ocpw.opendata.arcgis.com:443',     -- Orange County Public Works open GIS
    'irvine.granicus.com:443',               -- council & planning commission agendas/minutes
    'api.census.gov:443',                    -- ACS block-group (Phase 2)
    'hazards.fema.gov:443'                   -- flood hazard layers (Phase 2)
)
COMMENT = 'Tier A government/civic sources. Machine-readable public records.';

-- Tier B: local journalism, fetched as RSS/Atom.
CREATE OR REPLACE NETWORK RULE NR_NEWS_RSS
MODE = EGRESS
TYPE = HOST_PORT
VALUE_LIST = (
    'voiceofoc.org:443',
    'irvineweekly.com:443',
    'irvinewatchdog.org:443',
    'thehowleronline.org:443',                -- Northwood Howler; broke the asphalt-plant story
    'patch.com:443',
    'news.google.com:443'                     -- per-village RSS queries
)
COMMENT = 'Tier B local journalism via RSS. Highest-trust sentiment after civic records.';

-- Tier C/D: community forums and review platforms. Lowest trust weight, and the
-- tier most likely to need revoking, hence its own rule.
CREATE OR REPLACE NETWORK RULE NR_COMMUNITY
MODE = EGRESS
TYPE = HOST_PORT
VALUE_LIST = (
    'www.talkirvine.com:443',
    'www.city-data.com:443',
    'www.googleapis.com:443'                  -- YouTube Data API, Places API
)
COMMENT = 'Tier C/D community forums and review platforms. Crawled only where robots.txt permits; see docs/data_sources.md.';
