-- =============================================================================
-- fn_templated_summary.sql
-- Deterministic fallback narrative, used when the Cortex kill switch is off.
--
-- The point of a kill switch is that the product degrades instead of breaking.
-- This produces a plain, factual summary straight from the evidence bundle with
-- no model involved — less readable than the generated version, but complete,
-- accurate, and free. A user still gets their answer during a cost incident.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;

CREATE OR REPLACE FUNCTION MART.FN_TEMPLATED_SUMMARY(EVIDENCE VARIANT)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Model-free summary assembled from the evidence bundle. Used when LIVE_NARRATIVE is disabled.'
AS
$$
    'Summary for ' || COALESCE(EVIDENCE:parcel:address::VARCHAR, 'this parcel')
    || ' in ' || COALESCE(EVIDENCE:parcel:village::VARCHAR, 'Irvine') || '.'
    || '\n\nConstruction and development: '
    || COALESCE(EVIDENCE:construction:projects_nearby::VARCHAR, '0')
    || ' project(s) within one mile, of which '
    || COALESCE(EVIDENCE:construction:projects_active::VARCHAR, '0') || ' are active and '
    || COALESCE(EVIDENCE:construction:projects_pending::VARCHAR, '0') || ' are pending. '
    || CASE
        WHEN EVIDENCE:construction:nearest_project_meters IS NOT NULL
            THEN 'The nearest is ' || EVIDENCE:construction:nearest_project_meters::VARCHAR || ' metres away. '
        ELSE ''
    END
    || '\n\nCost burden: '
    || CASE COALESCE(EVIDENCE:cost_burden:band::VARCHAR, 'UNKNOWN')
        WHEN 'NO_SPECIAL_ASSESSMENTS' THEN 'No Mello-Roos special tax and no HOA dues recorded for this parcel.'
        WHEN 'HOA_ONLY' THEN 'No Mello-Roos special tax; HOA dues of $'
            || COALESCE(EVIDENCE:cost_burden:hoa_monthly::VARCHAR, '0') || ' per month.'
        ELSE 'Mello-Roos special tax of $'
            || COALESCE(EVIDENCE:cost_burden:cfd_annual_tax::VARCHAR, '0') || ' per year'
            || CASE
                WHEN EVIDENCE:cost_burden:cfd_years_remaining IS NOT NULL
                    THEN ' with ' || EVIDENCE:cost_burden:cfd_years_remaining::VARCHAR
                      || ' years remaining, a total remaining obligation of $'
                      || COALESCE(EVIDENCE:cost_burden:cfd_total_remaining_obligation::VARCHAR, 'unknown') || '.'
                ELSE '; remaining term not available in the parcel record.'
            END
    END
    || COALESCE('\n\nNote: ' || EVIDENCE:cost_burden:village_deviation_note::VARCHAR, '')
    || COALESCE('\n\nData caveat: ' || EVIDENCE:cost_burden:data_caveat::VARCHAR, '')
    || '\n\nCommunity sentiment: '
    || CASE COALESCE(EVIDENCE:sentiment:status::VARCHAR, 'INSUFFICIENT_DATA')
        WHEN 'SCORED' THEN 'based on '
            || COALESCE(EVIDENCE:sentiment:document_count::VARCHAR, '0')
            || ' documents across ' || COALESCE(EVIDENCE:sentiment:source_count::VARCHAR, '0')
            || ' sources for this village.'
        ELSE 'not enough recent discussion about this village to report reliably. This pillar was not scored.'
    END
    || '\n\nThis summary was generated without AI assistance and covers only the pillars listed. '
    || 'It is not an appraisal, not investment advice, and not a substitute for a title report '
    || 'or inspection. Verify all figures with Orange County before closing.'
$$;
