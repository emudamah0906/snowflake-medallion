-- ============================================================================
-- Stage 0 — Setup
-- Build the environment. Run once, top to bottom.
-- ============================================================================

USE ROLE ACCOUNTADMIN;


-- ----------------------------------------------------------------------------
-- WAREHOUSE = compute. Not a data warehouse — a cluster that runs queries.
-- Nothing is stored in it. Storage lives separately, which is why I can turn
-- this off and pay nothing while the data stays put.
--
-- AUTO_SUSPEND 60: parks after a minute idle. Billing is per-second.
-- ----------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS WH_MEDALLION
    WAREHOUSE_SIZE      = 'XSMALL'
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT             = 'Compute for the medallion pipeline';


-- ----------------------------------------------------------------------------
-- DATABASE + SCHEMAS = storage. One schema per layer.
-- The architecture, expressed as folders.
-- ----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS INSURANCE_DEMO
    COMMENT = 'P and C insurance medallion demo';

USE DATABASE INSURANCE_DEMO;

CREATE SCHEMA IF NOT EXISTS BRONZE COMMENT = 'Raw landing. Untyped, unmodified, append-only.';
CREATE SCHEMA IF NOT EXISTS SILVER COMMENT = 'Typed, deduplicated, conformed.';
CREATE SCHEMA IF NOT EXISTS GOLD   COMMENT = 'Dimensional model for reporting.';
CREATE SCHEMA IF NOT EXISTS OPS    COMMENT = 'Quarantine, reconciliation, run audit.';

USE WAREHOUSE WH_MEDALLION;


-- ----------------------------------------------------------------------------
-- FILE FORMAT = how to read the CSVs. Reusable, stored in the database.
--
-- The last three settings deliberately do nothing. Bronze keeps the mess
-- exactly as it arrived; Silver decides what's valid.
-- No date parsing, no number handling — that's the point.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT INSURANCE_DEMO.BRONZE.FF_CSV
    TYPE                         = 'CSV'
    FIELD_DELIMITER              = ','
    SKIP_HEADER                  = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    TRIM_SPACE                   = FALSE   -- keep the messy whitespace; Silver conforms it
    NULL_IF                      = ()      -- keep empty strings as empty strings, not NULL
    EMPTY_FIELD_AS_NULL          = FALSE
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;


-- ----------------------------------------------------------------------------
-- STAGE = a folder Snowflake manages. Files land here before becoming rows.
-- ----------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS INSURANCE_DEMO.BRONZE.STG_RAW
    FILE_FORMAT = INSURANCE_DEMO.BRONZE.FF_CSV
    COMMENT     = 'Landing stage for source CSV extracts';


-- ----------------------------------------------------------------------------
-- Verify
-- ----------------------------------------------------------------------------
SHOW SCHEMAS IN DATABASE INSURANCE_DEMO;
SHOW STAGES IN SCHEMA INSURANCE_DEMO.BRONZE;

SELECT CURRENT_WAREHOUSE() AS warehouse,
       CURRENT_DATABASE()  AS database,
       CURRENT_ROLE()      AS role;
