-- =============================================================================
-- Stage 0 — Environment setup
-- Run this once, top to bottom, in a Snowflake worksheet.
-- =============================================================================

-- ACCOUNTADMIN is only needed if you have to create the warehouse.
-- Use the least-privileged role that works for you.
USE ROLE ACCOUNTADMIN;


-- -----------------------------------------------------------------------------
-- Warehouse — this is COMPUTE. It is separate from storage, and that separation
-- is the single most important thing to understand about Snowflake.
--
-- AUTO_SUSPEND = 60 means it parks after a minute idle. Billing is per-second
-- with a 60-second minimum, so a low auto-suspend genuinely saves money.
-- INITIALLY_SUSPENDED means creating it costs nothing.
-- -----------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS WH_MEDALLION
    WAREHOUSE_SIZE      = 'XSMALL'
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT             = 'Compute for the medallion pipeline';


-- -----------------------------------------------------------------------------
-- Database and schemas — this is STORAGE. One schema per medallion layer.
-- -----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS INSURANCE_DEMO
    COMMENT = 'P&C insurance medallion demo';

USE DATABASE INSURANCE_DEMO;

CREATE SCHEMA IF NOT EXISTS BRONZE COMMENT = 'Raw landing. Untyped, unmodified, append-only.';
CREATE SCHEMA IF NOT EXISTS SILVER COMMENT = 'Typed, deduplicated, conformed.';
CREATE SCHEMA IF NOT EXISTS GOLD   COMMENT = 'Dimensional model for reporting.';
CREATE SCHEMA IF NOT EXISTS OPS    COMMENT = 'Quarantine, reconciliation, run audit.';

USE WAREHOUSE WH_MEDALLION;


-- -----------------------------------------------------------------------------
-- File format — how Snowflake should parse the CSVs.
--
-- Note what is NOT here: no date parsing, no numeric coercion. Bronze takes
-- everything as text. A malformed date must not be able to fail the load —
-- that is the whole point of landing raw.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT INSURANCE_DEMO.BRONZE.FF_CSV
    TYPE                         = 'CSV'
    FIELD_DELIMITER              = ','
    SKIP_HEADER                  = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    TRIM_SPACE                   = FALSE   -- keep the messy whitespace; Silver conforms it
    NULL_IF                      = ()      -- keep empty strings as empty strings, not NULL
    EMPTY_FIELD_AS_NULL          = FALSE
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;


-- -----------------------------------------------------------------------------
-- Internal stage — where the CSVs land before COPY INTO.
-- -----------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS INSURANCE_DEMO.BRONZE.STG_RAW
    FILE_FORMAT = INSURANCE_DEMO.BRONZE.FF_CSV
    COMMENT     = 'Landing stage for source CSV extracts';


-- -----------------------------------------------------------------------------
-- Verify
-- -----------------------------------------------------------------------------
SHOW SCHEMAS IN DATABASE INSURANCE_DEMO;
SHOW STAGES IN SCHEMA INSURANCE_DEMO.BRONZE;

SELECT CURRENT_WAREHOUSE() AS warehouse,
       CURRENT_DATABASE()  AS database,
       CURRENT_ROLE()      AS role;
