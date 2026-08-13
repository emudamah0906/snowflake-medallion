-- ============================================================================
-- Stage 3 — GOLD: star schema and SCD Type 2
-- The flagship. Steps 5 and 8 are the money shots.
--
-- THE GRAIN, SAID BEFORE ANY DDL:
--     ONE ROW OF FACT_CLAIM = ONE CLAIM.
--
-- Get it wrong and every number downstream double-counts. No clever SQL fixes
-- that later. So you decide it first, out loud.
--
--         DIM_DATE        DIM_BROKER
--             \               /
--              +-- FACT_CLAIM --+
--                      |
--                  DIM_POLICY  (SCD Type 2)
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_MEDALLION;
USE DATABASE INSURANCE_DEMO;
USE SCHEMA GOLD;


-- ============================================================================
-- 1. Surrogate key sequences
--
-- WHY SURROGATE KEYS — guaranteed interview question.
-- The natural key is policy_id. It can't be the dimension's primary key,
-- because under SCD2 the same policy_id lives on several rows, one per
-- version. You need a key that identifies a VERSION, not a policy.
--
-- Also: small integer in the fact instead of a wide string · source system can
-- renumber without rewriting every fact row · somewhere to put an "unknown"
-- member at key -1.
--
-- Sequences not AUTOINCREMENT, so key -1 can be inserted explicitly.
-- ============================================================================

CREATE OR REPLACE SEQUENCE GOLD.SEQ_BROKER_KEY START = 1 INCREMENT = 1;
CREATE OR REPLACE SEQUENCE GOLD.SEQ_POLICY_KEY START = 1 INCREMENT = 1;
CREATE OR REPLACE SEQUENCE GOLD.SEQ_CLAIM_KEY  START = 1 INCREMENT = 1;


-- ============================================================================
-- 2. DIM_BROKER — Type 1                          Expect 51 (50 + unknown)
--
-- Type 1 = overwrite. A broker moves region, the row updates, history is lost.
-- Right call here — nobody reports on "the region the broker used to be in".
-- Choosing Type 1 vs Type 2 per dimension, instead of applying one everywhere,
-- is the actual skill.
--
-- THE UNKNOWN MEMBER (-1) is standard practice, not a hack. A fact whose
-- dimension row is missing must still join to something, or an INNER JOIN
-- silently drops it and the totals stop tying.
-- ============================================================================

CREATE OR REPLACE TABLE GOLD.DIM_BROKER (
    broker_key    NUMBER       NOT NULL,
    broker_id     VARCHAR,
    broker_name   VARCHAR,
    region        VARCHAR,
    email         VARCHAR,
    _loaded_at    TIMESTAMP_NTZ
);

-- 2a. Unknown member first, so it exists before any fact loads.
INSERT INTO GOLD.DIM_BROKER
    (broker_key, broker_id, broker_name, region, email, _loaded_at)
VALUES
    (-1, 'UNKNOWN', 'Unknown broker', 'Unknown', NULL, CURRENT_TIMESTAMP());

-- 2b. The real brokers.   Expect 50.
INSERT INTO GOLD.DIM_BROKER
    (broker_key, broker_id, broker_name, region, email, _loaded_at)
SELECT
    GOLD.SEQ_BROKER_KEY.NEXTVAL,
    broker_id,
    broker_name,
    region,
    email,
    CURRENT_TIMESTAMP()
FROM SILVER.BROKERS;


-- ============================================================================
-- 3. DIM_DATE — a generated calendar          Expect 1,461 + 1 unknown
--
-- Why a date table when MONTH() exists? Because a date dimension holds what a
-- date function can't know: fiscal calendars, public holidays, which week
-- belongs to which reporting period.
--
-- GENERATOR manufactures rows out of nothing; SEQ4() numbers them 0,1,2...
--
-- Range deliberately overruns the data (claims to 2026-07, policies to
-- 2027-06). A date dimension that stops before your data does makes rows
-- vanish from reports — a common production bug.
-- ============================================================================

CREATE OR REPLACE TABLE GOLD.DIM_DATE (
    date_key        NUMBER,        -- YYYYMMDD, human-readable
    full_date       DATE,
    year            NUMBER,
    quarter         NUMBER,
    month           NUMBER,
    month_name      VARCHAR,
    day_of_month    NUMBER,
    day_of_week     NUMBER,
    day_name        VARCHAR,
    is_weekend      BOOLEAN
);

INSERT INTO GOLD.DIM_DATE
WITH calendar AS (
    SELECT DATEADD(DAY, SEQ4(), DATE '2024-01-01') AS full_date
    FROM TABLE(GENERATOR(ROWCOUNT => 1461))
)
SELECT
    TO_NUMBER(TO_CHAR(full_date, 'YYYYMMDD')),
    full_date,
    YEAR(full_date),
    QUARTER(full_date),
    MONTH(full_date),
    MONTHNAME(full_date),
    DAY(full_date),
    DAYOFWEEK(full_date),
    DAYNAME(full_date),
    DAYOFWEEK(full_date) IN (0, 6)
FROM calendar;

-- Unknown member. Claims with an unreadable date land here instead of falling
-- out of the join.
INSERT INTO GOLD.DIM_DATE
    (date_key, full_date, year, quarter, month, month_name,
     day_of_month, day_of_week, day_name, is_weekend)
VALUES
    (-1, NULL, NULL, NULL, NULL, 'Unknown', NULL, NULL, 'Unknown', NULL);


-- ============================================================================
-- 4. DIM_POLICY — SCD Type 2, initial load     Expect 5,000, all current
--
-- Loads the FIRST extract only. Step 5 merges the second, and that's where
-- Type 2 actually happens.
--
-- THE THREE COLUMNS:
--   valid_from  when this version became true
--   valid_to    when it stopped being true
--   is_current  cheap filter for "today's view"
--
-- >>> WHY valid_from IS 1900-01-01, NOT THE EXTRACT DATE <<<
-- Claims run 2024-06 to 2026-07 — ALL before the first extract on 2026-08-01.
-- If version 1 were only valid from the extract date, every claim would fall
-- outside every version window and every policy_key would be -1.
-- The load succeeds. The fact table fills. It's completely wrong.
--
-- valid_to 9999-12-31 not NULL, so range comparisons never special-case a NULL.
-- ============================================================================

CREATE OR REPLACE TABLE GOLD.DIM_POLICY (
    policy_key    NUMBER       NOT NULL,
    policy_id     VARCHAR,                  -- natural key, repeats across versions
    broker_key    NUMBER,
    product       VARCHAR,
    start_date    DATE,
    end_date      DATE,
    premium       NUMBER(38,2),
    status        VARCHAR,
    valid_from    DATE,
    valid_to      DATE,
    is_current    BOOLEAN,
    _loaded_at    TIMESTAMP_NTZ
);

-- 4a. Unknown member, for claims whose policy we never received.
INSERT INTO GOLD.DIM_POLICY
    (policy_key, policy_id, broker_key, product, start_date, end_date,
     premium, status, valid_from, valid_to, is_current, _loaded_at)
VALUES
    (-1, 'UNKNOWN', -1, 'Unknown', NULL, NULL, NULL, 'UNKNOWN',
     DATE '1900-01-01', DATE '9999-12-31', TRUE, CURRENT_TIMESTAMP());

-- 4b. Initial load from extract 1.   Expect 5,000.
INSERT INTO GOLD.DIM_POLICY
    (policy_key, policy_id, broker_key, product, start_date, end_date,
     premium, status, valid_from, valid_to, is_current, _loaded_at)
SELECT
    GOLD.SEQ_POLICY_KEY.NEXTVAL,
    s.policy_id,
    COALESCE(b.broker_key, -1),        -- unknown broker never drops the row
    s.product,
    s.start_date,
    s.end_date,
    s.premium,
    s.status,
    DATE '1900-01-01',
    DATE '9999-12-31',
    TRUE,
    CURRENT_TIMESTAMP()
FROM SILVER.POLICIES s
LEFT JOIN GOLD.DIM_BROKER b
       ON b.broker_id = s.broker_id
WHERE s.extract_date = DATE '2026-08-01';


-- ============================================================================
-- 5.  >>> THE MONEY SHOT — RECORD THIS <<<   SCD Type 2 in one MERGE
--
-- Before: 5,001 rows.   After: 5,603.
-- Result should read: 602 updated, 602 inserted.
--
-- 602 policies changed. Each got its old version closed and a new version
-- opened, in ONE statement.
--
-- HOW: a MERGE takes only one action per matched row, but a Type 2 change
-- needs two — close the old AND insert the new. So feed the source in twice.
--   pass 1 carries the real join key  -> MATCHES  -> UPDATE closes the row
--   pass 2 carries a NULL join key    -> can never match -> INSERT
--
-- Change detection lives in the USING subquery, which reads DIM_POLICY as it
-- stood BEFORE the merge. Testing inside the WHEN clauses would mean querying
-- the table you're currently writing to.
--
-- WHAT COUNTS AS A CHANGE is a decision: status or premium. Not product, not
-- broker. "We compare every column" is usually wrong — it makes the dimension
-- churn on noise.
--
-- IS DISTINCT FROM handles NULLs. Plain <> returns NULL when either side is
-- NULL, and a NULL predicate isn't TRUE, so real changes get missed silently.
-- ============================================================================

MERGE INTO GOLD.DIM_POLICY AS tgt
USING (
    SELECT
        s.policy_id AS join_key,          -- real key: this pass MATCHES
        s.policy_id, COALESCE(b.broker_key, -1) AS broker_key,
        s.product, s.start_date, s.end_date,
        s.premium, s.status, s.extract_date
    FROM SILVER.POLICIES s
    JOIN GOLD.DIM_POLICY d
      ON d.policy_id  = s.policy_id
     AND d.is_current = TRUE
    LEFT JOIN GOLD.DIM_BROKER b
      ON b.broker_id = s.broker_id
    WHERE s.extract_date = DATE '2026-08-15'
      AND (d.status  IS DISTINCT FROM s.status
           OR d.premium IS DISTINCT FROM s.premium)

    UNION ALL

    -- pass 2: the new version. NULL join key -> always falls to NOT MATCHED.
    SELECT
        NULL AS join_key,
        s.policy_id, COALESCE(b.broker_key, -1),
        s.product, s.start_date, s.end_date,
        s.premium, s.status, s.extract_date
    FROM SILVER.POLICIES s
    JOIN GOLD.DIM_POLICY d
      ON d.policy_id  = s.policy_id
     AND d.is_current = TRUE
    LEFT JOIN GOLD.DIM_BROKER b
      ON b.broker_id = s.broker_id
    WHERE s.extract_date = DATE '2026-08-15'
      AND (d.status  IS DISTINCT FROM s.status
           OR d.premium IS DISTINCT FROM s.premium)

    UNION ALL

    -- pass 3: policies never seen before. Zero rows here, but a Type 2 load
    -- that can't accept a new member is incomplete — first thing a reviewer
    -- looks for.
    SELECT
        NULL AS join_key,
        s.policy_id, COALESCE(b.broker_key, -1),
        s.product, s.start_date, s.end_date,
        s.premium, s.status, s.extract_date
    FROM SILVER.POLICIES s
    LEFT JOIN GOLD.DIM_BROKER b
      ON b.broker_id = s.broker_id
    WHERE s.extract_date = DATE '2026-08-15'
      AND NOT EXISTS (SELECT 1 FROM GOLD.DIM_POLICY d
                      WHERE d.policy_id = s.policy_id)
) AS src
   ON tgt.policy_id  = src.join_key
  AND tgt.is_current = TRUE

-- Matched = a pass-1 row = close the old version.
WHEN MATCHED THEN UPDATE SET
    tgt.valid_to   = src.extract_date,
    tgt.is_current = FALSE

-- Not matched = pass 2 or 3 = insert the new current version.
WHEN NOT MATCHED THEN INSERT
    (policy_key, policy_id, broker_key, product, start_date, end_date,
     premium, status, valid_from, valid_to, is_current, _loaded_at)
VALUES
    (GOLD.SEQ_POLICY_KEY.NEXTVAL,
     src.policy_id,
     src.broker_key,
     src.product, src.start_date, src.end_date, src.premium, src.status,
     src.extract_date, DATE '9999-12-31', TRUE, CURRENT_TIMESTAMP());


-- ============================================================================
-- 6. FACT_CLAIM                    Expect 11,887 · 128 with policy_key -1
--
-- >>> THE POINT OF THE WHOLE STAGE <<<
--     ON  p.policy_id = c.policy_id
--     AND c.claim_date >= p.valid_from
--     AND c.claim_date <  p.valid_to
--
-- Not "what does this policy look like now" but "what did it look like ON THE
-- DAY OF THE CLAIM". That's why the dimension keeps history. Point the fact at
-- is_current instead and you built SCD2 for nothing.
--
-- >= and <, never BETWEEN. BETWEEN is inclusive both ends, so a claim on the
-- changeover date matches two versions and duplicates the row.
--
-- MEASURES: amount is ADDITIVE — sums across every dimension.
-- A month-end policy count would be SEMI-ADDITIVE — sums across product and
-- broker but not across time.
-- ============================================================================

CREATE OR REPLACE TABLE GOLD.FACT_CLAIM (
    claim_key           NUMBER  NOT NULL,
    claim_id            VARCHAR,          -- degenerate dimension: the natural key
    policy_key          NUMBER,
    broker_key          NUMBER,
    claim_date_key      NUMBER,
    claim_date          DATE,
    amount              NUMBER(38,2),
    status              VARCHAR,
    is_orphan_policy    BOOLEAN,
    is_amount_outlier   BOOLEAN,
    has_invalid_date    BOOLEAN,
    _loaded_at          TIMESTAMP_NTZ
);

INSERT INTO GOLD.FACT_CLAIM
    (claim_key, claim_id, policy_key, broker_key, claim_date_key, claim_date,
     amount, status, is_orphan_policy, is_amount_outlier, has_invalid_date,
     _loaded_at)
SELECT
    GOLD.SEQ_CLAIM_KEY.NEXTVAL,
    c.claim_id,
    COALESCE(p.policy_key, -1),
    COALESCE(p.broker_key, -1),
    COALESCE(d.date_key, -1),
    c.claim_date,
    c.amount,
    c.status,
    c.is_orphan_policy,
    c.is_amount_outlier,
    c.has_invalid_date,
    CURRENT_TIMESTAMP()
FROM SILVER.CLAIMS c
-- No readable date means the claim can't be placed in time, so it resolves
-- against the current version. Stays visible via has_invalid_date.
LEFT JOIN GOLD.DIM_POLICY p
       ON p.policy_id  = c.policy_id
      AND COALESCE(c.claim_date, DATE '9999-12-30') >= p.valid_from
      AND COALESCE(c.claim_date, DATE '9999-12-30') <  p.valid_to
LEFT JOIN GOLD.DIM_DATE d
       ON d.full_date = c.claim_date;


-- ============================================================================
-- 7. Verify the star
-- ============================================================================

-- Expect 51 / 1,462 / 5,603 / 11,887.
SELECT 'DIM_BROKER' AS table_name, COUNT(*) AS row_count FROM GOLD.DIM_BROKER
UNION ALL SELECT 'DIM_DATE',   COUNT(*) FROM GOLD.DIM_DATE
UNION ALL SELECT 'DIM_POLICY', COUNT(*) FROM GOLD.DIM_POLICY
UNION ALL SELECT 'FACT_CLAIM', COUNT(*) FROM GOLD.FACT_CLAIM;

-- SCD2 shape.   Expect current 5,001 · closed 602.
SELECT is_current, COUNT(*) AS row_count
FROM GOLD.DIM_POLICY GROUP BY 1 ORDER BY 1;

-- GRAIN CHECK — the most important assertion in the file. Must return no rows.
-- Any row here means the date-range join fanned out and every sum is wrong.
SELECT claim_id, COUNT(*) AS copies
FROM GOLD.FACT_CLAIM GROUP BY 1 HAVING COUNT(*) > 1;

-- No overlapping validity windows. No rows.
SELECT a.policy_id, a.valid_from, a.valid_to, b.valid_from, b.valid_to
FROM GOLD.DIM_POLICY a
JOIN GOLD.DIM_POLICY b
  ON a.policy_id = b.policy_id
 AND a.policy_key < b.policy_key
 AND a.valid_from < b.valid_to
 AND b.valid_from < a.valid_to
WHERE a.policy_id <> 'UNKNOWN';

-- Orphans landed on the unknown member instead of being dropped.   Expect 128.
SELECT COUNT(*) AS claims_on_unknown_policy
FROM GOLD.FACT_CLAIM WHERE policy_key = -1;

-- RECONCILIATION. Expect variance 0.00.
-- Stage 5 automates this and makes a non-zero variance fail the run.
SELECT
    (SELECT SUM(amount) FROM SILVER.CLAIMS)     AS silver_total,
    (SELECT SUM(amount) FROM GOLD.FACT_CLAIM)   AS gold_total,
    (SELECT SUM(amount) FROM SILVER.CLAIMS)
      - (SELECT SUM(amount) FROM GOLD.FACT_CLAIM) AS variance;


-- ============================================================================
-- 8.  >>> RECORD THIS <<<   One policy, before and after
--
-- Take a policy_id from the first query, paste into the second.
-- You get one policy with two rows: one closed with a valid_to, one current.
--
-- That screenshot is the best evidence in the project.
-- Have both queries ready BEFORE you hit record.
-- ============================================================================

SELECT policy_id, COUNT(*) AS versions
FROM GOLD.DIM_POLICY
WHERE policy_id <> 'UNKNOWN'
GROUP BY 1 HAVING COUNT(*) > 1
ORDER BY 1 LIMIT 10;

-- Paste a policy_id from above:
SELECT policy_key, policy_id, status, premium, valid_from, valid_to, is_current
FROM GOLD.DIM_POLICY
WHERE policy_id = 'PASTE_A_POLICY_ID_HERE'
ORDER BY valid_from;


-- ============================================================================
-- 9. What the star schema is FOR
--
-- Against Bronze these needed casts, a dedupe and a date parse.
-- Here: one join and a GROUP BY.
-- ============================================================================

SELECT
    p.product,
    d.year,
    d.quarter,
    COUNT(*)          AS claim_count,
    SUM(f.amount)     AS total_paid
FROM GOLD.FACT_CLAIM f
JOIN GOLD.DIM_POLICY p ON p.policy_key = f.policy_key
JOIN GOLD.DIM_DATE   d ON d.date_key   = f.claim_date_key
WHERE f.is_amount_outlier = FALSE      -- sentinel rows excluded, deliberately
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- Top brokers by claim exposure.
SELECT
    b.broker_name,
    b.region,
    COUNT(*)      AS claim_count,
    SUM(f.amount) AS total_paid
FROM GOLD.FACT_CLAIM f
JOIN GOLD.DIM_BROKER b ON b.broker_key = f.broker_key
WHERE f.is_amount_outlier = FALSE
GROUP BY 1, 2
ORDER BY total_paid DESC
LIMIT 10;
