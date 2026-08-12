-- =============================================================================
-- Stage 3 — GOLD: star schema and SCD Type 2
--
-- The highest-value stage of the project. It proves the Gold-layer resume claim
-- and the star-schema / SCD Type 2 claim in one piece of work.
--
-- THE GRAIN, STATED BEFORE ANY DDL:
--     ONE ROW OF FACT_CLAIM = ONE CLAIM.
-- Say it out loud before you write a line. Interviewers notice when someone
-- leads with grain, because getting it wrong makes every downstream number
-- double-count and no amount of clever SQL fixes it afterwards.
--
-- The star:
--
--         DIM_DATE        DIM_BROKER
--             \               /
--              \             /
--               +-- FACT_CLAIM --+
--                      |
--                  DIM_POLICY  (SCD Type 2)
--
-- Steps 5 and 8 are the ones worth recording. Step 5 is the money shot of the
-- whole series.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_MEDALLION;
USE DATABASE INSURANCE_DEMO;
USE SCHEMA GOLD;


-- =============================================================================
-- 1. Surrogate key sequences
--
-- WHY SURROGATE KEYS AT ALL — this is a guaranteed interview question.
--
-- The natural key is policy_id, e.g. 'POL002351'. It cannot be the dimension's
-- primary key, because under SCD Type 2 the SAME policy_id exists on several
-- rows — one per version. You need something that identifies a VERSION, not a
-- policy. That is the surrogate key.
--
-- Three more reasons, worth having ready:
--   - The fact table stores a small integer instead of a wide string. On a
--     billion-row fact that is real storage and real join cost.
--   - If the source system ever renumbers or reformats its IDs, the warehouse
--     absorbs it in one dimension instead of rewriting every fact row.
--   - It gives you somewhere to put an "unknown" member (key -1) for facts
--     whose dimension row is missing.
--
-- Sequences rather than AUTOINCREMENT so we can insert key -1 explicitly.
-- =============================================================================

CREATE OR REPLACE SEQUENCE GOLD.SEQ_BROKER_KEY START = 1 INCREMENT = 1;
CREATE OR REPLACE SEQUENCE GOLD.SEQ_POLICY_KEY START = 1 INCREMENT = 1;
CREATE OR REPLACE SEQUENCE GOLD.SEQ_CLAIM_KEY  START = 1 INCREMENT = 1;


-- =============================================================================
-- 2. DIM_BROKER  —  a Type 1 dimension
--
-- Expect 51 rows: 50 real brokers plus the unknown member.
--
-- Type 1 means overwrite: when a broker moves region we just update the row and
-- history is lost. That is the right call here because nobody reports on
-- "claims by the region the broker used to be in". Choosing Type 1 vs Type 2
-- per dimension — rather than applying one everywhere — is the actual skill.
--
-- THE UNKNOWN MEMBER (key -1) is not a hack, it is standard practice. A fact
-- whose dimension row is missing must still join to something, or an INNER JOIN
-- silently drops it and your totals stop tying. Every dimension gets one.
-- =============================================================================

CREATE OR REPLACE TABLE GOLD.DIM_BROKER (
    broker_key    NUMBER       NOT NULL,
    broker_id     VARCHAR,
    broker_name   VARCHAR,
    region        VARCHAR,
    email         VARCHAR,
    _loaded_at    TIMESTAMP_NTZ
);

-- 2a. The unknown member first, so it always exists before any fact loads.
INSERT INTO GOLD.DIM_BROKER
    (broker_key, broker_id, broker_name, region, email, _loaded_at)
VALUES
    (-1, 'UNKNOWN', 'Unknown broker', 'Unknown', NULL, CURRENT_TIMESTAMP());

-- 2b. The real brokers.
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


-- =============================================================================
-- 3. DIM_DATE  —  a generated calendar
--
-- Expect 1,461 rows: 2024-01-01 through 2027-12-31.
--
-- WHY A DATE DIMENSION EXISTS AT ALL. You can extract a month from a date with
-- MONTH(), so why a whole table? Because a date dimension holds the things a
-- date function cannot know: your fiscal calendar, whether a day is a public
-- holiday, which week belongs to which reporting period. It also lets a BI tool
-- offer "fiscal quarter" as a clickable attribute rather than a formula.
--
-- Generating it: TABLE(GENERATOR(ROWCOUNT => n)) manufactures rows out of
-- nothing, and SEQ4() numbers them 0,1,2... A neat Snowflake trick — this is
-- how you build any sequence of rows with no source table.
--
-- The range deliberately overruns the data: claims run 2024-06 to 2026-07 and
-- policies to 2027-06. A date dimension that stops before your data does causes
-- rows to vanish from reports, and it is a genuinely common production bug.
-- =============================================================================

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

-- The unknown member. Claims with an unreadable date land here rather than
-- falling out of the join.
INSERT INTO GOLD.DIM_DATE
    (date_key, full_date, year, quarter, month, month_name,
     day_of_month, day_of_week, day_name, is_weekend)
VALUES
    (-1, NULL, NULL, NULL, NULL, 'Unknown', NULL, NULL, 'Unknown', NULL);


-- =============================================================================
-- 4. DIM_POLICY  —  SCD TYPE 2, initial load
--
-- Expect 5,000 rows, every one is_current = TRUE.
--
-- This loads the FIRST extract only (2026-08-01). Step 5 then merges the second
-- extract and that is where Type 2 actually happens.
--
-- THE THREE SCD2 COLUMNS:
--   valid_from  - when this version became true
--   valid_to    - when it stopped being true
--   is_current  - convenience flag so "today's view" is a cheap filter
--
-- WHY valid_from IS 1900-01-01 AND NOT THE EXTRACT DATE.
-- Your claims are dated 2024-06 to 2026-07 — all BEFORE the first extract on
-- 2026-08-01. If version 1 were only valid from 2026-08-01, every single claim
-- would fall outside every version's date range and the fact table would join
-- to nothing. On an initial load you do not know when the policy first took
-- this shape, so it is valid "from the beginning of time as far as we know".
-- Getting this wrong is subtle and silent: the load succeeds, the fact table
-- fills, and every policy_key is -1.
--
-- valid_to 9999-12-31 rather than NULL, so range comparisons never need to
-- special-case a NULL. BETWEEN and >= / < just work.
-- =============================================================================

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

-- 4b. Initial load from the first extract. Expect 5,000 rows.
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


-- =============================================================================
-- 5.  >>> THE MONEY SHOT — RECORD THIS <<<  SCD Type 2 as a single MERGE
--
-- Before running, note the count: 5,001 rows (5,000 + unknown member).
-- After running: 5,603 — because 602 policies changed and each now has TWO
-- rows, one closed and one current.
--
-- HOW A TYPE 2 MERGE WORKS. Snowflake's MERGE can only take ONE action per
-- matched source row, but a change needs TWO: close the old row AND insert a
-- new one. The standard trick is to feed the source in twice:
--
--   pass 'CLOSE'  - matches the existing current row, UPDATEs it shut
--   pass 'INSERT' - does not match anything, so falls to WHEN NOT MATCHED
--                   and inserts the new version
--
-- The join key on the CLOSE pass includes is_current = TRUE, so only the live
-- version is ever closed. The INSERT pass carries a deliberately unmatchable
-- join key so it always lands in NOT MATCHED.
--
-- WHAT COUNTS AS A CHANGE is a decision, not a given. Here: status or premium.
-- A change to product or broker would be ignored — fine for this model, but you
-- should be able to say what you track and why, because "we compare every
-- column" is usually wrong (it makes the dimension churn on noise).
--
-- IS NOT DISTINCT FROM handles NULLs: plain <> returns NULL when either side is
-- NULL, and a NULL predicate is not TRUE, so genuine changes to or from NULL
-- would be missed silently.
-- =============================================================================

-- ALL CHANGE DETECTION HAPPENS IN THE `USING` SUBQUERY, deliberately. It reads
-- DIM_POLICY as it stood before the MERGE began, which is well defined. Testing
-- for a change inside the WHEN clauses instead — with a subquery against the
-- table you are currently merging into — reads a table mid-write and is not
-- something you should rely on. Decide what changed first, then act.

MERGE INTO GOLD.DIM_POLICY AS tgt
USING (
    -- pass 1: CLOSE — the live version of every policy whose tracked
    -- attributes differ in the new extract.
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

    -- pass 2: INSERT — the new version of those same changed policies.
    -- join_key is NULL, so `tgt.policy_id = NULL` is never true and this row
    -- always falls through to WHEN NOT MATCHED.
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

    -- pass 3: brand-new policies never seen in any earlier extract.
    -- Zero rows in this dataset — both snapshots carry the same 5,000 policies —
    -- but a Type 2 load that cannot accept a new member is incomplete, and it is
    -- the first thing a reviewer will look for.
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

-- Matched -> this is a pass-1 row -> close the old version.
WHEN MATCHED THEN UPDATE SET
    tgt.valid_to   = src.extract_date,
    tgt.is_current = FALSE

-- Not matched -> pass 2 or pass 3 -> insert the new current version.
WHEN NOT MATCHED THEN INSERT
    (policy_key, policy_id, broker_key, product, start_date, end_date,
     premium, status, valid_from, valid_to, is_current, _loaded_at)
VALUES
    (GOLD.SEQ_POLICY_KEY.NEXTVAL,
     src.policy_id,
     src.broker_key,
     src.product, src.start_date, src.end_date, src.premium, src.status,
     src.extract_date, DATE '9999-12-31', TRUE, CURRENT_TIMESTAMP());


-- =============================================================================
-- 6. FACT_CLAIM
--
-- Expect 11,887 rows — the grain holds: one row in, one row out, no fan-out.
-- 128 of them carry policy_key = -1.
--
-- HOW THE POLICY KEY IS RESOLVED — this is the entire payoff of SCD Type 2:
--
--     ON  p.policy_id = c.policy_id
--     AND c.claim_date >= p.valid_from
--     AND c.claim_date <  p.valid_to
--
-- We are not asking "what does this policy look like now". We are asking
-- "what did this policy look like ON THE DAY OF THE CLAIM". That is the whole
-- reason the dimension keeps history. Point the fact at is_current instead and
-- you have built SCD2 for nothing.
--
-- >= valid_from AND < valid_to, never BETWEEN — BETWEEN is inclusive at both
-- ends, so a claim on the exact changeover date would match two versions and
-- duplicate the row.
--
-- MEASURES — the vocabulary interviewers use:
--   amount is ADDITIVE: it sums across every dimension. Claims by month, by
--   product, by broker all work.
--   A month-end policy count would be SEMI-ADDITIVE: it sums across product and
--   broker but NOT across time — adding January's and February's open policies
--   double-counts anything open in both.
-- =============================================================================

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
-- Version-aware join. A claim with no readable date cannot be placed in time,
-- so it resolves against the current version — the best answer available, and
-- it stays visible via has_invalid_date.
LEFT JOIN GOLD.DIM_POLICY p
       ON p.policy_id  = c.policy_id
      AND COALESCE(c.claim_date, DATE '9999-12-30') >= p.valid_from
      AND COALESCE(c.claim_date, DATE '9999-12-30') <  p.valid_to
LEFT JOIN GOLD.DIM_DATE d
       ON d.full_date = c.claim_date;


-- =============================================================================
-- 7. Verify the star
-- =============================================================================

-- Row counts. Expect 51 / 1,462 / 5,603 / 11,887.
SELECT 'DIM_BROKER' AS table_name, COUNT(*) AS row_count FROM GOLD.DIM_BROKER
UNION ALL SELECT 'DIM_DATE',   COUNT(*) FROM GOLD.DIM_DATE
UNION ALL SELECT 'DIM_POLICY', COUNT(*) FROM GOLD.DIM_POLICY
UNION ALL SELECT 'FACT_CLAIM', COUNT(*) FROM GOLD.FACT_CLAIM;

-- SCD2 shape. Expect current 5,001 (incl. unknown member) and closed 602.
SELECT is_current, COUNT(*) AS row_count
FROM GOLD.DIM_POLICY GROUP BY 1 ORDER BY 1;

-- GRAIN CHECK — the single most important assertion in the file.
-- FACT_CLAIM must have exactly one row per claim_id. Any row returned here
-- means the version-aware join fanned out and every sum is now wrong.
SELECT claim_id, COUNT(*) AS copies
FROM GOLD.FACT_CLAIM GROUP BY 1 HAVING COUNT(*) > 1;

-- No overlapping validity windows for a policy. Should return no rows.
SELECT a.policy_id, a.valid_from, a.valid_to, b.valid_from, b.valid_to
FROM GOLD.DIM_POLICY a
JOIN GOLD.DIM_POLICY b
  ON a.policy_id = b.policy_id
 AND a.policy_key < b.policy_key
 AND a.valid_from < b.valid_to
 AND b.valid_from < a.valid_to
WHERE a.policy_id <> 'UNKNOWN';

-- Orphans landed on the unknown member rather than being dropped. Expect 128.
SELECT COUNT(*) AS claims_on_unknown_policy
FROM GOLD.FACT_CLAIM WHERE policy_key = -1;

-- RECONCILIATION — Silver total must equal Gold total exactly.
-- Expect both 1,063,516,068.75 and variance 0.00. This is the Stage 5 gate
-- rehearsed by hand; Stage 5 automates it and makes a non-zero variance fail
-- the run.
SELECT
    (SELECT SUM(amount) FROM SILVER.CLAIMS)     AS silver_total,
    (SELECT SUM(amount) FROM GOLD.FACT_CLAIM)   AS gold_total,
    (SELECT SUM(amount) FROM SILVER.CLAIMS)
      - (SELECT SUM(amount) FROM GOLD.FACT_CLAIM) AS variance;


-- =============================================================================
-- 8.  >>> RECORD THIS <<<  Before and after, for one real policy
--
-- Pick any policy_id the first query returns, paste it into the second, and you
-- get the screenshot that carries the entire series: one policy, two rows, one
-- closed with a valid_to and one current.
--
-- That image is the best evidence you own that you built SCD Type 2. Have both
-- queries ready before you hit record.
-- =============================================================================

SELECT policy_id, COUNT(*) AS versions
FROM GOLD.DIM_POLICY
WHERE policy_id <> 'UNKNOWN'
GROUP BY 1 HAVING COUNT(*) > 1
ORDER BY 1 LIMIT 10;

-- Paste a policy_id from above into the WHERE clause:
SELECT policy_key, policy_id, status, premium, valid_from, valid_to, is_current
FROM GOLD.DIM_POLICY
WHERE policy_id = 'PASTE_A_POLICY_ID_HERE'
ORDER BY valid_from;


-- =============================================================================
-- 9. What the star schema is FOR
--
-- Everything above exists so a business question becomes a short query. This is
-- what you show a stakeholder — and what you show an interviewer who asks what
-- the Gold layer bought you.
-- =============================================================================

-- Claims paid by product by quarter. In Bronze this needed casts, dedupe and a
-- date parse. Here it is one join and a GROUP BY.
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
