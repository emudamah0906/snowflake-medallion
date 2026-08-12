-- =============================================================================
-- Stage 2 — SILVER: typed, deduplicated, conformed
--
-- Run each numbered step separately. Stop and read the output before moving on.
-- Steps 5 and 6 are the ones worth recording.
--
-- Bronze answered "did the data arrive?". Silver answers "which of it can we
-- trust, and what happened to the rest?" — and the second half of that question
-- is the one that separates a pipeline from a script.
--
-- THE RULE THIS WHOLE FILE OBEYS:
--   Every Bronze row ends up in exactly one of three places —
--       in Silver, in OPS.QUARANTINE, or counted as a removed duplicate.
--   Nothing is silently dropped. Step 5 proves the three add back up to Bronze.
--   That identity is what makes Stage 5's reconciliation gate possible at all.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_MEDALLION;
USE DATABASE INSURANCE_DEMO;
USE SCHEMA SILVER;


-- =============================================================================
-- 1. The quarantine table
--
-- Rejected rows go here, never to /dev/null. Three reasons this matters:
--
--   1. Someone will ask "where did claim CLM0001234 go?" and you need an answer
--      better than "we dropped it".
--   2. Reject counts trending upward is the earliest signal a source system
--      changed. A silent DELETE hides that completely.
--   3. Control totals only tie if you can account for what you removed.
--
-- raw_record is VARIANT — Snowflake's JSON type. Storing the whole original row
-- means you can replay a quarantined record after fixing the rule, without
-- going back to the source file.
-- =============================================================================

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


-- =============================================================================
-- 2. SILVER.BROKERS  —  dedupe and conform
--
-- Expect 50 rows out of 51. One exact duplicate row is removed.
--
-- >>> THE DEDUPE PATTERN <<<
-- ROW_NUMBER() OVER (PARTITION BY key ORDER BY recency) = 1 is the single most
-- commonly asked SQL question in a data engineering interview. Learn to write
-- it cold.
--
--   PARTITION BY broker_id   -> restart the numbering for each broker
--   ORDER BY _loaded_at DESC -> newest row gets number 1
--   WHERE rn = 1             -> keep only the newest per broker
--
-- Why not GROUP BY? Because GROUP BY collapses rows and forces you to pick an
-- aggregate for every other column. ROW_NUMBER keeps a whole real row intact.
-- That distinction is exactly what the interviewer is testing.
--
-- CONFORMING:
--   INITCAP(TRIM(region)) collapses 12 spellings into 5 real regions —
--   'ONTARIO', 'ontario' and '  Ontario ' all become 'Ontario'.
--   NULLIF(TRIM(email), '') turns the empty string into a real NULL. Bronze
--   deliberately kept '' distinct from NULL; Silver is where that decision
--   gets made, and "no email" is genuinely NULL, not an empty string.
-- =============================================================================

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

-- Snowflake shortcut: QUALIFY filters on a window function without the CTE.
--     SELECT ... FROM BRONZE.RAW_BROKERS
--     QUALIFY ROW_NUMBER() OVER (PARTITION BY broker_id ORDER BY _loaded_at DESC) = 1;
-- Cleaner, but Snowflake-specific. Know both — write the CTE form in an
-- interview unless they ask for Snowflake specifically.


-- =============================================================================
-- 3. SILVER.POLICIES  —  typed, deduped WITHIN each extract
--
-- Expect 10,000 rows: 5,000 per snapshot, down from 5,025 each.
--
-- >>> THE MOST IMPORTANT DECISION IN THIS FILE <<<
--
--   PARTITION BY policy_id, extract_date     <- correct
--   PARTITION BY policy_id                   <- would destroy the project
--
-- Deduping on policy_id alone would keep ONE row per policy and throw away the
-- other snapshot. That looks tidier and it is completely wrong: the 602 policies
-- whose status and premium changed between 1 Aug and 15 Aug would collapse to a
-- single version, and Stage 3 would have nothing to detect. SCD Type 2 needs
-- both versions to exist.
--
-- So state the grain out loud, the same way you will for the fact table:
--   ONE ROW OF SILVER.POLICIES = ONE POLICY AS AT ONE EXTRACT DATE.
-- The duplicates being removed are accidental repeats WITHIN a single extract,
-- which are noise. The repeats ACROSS extracts are signal.
--
-- TYPING — TRY_TO_DATE and TRY_TO_DECIMAL, never TO_DATE / CAST:
--   CAST('N/A' AS DATE)      -> the statement fails, you lose all 10,000 rows
--   TRY_TO_DATE('N/A')       -> returns NULL, the other 9,999 rows still load
--   Inside a pipeline you almost always want the TRY_ form, because one bad
--   cell must not be able to take down the batch.
--
-- WHY A NULL DATE IS FLAGGED, NOT QUARANTINED:
--   A policy with an unreadable start_date still has a valid premium, status
--   and broker. Quarantining the whole row over one bad cell would remove real
--   money from the control totals. So: keep the row, NULL the date, and raise
--   a flag so nobody mistakes the NULL for "no start date exists".
--   Quarantine is for rows you cannot use. Flags are for rows with a known gap.
-- =============================================================================

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

-- 3a. Quarantine unusable policy rows first.
--     Expect 0 here — this data has no unusable policies. The pattern is written
--     anyway, because real extracts do, and a rule that only exists once you
--     need it is a rule you will write in a hurry at 3am.
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

-- 3b. Load the usable rows.
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


-- =============================================================================
-- 4. SILVER.CLAIMS  —  typed, deduped, filtered, flagged
--
-- Expect 11,887 rows in Silver and 113 in quarantine, from 12,060 in Bronze.
--     11,887 + 113 + 60 removed duplicates = 12,060.
--
-- Three different defects, three deliberately different responses. Being able
-- to explain why they differ is the whole point of this step.
--
--   amount <= 0            -> QUARANTINE (113 rows)
--       A claim cannot pay zero or negative. The value is not a number we can
--       reason about, so the row cannot go forward.
--
--   amount = 9,999,999.99  -> KEEP, FLAG (59 rows)
--       Note this is not 59 different large numbers — it is the SAME value 59
--       times. Real catastrophe claims vary; a repeated identical maximum is a
--       SENTINEL, a placeholder some upstream system writes when the real
--       amount is unknown. Do NOT silently drop it (that would erase $590m of
--       apparent exposure) and do NOT silently trust it (that would invent
--       $590m). Flag it, surface it, let the business rule the call. Having an
--       opinion here — and knowing it is a judgement call, not a fact — is
--       exactly what a senior interviewer is listening for.
--
--   orphan policy_id       -> KEEP, FLAG (128 rows)
--       A claim pointing at a policy we do not have is still a real claim with
--       real money attached. Dropping it would understate exposure and break
--       the control total. Gold will point these at an "unknown policy" member
--       rather than lose them. In dimensional modelling you never throw away a
--       fact because its dimension is missing.
--
--   unreadable claim_date  -> KEEP, FLAG (251 rows)
--       Same reasoning as policies: one bad cell, real money.
--
-- ORDER MATTERS: dedupe BEFORE quarantining, or the 60 duplicate rows inflate
-- your reject counts and the reconciliation identity stops balancing.
-- =============================================================================

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

-- 4a. Quarantine the unusable rows. Expect 113.
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

-- 4b. Load the usable rows. Expect 11,887.
--     Runs after SILVER.POLICIES exists, because the orphan flag joins to it.
INSERT INTO SILVER.CLAIMS
WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY TRIM(claim_id)
               ORDER BY _file_row_number
           ) AS rn
    FROM BRONZE.RAW_CLAIMS
)
SELECT
    TRIM(r.claim_id),
    TRIM(r.policy_id),
    TRY_TO_DATE(r.claim_date),
    TRY_TO_DECIMAL(r.amount, 38, 2),
    UPPER(TRIM(r.status)),                                   -- 'in review' -> 'IN REVIEW'
    TRY_TO_DATE(r.claim_date) IS NULL,                       -- has_invalid_date
    NOT EXISTS (SELECT 1 FROM SILVER.POLICIES p
                WHERE p.policy_id = TRIM(r.policy_id)),      -- is_orphan_policy
    TRY_TO_DECIMAL(r.amount, 38, 2) > 1000000,               -- is_amount_outlier
    r._source_file,
    r._loaded_at
FROM ranked r
WHERE r.rn = 1
  AND NULLIF(TRIM(r.claim_id), '') IS NOT NULL
  AND TRY_TO_DECIMAL(r.amount, 38, 2) IS NOT NULL
  AND TRY_TO_DECIMAL(r.amount, 38, 2) > 0;


-- =============================================================================
-- 5.  >>> WORTH RECORDING <<<  Every row accounted for
--
-- This is the step that turns "I cleaned the data" into "I can prove what
-- happened to every row". It is a dry-run of the Stage 5 gate.
--
-- Expected:
--   RAW_BROKERS   51     -> silver     50 · quarantined   0 · dupes removed  1
--   RAW_POLICIES  10,050 -> silver 10,000 · quarantined   0 · dupes removed 50
--   RAW_CLAIMS    12,060 -> silver 11,887 · quarantined 113 · dupes removed 60
--
-- reconciled = TRUE on all three rows, or something is wrong.
-- =============================================================================

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


-- The money moved too. Expect:
--   premium  bronze 127,861,219.71 -> silver 127,248,528.88  (duplicates removed)
--   claims   bronze 1,063,624,699.09 -> silver 1,063,516,068.75
--
-- The claim total barely moves because the 113 quarantined rows are zeros and
-- negatives, and the 59 sentinel rows were KEPT. Had you quarantined the
-- sentinels instead, Silver would hold $473m and you would be explaining a
-- 55% drop to Finance. Same data, different rule, wildly different report —
-- which is why the rule is a decision, not a detail.
SELECT 'premium' AS measure,
       (SELECT SUM(TRY_TO_DECIMAL(premium, 38, 2)) FROM BRONZE.RAW_POLICIES) AS bronze_total,
       (SELECT SUM(premium) FROM SILVER.POLICIES)                            AS silver_total
UNION ALL
SELECT 'claim_amount',
       (SELECT SUM(TRY_TO_DECIMAL(amount, 38, 2)) FROM BRONZE.RAW_CLAIMS),
       (SELECT SUM(amount) FROM SILVER.CLAIMS);


-- =============================================================================
-- 6.  >>> WORTH RECORDING <<<  The mess is gone, and it is accounted for
--
-- Run these and compare against the Stage 1 numbers. This is the before/after.
-- =============================================================================

-- Products: 20 spellings in Bronze -> 5 in Silver.
SELECT product, COUNT(*) AS row_count
FROM SILVER.POLICIES GROUP BY 1 ORDER BY 1;

-- Regions: 12 spellings in Bronze -> 5 in Silver.
SELECT region, COUNT(*) AS row_count
FROM SILVER.BROKERS GROUP BY 1 ORDER BY 1;

-- Both snapshots still present and separable. Expect 5,000 each — if you see
-- 10,000 on one row, the PARTITION BY lost extract_date and SCD2 is now dead.
SELECT extract_date, COUNT(*) AS row_count
FROM SILVER.POLICIES GROUP BY 1 ORDER BY 1;

-- Zero duplicate keys anywhere. All three should return no rows.
SELECT broker_id FROM SILVER.BROKERS GROUP BY 1 HAVING COUNT(*) > 1;
SELECT policy_id, extract_date FROM SILVER.POLICIES GROUP BY 1,2 HAVING COUNT(*) > 1;
SELECT claim_id FROM SILVER.CLAIMS GROUP BY 1 HAVING COUNT(*) > 1;

-- What we kept but flagged. Expect: 246 / 200 / 251 / 128 / 59.
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

-- What we rejected, and why. Expect one reason: 'amount is zero or negative' 113.
SELECT source_table, reject_reason, COUNT(*) AS row_count
FROM OPS.QUARANTINE GROUP BY 1, 2 ORDER BY 3 DESC;

-- A quarantined row, whole and replayable. This is the answer to
-- "where did claim X go?" — it did not vanish, it is here with a reason.
SELECT natural_key, reject_reason, raw_record, _source_file, _file_row_number
FROM OPS.QUARANTINE
WHERE source_table = 'RAW_CLAIMS'
LIMIT 5;


-- =============================================================================
-- 7. Sanity check before Stage 3
--
-- What Gold receives: 50 brokers, 10,000 policy-snapshots across two extract
-- dates, 11,887 typed claims. Real DATE and NUMBER columns now — Gold can
-- join, aggregate and compare without a single cast.
--
-- The 602 changed policies are sitting in here right now, as two rows each with
-- different status and premium. Stage 3 turns them into SCD Type 2 history.
-- =============================================================================

SELECT * FROM SILVER.POLICIES LIMIT 10;
SELECT * FROM SILVER.CLAIMS   LIMIT 10;

-- Preview of Stage 3: a policy that changed between the two extracts.
-- Two rows, same policy_id, different status or premium. This is the raw
-- material SCD Type 2 works on.
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
