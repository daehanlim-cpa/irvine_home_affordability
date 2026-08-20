-- =============================================================================
-- fn_resolve_address.sql
-- Address string -> parcel. The front door of the whole product.
--
-- Irvine's own address-point layer is the geocoder; no paid API is needed. The
-- match cascade degrades rather than failing:
--
--   EXACT      normalised house number + street matches a point
--   FUZZY      exact house number, street within Jaro-Winkler 0.92
--   VILLAGE    ZIP or village name only -> village-level report, clearly labelled
--   NONE       nothing matched; say so rather than guessing at a parcel
--
-- The confidence level travels with the result and is shown to the user, because
-- a village-level answer presented as a parcel-level one is worse than no answer.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA APP;

-- Normalisation: uppercase, strip punctuation, expand common abbreviations so
-- "123 Main St." and "123 MAIN STREET" reach the same key.
CREATE OR REPLACE FUNCTION APP.FN_NORMALIZE_ADDRESS(RAW_ADDRESS VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Normalises a free-text address for matching: uppercase, punctuation stripped, street suffixes standardised.'
AS
$$
    TRIM(
        REGEXP_REPLACE(
            REGEXP_REPLACE(
                REGEXP_REPLACE(UPPER(TRIM(RAW_ADDRESS)), '[.,#]', ' '),
                '\\b(STREET|ST)\\b', 'ST'
            ),
            '\\s+', ' '
        )
    )
$$;

CREATE OR REPLACE FUNCTION APP.FN_RESOLVE_ADDRESS(RAW_ADDRESS VARCHAR)
RETURNS TABLE (
    APN VARCHAR,
    VILLAGE_CODE VARCHAR,
    MATCHED_ADDRESS VARCHAR,
    MATCH_CONFIDENCE VARCHAR,
    MATCH_SCORE FLOAT
)
LANGUAGE SQL
COMMENT = 'Resolves a free-text address to a parcel, degrading to village level rather than guessing.'
AS
$$
    WITH INPUT AS (
        SELECT
            APP.FN_NORMALIZE_ADDRESS(RAW_ADDRESS) AS NORM,
            TRY_TO_NUMBER(REGEXP_SUBSTR(APP.FN_NORMALIZE_ADDRESS(RAW_ADDRESS), '^[0-9]+')) AS HOUSE_NUM,
            TRIM(REGEXP_REPLACE(APP.FN_NORMALIZE_ADDRESS(RAW_ADDRESS), '^[0-9]+\\s*', '')) AS STREET_PART,
            REGEXP_SUBSTR(RAW_ADDRESS, '\\b9[0-9]{4}\\b') AS ZIP_PART
    ),

    EXACT_MATCH AS (
        SELECT
            PT.APN,
            PARCEL.VILLAGE_CODE,
            PT.ADDRESS_NORMALIZED AS MATCHED_ADDRESS,
            'EXACT' AS MATCH_CONFIDENCE,
            1.0 AS MATCH_SCORE
        FROM STAGE.STG_ADDRESS_POINTS AS PT
        INNER JOIN INPUT ON PT.HOUSE_NUMBER = INPUT.HOUSE_NUM
        LEFT JOIN MART.DIM_PARCEL AS PARCEL ON PT.APN = PARCEL.APN
        WHERE PT.ADDRESS_NORMALIZED = INPUT.NORM
        LIMIT 1
    ),

    FUZZY_MATCH AS (
        -- House number must match exactly; only the street name is fuzzy.
        -- Fuzzy-matching the number would silently return the wrong house.
        SELECT
            PT.APN,
            PARCEL.VILLAGE_CODE,
            PT.ADDRESS_NORMALIZED AS MATCHED_ADDRESS,
            'FUZZY' AS MATCH_CONFIDENCE,
            JAROWINKLER_SIMILARITY(PT.STREET_NAME, INPUT.STREET_PART) / 100.0 AS MATCH_SCORE
        FROM STAGE.STG_ADDRESS_POINTS AS PT
        INNER JOIN INPUT ON PT.HOUSE_NUMBER = INPUT.HOUSE_NUM
        LEFT JOIN MART.DIM_PARCEL AS PARCEL ON PT.APN = PARCEL.APN
        WHERE JAROWINKLER_SIMILARITY(PT.STREET_NAME, INPUT.STREET_PART) >= 92
            AND NOT EXISTS (SELECT 1 FROM EXACT_MATCH)
        ORDER BY MATCH_SCORE DESC
        LIMIT 1
    ),

    VILLAGE_MATCH AS (
        -- ZIP-only or village-name query. Returns no APN deliberately: a
        -- village-level answer must not masquerade as a parcel-level one.
        SELECT
            NULL AS APN,
            PARCEL.VILLAGE_CODE,
            'ZIP ' || INPUT.ZIP_PART AS MATCHED_ADDRESS,
            'VILLAGE' AS MATCH_CONFIDENCE,
            0.5 AS MATCH_SCORE
        FROM MART.DIM_PARCEL AS PARCEL
        INNER JOIN INPUT ON PARCEL.ZIP_CODE = INPUT.ZIP_PART
        WHERE INPUT.ZIP_PART IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM EXACT_MATCH)
            AND NOT EXISTS (SELECT 1 FROM FUZZY_MATCH)
        GROUP BY PARCEL.VILLAGE_CODE, INPUT.ZIP_PART
        ORDER BY COUNT(*) DESC
        LIMIT 1
    )

    SELECT * FROM EXACT_MATCH
    UNION ALL
    SELECT * FROM FUZZY_MATCH
    UNION ALL
    SELECT * FROM VILLAGE_MATCH
$$;
