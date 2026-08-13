-- ============================================================================
-- Stage 1 — BRONZE: raw landing
-- Run one statement at a time. Steps 5, 6, 7 are the ones to record.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_MEDALLION;
USE DATABASE INSURANCE_DEMO;
USE SCHEMA BRONZE;


-- ============================================================================
-- 0. What's actually in the stage?
--
-- Run this first. Expect 4 files ending .csv.gz.
-- Plain .csv means the PATTERN in step 3 matches nothing and policies land 0.
-- ============================================================================

LIST @STG_RAW;


-- ============================================================================
-- 1. Bronze tables — every column VARCHAR
--
-- If premium were NUMBER, one row saying "N/A" fails the whole file.
-- As text, everything lands. Silver decides what's valid.
-- Bronze gets data in the building. It doesn't judge it.
--
-- The three _ columns are load metadata: which file, which line, what time.
-- That's how you trace a bad number back to its source six months later.
-- ============================================================================

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


-- ============================================================================
-- 2. Load brokers                                          Expect 51 rows
--
-- COPY INTO reading from a SELECT — that's what lets me attach the filename
-- and row number as it loads.
--
-- ON_ERROR = CONTINUE: a bad row is skipped, not fatal.
-- Watch rows_parsed vs rows_loaded. A gap is what got silently skipped.
-- ============================================================================

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


-- ============================================================================
-- 3. Load BOTH policy snapshots into ONE table       Expect 2 files, 5,025 each
--
-- Two dated extracts of the same policies, two weeks apart. They append.
-- Bronze is append-only — I keep every extract I've ever received.
--
-- This is what makes SCD Type 2 possible at Stage 3. If the second load
-- overwrote the first, there'd be no history to detect.
--
-- PATTERN is anchored to the WHOLE filename. A near-miss matches zero files,
-- not some. That's how policies silently landed 0 rows the first time.
-- ============================================================================

COPY INTO RAW_POLICIES (policy_id, broker_id, product, start_date, end_date,
                        premium, status, extract_date,
                        _source_file, _file_row_number, _loaded_at)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8,
           METADATA$FILENAME,
           METADATA$FILE_ROW_NUMBER,
           CURRENT_TIMESTAMP()
    FROM @STG_RAW (FILE_FORMAT => FF_CSV, PATTERN => '.*policies_snapshot_.*[.]csv([.]gz)?')
)
ON_ERROR = 'CONTINUE';


-- ============================================================================
-- 4. Load claims                                        Expect 12,060 rows
-- ============================================================================

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


-- ============================================================================
-- 5.  >>> RECORD THIS <<<   Did it all land?
--
-- Expect: brokers 51 · policies 10,050 · claims 12,060
--
-- Matches what generate_data.py printed. That's a reconciliation, done by eye.
-- Stage 5 automates exactly this and makes it block the pipeline.
-- ============================================================================

SELECT 'RAW_BROKERS'  AS table_name, COUNT(*) AS row_count FROM RAW_BROKERS
UNION ALL
SELECT 'RAW_POLICIES', COUNT(*) FROM RAW_POLICIES
UNION ALL
SELECT 'RAW_CLAIMS',   COUNT(*) FROM RAW_CLAIMS;


-- Both snapshots present?   Expect 2026-08-01 → 5,025 and 2026-08-15 → 5,025
SELECT _source_file, extract_date, COUNT(*) AS row_count
FROM RAW_POLICIES
GROUP BY 1, 2
ORDER BY 1;


-- The money control totals. Write these down — Stage 5 reconciles against them.
-- Expect  premium 127,861,219.71  ·  claims 1,063,624,699.09
--
-- TRY_TO_DECIMAL(x, 38, 2), not TRY_TO_NUMBER(x). Bare TRY_TO_NUMBER defaults
-- to zero decimal places and silently rounds every value.
SELECT SUM(TRY_TO_DECIMAL(premium, 38, 2)) AS total_premium FROM RAW_POLICIES;
SELECT SUM(TRY_TO_DECIMAL(amount,  38, 2)) AS total_claim_amount FROM RAW_CLAIMS;


-- ============================================================================
-- 6.  >>> RECORD THIS <<<   Bronze kept the mess
--
-- Every defect is sitting there. Nothing was cleaned. Nothing failed the load.
-- That's the layer working correctly.
--
-- These five numbers are Stage 2's entire to-do list.
-- ============================================================================

-- Malformed dates.   Expect 248 across 5 values:
--   '0000-00-00' 60 · 'N/A' 50 · '' 49 · '31/12/2025' 48 · '2026-13-45' 41
--
-- Look at '0000-00-00' and '2026-13-45'. Both LOOK like valid dates — a regex
-- passes them. Only a real calendar parse rejects them. That's why you validate
-- with TRY_TO_DATE, not a pattern match.
SELECT start_date, COUNT(*) AS row_count
FROM RAW_POLICIES
WHERE TRY_TO_DATE(start_date) IS NULL
GROUP BY 1
ORDER BY 2 DESC;

-- Casing and whitespace.   Expect 20 spellings of 5 real products.
SELECT DISTINCT product FROM RAW_POLICIES ORDER BY 1;

-- Duplicate claims.   Expect 60, each appearing twice.
SELECT claim_id, COUNT(*) AS copies
FROM RAW_CLAIMS
GROUP BY 1
HAVING COUNT(*) > 1
ORDER BY 2 DESC
LIMIT 10;

-- Zero, negative or absurd amounts.   Expect 172.
SELECT COUNT(*) AS suspect_amounts
FROM RAW_CLAIMS
WHERE TRY_TO_NUMBER(amount) IS NULL
   OR TRY_TO_NUMBER(amount) <= 0
   OR TRY_TO_NUMBER(amount) > 1000000;

-- Claims pointing at policies that don't exist.   Expect 129.
SELECT COUNT(*) AS orphan_claims
FROM RAW_CLAIMS c
WHERE NOT EXISTS (SELECT 1 FROM RAW_POLICIES p WHERE p.policy_id = c.policy_id);


-- ============================================================================
-- 7.  >>> RECORD THIS <<<   Reruns are safe
--
-- Same COPY INTO, run again. Expect "0 files processed".
--
-- Snowflake keeps 64 days of load history per table and skips files it already
-- ingested. So a pipeline that dies at 3am can just be restarted — nothing
-- double-counts. FORCE = TRUE overrides it.
--
-- "How do you make loads idempotent?" — most people describe building it.
-- Snowflake does it natively.
-- ============================================================================

COPY INTO RAW_CLAIMS (claim_id, policy_id, claim_date, amount, status,
                      _source_file, _file_row_number, _loaded_at)
FROM (
    SELECT $1, $2, $3, $4, $5,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, CURRENT_TIMESTAMP()
    FROM @STG_RAW/claims.csv (FILE_FORMAT => FF_CSV)
)
ON_ERROR = 'CONTINUE';

-- Count unchanged.   Expect 12,060.
SELECT COUNT(*) AS claims_after_rerun FROM RAW_CLAIMS;


-- ============================================================================
-- 8. The load audit trail
--
-- Where you go when someone asks "did last night's load run, and did anything
-- get rejected?"
-- ============================================================================

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


-- ============================================================================
-- 9. Eyeball it before Stage 2
-- ============================================================================

SELECT * FROM RAW_POLICIES LIMIT 10;
SELECT * FROM RAW_CLAIMS   LIMIT 10;
