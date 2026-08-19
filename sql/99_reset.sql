-- ============================================================================
-- Stage 99 — RESET
-- Tears the whole build down so Stage 0 can be recorded from a clean account.
--
-- ⚠️  DESTRUCTIVE. Run section 1 FIRST and look at what you are about to lose.
-- ============================================================================

USE ROLE ACCOUNTADMIN;


-- ============================================================================
-- 1. LOOK BEFORE YOU DELETE — nothing here destroys anything
--
-- Run this whole section first. Screenshot the last query.
-- Deleting without looking is how people lose the wrong database.
-- ============================================================================

SHOW DATABASES  LIKE 'INSURANCE_DEMO';
SHOW WAREHOUSES LIKE 'WH_MEDALLION';

-- The 6 tasks, 3 streams and 2 procedures that will go with the database
SHOW TASKS      IN DATABASE INSURANCE_DEMO;
SHOW STREAMS    IN DATABASE INSURANCE_DEMO;
SHOW PROCEDURES IN DATABASE INSURANCE_DEMO;

-- The 4 CSVs. These are INSIDE the database, in an internal stage —
-- dropping the database deletes them too, and they must be re-uploaded.
LIST @INSURANCE_DEMO.BRONZE.STG_RAW;

-- Every table and its row count, in one query.
-- INFORMATION_SCHEMA is the metadata catalogue Snowflake keeps about itself —
-- no need to know the table names in advance.
SELECT table_schema,
       table_name,
       row_count,
       ROUND(bytes / 1024, 1) AS kb
FROM   INSURANCE_DEMO.INFORMATION_SCHEMA.TABLES
WHERE  table_type = 'BASE TABLE'
ORDER  BY table_schema, table_name;


-- ============================================================================
-- 2. Stop the task tree before dropping
--
-- Suspend the ROOT only — children stop with it. IF EXISTS so this is safe
-- even if Stage 4 was never built.
-- ============================================================================

ALTER TASK IF EXISTS INSURANCE_DEMO.OPS.T_CLAIMS_01_DRAIN_STREAM SUSPEND;


-- ============================================================================
-- 3. THE DROP — this is the destructive statement
--
-- One statement removes: 4 schemas, every table, 3 streams, 6 tasks,
-- 2 procedures, the file format, the stage, and the 4 staged CSVs.
-- ============================================================================

DROP DATABASE IF EXISTS INSURANCE_DEMO;


-- ============================================================================
-- 4. Drop the warehouse too — optional
--
-- Do this if you want Episode 0 to build compute on camera from nothing.
-- Skip it if you would rather keep the warehouse and only rebuild the data.
-- Costs nothing either way; it is suspended.
-- ============================================================================

DROP WAREHOUSE IF EXISTS WH_MEDALLION;


-- ============================================================================
-- 5. Verify — both should return ZERO rows
-- ============================================================================

SHOW DATABASES  LIKE 'INSURANCE_DEMO';
SHOW WAREHOUSES LIKE 'WH_MEDALLION';


-- ============================================================================
-- SAFETY NET — Time Travel
--
-- A dropped database is not gone immediately. Snowflake keeps it for the
-- retention window (DATA_RETENTION_TIME_IN_DAYS, default 1 on this account):
--
--     UNDROP DATABASE INSURANCE_DEMO;
--
-- That restores everything, including the staged files. It is the reason
-- DROP is survivable here — and it is a very common interview question,
-- because most databases have no equivalent.
--
-- After the retention window it moves to Fail-safe (7 days, Snowflake support
-- only, not self-service), then it is genuinely gone.
-- ============================================================================


-- ============================================================================
-- AFTER THE RESET — the CSVs must go back up
--
-- The stage was inside the database, so the 4 files went with it.
-- Rebuild the environment first (00_setup.sql creates the stage), THEN upload.
--
-- Option A — Snowsight UI: Data > Databases > INSURANCE_DEMO > BRONZE >
--            Stages > STG_RAW > "+ Files". Drag the 4 CSVs in. Records well.
--
-- Option B — terminal:
--
--   snow sql -q "PUT 'file:///Users/maheshshettynani/Desktop/DE Portfolio 2026/04-Projects/snowflake-medallion/data/*.csv' @INSURANCE_DEMO.BRONZE.STG_RAW AUTO_COMPRESS=FALSE OVERWRITE=TRUE"
--
-- AUTO_COMPRESS=FALSE keeps them as plain .csv, matching how they are now.
-- Turning it on would make them .csv.gz and contradict the notes in
-- 01_bronze.sql and SCRIPT.md episode 0.
--
-- Then confirm 4 files:  LIST @INSURANCE_DEMO.BRONZE.STG_RAW;
-- ============================================================================
