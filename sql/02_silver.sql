-- ============================================================================
-- Stage 2 — SILVER: typed, deduplicated, conformed
-- Run one statement at a time. Steps 5 and 6 are the ones to record.
--
-- Bronze answered "did the data arrive?"
-- Silver answers "which of it can we trust, and what happened to the rest?"
--
-- THE RULE: every Bronze row ends up in exactly one of three places —
-- Silver, quarantine, or counted as a removed duplicate. Nothing vanishes.
-- Step 5 proves the three add back up.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_MEDALLION;
USE DATABASE INSURANCE_DEMO;
USE SCHEMA SILVER;


-- ============================================================================
-- 1. The quarantine table
--
-- Rejected rows come here. They don't get deleted.
--   - "Where did claim X go?" needs a better answer than "we dropped it".
--   - Reject counts climbing = earliest signal a source system changed.
--   - Control totals only tie if you can account for what you removed.
--
-- raw_record is VARIANT (JSON) — the whole original row, so it's replayable
-- after you fix the rule.
-- ============================================================================

CREATE OR REPLACE TABLE OPS.QUARANTINE (
    quarantine_id     NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    source_table      VARCHAR,
    natural_key       VARCHAR,
    reject_reason     VARCHAR,
    raw_record        VARIANT,
    _source_file      VARCHAR,
    _file_row_number  NUMBER,
    quarantined_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);


-- ============================================================================
-- 2. SILVER.BROKERS                              Expect 50 rows (from 51)
--
-- THE DEDUPE PATTERN — the most asked SQL question in a DE interview:
--   PARTITION BY broker_id    restart numbering per broker
--   ORDER BY loaded_at DESC   newest row gets number 1
--   WHERE rn = 1              keep only the newest
--
-- Why not GROUP BY? It collapses rows and forces an aggregate on every other
-- column. ROW_NUMBER keeps one whole real row.
--
-- Conforming: INITCAP(TRIM(region)) turns 12 spellings into 5 regions.
-- NULLIF(TRIM(email),'') makes "no email" a real NULL.
-- ============================================================================

CREATE OR REPLACE TABLE SILVER.BROKERS (
    broker_id     VARCHAR,
    broker_name   VARCHAR,
    region        VARCHAR,
    email         VARCHAR,
    _source_file  VARCHAR,
    _loaded_at    TIMESTAMP_NTZ
);

INSERT INTO SILVER.BROKERS
WITH ranked AS (
    SELECT
        TRIM(broker_id)            AS broker_id,
        TRIM(broker_name)          AS broker_name,
        INITCAP(TRIM(region))      AS region,
        NULLIF(TRIM(email), '')    AS email,
        _source_file,
        _loaded_at,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(broker_id)
            ORDER BY _loaded_at DESC, _file_row_number DESC
        ) AS rn
    FROM BRONZE.RAW_BROKERS
)
SELECT broker_id, broker_name, region, email, _source_file, _loaded_at
FROM ranked
WHERE rn = 1;

-- Snowflake shortcut: QUALIFY does this without the CTE.
--   QUALIFY ROW_NUMBER() OVER (PARTITION BY broker_id ORDER BY _loaded_at DESC) = 1
-- Cleaner, but Snowflake-only. Write the CTE form in an interview.


-- ============================================================================
-- 3. SILVER.POLICIES                    Expect 10,000 (5,000 per snapshot)
--
-- >>> THE MOST IMPORTANT LINE IN THIS FILE <<<
--   PARTITION BY policy_id, extract_date   correct
--   PARTITION BY policy_id                 destroys the project
--
-- Deduping on policy_id alone keeps one row per policy and throws the other
-- snapshot away. The 602 policies that changed would collapse to one version
-- and Stage 3 would have nothing to detect.
--
-- Repeats INSIDE one extract are noise. Repeats ACROSS extracts are signal.
--
-- GRAIN: one row = one policy as at one extract date.
--
-- TRY_TO_DATE not CAST: CAST('N/A') fails the whole statement. TRY_ returns
-- NULL and the other 9,999 rows still load.
--
-- Bad date → flag it, don't quarantine it. The row still has a valid premium,
-- and removing it would take real money out of the control totals.
-- Quarantine = unusable row. Flag = usable row with a known gap.
-- ============================================================================

CREATE OR REPLACE TABLE SILVER.POLICIES (
    policy_id               VARCHAR,
    broker_id               VARCHAR,
    product                 VARCHAR,
    start_date              DATE,
    end_date                DATE,
    premium                 NUMBER(38,2),
    status                  VARCHAR,
    extract_date            DATE,
    has_invalid_start_date  BOOLEAN,
    has_invalid_end_date    BOOLEAN,
    _source_file            VARCHAR,
    _loaded_at              TIMESTAMP_NTZ
);

-- 3a. Quarantine unusable policies.   Expect 0.
--     The pattern is here anyway — real extracts do have them, and a rule you
--     only write when you need it is a rule you write in a hurry at 3am.
INSERT INTO OPS.QUARANTINE
    (source_table, natural_key, reject_reason, raw_record, _source_file, _file_row_number)
WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY TRIM(policy_id), TRIM(extract_date)
               ORDER BY _file_row_number
           ) AS rn
    FROM BRONZE.RAW_POLICIES
)
SELECT
    'RAW_POLICIES',
    TRIM(policy_id),
    CASE
        WHEN NULLIF(TRIM(policy_id), '') IS NULL       THEN 'policy_id is null or blank'
        WHEN TRY_TO_DECIMAL(premium, 38, 2) IS NULL    THEN 'premium is not numeric'
        WHEN TRY_TO_DATE(extract_date) IS NULL         THEN 'extract_date is not a valid date'
    END,
    OBJECT_CONSTRUCT(
        'policy_id', policy_id, 'broker_id', broker_id, 'product', product,
        'start_date', start_date, 'end_date', end_date, 'premium', premium,
        'status', status, 'extract_date', extract_date
    ),
    _source_file,
    _file_row_number
FROM ranked
WHERE rn = 1
  AND (NULLIF(TRIM(policy_id), '') IS NULL
       OR TRY_TO_DECIMAL(premium, 38, 2) IS NULL
       OR TRY_TO_DATE(extract_date) IS NULL);

-- 3b. Load the usable rows.   Expect 10,000.
INSERT INTO SILVER.POLICIES
WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY TRIM(policy_id), TRIM(extract_date)
               ORDER BY _file_row_number
           ) AS rn
    FROM BRONZE.RAW_POLICIES
)
SELECT
    TRIM(policy_id),
    TRIM(broker_id),
    INITCAP(TRIM(product)),               -- 20 spellings collapse to 5 products
    TRY_TO_DATE(start_date),              -- unreadable -> NULL, row survives
    TRY_TO_DATE(end_date),
    TRY_TO_DECIMAL(premium, 38, 2),       -- scale 2 stated: money must not round
    UPPER(TRIM(status)),
    TRY_TO_DATE(extract_date),
    TRY_TO_DATE(start_date) IS NULL,      -- has_invalid_start_date
    TRY_TO_DATE(end_date)   IS NULL,      -- has_invalid_end_date
    _source_file,
    _loaded_at
FROM ranked
WHERE rn = 1
  AND NULLIF(TRIM(policy_id), '') IS NOT NULL
  AND TRY_TO_DECIMAL(premium, 38, 2) IS NOT NULL
  AND TRY_TO_DATE(extract_date) IS NOT NULL;


-- ============================================================================
-- 4. SILVER.CLAIMS         Expect 11,887 in Silver, 113 quarantined
--                          11,887 + 113 + 60 duplicates = 12,060
--
-- Three defects, three deliberately different answers:
--
--   amount <= 0  ->  QUARANTINE (113)
--       A claim can't pay zero. The row can't go forward.
--
--   amount = 9,999,999.99  ->  KEEP + FLAG (59)
--       Not 59 different big numbers — the SAME number 59 times.
--       Real catastrophe claims vary. An identical repeated maximum is a
--       SENTINEL: a placeholder written when the real amount is unknown.
--       Drop it and you erase $590m. Trust it and you invent $590m.
--       Flag it, surface it, let the business decide. That's a judgement call.
--
--   orphan policy_id  ->  KEEP + FLAG (128)
--       Still a real claim with real money. Gold points these at an "unknown
--       policy" member. You never throw away a fact because its dimension is
--       missing.
--
--   bad claim_date  ->  KEEP + FLAG (251)
--
-- ORDER MATTERS: dedupe BEFORE quarantining, or the 60 duplicates inflate the
-- reject counts and the reconciliation stops balancing.
-- ============================================================================

CREATE OR REPLACE TABLE SILVER.CLAIMS (
    claim_id           VARCHAR,
    policy_id          VARCHAR,
    claim_date         DATE,
    amount             NUMBER(38,2),
    status             VARCHAR,
    has_invalid_date   BOOLEAN,
    is_orphan_policy   BOOLEAN,
    is_amount_outlier  BOOLEAN,
    _source_file       VARCHAR,
    _loaded_at         TIMESTAMP_NTZ
);

-- 4a. Quarantine the unusable rows.   Expect 113.
INSERT INTO OPS.QUARANTINE
    (source_table, natural_key, reject_reason, raw_record, _source_file, _file_row_number)
WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY TRIM(claim_id)
               ORDER BY _file_row_number
           ) AS rn
    FROM BRONZE.RAW_CLAIMS
)
SELECT
    'RAW_CLAIMS',
    TRIM(claim_id),
    CASE
        WHEN NULLIF(TRIM(claim_id), '') IS NULL      THEN 'claim_id is null or blank'
        WHEN TRY_TO_DECIMAL(amount, 38, 2) IS NULL   THEN 'amount is not numeric'
        WHEN TRY_TO_DECIMAL(amount, 38, 2) <= 0      THEN 'amount is zero or negative'
    END,
    OBJECT_CONSTRUCT(
        'claim_id', claim_id, 'policy_id', policy_id, 'claim_date', claim_date,
        'amount', amount, 'status', status
    ),
    _source_file,
    _file_row_number
FROM ranked
WHERE rn = 1
  AND (NULLIF(TRIM(claim_id), '') IS NULL
       OR TRY_TO_DECIMAL(amount, 38, 2) IS NULL
       OR TRY_TO_DECIMAL(amount, 38, 2) <= 0);

-- 4b. Load the usable rows.   Expect 11,887.
--     Runs after SILVER.POLICIES — the orphan flag joins to it.
--
-- The orphan flag is a LEFT JOIN, not a correlated NOT EXISTS in the SELECT
-- list. Snowflake can't evaluate that: "Unsupported subquery type".
--
-- >>> WHY policy_keys IS `SELECT DISTINCT` <<<
-- SILVER.POLICIES has TWO rows per policy_id, one per extract date. Joining
-- straight to it matches every claim twice and silently DOUBLES the table.
-- That's join fan-out — the query succeeds, the count looks plausible, and
-- every sum is exactly 2x. Always know the grain of what you join to.
INSERT INTO SILVER.CLAIMS
WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY TRIM(claim_id)
               ORDER BY _file_row_number
           ) AS rn
    FROM BRONZE.RAW_CLAIMS
),
deduped AS (
    SELECT *
    FROM ranked
    WHERE rn = 1
      AND NULLIF(TRIM(claim_id), '') IS NOT NULL
      AND TRY_TO_DECIMAL(amount, 38, 2) IS NOT NULL
      AND TRY_TO_DECIMAL(amount, 38, 2) > 0
),
policy_keys AS (
    SELECT DISTINCT policy_id FROM SILVER.POLICIES
)
SELECT
    TRIM(d.claim_id),
    TRIM(d.policy_id),
    TRY_TO_DATE(d.claim_date),
    TRY_TO_DECIMAL(d.amount, 38, 2),
    UPPER(TRIM(d.status)),                                   -- 'in review' -> 'IN REVIEW'
    TRY_TO_DATE(d.claim_date) IS NULL,                       -- has_invalid_date
    p.policy_id IS NULL,                                     -- is_orphan_policy
    TRY_TO_DECIMAL(d.amount, 38, 2) > 1000000,               -- is_amount_outlier
    d._source_file,
    d._loaded_at
FROM deduped d
LEFT JOIN policy_keys p
       ON p.policy_id = TRIM(d.policy_id);


-- ============================================================================
-- 5.  >>> RECORD THIS <<<   Every row accounted for
--
-- Expect:
--   RAW_BROKERS   51     -> silver     50 · quarantined   0 · dupes  1
--   RAW_POLICIES  10,050 -> silver 10,000 · quarantined   0 · dupes 50
--   RAW_CLAIMS    12,060 -> silver 11,887 · quarantined 113 · dupes 60
--
-- reconciled = TRUE on all three, or something is wrong.
--
-- Anyone can write SELECT DISTINCT and call it cleaning. This says where every
-- single row went. It's a dry run of the Stage 5 gate.
-- ============================================================================

SELECT
    source_table,
    bronze_rows,
    silver_rows,
    quarantined,
    bronze_rows - silver_rows - quarantined   AS duplicates_removed,
    silver_rows + quarantined
        + (bronze_rows - silver_rows - quarantined) = bronze_rows AS reconciled
FROM (
    SELECT 'RAW_BROKERS' AS source_table,
           (SELECT COUNT(*) FROM BRONZE.RAW_BROKERS)  AS bronze_rows,
           (SELECT COUNT(*) FROM SILVER.BROKERS)      AS silver_rows,
           (SELECT COUNT(*) FROM OPS.QUARANTINE
             WHERE source_table = 'RAW_BROKERS')      AS quarantined
    UNION ALL
    SELECT 'RAW_POLICIES',
           (SELECT COUNT(*) FROM BRONZE.RAW_POLICIES),
           (SELECT COUNT(*) FROM SILVER.POLICIES),
           (SELECT COUNT(*) FROM OPS.QUARANTINE WHERE source_table = 'RAW_POLICIES')
    UNION ALL
    SELECT 'RAW_CLAIMS',
           (SELECT COUNT(*) FROM BRONZE.RAW_CLAIMS),
           (SELECT COUNT(*) FROM SILVER.CLAIMS),
           (SELECT COUNT(*) FROM OPS.QUARANTINE WHERE source_table = 'RAW_CLAIMS')
);


-- The money.   Expect premium 127,248,528.88 · claims 1,063,516,068.75
--
-- The claim total barely moves — the 113 quarantined rows are zeros and
-- negatives, and the 59 sentinels were KEPT. Quarantine the sentinels instead
-- and Silver holds $473m: a 55% drop to explain to Finance. Same data,
-- different rule. That's why the rule is a decision, not a detail.
SELECT 'premium' AS measure,
       (SELECT SUM(TRY_TO_DECIMAL(premium, 38, 2)) FROM BRONZE.RAW_POLICIES) AS bronze_total,
       (SELECT SUM(premium) FROM SILVER.POLICIES)                            AS silver_total
UNION ALL
SELECT 'claim_amount',
       (SELECT SUM(TRY_TO_DECIMAL(amount, 38, 2)) FROM BRONZE.RAW_CLAIMS),
       (SELECT SUM(amount) FROM SILVER.CLAIMS);


-- ============================================================================
-- 6.  >>> RECORD THIS <<<   The before and after
-- ============================================================================

-- Products: 20 spellings -> 5.
SELECT product, COUNT(*) AS row_count
FROM SILVER.POLICIES GROUP BY 1 ORDER BY 1;

-- Regions: 12 spellings -> 5.
SELECT region, COUNT(*) AS row_count
FROM SILVER.BROKERS GROUP BY 1 ORDER BY 1;

-- Both snapshots still separable.   Expect 5,000 each.
-- One row of 10,000 would mean the PARTITION BY lost extract_date — SCD2 dead.
SELECT extract_date, COUNT(*) AS row_count
FROM SILVER.POLICIES GROUP BY 1 ORDER BY 1;

-- Zero duplicate keys. All three return no rows.
SELECT broker_id FROM SILVER.BROKERS GROUP BY 1 HAVING COUNT(*) > 1;
SELECT policy_id, extract_date FROM SILVER.POLICIES GROUP BY 1,2 HAVING COUNT(*) > 1;
SELECT claim_id FROM SILVER.CLAIMS GROUP BY 1 HAVING COUNT(*) > 1;

-- Kept but flagged.   Expect 246 / 200 / 251 / 128 / 59.
SELECT 'policies: invalid start_date' AS flag, COUNT(*) AS row_count
    FROM SILVER.POLICIES WHERE has_invalid_start_date
UNION ALL SELECT 'policies: invalid end_date',
    COUNT(*) FROM SILVER.POLICIES WHERE has_invalid_end_date
UNION ALL SELECT 'claims: invalid claim_date',
    COUNT(*) FROM SILVER.CLAIMS WHERE has_invalid_date
UNION ALL SELECT 'claims: orphan policy_id',
    COUNT(*) FROM SILVER.CLAIMS WHERE is_orphan_policy
UNION ALL SELECT 'claims: amount outlier',
    COUNT(*) FROM SILVER.CLAIMS WHERE is_amount_outlier;

-- What we rejected and why.   Expect 'amount is zero or negative' 113.
SELECT source_table, reject_reason, COUNT(*) AS row_count
FROM OPS.QUARANTINE GROUP BY 1, 2 ORDER BY 3 DESC;

-- A quarantined row, whole and replayable.
-- This is the answer to "where did claim X go?"
SELECT natural_key, reject_reason, raw_record, _source_file, _file_row_number
FROM OPS.QUARANTINE
WHERE source_table = 'RAW_CLAIMS'
LIMIT 5;


-- ============================================================================
-- 7. What Gold receives
--
-- 50 brokers · 10,000 policy-snapshots · 11,887 claims.
-- Real DATE and NUMBER columns — Gold can join and aggregate without a cast.
--
-- The 602 changed policies are sitting in here as two rows each.
-- Stage 3 turns them into history.
-- ============================================================================

SELECT * FROM SILVER.POLICIES LIMIT 10;
SELECT * FROM SILVER.CLAIMS   LIMIT 10;

-- Preview of Stage 3: same policy_id, two rows, different status or premium.
-- This is the raw material SCD Type 2 works on.
SELECT policy_id, extract_date, status, premium
FROM SILVER.POLICIES
WHERE policy_id IN (
    SELECT policy_id
    FROM SILVER.POLICIES
    GROUP BY policy_id
    HAVING COUNT(DISTINCT status) > 1 OR COUNT(DISTINCT premium) > 1
)
ORDER BY policy_id, extract_date
LIMIT 20;
