-- =============================================================================
-- Stage 1 — BRONZE: raw landing
--
-- Run each numbered step separately. Stop and read the output before moving on.
-- Steps 5, 6 and 7 are the interesting ones — they're worth recording.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_MEDALLION;
USE DATABASE INSURANCE_DEMO;
USE SCHEMA BRONZE;


-- =============================================================================
-- 1. Create the Bronze tables
--
-- Every column is VARCHAR. That is deliberate, and it is the single idea behind
-- this layer.
--
-- If premium were NUMBER and a row contained "N/A", the load would fail and you
-- would lose the whole file over one bad cell. As VARCHAR, everything lands and
-- Silver decides what is valid. Bronze's job is to get data in the building,
-- not to judge it.
--
-- The three underscore-prefixed columns are load metadata. Without them you
-- cannot answer "where did this row come from and when" six months from now.
-- =============================================================================

CREATE OR REPLACE TABLE RAW_BROKERS (
    broker_id          VARCHAR,
    broker_name        VARCHAR,
    region             VARCHAR,
    email              VARCHAR,
    _source_file       VARCHAR,
    _file_row_number   NUMBER,
    _loaded_at         TIMESTAMP_NTZ
);

CREATE OR REPLACE TABLE RAW_POLICIES (
    policy_id          VARCHAR,
    broker_id          VARCHAR,
    product            VARCHAR,
    start_date         VARCHAR,
    end_date           VARCHAR,
    premium            VARCHAR,
    status             VARCHAR,
    extract_date       VARCHAR,
    _source_file       VARCHAR,
    _file_row_number   NUMBER,
    _loaded_at         TIMESTAMP_NTZ
);

CREATE OR REPLACE TABLE RAW_CLAIMS (
    claim_id           VARCHAR,
    policy_id          VARCHAR,
    claim_date         VARCHAR,
    amount             VARCHAR,
    status             VARCHAR,
    _source_file       VARCHAR,
    _file_row_number   NUMBER,
    _loaded_at         TIMESTAMP_NTZ
);


-- =============================================================================
-- 2. Load brokers
--
-- COPY INTO can read from a SELECT over the stage, which lets you attach
-- METADATA$FILENAME and METADATA$FILE_ROW_NUMBER as you load.
--
-- ON_ERROR = 'CONTINUE' means a bad row is skipped, not fatal. For Bronze that
-- is usually right — but see step 5, where you will see what it actually skips.
-- =============================================================================

COPY INTO RAW_BROKERS (broker_id, broker_name, region, email,
                       _source_file, _file_row_number, _loaded_at)
FROM (
    SELECT $1, $2, $3, $4,
           METADATA$FILENAME,
           METADATA$FILE_ROW_NUMBER,
           CURRENT_TIMESTAMP()
    FROM @STG_RAW/brokers.csv (FILE_FORMAT => FF_CSV)
)
ON_ERROR = 'CONTINUE';


-- =============================================================================
-- 3. Load both policy snapshots into the SAME table
--
-- The pattern matcher picks up both files. They append — Bronze is
-- append-only, so you keep every extract you have ever received.
--
-- This is what makes SCD Type 2 possible later. Two snapshots of the same
-- policy, taken two weeks apart, with different status values. If Bronze
-- overwrote instead of appending, that history would be gone and there would
-- be nothing for SCD2 to detect.
-- =============================================================================

COPY INTO RAW_POLICIES (policy_id, broker_id, product, start_date, end_date,
                        premium, status, extract_date,
                        _source_file, _file_row_number, _loaded_at)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8,
           METADATA$FILENAME,
           METADATA$FILE_ROW_NUMBER,
           CURRENT_TIMESTAMP()
    FROM @STG_RAW (FILE_FORMAT => FF_CSV, PATTERN => '.*policies_snapshot_.*[.]csv[.]gz')
)
ON_ERROR = 'CONTINUE';


-- =============================================================================
-- 4. Load claims
-- =============================================================================

COPY INTO RAW_CLAIMS (claim_id, policy_id, claim_date, amount, status,
                      _source_file, _file_row_number, _loaded_at)
FROM (
    SELECT $1, $2, $3, $4, $5,
           METADATA$FILENAME,
           METADATA$FILE_ROW_NUMBER,
           CURRENT_TIMESTAMP()
    FROM @STG_RAW/claims.csv (FILE_FORMAT => FF_CSV)
)
ON_ERROR = 'CONTINUE';


-- =============================================================================
-- 5.  >>> WORTH RECORDING <<<  Did it all land?
--
-- Expected:  brokers 51,  policies 10,050 (two snapshots),  claims 12,060.
--
-- Compare these against what generate_data.py printed. This is your first
-- reconciliation, done by eye — Stage 5 automates exactly this comparison.
-- =============================================================================

SELECT 'RAW_BROKERS'  AS table_name, COUNT(*) AS rows FROM RAW_BROKERS
UNION ALL
SELECT 'RAW_POLICIES', COUNT(*) FROM RAW_POLICIES
UNION ALL
SELECT 'RAW_CLAIMS',   COUNT(*) FROM RAW_CLAIMS;


-- Both snapshots present, and separable by extract_date?
SELECT _source_file, extract_date, COUNT(*) AS rows
FROM RAW_POLICIES
GROUP BY 1, 2
ORDER BY 1;


-- =============================================================================
-- 6.  >>> WORTH RECORDING <<<  Bronze keeps the mess
--
-- These are the defects planted in the source data. They are all sitting in
-- Bronze exactly as they arrived — nothing has been cleaned, and nothing failed
-- the load. That is the layer working correctly.
--
-- Silver's entire job, at Stage 2, is this list.
-- =============================================================================

-- Malformed dates that would have killed a typed load
SELECT start_date, COUNT(*) AS rows
FROM RAW_POLICIES
WHERE TRY_TO_DATE(start_date) IS NULL
GROUP BY 1
ORDER BY 2 DESC;

-- Inconsistent casing and stray whitespace
SELECT DISTINCT product FROM RAW_POLICIES ORDER BY 1;

-- Duplicate claim rows
SELECT claim_id, COUNT(*) AS copies
FROM RAW_CLAIMS
GROUP BY 1
HAVING COUNT(*) > 1
ORDER BY 2 DESC
LIMIT 10;

-- Amounts that are zero, negative, or absurd
SELECT COUNT(*) AS suspect_amounts
FROM RAW_CLAIMS
WHERE TRY_TO_NUMBER(amount) IS NULL
   OR TRY_TO_NUMBER(amount) <= 0
   OR TRY_TO_NUMBER(amount) > 1000000;

-- Claims pointing at policies that do not exist
SELECT COUNT(*) AS orphan_claims
FROM RAW_CLAIMS c
WHERE NOT EXISTS (SELECT 1 FROM RAW_POLICIES p WHERE p.policy_id = c.policy_id);


-- =============================================================================
-- 7.  >>> WORTH RECORDING <<<  Load idempotence
--
-- Run this COPY INTO again. It will load ZERO rows.
--
-- Snowflake keeps 64 days of load history per table and skips files it has
-- already ingested. Reruns are safe by default, which means a failed pipeline
-- can simply be restarted without double-counting.
--
-- This is the answer to "how do you make your loads idempotent?" — and being
-- able to say Snowflake does it via load metadata, with FORCE = TRUE to
-- override, is a genuinely strong answer.
-- =============================================================================

COPY INTO RAW_CLAIMS (claim_id, policy_id, claim_date, amount, status,
                      _source_file, _file_row_number, _loaded_at)
FROM (
    SELECT $1, $2, $3, $4, $5,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, CURRENT_TIMESTAMP()
    FROM @STG_RAW/claims.csv (FILE_FORMAT => FF_CSV)
)
ON_ERROR = 'CONTINUE';
-- Expect: "Copy executed with 0 files processed."

-- Count is unchanged:
SELECT COUNT(*) AS claims_after_rerun FROM RAW_CLAIMS;


-- =============================================================================
-- 8. The load audit trail
--
-- COPY_HISTORY is where you go when someone asks "did last night's load run,
-- and did anything get rejected?" Know this view exists — it comes up.
-- =============================================================================

SELECT file_name,
       status,
       row_count,
       row_parsed,
       error_count,
       first_error_message,
       last_load_time
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME  => 'INSURANCE_DEMO.BRONZE.RAW_CLAIMS',
    START_TIME  => DATEADD(HOUR, -2, CURRENT_TIMESTAMP())
))
ORDER BY last_load_time DESC;


-- =============================================================================
-- 9. Sanity check before Stage 2
-- =============================================================================

SELECT * FROM RAW_POLICIES LIMIT 10;
SELECT * FROM RAW_CLAIMS   LIMIT 10;
