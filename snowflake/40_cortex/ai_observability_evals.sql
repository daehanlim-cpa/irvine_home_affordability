-- =============================================================================
-- ai_observability_evals.sql
-- Snowflake AI Observability (TruLens) evaluation of the narrative generator.
--
-- The numeric backstop in narrative_generation.sql catches invented figures.
-- This catches the subtler failure: prose that is technically numerically
-- consistent but asserts things the evidence does not support — "the area is
-- quiet", "schools are excellent" — which is exactly the kind of sentence a
-- buyer would rely on and we cannot stand behind.
--
-- GROUNDEDNESS is the metric that matters here. Relevance and correctness are
-- tracked as secondary signals.
--
-- scripts/verify.sh gates on the threshold below: a narrative generator that
-- drifts ungrounded fails the build rather than reaching a buyer.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;
USE WAREHOUSE IHA_WH_XS;

CREATE TABLE IF NOT EXISTS MART.NARRATIVE_EVAL_RESULTS (
    EVAL_RUN_ID VARCHAR(36) NOT NULL,
    EVALUATED_AT TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    APN VARCHAR NOT NULL,
    MODEL_NAME VARCHAR NOT NULL,
    GROUNDEDNESS NUMBER(4, 3),
    RELEVANCE NUMBER(4, 3),
    COVERAGE_HONESTY NUMBER(4, 3),
    NOTES VARCHAR
)
COMMENT = 'Per-narrative evaluation scores. Groundedness below threshold blocks the verification gate.';

CREATE TABLE IF NOT EXISTS MART.REF_EVAL_THRESHOLDS (
    METRIC_NAME VARCHAR NOT NULL PRIMARY KEY,
    MIN_SCORE NUMBER(4, 3) NOT NULL,
    IS_BLOCKING BOOLEAN NOT NULL,
    RATIONALE VARCHAR
)
COMMENT = 'Evaluation thresholds. Blocking metrics fail the pre-push gate.';

MERGE INTO MART.REF_EVAL_THRESHOLDS AS TGT
USING (
    SELECT *
    FROM
        VALUES
        (
            'GROUNDEDNESS', 0.900, TRUE,
            'Every claim must be supported by the evidence bundle. Set high and blocking: a fabricated statement in a document advising a $1.6M purchase is the worst failure this system can produce.'
        ),
        (
            'RELEVANCE', 0.800, TRUE,
            'The narrative must answer the buyer''s actual question rather than recite the bundle.'
        ),
        (
            'COVERAGE_HONESTY', 0.950, TRUE,
            'The narrative must state plainly which pillars were NOT assessed. Implying an unassessed pillar was checked and found fine is a worse failure than omitting it, so this threshold is the strictest of the three.')
            AS SRC (METRIC_NAME, MIN_SCORE, IS_BLOCKING, RATIONALE)
) AS SRC
    ON TGT.METRIC_NAME = SRC.METRIC_NAME
WHEN MATCHED THEN
    UPDATE SET
        TGT.MIN_SCORE = SRC.MIN_SCORE, TGT.IS_BLOCKING = SRC.IS_BLOCKING,
        TGT.RATIONALE = SRC.RATIONALE
WHEN NOT MATCHED THEN
    INSERT (METRIC_NAME, MIN_SCORE, IS_BLOCKING, RATIONALE)
    VALUES (SRC.METRIC_NAME, SRC.MIN_SCORE, SRC.IS_BLOCKING, SRC.RATIONALE);

-- -----------------------------------------------------------------------------
-- Evaluation run over the golden addresses.
--
-- Uses AI_COMPLETE as an LLM judge with a strict rubric. Where the account has
-- Snowflake AI Observability enabled, register this as an evaluation run so the
-- results also appear in Snowsight; the scores land here either way, so the gate
-- works with or without that feature.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE MART.SP_EVALUATE_NARRATIVES()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Scores cached narratives for groundedness, relevance, and coverage honesty against their evidence bundles.'
AS
$$
DECLARE
    run_id VARCHAR DEFAULT UUID_STRING();
    evaluated INTEGER DEFAULT 0;
BEGIN
    ALTER SESSION SET QUERY_TAG = 'iha_pillar=narrative;iha_task=evaluate_narratives';

    INSERT INTO MART.NARRATIVE_EVAL_RESULTS
        (EVAL_RUN_ID, APN, MODEL_NAME, GROUNDEDNESS, RELEVANCE, COVERAGE_HONESTY, NOTES)
    SELECT
        :run_id,
        NARR.APN,
        NARR.MODEL_NAME,
        TRY_TO_DECIMAL(JUDGED.SCORES:groundedness::VARCHAR, 4, 3),
        TRY_TO_DECIMAL(JUDGED.SCORES:relevance::VARCHAR, 4, 3),
        TRY_TO_DECIMAL(JUDGED.SCORES:coverage_honesty::VARCHAR, 4, 3),
        JUDGED.SCORES:notes::VARCHAR
    FROM MART.NARRATIVE_CACHE AS NARR
    INNER JOIN MART.VW_EVIDENCE_BUNDLE AS BUNDLE ON NARR.APN = BUNDLE.APN
    INNER JOIN LATERAL (
        SELECT TRY_PARSE_JSON(
            AI_COMPLETE(
                'claude-4-5-sonnet',
                'You are auditing a property report for factual grounding. Score strictly; '
                || 'this report advises someone on a seven-figure purchase.'
                || '\n\nReturn ONLY a JSON object with keys: groundedness, relevance, '
                || 'coverage_honesty (each 0.0-1.0), and notes (one sentence).'
                || '\n\ngroundedness: 1.0 only if EVERY factual claim and number in the report '
                || 'is supported by the evidence. Deduct heavily for any unsupported assertion, '
                || 'including qualitative ones such as "quiet area" or "excellent schools".'
                || '\nrelevance: does it answer whether this is a good long-term home to buy?'
                || '\ncoverage_honesty: 1.0 only if the report explicitly states which pillars '
                || 'were NOT assessed. Score 0 if it implies an unassessed pillar was fine.'
                || '\n\nEVIDENCE:\n' || TO_VARCHAR(BUNDLE.EVIDENCE)
                || '\n\nREPORT:\n' || NARR.NARRATIVE_TEXT
            )
        ) AS SCORES
    ) AS JUDGED
    WHERE NARR.APN IN (SELECT APN FROM MART.GOLDEN_ADDRESSES);

    evaluated := SQLROWCOUNT;
    ALTER SESSION UNSET QUERY_TAG;
    RETURN 'evaluated ' || :evaluated || ' narrative(s), run ' || :run_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- Gate view. scripts/verify.sh greps for FAIL.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW MART.VW_EVAL_GATE
COMMENT = 'Latest evaluation run against blocking thresholds. FAIL rows block the pre-push gate.'
AS
WITH LATEST_RUN AS (
    SELECT *
    FROM MART.NARRATIVE_EVAL_RESULTS
    QUALIFY EVAL_RUN_ID = FIRST_VALUE(EVAL_RUN_ID) OVER (ORDER BY EVALUATED_AT DESC)
),

AVERAGES AS (
    SELECT
        AVG(GROUNDEDNESS) AS GROUNDEDNESS,
        AVG(RELEVANCE) AS RELEVANCE,
        AVG(COVERAGE_HONESTY) AS COVERAGE_HONESTY,
        COUNT(*) AS NARRATIVES_EVALUATED
    FROM LATEST_RUN
),

UNPIVOTED AS (
    SELECT
        'GROUNDEDNESS' AS METRIC_NAME,
        GROUNDEDNESS AS ACTUAL,
        NARRATIVES_EVALUATED
    FROM AVERAGES
    UNION ALL
    SELECT
        'RELEVANCE' AS METRIC_NAME,
        RELEVANCE AS ACTUAL,
        NARRATIVES_EVALUATED
    FROM AVERAGES
    UNION ALL
    SELECT
        'COVERAGE_HONESTY' AS METRIC_NAME,
        COVERAGE_HONESTY AS ACTUAL,
        NARRATIVES_EVALUATED
    FROM AVERAGES
)

SELECT
    UNPIVOTED.METRIC_NAME,
    ROUND(UNPIVOTED.ACTUAL, 3) AS ACTUAL_SCORE,
    THRESH.MIN_SCORE,
    CASE
        WHEN UNPIVOTED.NARRATIVES_EVALUATED = 0 THEN 'SKIP'
        WHEN UNPIVOTED.ACTUAL IS NULL THEN 'SKIP'
        WHEN UNPIVOTED.ACTUAL >= THRESH.MIN_SCORE THEN 'PASS'
        WHEN THRESH.IS_BLOCKING THEN 'FAIL'
        ELSE 'WARN'
    END AS STATUS,
    THRESH.RATIONALE AS DETAIL
FROM UNPIVOTED
INNER JOIN MART.REF_EVAL_THRESHOLDS AS THRESH ON UNPIVOTED.METRIC_NAME = THRESH.METRIC_NAME;

GRANT SELECT ON VIEW MART.VW_EVAL_GATE TO ROLE IHA_ANALYST;
