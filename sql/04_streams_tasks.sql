-- ============================================================================
-- Stage 4 — STREAMS AND TASKS: make it incremental
-- Steps 8 and 9 are the ones to record.
--
-- Everything so far rebuilds the whole table every run. Fine at 12,000 rows.
-- Ruinous at 12 million.
--
-- This changes the shape: find what changed, move only that, cost nothing when
-- nothing changed.
--
-- SCOPE: streams on all three Bronze tables, task tree built end-to-end for
-- the CLAIMS path only. Policies and brokers follow the identical pattern —
-- building all three triples the file and teaches nothing new. Say that if asked.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_MEDALLION;
USE DATABASE INSURANCE_DEMO;
USE SCHEMA BRONZE;


-- ============================================================================
-- 1. Streams
--
-- A stream is NOT a copy of your data. It's a bookmark — an offset into the
-- table, plus enough metadata to work out what's arrived since you last looked.
-- Stores almost nothing, costs almost nothing.
--
-- APPEND_ONLY because Bronze is append-only. Cheaper than a standard stream.
--   Standard    inserts, updates, deletes (full CDC)
--   Append-only inserts only, cheapest
--   Insert-only external tables
--
-- >>> THE THING THEY ASK <<<
-- READING A STREAM INSIDE DML ADVANCES ITS OFFSET.
-- A plain SELECT doesn't — look all day, it stays put. But make a stream the
-- source of an INSERT or MERGE, and on commit those rows are gone from it.
--
-- So a stream can only be consumed ONCE. Two tasks reading the same stream is
-- a silent data-loss bug. That's why step 2 exists.
-- ============================================================================

CREATE OR REPLACE STREAM BRONZE.STR_RAW_BROKERS
    ON TABLE BRONZE.RAW_BROKERS  APPEND_ONLY = TRUE;

CREATE OR REPLACE STREAM BRONZE.STR_RAW_POLICIES
    ON TABLE BRONZE.RAW_POLICIES APPEND_ONLY = TRUE;

CREATE OR REPLACE STREAM BRONZE.STR_RAW_CLAIMS
    ON TABLE BRONZE.RAW_CLAIMS   APPEND_ONLY = TRUE;


-- All three empty, even though Bronze holds 22,161 rows.
-- A stream's offset is set to NOW when created — it shows what arrives AFTER
-- creation, not history. That surprises people.
SELECT 'STR_RAW_BROKERS'  AS stream_name,
       SYSTEM$STREAM_HAS_DATA('INSURANCE_DEMO.BRONZE.STR_RAW_BROKERS')  AS has_data
UNION ALL SELECT 'STR_RAW_POLICIES',
       SYSTEM$STREAM_HAS_DATA('INSURANCE_DEMO.BRONZE.STR_RAW_POLICIES')
UNION ALL SELECT 'STR_RAW_CLAIMS',
       SYSTEM$STREAM_HAS_DATA('INSURANCE_DEMO.BRONZE.STR_RAW_CLAIMS');


-- ============================================================================
-- 2. The batch table
--
-- Exists purely because of the offset rule above.
--
-- The claims path needs the incoming rows three times — quarantine the bad,
-- load the good, push to Gold. If each read the stream, only the first would
-- see anything.
--
-- So task 1 drains the stream here ONCE, and everything downstream reads this
-- table.
--
-- TRANSIENT: skips Fail-safe, which is 7 days of storage you'd otherwise pay
-- for on data that can be rebuilt.
-- ============================================================================

CREATE OR REPLACE TRANSIENT TABLE OPS.BATCH_CLAIMS (
    claim_id           VARCHAR,
    policy_id          VARCHAR,
    claim_date         VARCHAR,
    amount             VARCHAR,
    status             VARCHAR,
    _source_file       VARCHAR,
    _file_row_number   NUMBER,
    _loaded_at         TIMESTAMP_NTZ,
    _batch_at          TIMESTAMP_NTZ
);


-- ============================================================================
-- 3. TASK 1 (root) — drain the stream into the batch table
--
-- A task runs exactly ONE SQL statement. That constraint shapes the design:
-- anything needing several statements becomes several tasks.
--
-- INSERT OVERWRITE truncates and refills in one statement — that's what makes
-- "clear last batch, load this batch" a single task.
--
-- WHEN SYSTEM$STREAM_HAS_DATA is the cost control. False = task is SKIPPED and
-- NO WAREHOUSE STARTS. The check is metadata only, so it's free. Polling every
-- 5 minutes on an idle stream costs nothing.
--
-- Gating at the ROOT skips the whole tree. One cheap check protects five tasks.
-- ============================================================================

CREATE OR REPLACE TASK OPS.T_CLAIMS_01_DRAIN_STREAM
    WAREHOUSE = WH_MEDALLION
    SCHEDULE  = '5 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('INSURANCE_DEMO.BRONZE.STR_RAW_CLAIMS')
AS
INSERT OVERWRITE INTO OPS.BATCH_CLAIMS
    (claim_id, policy_id, claim_date, amount, status,
     _source_file, _file_row_number, _loaded_at, _batch_at)
SELECT claim_id, policy_id, claim_date, amount, status,
       _source_file, _file_row_number, _loaded_at, CURRENT_TIMESTAMP()
FROM BRONZE.STR_RAW_CLAIMS
WHERE METADATA$ACTION = 'INSERT';


-- ============================================================================
-- 4. TASK 2 — quarantine the bad rows from the batch
--
-- AFTER makes this a child. Children run only when the parent succeeds.
-- The dependency graph is a DAG — Snowflake's built-in orchestration, and the
-- reason a simple pipeline doesn't need Airflow.
-- ============================================================================

CREATE OR REPLACE TASK OPS.T_CLAIMS_02_QUARANTINE
    WAREHOUSE = WH_MEDALLION
    AFTER OPS.T_CLAIMS_01_DRAIN_STREAM
AS
INSERT INTO OPS.QUARANTINE
    (source_table, natural_key, reject_reason, raw_record,
     _source_file, _file_row_number)
SELECT
    'RAW_CLAIMS',
    TRIM(claim_id),
    CASE
        WHEN NULLIF(TRIM(claim_id), '') IS NULL     THEN 'claim_id is null or blank'
        WHEN TRY_TO_DECIMAL(amount, 38, 2) IS NULL  THEN 'amount is not numeric'
        ELSE 'amount is zero or negative'
    END,
    OBJECT_CONSTRUCT('claim_id', claim_id, 'policy_id', policy_id,
                     'claim_date', claim_date, 'amount', amount, 'status', status),
    _source_file,
    _file_row_number
FROM OPS.BATCH_CLAIMS
WHERE NULLIF(TRIM(claim_id), '') IS NULL
   OR TRY_TO_DECIMAL(amount, 38, 2) IS NULL
   OR TRY_TO_DECIMAL(amount, 38, 2) <= 0;


-- ============================================================================
-- 5. TASK 3 — MERGE the good rows into Silver
--
-- MERGE, not INSERT. That's what makes the task idempotent: run it twice on
-- the same batch and the second run updates rows to values they already hold.
--
-- In Stage 1 idempotence was free — COPY INTO tracks loaded files. Here there's
-- no such protection. You build it, and MERGE on the natural key is how.
-- Being able to explain BOTH mechanisms is the strong answer.
--
-- Dedupe inside the batch too: MERGE errors if two source rows hit the same
-- target row.
--
-- Nested subquery not a CTE — a WITH leading the USING subquery isn't reliably
-- accepted inside MERGE.
-- ============================================================================

CREATE OR REPLACE TASK OPS.T_CLAIMS_03_SILVER
    WAREHOUSE = WH_MEDALLION
    AFTER OPS.T_CLAIMS_01_DRAIN_STREAM
AS
MERGE INTO SILVER.CLAIMS AS tgt
USING (
    SELECT
        TRIM(r.claim_id)                       AS claim_id,
        TRIM(r.policy_id)                      AS policy_id,
        TRY_TO_DATE(r.claim_date)              AS claim_date,
        TRY_TO_DECIMAL(r.amount, 38, 2)        AS amount,
        UPPER(TRIM(r.status))                  AS status,
        TRY_TO_DATE(r.claim_date) IS NULL      AS has_invalid_date,
        p.policy_id IS NULL                    AS is_orphan_policy,
        TRY_TO_DECIMAL(r.amount, 38, 2) > 1000000 AS is_amount_outlier,
        r._source_file,
        r._loaded_at
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY TRIM(claim_id)
                   ORDER BY _file_row_number
               ) AS rn
        FROM OPS.BATCH_CLAIMS
        WHERE NULLIF(TRIM(claim_id), '') IS NOT NULL
          AND TRY_TO_DECIMAL(amount, 38, 2) IS NOT NULL
          AND TRY_TO_DECIMAL(amount, 38, 2) > 0
    ) r
    LEFT JOIN (SELECT DISTINCT policy_id FROM SILVER.POLICIES) p
           ON p.policy_id = TRIM(r.policy_id)
    WHERE r.rn = 1
) AS src
   ON tgt.claim_id = src.claim_id
WHEN MATCHED THEN UPDATE SET
    tgt.policy_id         = src.policy_id,
    tgt.claim_date        = src.claim_date,
    tgt.amount            = src.amount,
    tgt.status            = src.status,
    tgt.has_invalid_date  = src.has_invalid_date,
    tgt.is_orphan_policy  = src.is_orphan_policy,
    tgt.is_amount_outlier = src.is_amount_outlier,
    tgt._source_file      = src._source_file,
    tgt._loaded_at        = src._loaded_at
WHEN NOT MATCHED THEN INSERT
    (claim_id, policy_id, claim_date, amount, status,
     has_invalid_date, is_orphan_policy, is_amount_outlier,
     _source_file, _loaded_at)
VALUES
    (src.claim_id, src.policy_id, src.claim_date, src.amount, src.status,
     src.has_invalid_date, src.is_orphan_policy, src.is_amount_outlier,
     src._source_file, src._loaded_at);


-- ============================================================================
-- 6. TASK 4 — MERGE into Gold
--
-- AFTER the Silver task, because Gold reads what Silver just wrote.
-- That ordering is the whole point of a task tree.
--
-- Same version-aware policy lookup as Stage 3: natural key AND claim_date
-- inside [valid_from, valid_to). Half-open, never BETWEEN.
-- ============================================================================

CREATE OR REPLACE TASK OPS.T_CLAIMS_04_GOLD
    WAREHOUSE = WH_MEDALLION
    AFTER OPS.T_CLAIMS_03_SILVER
AS
MERGE INTO GOLD.FACT_CLAIM AS tgt
USING (
    SELECT
        c.claim_id,
        COALESCE(p.policy_key, -1) AS policy_key,
        COALESCE(p.broker_key, -1) AS broker_key,
        COALESCE(d.date_key,   -1) AS claim_date_key,
        c.claim_date,
        c.amount,
        c.status,
        c.is_orphan_policy,
        c.is_amount_outlier,
        c.has_invalid_date
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


-- ============================================================================
-- 7. Start the tree
--
-- >>> ORDER MATTERS AND IT'S BACKWARDS FROM WHAT YOU'D EXPECT <<<
-- Tasks are created SUSPENDED. RESUME CHILDREN FIRST, ROOT LAST.
--
-- Resume the root first and it can fire before its children are live. The run
-- does step one and silently stops. The tree "works" and moves no data.
--
-- Mirror image for changes: to alter any task, SUSPEND THE ROOT first.
-- Snowflake won't let you modify a task whose tree is running.
-- ============================================================================

ALTER TASK OPS.T_CLAIMS_04_GOLD        RESUME;
ALTER TASK OPS.T_CLAIMS_03_SILVER      RESUME;
ALTER TASK OPS.T_CLAIMS_02_QUARANTINE  RESUME;
ALTER TASK OPS.T_CLAIMS_01_DRAIN_STREAM RESUME;   -- root LAST

SHOW TASKS IN SCHEMA OPS;
-- All four should show state = started.


-- ============================================================================
-- 8.  >>> RECORD THIS <<<   No new data — nothing moves
--
-- Counts, fire the pipeline, counts again. Identical.
--
-- EXECUTE TASK triggers the root now instead of waiting 5 minutes.
-- Expect state = SKIPPED on the root and no child runs.
-- (If yours shows SUCCEEDED, the WHEN wasn't applied to the manual trigger —
-- counts are still unchanged, because an empty stream writes zero rows.)
--
-- SAY IT PRECISELY: the pipeline didn't run and change nothing.
-- It didn't run at all. No warehouse started. No credit burned.
-- ============================================================================

-- Before.   Expect 11,887 / 11,887 / 113.
SELECT (SELECT COUNT(*) FROM SILVER.CLAIMS)     AS silver_claims,
       (SELECT COUNT(*) FROM GOLD.FACT_CLAIM)   AS gold_facts,
       (SELECT COUNT(*) FROM OPS.QUARANTINE)    AS quarantined;

EXECUTE TASK OPS.T_CLAIMS_01_DRAIN_STREAM;

-- Wait ~10 seconds, then look.
SELECT name, state, scheduled_time, completed_time, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
))
ORDER BY scheduled_time DESC;

-- After. IDENTICAL.
SELECT (SELECT COUNT(*) FROM SILVER.CLAIMS)     AS silver_claims,
       (SELECT COUNT(*) FROM GOLD.FACT_CLAIM)   AS gold_facts,
       (SELECT COUNT(*) FROM OPS.QUARANTINE)    AS quarantined;


-- ============================================================================
-- 9.  >>> RECORD THIS <<<   Now feed it three rows
--
-- Two good, one with a negative amount. Watch three land in Bronze and exactly
-- two arrive in Gold — typed, conformed, key-resolved, joined to the right
-- policy version. No rebuild anywhere.
-- ============================================================================

INSERT INTO BRONZE.RAW_CLAIMS
    (claim_id, policy_id, claim_date, amount, status,
     _source_file, _file_row_number, _loaded_at)
VALUES
    ('CLM9999001', 'POL000001', '2026-08-10',  '12345.67', 'OPEN',
     'manual_demo.csv', 1, CURRENT_TIMESTAMP()),
    ('CLM9999002', 'POL000002', '2026-08-11',  '54321.00', 'IN REVIEW',
     'manual_demo.csv', 2, CURRENT_TIMESTAMP()),
    ('CLM9999003', 'POL000003', '2026-08-11', '-999.00',   'OPEN',
     'manual_demo.csv', 3, CURRENT_TIMESTAMP());

-- Stream sees them.   Expect TRUE.
SELECT SYSTEM$STREAM_HAS_DATA('INSURANCE_DEMO.BRONZE.STR_RAW_CLAIMS') AS has_data;

-- Look WITHOUT consuming — a plain SELECT doesn't move the offset.
-- Expect 3 rows, METADATA$ACTION = 'INSERT'.
SELECT claim_id, amount, METADATA$ACTION, METADATA$ISUPDATE
FROM BRONZE.STR_RAW_CLAIMS;

EXECUTE TASK OPS.T_CLAIMS_01_DRAIN_STREAM;

-- Wait ~20 seconds. Expect SUCCEEDED on all four this time.
SELECT name, state, scheduled_time, completed_time, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
))
ORDER BY scheduled_time DESC;

-- Expect 11,889 / 11,889 / 114. Two through, one quarantined.
SELECT (SELECT COUNT(*) FROM SILVER.CLAIMS)     AS silver_claims,
       (SELECT COUNT(*) FROM GOLD.FACT_CLAIM)   AS gold_facts,
       (SELECT COUNT(*) FROM OPS.QUARANTINE)    AS quarantined;

-- The two new facts, fully resolved. Real surrogate keys, not -1 — the
-- incremental path did the same dimensional lookup the full rebuild did.
SELECT claim_key, claim_id, policy_key, broker_key, claim_date_key, amount, status
FROM GOLD.FACT_CLAIM
WHERE claim_id LIKE 'CLM9999%'
ORDER BY claim_id;

-- The rejected one, with its reason.
SELECT natural_key, reject_reason, raw_record
FROM OPS.QUARANTINE
WHERE natural_key = 'CLM9999003';

-- Stream empty again — those rows were consumed.   Expect FALSE.
SELECT SYSTEM$STREAM_HAS_DATA('INSURANCE_DEMO.BRONZE.STR_RAW_CLAIMS') AS has_data;


-- ============================================================================
-- 10.  SUSPEND WHEN DONE
--
-- These poll every 5 minutes forever. Skipped runs cost nothing, but an
-- unattended task tree is a bad habit. Suspend the ROOT, the tree stops.
-- ============================================================================

ALTER TASK OPS.T_CLAIMS_01_DRAIN_STREAM SUSPEND;
SHOW TASKS IN SCHEMA OPS;


-- ============================================================================
-- 11. Streams+Tasks, or dbt on a schedule?
--
--   Streams + Tasks — native, low latency, no extra infrastructure or bill.
--     Best when the logic is SQL, lives in Snowflake, and needs to react
--     within minutes. Weak on testing, docs and lineage — a task tree is a DAG
--     you can't easily see.
--
--   dbt on a schedule — version-controlled models, built-in tests, generated
--     docs, visible lineage. Weak on latency: runs when the scheduler says so,
--     not when data lands.
--
--   Large teams run both. dbt for modelled transformations, streams and tasks
--     for the low-latency ingestion edge.
--
-- The one-liner: "Streams and Tasks when latency matters and the logic is SQL
-- inside Snowflake. dbt when the transformations need to be tested, documented
-- and reviewed like code."
-- ============================================================================
