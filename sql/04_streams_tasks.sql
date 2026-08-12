-- =============================================================================
-- Stage 4 — STREAMS AND TASKS: make it incremental
--
-- Everything up to now was full rebuild: CREATE OR REPLACE, reload all 12,060
-- claims, every run. That is fine at 12,000 rows and ruinous at 12 million.
--
-- This stage changes the shape of the pipeline. Instead of "rebuild everything",
-- it becomes "find what changed, move only that, and cost nothing when nothing
-- changed."
--
-- SCOPE, STATED HONESTLY: streams go on all three Bronze tables, and the task
-- tree is built end-to-end for the CLAIMS path — Bronze → Silver → quarantine →
-- Gold. Policies and brokers follow the identical pattern; building all three
-- triples the file and teaches nothing new. Say exactly that if asked.
--
-- Steps 6 and 7 are the ones worth recording.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_MEDALLION;
USE DATABASE INSURANCE_DEMO;
USE SCHEMA BRONZE;


-- =============================================================================
-- 1. Streams
--
-- A stream is NOT a copy of your data. It is a bookmark — an offset into the
-- table plus the metadata needed to work out which rows have arrived since you
-- last looked. It stores almost nothing and costs almost nothing.
--
-- APPEND_ONLY = TRUE because Bronze is append-only. An append-only stream tracks
-- inserts and ignores updates and deletes, which makes it cheaper and faster
-- than a standard stream. Choosing the right stream type is a real answer to
-- "how would you keep costs down?"
--
--   Standard    - inserts, updates, deletes (full CDC)
--   Append-only - inserts only, cheapest
--   Insert-only - external tables
--
-- >>> THE THING THEY WILL ASK YOU <<<
-- READING A STREAM INSIDE A DML STATEMENT ADVANCES ITS OFFSET.
-- A plain SELECT does not — you can look at a stream all day and it stays put.
-- But the moment a stream is the source of an INSERT, MERGE, UPDATE or DELETE,
-- and that statement commits, the offset moves and those rows are gone from the
-- stream forever.
--
-- The consequence, which is the whole reason step 3 exists: a stream can only
-- be consumed ONCE per transaction. If two different statements both read the
-- stream, the first one wins and the second sees an empty stream. Two tasks
-- reading the same stream is a silent data-loss bug.
-- =============================================================================

CREATE OR REPLACE STREAM BRONZE.STR_RAW_BROKERS
    ON TABLE BRONZE.RAW_BROKERS  APPEND_ONLY = TRUE;

CREATE OR REPLACE STREAM BRONZE.STR_RAW_POLICIES
    ON TABLE BRONZE.RAW_POLICIES APPEND_ONLY = TRUE;

CREATE OR REPLACE STREAM BRONZE.STR_RAW_CLAIMS
    ON TABLE BRONZE.RAW_CLAIMS   APPEND_ONLY = TRUE;


-- All three should be empty. A stream created now has its offset set to NOW,
-- so the 22,161 rows already in Bronze are behind it — a stream shows you what
-- arrived AFTER it was created, not the history.
SELECT 'STR_RAW_BROKERS'  AS stream_name,
       SYSTEM$STREAM_HAS_DATA('INSURANCE_DEMO.BRONZE.STR_RAW_BROKERS')  AS has_data
UNION ALL SELECT 'STR_RAW_POLICIES',
       SYSTEM$STREAM_HAS_DATA('INSURANCE_DEMO.BRONZE.STR_RAW_POLICIES')
UNION ALL SELECT 'STR_RAW_CLAIMS',
       SYSTEM$STREAM_HAS_DATA('INSURANCE_DEMO.BRONZE.STR_RAW_CLAIMS');


-- =============================================================================
-- 2. The batch table
--
-- This exists purely because of the offset rule above.
--
-- The claims path needs the incoming rows THREE times: once to quarantine the
-- bad ones, once to load the good ones into Silver, once to push to Gold. If
-- each of those read the stream directly, only the first would see any rows.
--
-- So the first task drains the stream into this table, exactly once, and
-- everything downstream reads the table. The stream is consumed once; the batch
-- is read as often as needed.
--
-- TRANSIENT because it holds nothing that cannot be rebuilt — transient tables
-- skip Fail-safe, which is 7 days of storage you would otherwise pay for on
-- data with no long-term value.
-- =============================================================================

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


-- =============================================================================
-- 3. TASK 1 (root) — drain the stream into the batch table
--
-- A Snowflake task runs exactly ONE SQL statement. That constraint shapes the
-- whole design: anything needing several statements becomes several tasks, or a
-- stored procedure.
--
-- INSERT OVERWRITE truncates and refills in a single statement, which is what
-- lets "clear last batch, load this batch" be one task instead of two.
--
-- WHEN SYSTEM$STREAM_HAS_DATA(...) is the cost control. When it is false the
-- task is marked SKIPPED and NO WAREHOUSE STARTS. That check is metadata only —
-- it is free. A pipeline polling every 5 minutes on an idle stream costs
-- nothing, which is the honest answer to "isn't running this every 5 minutes
-- expensive?"
--
-- Gating at the ROOT means the entire tree below skips too. One cheap check
-- protects five tasks.
-- =============================================================================

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


-- =============================================================================
-- 4. TASK 2 — quarantine the unusable rows from the batch
--
-- AFTER makes this a child. Children run only when the parent succeeds, and the
-- dependency graph is a DAG — this is Snowflake's built-in orchestration, and
-- the reason a simple pipeline does not need Airflow.
--
-- Same rule as Stage 2: amount <= 0 cannot go forward.
-- =============================================================================

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


-- =============================================================================
-- 5. TASK 3 — MERGE the good rows into Silver
--
-- MERGE, not INSERT. This is what makes the task idempotent: run it twice on the
-- same batch and the second run updates rows to the values they already hold.
-- Nothing duplicates.
--
-- In Stage 1 idempotence came free, because COPY INTO tracks loaded files. Here
-- there is no such protection — you have to build it, and MERGE on the natural
-- key is how. Being able to explain BOTH mechanisms is a strong answer to
-- "how do you make your pipeline safe to rerun?"
--
-- Dedupe inside the batch as well: a single batch can contain the same claim_id
-- twice, and MERGE errors out if two source rows target the same target row.
-- =============================================================================

CREATE OR REPLACE TASK OPS.T_CLAIMS_03_SILVER
    WAREHOUSE = WH_MEDALLION
    AFTER OPS.T_CLAIMS_01_DRAIN_STREAM
AS
MERGE INTO SILVER.CLAIMS AS tgt
-- Nested subquery rather than a CTE: a WITH clause leading the USING subquery
-- is not reliably accepted inside MERGE. Same logic, safer syntax.
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


-- =============================================================================
-- 6. TASK 4 — MERGE into Gold
--
-- AFTER the Silver task, because Gold reads what Silver just wrote. That
-- ordering is the entire point of a task tree.
--
-- Same version-aware policy lookup as Stage 3: match on natural key AND
-- claim_date inside [valid_from, valid_to). Half-open, never BETWEEN.
-- =============================================================================

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


-- =============================================================================
-- 7. Start the tree
--
-- >>> ORDER MATTERS AND IT IS COUNTERINTUITIVE <<<
--
-- Tasks are created SUSPENDED. You must RESUME CHILDREN FIRST, ROOT LAST.
--
-- Resume the root first and it can fire before its children are live, so the
-- run does the first step and silently stops. The tree "works" and moves no
-- data. It is a favourite interview question because it catches people who have
-- only read about tasks.
--
-- The mirror image applies to changes: to alter any task in a tree, SUSPEND THE
-- ROOT first. Snowflake will not let you modify a task whose tree is running.
-- =============================================================================

ALTER TASK OPS.T_CLAIMS_04_GOLD        RESUME;
ALTER TASK OPS.T_CLAIMS_03_SILVER      RESUME;
ALTER TASK OPS.T_CLAIMS_02_QUARANTINE  RESUME;
ALTER TASK OPS.T_CLAIMS_01_DRAIN_STREAM RESUME;   -- root LAST

SHOW TASKS IN SCHEMA OPS;
-- All four should show state = started.


-- =============================================================================
-- 8.  >>> WORTH RECORDING <<<  Run it with no new data — nothing moves
--
-- Record the counts, fire the pipeline, record them again. Identical.
--
-- EXECUTE TASK triggers the root immediately instead of waiting for the 5-minute
-- schedule, which is what makes this demoable on camera.
--
-- Expect state = SKIPPED on the root and no child runs. If your account shows
-- SUCCEEDED instead, the WHEN clause was not applied to the manual trigger —
-- the counts are still unchanged, because INSERT OVERWRITE from an empty stream
-- writes zero rows and every downstream MERGE then has an empty source. Either
-- outcome proves the point; SKIPPED proves it more cheaply, because a skipped
-- task never starts a warehouse at all.
-- =============================================================================

-- Counts before. Expect 11,887 / 11,887 / 113.
SELECT (SELECT COUNT(*) FROM SILVER.CLAIMS)     AS silver_claims,
       (SELECT COUNT(*) FROM GOLD.FACT_CLAIM)   AS gold_facts,
       (SELECT COUNT(*) FROM OPS.QUARANTINE)    AS quarantined;

EXECUTE TASK OPS.T_CLAIMS_01_DRAIN_STREAM;

-- Wait ~10 seconds, then look at what happened.
-- Expect state = SKIPPED on the root, and no child runs at all.
SELECT name, state, scheduled_time, completed_time, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
))
ORDER BY scheduled_time DESC;

-- Counts after. IDENTICAL to before.
SELECT (SELECT COUNT(*) FROM SILVER.CLAIMS)     AS silver_claims,
       (SELECT COUNT(*) FROM GOLD.FACT_CLAIM)   AS gold_facts,
       (SELECT COUNT(*) FROM OPS.QUARANTINE)    AS quarantined;

-- THAT is idempotence, and it is worth saying precisely: the pipeline did not
-- "run and change nothing". It did not run at all. No warehouse started, no
-- credit burned. The difference between those two sentences is the difference
-- between someone who has read about tasks and someone who has run them.


-- =============================================================================
-- 9.  >>> WORTH RECORDING <<<  Now feed it three rows
--
-- Two of these are good, one has a negative amount and must be quarantined.
-- Watch three rows land in Bronze and exactly two arrive in Gold, having been
-- typed, conformed, key-resolved and joined to the right policy version — with
-- no full rebuild anywhere.
-- =============================================================================

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

-- The stream can see them now. Expect TRUE.
SELECT SYSTEM$STREAM_HAS_DATA('INSURANCE_DEMO.BRONZE.STR_RAW_CLAIMS') AS has_data;

-- Look at the stream WITHOUT consuming it — a plain SELECT does not move the
-- offset. Expect the 3 rows, each with METADATA$ACTION = 'INSERT'.
SELECT claim_id, amount, METADATA$ACTION, METADATA$ISUPDATE
FROM BRONZE.STR_RAW_CLAIMS;

EXECUTE TASK OPS.T_CLAIMS_01_DRAIN_STREAM;

-- Wait ~20 seconds for the tree to finish, then check history.
-- Expect SUCCEEDED on all four tasks this time.
SELECT name, state, scheduled_time, completed_time, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
))
ORDER BY scheduled_time DESC;

-- Expect 11,889 / 11,889 / 114 — two good rows through, one quarantined.
SELECT (SELECT COUNT(*) FROM SILVER.CLAIMS)     AS silver_claims,
       (SELECT COUNT(*) FROM GOLD.FACT_CLAIM)   AS gold_facts,
       (SELECT COUNT(*) FROM OPS.QUARANTINE)    AS quarantined;

-- The two new facts, fully resolved. policy_key and broker_key are real
-- surrogate keys, not -1 — the incremental path did the same dimensional
-- lookup the full rebuild did.
SELECT claim_key, claim_id, policy_key, broker_key, claim_date_key, amount, status
FROM GOLD.FACT_CLAIM
WHERE claim_id LIKE 'CLM9999%'
ORDER BY claim_id;

-- The rejected one, with its reason.
SELECT natural_key, reject_reason, raw_record
FROM OPS.QUARANTINE
WHERE natural_key = 'CLM9999003';

-- And the stream is empty again — those rows were consumed. Expect FALSE.
SELECT SYSTEM$STREAM_HAS_DATA('INSURANCE_DEMO.BRONZE.STR_RAW_CLAIMS') AS has_data;


-- =============================================================================
-- 10.  IMPORTANT — suspend the tree when you are done
--
-- These tasks poll every 5 minutes forever. Skipped runs cost nothing, but an
-- unattended task tree on a trial account is a bad habit to build. Suspend the
-- ROOT and the whole tree stops.
--
-- Leave them running only while you are actively demoing.
-- =============================================================================

ALTER TASK OPS.T_CLAIMS_01_DRAIN_STREAM SUSPEND;
SHOW TASKS IN SCHEMA OPS;


-- =============================================================================
-- 11. Streams and Tasks, or dbt on a schedule?
--
-- You will be asked this, and having lived both is the point of next week.
--
--   Streams + Tasks - native, low-latency, no extra infrastructure, no extra
--     bill. Best when the transformation is SQL, lives inside Snowflake, and
--     needs to react to arriving data within minutes. Weak on testing,
--     documentation and lineage — a task tree is a DAG you cannot easily see.
--
--   dbt on a schedule - version-controlled models, built-in tests, generated
--     documentation, a visible lineage graph, and the same code runnable across
--     environments. Weak on latency: it runs when the scheduler says so, not
--     when data lands.
--
--   In practice large teams run both — dbt for modelled transformations,
--     streams and tasks for the low-latency ingestion edge.
--
-- The honest one-liner: "Streams and Tasks when latency matters and the logic
-- is SQL that lives in Snowflake; dbt when the transformations need to be
-- tested, documented and reviewed like code."
-- =============================================================================
