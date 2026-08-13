-- ============================================================================
-- Stage 5 — RECONCILIATION GATE
-- Steps 4 and 5 are the ones to record.
--
-- GATE vs REPORT. A report tells you afterwards that yesterday was wrong.
-- A gate stops the wrong numbers reaching the layer people query.
--
-- The mechanism is ordinary: a stored procedure RAISEs, the task running it
-- fails, and every task downstream never fires. Gold doesn't get built from a
-- Silver that doesn't tie.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_MEDALLION;
USE DATABASE INSURANCE_DEMO;
USE SCHEMA OPS;


-- ============================================================================
-- 1. Where results live
--
-- Every check writes a row every run, pass or fail.
--
-- Keeping the passes matters as much as the failures: a variance that's been
-- drifting up for six days is a different conversation from one that appeared
-- this morning. You can only tell them apart with history.
-- ============================================================================

CREATE OR REPLACE TABLE OPS.RECONCILIATION (
    run_label      VARCHAR,
    gate           VARCHAR,        -- which promotion this guards
    check_name     VARCHAR,
    source_layer   VARCHAR,
    target_layer   VARCHAR,
    source_value   NUMBER(38,2),
    target_value   NUMBER(38,2),
    variance       NUMBER(38,2),
    tolerance      NUMBER(38,2),
    passed         BOOLEAN,
    checked_at     TIMESTAMP_NTZ
);


-- ============================================================================
-- 2. GATE 1 — Bronze → Silver
-- Runs BEFORE Gold is built. If it fails, Gold is never promoted.
--
-- >>> TOLERANCES — have an opinion, you WILL be asked <<<
--
--   0      for STRUCTURAL. Row counts and key uniqueness aren't approximately
--          right — they're right, or the pipeline is broken. A tolerance here
--          only hides a bug.
--
--   0.01   for MONEY. Not because a cent of drift is fine, but because decimal
--          arithmetic across systems makes sub-cent noise. A gate that fires on
--          floating-point dust gets switched off within a week, and a gate
--          nobody trusts is worse than no gate.
--
--   2%     for RATES. Some orphans are normal — claims do arrive before their
--          policy extract. One in fifty is business as usual. One in five means
--          an upstream feed broke. This one needs judgement, not arithmetic.
--
-- FAIL vs QUARANTINE:
--   Quarantine the ROW when one record is bad and the batch is fine.
--   Fail the RUN when the batch itself can't be trusted.
--
--   113 negative amounts = data quality. Quarantine them.
--   Silver holding fewer rows than Bronze can account for = pipeline problem.
--   Fail, because you no longer know what else it lost.
-- ============================================================================

CREATE OR REPLACE PROCEDURE OPS.SP_RECONCILE_SILVER(RUN_LABEL VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    failed_count  INTEGER;
    gate_failed   EXCEPTION (-20001,
        'RECONCILIATION FAILED at Bronze->Silver. Promotion to Gold is blocked.');
BEGIN
    DELETE FROM OPS.RECONCILIATION
     WHERE run_label = :RUN_LABEL AND gate = 'BRONZE_TO_SILVER';

    INSERT INTO OPS.RECONCILIATION
        (run_label, gate, check_name, source_layer, target_layer,
         source_value, target_value, variance, tolerance, passed, checked_at)
    SELECT
        :RUN_LABEL,
        'BRONZE_TO_SILVER',
        check_name, source_layer, target_layer,
        source_value, target_value,
        ABS(source_value - target_value),
        tolerance,
        ABS(source_value - target_value) <= tolerance,
        CURRENT_TIMESTAMP()
    FROM (
        -- Every distinct Bronze claim is either in Silver or in quarantine.
        -- Nothing may simply be missing.
        SELECT 'every bronze claim is accounted for' AS check_name,
               'BRONZE' AS source_layer, 'SILVER' AS target_layer,
               (SELECT COUNT(DISTINCT TRIM(claim_id))
                  FROM BRONZE.RAW_CLAIMS)::NUMBER(38,2) AS source_value,
               ((SELECT COUNT(*) FROM SILVER.CLAIMS)
                + (SELECT COUNT(DISTINCT natural_key) FROM OPS.QUARANTINE
                    WHERE source_table = 'RAW_CLAIMS'))::NUMBER(38,2) AS target_value,
               0::NUMBER(38,2) AS tolerance

        UNION ALL

        -- Silver must not invent claims that were never in Bronze.
        SELECT 'no silver claims absent from bronze',
               'SILVER', 'BRONZE',
               0::NUMBER(38,2),
               (SELECT COUNT(*) FROM SILVER.CLAIMS s
                 WHERE NOT EXISTS (SELECT 1 FROM BRONZE.RAW_CLAIMS b
                                    WHERE TRIM(b.claim_id) = s.claim_id))::NUMBER(38,2),
               0::NUMBER(38,2)

        UNION ALL

        -- Silver claim_id must be unique. This is the grain of the table.
        SELECT 'silver claim_id is unique',
               'SILVER', 'SILVER',
               0::NUMBER(38,2),
               (SELECT COUNT(*) FROM (SELECT claim_id FROM SILVER.CLAIMS
                                       GROUP BY 1 HAVING COUNT(*) > 1))::NUMBER(38,2),
               0::NUMBER(38,2)

        UNION ALL

        -- Policy snapshots survive intact: both extracts, deduped per extract.
        SELECT 'policy snapshots per extract are unique',
               'SILVER', 'SILVER',
               0::NUMBER(38,2),
               (SELECT COUNT(*) FROM (SELECT policy_id, extract_date
                                        FROM SILVER.POLICIES
                                       GROUP BY 1,2 HAVING COUNT(*) > 1))::NUMBER(38,2),
               0::NUMBER(38,2)

        UNION ALL

        -- Money: Bronze total, less what was quarantined and less duplicates,
        -- must equal Silver. Sub-cent tolerance for decimal noise.
        SELECT 'claim amount ties bronze to silver',
               'BRONZE', 'SILVER',
               (SELECT SUM(TRY_TO_DECIMAL(b.amount, 38, 2))
                  FROM (SELECT amount,
                               ROW_NUMBER() OVER (PARTITION BY TRIM(claim_id)
                                                  ORDER BY _file_row_number) AS rn
                          FROM BRONZE.RAW_CLAIMS) b
                 WHERE b.rn = 1
                   AND TRY_TO_DECIMAL(b.amount, 38, 2) > 0)::NUMBER(38,2),
               (SELECT SUM(amount) FROM SILVER.CLAIMS)::NUMBER(38,2),
               0.01::NUMBER(38,2)

        UNION ALL

        -- Orphan RATE, not orphan count. Some orphans are normal; a spike is not.
        SELECT 'orphan claim rate below 2 percent',
               'SILVER', 'SILVER',
               0::NUMBER(38,2),
               (SELECT ROUND(100.0 * COUNT_IF(is_orphan_policy) / NULLIF(COUNT(*), 0), 2)
                  FROM SILVER.CLAIMS)::NUMBER(38,2),
               2.00::NUMBER(38,2)
    );

    SELECT COUNT(*) INTO :failed_count
      FROM OPS.RECONCILIATION
     WHERE run_label = :RUN_LABEL
       AND gate      = 'BRONZE_TO_SILVER'
       AND passed    = FALSE;

    IF (failed_count > 0) THEN
        RAISE gate_failed;
    END IF;

    RETURN 'PASSED - Bronze to Silver reconciled, promotion to Gold allowed';
END;
$$;


-- ============================================================================
-- 3. GATE 2 — Silver → Gold
-- Runs AFTER Gold is built. Guards what reporting actually reads.
--
-- These are the three things a Type 2 dimension gets silently wrong:
-- overlapping validity windows, more than one current row per policy, and fact
-- fan-out. All three produce a table that looks fine and sums wrong.
-- ============================================================================

CREATE OR REPLACE PROCEDURE OPS.SP_RECONCILE_GOLD(RUN_LABEL VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    failed_count  INTEGER;
    gate_failed   EXCEPTION (-20002,
        'RECONCILIATION FAILED at Silver->Gold. Gold is not fit to publish.');
BEGIN
    DELETE FROM OPS.RECONCILIATION
     WHERE run_label = :RUN_LABEL AND gate = 'SILVER_TO_GOLD';

    INSERT INTO OPS.RECONCILIATION
        (run_label, gate, check_name, source_layer, target_layer,
         source_value, target_value, variance, tolerance, passed, checked_at)
    SELECT
        :RUN_LABEL,
        'SILVER_TO_GOLD',
        check_name, source_layer, target_layer,
        source_value, target_value,
        ABS(source_value - target_value),
        tolerance,
        ABS(source_value - target_value) <= tolerance,
        CURRENT_TIMESTAMP()
    FROM (
        -- One fact row per Silver claim. No more, no fewer.
        SELECT 'fact row count matches silver' AS check_name,
               'SILVER' AS source_layer, 'GOLD' AS target_layer,
               (SELECT COUNT(*) FROM SILVER.CLAIMS)::NUMBER(38,2)   AS source_value,
               (SELECT COUNT(*) FROM GOLD.FACT_CLAIM)::NUMBER(38,2) AS target_value,
               0::NUMBER(38,2) AS tolerance

        UNION ALL

        -- THE control total. If this drifts, someone's report is wrong.
        SELECT 'claim amount ties silver to gold',
               'SILVER', 'GOLD',
               (SELECT SUM(amount) FROM SILVER.CLAIMS)::NUMBER(38,2),
               (SELECT SUM(amount) FROM GOLD.FACT_CLAIM)::NUMBER(38,2),
               0.01::NUMBER(38,2)

        UNION ALL

        -- Grain assertion: one row per claim in the fact table.
        SELECT 'fact grain is one row per claim',
               'GOLD', 'GOLD',
               0::NUMBER(38,2),
               (SELECT COUNT(*) FROM (SELECT claim_id FROM GOLD.FACT_CLAIM
                                       GROUP BY 1 HAVING COUNT(*) > 1))::NUMBER(38,2),
               0::NUMBER(38,2)

        UNION ALL

        -- SCD2: exactly one current row per policy. Two current versions means
        -- a MERGE closed the wrong row, and every "as at today" query is wrong.
        SELECT 'exactly one current version per policy',
               'GOLD', 'GOLD',
               0::NUMBER(38,2),
               (SELECT COUNT(*) FROM (SELECT policy_id FROM GOLD.DIM_POLICY
                                       WHERE is_current = TRUE
                                       GROUP BY 1 HAVING COUNT(*) > 1))::NUMBER(38,2),
               0::NUMBER(38,2)

        UNION ALL

        -- SCD2: no overlapping validity windows. Overlap means a claim can match
        -- two versions and the fact silently doubles.
        SELECT 'no overlapping policy validity windows',
               'GOLD', 'GOLD',
               0::NUMBER(38,2),
               (SELECT COUNT(*)
                  FROM GOLD.DIM_POLICY a
                  JOIN GOLD.DIM_POLICY b
                    ON a.policy_id  = b.policy_id
                   AND a.policy_key < b.policy_key
                   AND a.valid_from < b.valid_to
                   AND b.valid_from < a.valid_to
                 WHERE a.policy_id <> 'UNKNOWN')::NUMBER(38,2),
               0::NUMBER(38,2)

        UNION ALL

        -- Every distinct policy in Silver has a current row in Gold.
        SELECT 'policy coverage silver to gold',
               'SILVER', 'GOLD',
               (SELECT COUNT(DISTINCT policy_id) FROM SILVER.POLICIES)::NUMBER(38,2),
               (SELECT COUNT(*) FROM GOLD.DIM_POLICY
                 WHERE is_current = TRUE AND policy_id <> 'UNKNOWN')::NUMBER(38,2),
               0::NUMBER(38,2)
    );

    SELECT COUNT(*) INTO :failed_count
      FROM OPS.RECONCILIATION
     WHERE run_label = :RUN_LABEL
       AND gate      = 'SILVER_TO_GOLD'
       AND passed    = FALSE;

    IF (failed_count > 0) THEN
        RAISE gate_failed;
    END IF;

    RETURN 'PASSED - Silver to Gold reconciled, Gold is fit to publish';
END;
$$;


-- ============================================================================
-- 4.  >>> RECORD THIS <<<   Both gates on clean data
-- Expect PASSED from both, and all 12 checks TRUE.
-- ============================================================================

CALL OPS.SP_RECONCILE_SILVER('baseline');
CALL OPS.SP_RECONCILE_GOLD('baseline');

SELECT gate, check_name, source_value, target_value, variance, tolerance, passed
FROM OPS.RECONCILIATION
WHERE run_label = 'baseline'
ORDER BY gate, check_name;


-- ============================================================================
-- 5.  >>> THE MONEY SHOT — RECORD THIS <<<   Break it on purpose
--
-- Anyone can show a green dashboard. What proves a gate works is watching it
-- go red and stop something.
--
-- One claim moves by $1,000. Out of $1.06 billion — 0.0001%.
-- Row count still right. Grain still right. Every dimension intact.
-- Only the control total moves.
--
-- That's exactly the error a human eye never catches and a control total
-- always does.
--
-- THE ERROR IS THE SUCCESS CONDITION HERE.
-- ============================================================================

-- Before: what Gold currently totals.
SELECT SUM(amount) AS gold_total_before FROM GOLD.FACT_CLAIM;

-- Introduce the drift.
UPDATE GOLD.FACT_CLAIM
   SET amount = amount + 1000
 WHERE claim_id = (SELECT MIN(claim_id) FROM GOLD.FACT_CLAIM);

-- Run the gate. THIS SHOULD FAIL with:
--   "RECONCILIATION FAILED at Silver->Gold. Gold is not fit to publish."
CALL OPS.SP_RECONCILE_GOLD('demo_broken');

-- The error stops the script, so run this next to see WHICH check caught it.
-- Expect 'claim amount ties silver to gold' with variance 1000.00 and
-- passed = FALSE, while every other check still passes. A good gate does not
-- just say "something is wrong" — it says what.
SELECT check_name, source_value, target_value, variance, tolerance, passed
FROM OPS.RECONCILIATION
WHERE run_label = 'demo_broken'
ORDER BY passed, check_name;


-- =============================================================================
-- 6. Put it back and confirm green
-- =============================================================================

UPDATE GOLD.FACT_CLAIM
   SET amount = amount - 1000
 WHERE claim_id = (SELECT MIN(claim_id) FROM GOLD.FACT_CLAIM);

CALL OPS.SP_RECONCILE_GOLD('demo_fixed');
-- Expect: PASSED - Silver to Gold reconciled, Gold is fit to publish


-- ============================================================================
-- 7. Wire the gate into the task tree
--
-- Until now the gates are something you call by hand. This makes them actually
-- block promotion.
--
--   01 DRAIN STREAM
--     ├── 02 QUARANTINE
--     └── 03 SILVER
--           └── 05 RECONCILE SILVER   <-- new gate
--                 └── 04 GOLD          <-- runs ONLY if the gate passed
--                       └── 06 RECONCILE GOLD
--
-- If 05 raises, it fails, and 04 never runs. Gold keeps yesterday's good data
-- instead of being overwritten with today's bad data.
--
-- That's "blocking promotion between layers", and it's now literally true.
--
-- >>> SUSPEND THE ROOT BEFORE CHANGING ANYTHING <<<
-- Snowflake won't let you modify a task whose tree is running.
-- ============================================================================

ALTER TASK OPS.T_CLAIMS_01_DRAIN_STREAM SUSPEND;

-- The new gate task, between Silver and Gold.
CREATE OR REPLACE TASK OPS.T_CLAIMS_05_RECONCILE_SILVER
    WAREHOUSE = WH_MEDALLION
    AFTER OPS.T_CLAIMS_03_SILVER
AS
CALL OPS.SP_RECONCILE_SILVER('task_run_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISS'));

-- Re-point Gold so it now depends on the gate, not on Silver directly.
-- Recreating the task is how you change an AFTER dependency.
CREATE OR REPLACE TASK OPS.T_CLAIMS_04_GOLD
    WAREHOUSE = WH_MEDALLION
    AFTER OPS.T_CLAIMS_05_RECONCILE_SILVER
AS
MERGE INTO GOLD.FACT_CLAIM AS tgt
USING (
    SELECT
        c.claim_id,
        COALESCE(p.policy_key, -1) AS policy_key,
        COALESCE(p.broker_key, -1) AS broker_key,
        COALESCE(d.date_key,   -1) AS claim_date_key,
        c.claim_date, c.amount, c.status,
        c.is_orphan_policy, c.is_amount_outlier, c.has_invalid_date
    FROM SILVER.CLAIMS c
    LEFT JOIN GOLD.DIM_POLICY p
           ON p.policy_id = c.policy_id
          AND COALESCE(c.claim_date, DATE '9999-12-30') >= p.valid_from
          AND COALESCE(c.claim_date, DATE '9999-12-30') <  p.valid_to
    LEFT JOIN GOLD.DIM_DATE d
           ON d.full_date = c.claim_date
    WHERE c.claim_id IN (SELECT TRIM(claim_id) FROM OPS.BATCH_CLAIMS)
) AS src
   ON tgt.claim_id = src.claim_id
WHEN MATCHED THEN UPDATE SET
    tgt.policy_key        = src.policy_key,
    tgt.broker_key        = src.broker_key,
    tgt.claim_date_key    = src.claim_date_key,
    tgt.claim_date        = src.claim_date,
    tgt.amount            = src.amount,
    tgt.status            = src.status,
    tgt.is_orphan_policy  = src.is_orphan_policy,
    tgt.is_amount_outlier = src.is_amount_outlier,
    tgt.has_invalid_date  = src.has_invalid_date,
    tgt._loaded_at        = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
    (claim_key, claim_id, policy_key, broker_key, claim_date_key, claim_date,
     amount, status, is_orphan_policy, is_amount_outlier, has_invalid_date,
     _loaded_at)
VALUES
    (GOLD.SEQ_CLAIM_KEY.NEXTVAL, src.claim_id, src.policy_key, src.broker_key,
     src.claim_date_key, src.claim_date, src.amount, src.status,
     src.is_orphan_policy, src.is_amount_outlier, src.has_invalid_date,
     CURRENT_TIMESTAMP());

-- The closing gate, after Gold is built.
CREATE OR REPLACE TASK OPS.T_CLAIMS_06_RECONCILE_GOLD
    WAREHOUSE = WH_MEDALLION
    AFTER OPS.T_CLAIMS_04_GOLD
AS
CALL OPS.SP_RECONCILE_GOLD('task_run_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISS'));

-- Resume children first, root last. Same rule as Stage 4.
ALTER TASK OPS.T_CLAIMS_06_RECONCILE_GOLD   RESUME;
ALTER TASK OPS.T_CLAIMS_04_GOLD             RESUME;
ALTER TASK OPS.T_CLAIMS_05_RECONCILE_SILVER RESUME;
ALTER TASK OPS.T_CLAIMS_03_SILVER           RESUME;
ALTER TASK OPS.T_CLAIMS_02_QUARANTINE       RESUME;
ALTER TASK OPS.T_CLAIMS_01_DRAIN_STREAM     RESUME;   -- root LAST

SHOW TASKS IN SCHEMA OPS;


-- =============================================================================
-- 8. Prove the gate blocks a real run
--
-- Feed two good claims, break Silver->Gold reconciliation first, and watch the
-- Gold task never execute.
-- =============================================================================

-- Two new claims into Bronze.
INSERT INTO BRONZE.RAW_CLAIMS
    (claim_id, policy_id, claim_date, amount, status,
     _source_file, _file_row_number, _loaded_at)
VALUES
    ('CLM9999101', 'POL000010', '2026-08-12', '4321.00', 'OPEN',
     'gate_demo.csv', 1, CURRENT_TIMESTAMP()),
    ('CLM9999102', 'POL000011', '2026-08-12', '8765.00', 'OPEN',
     'gate_demo.csv', 2, CURRENT_TIMESTAMP());

-- Break the Bronze->Silver gate: delete a Silver row that Bronze still has and
-- quarantine does not. Now Bronze cannot be accounted for.
DELETE FROM SILVER.CLAIMS
 WHERE claim_id = (SELECT MIN(claim_id) FROM SILVER.CLAIMS);

EXECUTE TASK OPS.T_CLAIMS_01_DRAIN_STREAM;

-- Wait ~30 seconds, then look. Expect:
--   01, 02, 03 SUCCEEDED
--   05 FAILED   <- the gate
--   04, 06 never appear at all — promotion was blocked
SELECT name, state, scheduled_time, completed_time, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
))
ORDER BY scheduled_time DESC;

-- The two new claims reached Silver but NOT Gold. That is the gate doing its
-- job: bad state stops where it is instead of propagating to the layer people
-- report from.
SELECT (SELECT COUNT(*) FROM SILVER.CLAIMS)   AS silver_claims,
       (SELECT COUNT(*) FROM GOLD.FACT_CLAIM) AS gold_facts;

-- Which check failed, and by how much.
SELECT run_label, check_name, source_value, target_value, variance, tolerance, passed
FROM OPS.RECONCILIATION
WHERE gate = 'BRONZE_TO_SILVER' AND passed = FALSE
ORDER BY checked_at DESC
LIMIT 5;


-- =============================================================================
-- 9. Repair and re-run
--
-- Rebuild Silver from Bronze, then let the pipeline through cleanly.
-- =============================================================================

-- 9a. Restore any Bronze claim that Silver is missing.
INSERT INTO SILVER.CLAIMS
    (claim_id, policy_id, claim_date, amount, status,
     has_invalid_date, is_orphan_policy, is_amount_outlier,
     _source_file, _loaded_at)
SELECT
    b.claim_id, b.policy_id, b.claim_date, b.amount, b.status,
    b.has_invalid_date,
    p.policy_id IS NULL,
    b.is_outlier,
    b._source_file, b._loaded_at
FROM (
    SELECT TRIM(claim_id)                        AS claim_id,
           TRIM(policy_id)                       AS policy_id,
           TRY_TO_DATE(claim_date)               AS claim_date,
           TRY_TO_DECIMAL(amount, 38, 2)         AS amount,
           UPPER(TRIM(status))                   AS status,
           TRY_TO_DATE(claim_date) IS NULL       AS has_invalid_date,
           TRY_TO_DECIMAL(amount, 38, 2) > 1000000 AS is_outlier,
           _source_file, _loaded_at,
           ROW_NUMBER() OVER (PARTITION BY TRIM(claim_id)
                              ORDER BY _file_row_number) AS rn
    FROM BRONZE.RAW_CLAIMS
) b
LEFT JOIN (SELECT DISTINCT policy_id FROM SILVER.POLICIES) p
       ON p.policy_id = b.policy_id
WHERE b.rn = 1
  AND b.amount > 0
  AND NOT EXISTS (SELECT 1 FROM SILVER.CLAIMS s WHERE s.claim_id = b.claim_id);

-- 9b. Gate 1 should pass again.
CALL OPS.SP_RECONCILE_SILVER('after_repair');

-- 9c. Catch Gold up. The two claims blocked at the gate are in Silver but not
--     in Gold, so Gate 2 would still fail on the row-count check — correctly.
--     A gate that goes green before the data is actually fixed is worse than no
--     gate at all.
MERGE INTO GOLD.FACT_CLAIM AS tgt
USING (
    SELECT
        c.claim_id,
        COALESCE(p.policy_key, -1) AS policy_key,
        COALESCE(p.broker_key, -1) AS broker_key,
        COALESCE(d.date_key,   -1) AS claim_date_key,
        c.claim_date, c.amount, c.status,
        c.is_orphan_policy, c.is_amount_outlier, c.has_invalid_date
    FROM SILVER.CLAIMS c
    LEFT JOIN GOLD.DIM_POLICY p
           ON p.policy_id = c.policy_id
          AND COALESCE(c.claim_date, DATE '9999-12-30') >= p.valid_from
          AND COALESCE(c.claim_date, DATE '9999-12-30') <  p.valid_to
    LEFT JOIN GOLD.DIM_DATE d
           ON d.full_date = c.claim_date
) AS src
   ON tgt.claim_id = src.claim_id
WHEN MATCHED THEN UPDATE SET
    tgt.amount     = src.amount,
    tgt.status     = src.status,
    tgt._loaded_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
    (claim_key, claim_id, policy_key, broker_key, claim_date_key, claim_date,
     amount, status, is_orphan_policy, is_amount_outlier, has_invalid_date,
     _loaded_at)
VALUES
    (GOLD.SEQ_CLAIM_KEY.NEXTVAL, src.claim_id, src.policy_key, src.broker_key,
     src.claim_date_key, src.claim_date, src.amount, src.status,
     src.is_orphan_policy, src.is_amount_outlier, src.has_invalid_date,
     CURRENT_TIMESTAMP());

-- 9d. Gate 2 should now pass.
CALL OPS.SP_RECONCILE_GOLD('after_repair');

SELECT gate, check_name, variance, tolerance, passed
FROM OPS.RECONCILIATION
WHERE run_label = 'after_repair'
ORDER BY gate, check_name;


-- =============================================================================
-- 10. Suspend when done
-- =============================================================================

ALTER TASK OPS.T_CLAIMS_01_DRAIN_STREAM SUSPEND;
SHOW TASKS IN SCHEMA OPS;


-- =============================================================================
-- 11. The run history — what you would actually monitor
--
-- Every gate run, every check, pass or fail, with the variance. This is the
-- table you would put a chart on and alert from.
-- =============================================================================

SELECT run_label, gate,
       COUNT(*)                              AS checks_run,
       COUNT_IF(passed = FALSE)              AS checks_failed,
       MAX(variance)                         AS worst_variance,
       MIN(checked_at)                       AS run_at
FROM OPS.RECONCILIATION
GROUP BY 1, 2
ORDER BY run_at DESC;
