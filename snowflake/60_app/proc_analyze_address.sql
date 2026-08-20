-- =============================================================================
-- proc_analyze_address.sql
-- The single entrypoint: address in, complete report out.
--
-- One procedure so that quota enforcement, lead capture, scoring, and narrative
-- generation cannot be called out of order or skipped. The Streamlit app and any
-- future web front end both go through here, which means the controls apply
-- identically no matter what is in front of them.
--
-- Order matters and is deliberate:
--   1. quota check      — before any Cortex spend, not after
--   2. resolve address  — cheap, and determines whether the rest is possible
--   3. capture lead     — with consent recorded
--   4. score            — deterministic SQL, no LLM
--   5. narrative        — the only per-request Cortex call, cached on evidence
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA APP;

CREATE OR REPLACE PROCEDURE APP.SP_ANALYZE_ADDRESS(
    RAW_ADDRESS VARCHAR,
    LEAD_EMAIL VARCHAR,
    CONSENT_TEXT VARCHAR,
    CLIENT_IP VARCHAR,
    USER_AGENT VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Address to full report. Enforces quota, records consent, scores deterministically, then generates one cached narrative.'
AS
$$
DECLARE
    resolved_apn VARCHAR;
    resolved_village VARCHAR;
    match_confidence VARCHAR;
    matched_address VARCHAR;
    email_count INTEGER;
    email_limit INTEGER;
    global_count INTEGER;
    global_limit INTEGER;
    ip_count INTEGER;
    ip_limit INTEGER;
    accepting_leads BOOLEAN;
    narrative VARCHAR;
    result VARIANT;
BEGIN
    -- --- 0. funnel switch ---------------------------------------------------
    SELECT COALESCE(FLAG_VALUE, TRUE) INTO :accepting_leads
    FROM OPS.FEATURE_FLAGS WHERE FLAG_NAME = 'ACCEPT_NEW_LEADS';

    IF (:accepting_leads = FALSE) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'UNAVAILABLE',
            'message', 'Analysis is temporarily unavailable. Please try again later.'
        );
    END IF;

    -- --- 1. quota, BEFORE any spend ----------------------------------------
    -- Defaults if a limits row is missing. A NULL limit makes the comparison
    -- below NULL, the IF never fires, and rate limiting silently disappears —
    -- the failure mode where the cost controls look present and do nothing.
    SELECT COALESCE(MAX(MAX_REQUESTS), 10) INTO :email_limit
    FROM APP.QUOTA_LIMITS WHERE QUOTA_TYPE = 'EMAIL';
    SELECT COALESCE(MAX(MAX_REQUESTS), 25) INTO :ip_limit
    FROM APP.QUOTA_LIMITS WHERE QUOTA_TYPE = 'IP';
    SELECT COALESCE(MAX(MAX_REQUESTS), 2000) INTO :global_limit
    FROM APP.QUOTA_LIMITS WHERE QUOTA_TYPE = 'GLOBAL';

    -- The global ceiling was seeded but never read. It is the control that
    -- bounds a bad day to a known cost rather than an open-ended one.
    SELECT COUNT(*) INTO :global_count FROM APP.LEADS
    WHERE CREATED_AT >= DATEADD('hour', -24, SYSDATE());

    SELECT COUNT(*) INTO :email_count FROM APP.LEADS
    WHERE EMAIL_ADDRESS = :LEAD_EMAIL AND CREATED_AT >= DATEADD('hour', -24, SYSDATE());

    SELECT COUNT(*) INTO :ip_count FROM APP.LEADS
    WHERE CLIENT_IP = :CLIENT_IP AND CREATED_AT >= DATEADD('hour', -24, SYSDATE());

    IF (:global_count >= :global_limit) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'UNAVAILABLE',
            'message', 'We are at capacity for today. Please try again tomorrow.'
        );
    END IF;

    IF (:email_count >= :email_limit OR :ip_count >= :ip_limit) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'QUOTA_EXCEEDED',
            'message', 'You have reached the daily limit for address analyses. Please try again tomorrow.',
            'requests_today', GREATEST(:email_count, :ip_count)
        );
    END IF;

    -- --- 2. resolve ---------------------------------------------------------
    SELECT APN, VILLAGE_CODE, MATCH_CONFIDENCE, MATCHED_ADDRESS
    INTO :resolved_apn, :resolved_village, :match_confidence, :matched_address
    FROM TABLE(APP.FN_RESOLVE_ADDRESS(:RAW_ADDRESS))
    LIMIT 1;

    IF (:match_confidence IS NULL) THEN
        -- Record the miss: unmatched addresses are the best signal for where the
        -- geocoder needs work, and the lead is still worth having.
        INSERT INTO APP.LEADS
            (EMAIL_ADDRESS, ADDRESS_QUERIED, RESOLVED_APN, RESOLVED_VILLAGE,
             MATCH_CONFIDENCE, CONSENT_AT, CONSENT_TEXT, SOURCE_CHANNEL, CLIENT_IP, USER_AGENT)
        VALUES
            (:LEAD_EMAIL, :RAW_ADDRESS, NULL, NULL, 'NONE', SYSDATE(), :CONSENT_TEXT,
             'streamlit', :CLIENT_IP, :USER_AGENT);

        RETURN OBJECT_CONSTRUCT(
            'status', 'NOT_FOUND',
            'message', 'We could not match that address to an Irvine parcel. Check the spelling, '
                    || 'or try the street address without a unit number.',
            'address_queried', :RAW_ADDRESS
        );
    END IF;

    -- --- 3. capture the lead with consent ----------------------------------
    INSERT INTO APP.LEADS
        (EMAIL_ADDRESS, ADDRESS_QUERIED, RESOLVED_APN, RESOLVED_VILLAGE,
         MATCH_CONFIDENCE, CONSENT_AT, CONSENT_TEXT, SOURCE_CHANNEL, CLIENT_IP, USER_AGENT)
    VALUES
        (:LEAD_EMAIL, :RAW_ADDRESS, :resolved_apn, :resolved_village,
         :match_confidence, SYSDATE(), :CONSENT_TEXT, 'streamlit', :CLIENT_IP, :USER_AGENT);

    -- --- 4. village-level answers stop here, labelled as such ---------------
    IF (:resolved_apn IS NULL) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'VILLAGE_LEVEL',
            'match_confidence', :match_confidence,
            'village', :resolved_village,
            'message', 'We matched this to a village but not a specific parcel, so cost figures '
                    || 'such as Mello-Roos — which vary parcel by parcel — cannot be shown. '
                    || 'Enter a full street address for a parcel-level report.',
            'sentiment', (SELECT OBJECT_CONSTRUCT('subscore', SUBSCORE, 'themes', TOP_THEMES,
                                                  'status', DATA_STATUS)
                          FROM MART.FCT_SENTIMENT_VILLAGE
                          WHERE VILLAGE_CODE = :resolved_village
                          ORDER BY AS_OF_DATE DESC LIMIT 1)
        );
    END IF;

    -- --- 5. score (deterministic) and narrate (cached) ----------------------
    CALL MART.SP_SNAPSHOT_SCORE(:resolved_apn);
    CALL MART.SP_GENERATE_NARRATIVE(:resolved_apn) INTO :narrative;

    SELECT OBJECT_CONSTRUCT(
        'status', 'OK',
        'match_confidence', :match_confidence,
        'matched_address', :matched_address,
        'apn', SCORE.APN,
        'village', PARCEL.VILLAGE_NAME,
        'composite_score', SCORE.COMPOSITE_SCORE,
        'confidence_level', SCORE.CONFIDENCE_LEVEL,
        'pillars', SCORE.PILLAR_SCORES,
        'pillars_omitted', SCORE.PILLARS_OMITTED,
        'narrative', :narrative,
        'evidence', BUNDLE.EVIDENCE,
        'disclaimer', 'This report summarises public records. It is not an appraisal, not '
                   || 'investment advice, and not a substitute for a title report or inspection. '
                   || 'Verify all figures with Orange County before closing.'
    ) INTO :result
    FROM MART.VW_PARCEL_SCORE AS SCORE
    INNER JOIN MART.DIM_PARCEL AS PARCEL ON SCORE.APN = PARCEL.APN
    INNER JOIN MART.VW_EVIDENCE_BUNDLE AS BUNDLE ON SCORE.APN = BUNDLE.APN
    WHERE SCORE.APN = :resolved_apn;

    RETURN :result;
END;
$$;

GRANT USAGE ON PROCEDURE APP.SP_ANALYZE_ADDRESS(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR)
TO ROLE IHA_APP;
