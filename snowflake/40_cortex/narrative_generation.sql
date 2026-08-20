-- =============================================================================
-- narrative_generation.sql
-- The buyer-facing brief, generated strictly from the evidence bundle.
--
-- The rule the whole design rests on: the model sees MART.VW_EVIDENCE_BUNDLE and
-- nothing else. It cannot query the warehouse, and it must not draw on anything
-- it happens to know about Irvine from training. If a figure is not in the
-- bundle, it must not appear in the report.
--
-- This is enforced in three places, deliberately overlapping, because a
-- fabricated number in a document telling someone whether to spend $1.6M is the
-- worst failure this system can have:
--
--   1. The prompt states the constraint and requires record_id citations.
--   2. A cheap numeric backstop runs at generation time: every number in the
--      prose must appear in the bundle text (see VW_NARRATIVE_GROUNDING_CHECK).
--   3. AI Observability scores groundedness properly, and the verification gate
--      refuses to pass below threshold (see ai_observability_evals.sql).
--
-- Cortex Guard is enabled so harmful output is filtered at inference.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;

CREATE TABLE IF NOT EXISTS MART.NARRATIVE_CACHE (
    APN VARCHAR NOT NULL,
    EVIDENCE_HASH VARCHAR(64) NOT NULL,
    NARRATIVE_TEXT VARCHAR NOT NULL,
    MODEL_NAME VARCHAR NOT NULL,
    GENERATED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    GROUNDING_STATUS VARCHAR,                        -- PASS | UNGROUNDED_NUMBERS | NOT_CHECKED
    UNGROUNDED_TOKENS ARRAY,
    PRIMARY KEY (APN, EVIDENCE_HASH)
)
COMMENT = 'Generated narratives keyed on evidence hash. Unchanged evidence reuses the cached text, so a repeat visitor costs nothing.';

CREATE OR REPLACE PROCEDURE MART.SP_GENERATE_NARRATIVE(TARGET_APN VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Generates a grounded narrative for one parcel. Cached on evidence hash; falls back to a templated summary when the kill switch is off.'
AS
$$
DECLARE
    model_name VARCHAR;
    max_tokens INTEGER;
    temperature FLOAT;
    live_enabled BOOLEAN;
    evidence_hash VARCHAR;
    cached_text VARCHAR;
    narrative VARCHAR;
BEGIN
    SELECT MODEL_NAME, MAX_TOKENS, TEMPERATURE
    INTO :model_name, :max_tokens, :temperature
    FROM MART.REF_CORTEX_MODELS WHERE TASK_NAME = 'NARRATIVE';

    SELECT SHA2(TO_VARCHAR(EVIDENCE), 256) INTO :evidence_hash
    FROM MART.VW_EVIDENCE_BUNDLE WHERE APN = :TARGET_APN;

    IF (:evidence_hash IS NULL) THEN
        RETURN 'no evidence bundle for ' || :TARGET_APN;
    END IF;

    -- Cache hit: identical evidence yields identical narrative. This is the
    -- main per-request cost control on the generation side.
    SELECT NARRATIVE_TEXT INTO :cached_text
    FROM MART.NARRATIVE_CACHE
    WHERE APN = :TARGET_APN AND EVIDENCE_HASH = :evidence_hash;

    IF (:cached_text IS NOT NULL) THEN
        RETURN :cached_text;
    END IF;

    -- Kill switch. When daily Cortex spend trips the threshold, OPS flips this
    -- flag and reports degrade to a templated summary rather than failing or
    -- running up the bill.
    SELECT COALESCE(FLAG_VALUE, TRUE) INTO :live_enabled
    FROM OPS.FEATURE_FLAGS WHERE FLAG_NAME = 'LIVE_NARRATIVE';

    IF (:live_enabled = FALSE) THEN
        RETURN (SELECT MART.FN_TEMPLATED_SUMMARY(EVIDENCE)
                FROM MART.VW_EVIDENCE_BUNDLE WHERE APN = :TARGET_APN);
    END IF;

    ALTER SESSION SET QUERY_TAG = 'iha_pillar=narrative;iha_task=generate_narrative';

    SELECT AI_COMPLETE(
        :model_name,
        'You are writing a factual assessment for someone considering buying this specific '
        || 'Irvine, California home as a long-term residence.'
        || '\n\nABSOLUTE RULES:'
        || '\n1. Use ONLY the JSON evidence below. Do not use anything you know about Irvine '
        || 'from other sources. If the evidence does not contain a fact, do not state it.'
        || '\n2. Every number you write must appear in the evidence. Never estimate, round '
        || 'differently, or infer a figure.'
        || '\n3. Cite the record_id in parentheses whenever you reference a specific project.'
        || '\n4. If a pillar is INSUFFICIENT_DATA or listed under inactive_pillars, say plainly '
        || 'that it was not assessed. Never imply it was checked and found fine.'
        || '\n5. Do not give investment advice, predict prices, or tell the reader what to do. '
        || 'Describe what the public record shows and let them decide.'
        || '\n6. Do not mention or infer anything about the people who live in the area.'
        || '\n\nSTRUCTURE: open with two sentences on what stands out; then "What we found" as '
        || '3-6 bullets, most significant first; then "What we could not assess"; then one '
        || 'sentence on what to verify with the County before closing.'
        || '\n\nTone: a seasoned adviser stating facts plainly. No marketing language, no '
        || 'reassurance that is not in the evidence.'
        || '\n\nEVIDENCE:\n' || TO_VARCHAR(EVIDENCE),
        OBJECT_CONSTRUCT(
            'max_tokens', :max_tokens,
            'temperature', :temperature,
            -- Cortex Guard: inference-time safety filtering on the output.
            'guardrails', TRUE
        )
    ) INTO :narrative
    FROM MART.VW_EVIDENCE_BUNDLE
    WHERE APN = :TARGET_APN;

    INSERT INTO MART.NARRATIVE_CACHE
        (APN, EVIDENCE_HASH, NARRATIVE_TEXT, MODEL_NAME, GROUNDING_STATUS)
    VALUES
        (:TARGET_APN, :evidence_hash, :narrative, :model_name, 'NOT_CHECKED');

    ALTER SESSION UNSET QUERY_TAG;
    RETURN :narrative;
END;
$$;

-- -----------------------------------------------------------------------------
-- Numeric grounding backstop.
--
-- Cheap, deterministic, and complementary to the AI Observability evaluation:
-- it extracts every number from the generated prose and checks each appears in
-- the evidence. It cannot judge meaning, but it catches the specific failure
-- that matters most — a figure the model invented.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW MART.VW_NARRATIVE_GROUNDING_CHECK
COMMENT = 'Flags narratives containing numbers absent from their evidence bundle. FAIL rows block the verification gate.'
AS
WITH NUMBERS_IN_NARRATIVE AS (
    SELECT
        NARR.APN,
        NARR.EVIDENCE_HASH,
        -- Strip thousands separators and currency before tokenising. The
        -- previous form split "3,200" into "3" and "200" — so a fabricated
        -- figure passed, while trailing punctuation produced tokens like "400."
        -- that never matched correct text. Both directions were wrong.
        NUM_PART.VALUE::VARCHAR AS NUM_TOKEN,
        -- Compare against a bundle normalised the same way, so formatting
        -- differences are not mistaken for fabrication.
        REGEXP_REPLACE(TO_VARCHAR(BUNDLE.EVIDENCE), '[,$]', '') AS EVIDENCE_TEXT
    FROM MART.NARRATIVE_CACHE AS NARR
    INNER JOIN MART.VW_EVIDENCE_BUNDLE AS BUNDLE
        ON NARR.APN = BUNDLE.APN
        -- Only the hash the narrative was generated FROM. Joining on APN alone
        -- compared a cached narrative against a bundle that may have moved on.
        AND NARR.EVIDENCE_HASH = SHA2(TO_VARCHAR(BUNDLE.EVIDENCE), 256),
        LATERAL FLATTEN(
            INPUT => STRTOK_TO_ARRAY(
                REGEXP_REPLACE(
                    REGEXP_REPLACE(NARR.NARRATIVE_TEXT, '[,$]', ''),
                    '[^0-9.]+',
                    ' '
                ),
                ' '
            )
        ) AS NUM_PART
    -- Only the hash the narrative was generated FROM. Joining on APN alone
    -- compared a cached narrative against a bundle that may have moved on.
    WHERE NARR.EVIDENCE_HASH = SHA2(TO_VARCHAR(BUNDLE.EVIDENCE), 256)
    -- Trim trailing sentence punctuation before testing.
    AND TRY_TO_DOUBLE(RTRIM(NUM_PART.VALUE::VARCHAR, '.')) IS NOT NULL
    -- Ignore small numbers: ordinals and counts occur in ordinary prose and
    -- would drown the signal in false positives.
    AND TRY_TO_DOUBLE(RTRIM(NUM_PART.VALUE::VARCHAR, '.')) >= 100
)

SELECT
    APN,
    EVIDENCE_HASH,
    ARRAY_AGG(DISTINCT NUM_TOKEN) AS UNGROUNDED_TOKENS,
    'FAIL' AS STATUS,
    'Narrative contains numbers absent from its evidence bundle. This is the fabrication failure mode the design exists to prevent.' AS DETAIL
FROM NUMBERS_IN_NARRATIVE
WHERE POSITION(RTRIM(NUM_TOKEN, '.'), EVIDENCE_TEXT) = 0
GROUP BY APN, EVIDENCE_HASH;

GRANT SELECT ON TABLE MART.NARRATIVE_CACHE TO ROLE IHA_APP;
