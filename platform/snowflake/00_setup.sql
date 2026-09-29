-- ============================================================================
-- 00_setup.sql  |  Set up Snowflake for the pipeline
--
-- HOW TO RUN
--   One section at a time. Highlight the section, press Cmd + Return.
--   Then run its CHECK line on its own and compare with EXPECT.
--   Never type SQL by hand. Copy it from this file.
--
-- WHAT WE BUILD
--   Warehouses  = computers that run queries  -> WH_LOAD, WH_TRANSFORM
--   Spend cap   = a credit limit              -> RM_MEDALLION
--   Databases   = where data is stored        -> RAW, ANALYTICS
--   Roles       = job badges with permissions -> LOADER, TRANSFORMER, REPORTER
--   Service user = a login for dbt, not a person -> SVC_DBT
-- ============================================================================


-- ============================================================================
-- 0. CHECK FIRST  (changes nothing)
--
-- WHY:    "IF NOT EXISTS" skips anything that already exists, even if its
--         settings are wrong. So we look before we build.
-- EXPECT: only Snowflake's own objects. No WH_LOAD, RAW or LOADER.
-- ============================================================================
USE ROLE ACCOUNTADMIN;

SHOW WAREHOUSES;          -- expect COMPUTE_WH and 2 other built-in ones
SHOW DATABASES;           -- expect no RAW, no ANALYTICS
SHOW ROLES LIKE '%ER';    -- expect "Query produced no results"


-- ============================================================================
-- 1. WAREHOUSES  (the computers that run our queries)
--
-- WHY TWO:  one for loading data, one for dbt.
--           The bill then shows what each job costs.
-- XSMALL:   smallest size. Enough for our 12k rows.
-- AUTO_SUSPEND = 60: switch off after 1 idle minute.
--           Snowflake's default is 10 minutes of paying for nothing.
-- INITIALLY_SUSPENDED: start switched off, so creating it costs nothing.
-- SYSADMIN: the admin role for creating objects. It will own them.
-- ============================================================================
USE ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS WH_LOAD
    WAREHOUSE_SIZE      = 'XSMALL'
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT             = 'Loading data into RAW';

CREATE WAREHOUSE IF NOT EXISTS WH_TRANSFORM
    WAREHOUSE_SIZE      = 'XSMALL'
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT             = 'dbt runs and reporting queries';

-- CHECK. EXPECT 2 rows: SUSPENDED, X-Small, auto_suspend 60, owner SYSADMIN
SHOW WAREHOUSES LIKE 'WH_%';


-- ============================================================================
-- 2. SPEND CAP  (a credit limit, like on a credit card)
--
-- WHY:      if a job gets stuck in a loop, it can't burn all the credits.
-- THE RULE: 30 credits a month. Email me at 50% and 75%.
--           At 100%, switch both warehouses off.
-- ACCOUNTADMIN: only this role can create a spend cap. That's the only
--           thing we use it for.
-- ============================================================================
USE ROLE ACCOUNTADMIN;

CREATE RESOURCE MONITOR IF NOT EXISTS RM_MEDALLION
    WITH CREDIT_QUOTA    = 30
         FREQUENCY       = MONTHLY
         START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 50  PERCENT DO NOTIFY
             ON 75  PERCENT DO NOTIFY
             ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE WH_LOAD      SET RESOURCE_MONITOR = RM_MEDALLION;
ALTER WAREHOUSE WH_TRANSFORM SET RESOURCE_MONITOR = RM_MEDALLION;

-- CHECK. EXPECT 1 row: quota 30, MONTHLY, notify 50%,75%, suspend 100%
SHOW RESOURCE MONITORS;


-- ============================================================================
-- 3. DATABASES  (where the data is stored)
--
-- RAW       = Bronze. Files land here exactly as they came.
-- ANALYTICS = Silver and Gold. dbt builds everything in here.
-- WHY SPLIT: each database has one writer. Only the loader writes to RAW.
--            Only dbt writes to ANALYTICS. Easy to control and explain.
-- NO SILVER/GOLD SCHEMAS YET: dbt creates its own schemas later.
-- ============================================================================
USE ROLE SYSADMIN;

CREATE DATABASE IF NOT EXISTS RAW
    COMMENT = 'Bronze: raw source data';

CREATE SCHEMA IF NOT EXISTS RAW.INSURANCE
    COMMENT = 'Policy, claims and broker files from Azure';

CREATE DATABASE IF NOT EXISTS ANALYTICS
    COMMENT = 'Silver and Gold: built by dbt';

-- CHECK. EXPECT RAW and ANALYTICS in the list, owner SYSADMIN
SHOW DATABASES LIKE '%A%';


-- ============================================================================
-- 4. ROLES  (job badges. A person or program wears one to get access)
--
-- LOADER      = loads files into RAW
-- TRANSFORMER = dbt. Reads RAW, builds ANALYTICS
-- REPORTER    = analysts and dashboards. Reads Gold only
-- USERADMIN:  the admin role for creating roles and users.
-- GRANT ... TO ROLE SYSADMIN: puts the new roles under SYSADMIN,
--             so the admin can still see and fix what they create.
-- ============================================================================
USE ROLE USERADMIN;

CREATE ROLE IF NOT EXISTS LOADER      COMMENT = 'Loads data into RAW';
CREATE ROLE IF NOT EXISTS TRANSFORMER COMMENT = 'dbt: reads RAW, builds ANALYTICS';
CREATE ROLE IF NOT EXISTS REPORTER    COMMENT = 'Reads Gold tables only';

USE ROLE SECURITYADMIN;

GRANT ROLE LOADER      TO ROLE SYSADMIN;
GRANT ROLE TRANSFORMER TO ROLE SYSADMIN;
GRANT ROLE REPORTER    TO ROLE SYSADMIN;

-- CHECK. EXPECT 3 rows: LOADER, REPORTER, TRANSFORMER
SHOW ROLES LIKE '%ER';


-- ============================================================================
-- 5. PERMISSIONS  (what each badge is allowed to do)
--
-- RULE:    each role gets only what its job needs. Nothing extra.
-- USAGE:   allowed to use it (a warehouse, database or schema).
-- OPERATE: allowed to start and stop the warehouse.
-- FUTURE TABLES: also covers tables created later. Without it, dbt
--          can't read a new RAW table until someone grants it by hand.
-- REPORTER gets table access later. dbt gives it, on Gold tables only.
-- SECURITYADMIN: the admin role for handing out permissions.
-- ============================================================================
USE ROLE SECURITYADMIN;

-- LOADER: use WH_LOAD, and create tables, stages and pipes in RAW.INSURANCE
GRANT USAGE, OPERATE ON WAREHOUSE WH_LOAD TO ROLE LOADER;
GRANT USAGE ON DATABASE RAW               TO ROLE LOADER;
GRANT USAGE ON SCHEMA RAW.INSURANCE       TO ROLE LOADER;
GRANT CREATE TABLE, CREATE STAGE, CREATE PIPE, CREATE FILE FORMAT
      ON SCHEMA RAW.INSURANCE             TO ROLE LOADER;

-- TRANSFORMER: use WH_TRANSFORM, read RAW, create schemas in ANALYTICS
GRANT USAGE, OPERATE ON WAREHOUSE WH_TRANSFORM        TO ROLE TRANSFORMER;
GRANT USAGE ON DATABASE RAW                           TO ROLE TRANSFORMER;
GRANT USAGE ON SCHEMA RAW.INSURANCE                   TO ROLE TRANSFORMER;
GRANT SELECT ON ALL TABLES    IN SCHEMA RAW.INSURANCE TO ROLE TRANSFORMER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RAW.INSURANCE TO ROLE TRANSFORMER;
GRANT USAGE, CREATE SCHEMA ON DATABASE ANALYTICS      TO ROLE TRANSFORMER;

-- REPORTER: use WH_TRANSFORM, and see the ANALYTICS database
GRANT USAGE ON WAREHOUSE WH_TRANSFORM TO ROLE REPORTER;
GRANT USAGE ON DATABASE ANALYTICS     TO ROLE REPORTER;

-- Me: I can switch into any of the three roles while building.
-- Replace the placeholder with your own Snowflake username (SHOW USERS, or
-- Snowsight > Settings > Profile). It is not your login email.
GRANT ROLE LOADER      TO USER <YOUR_SNOWFLAKE_USER>;
GRANT ROLE TRANSFORMER TO USER <YOUR_SNOWFLAKE_USER>;
GRANT ROLE REPORTER    TO USER <YOUR_SNOWFLAKE_USER>;

-- CHECK. Run one at a time.
SHOW GRANTS TO ROLE LOADER;                  -- expect 8 rows
SHOW GRANTS TO ROLE TRANSFORMER;             -- expect 6 rows (RAW has no tables yet)
SHOW GRANTS TO ROLE REPORTER;                -- expect 2 rows
SHOW FUTURE GRANTS IN SCHEMA RAW.INSURANCE;  -- expect 1 row: SELECT to TRANSFORMER


-- ============================================================================
-- 6. SERVICE USER FOR dbt  (a login for a program, not a person)
--
-- TYPE = SERVICE: no password, can't log in to the website.
--                 It logs in with a key file only.
-- WHY A KEY:  it can't be guessed or phished. Snowflake keeps only the
--             public half. The private half stays on my Mac.
--
-- BEFORE RUNNING: replace <PASTE_PUBLIC_KEY_BODY> with your public key.
-- Copy it on the Mac with:
--   grep -v "PUBLIC KEY" ~/.snowflake/keys/svc_dbt_key.pub | tr -d '\n' | pbcopy
-- Paste it in Snowsight only. Don't save the key into this file in Git.
-- ============================================================================
USE ROLE USERADMIN;

CREATE USER IF NOT EXISTS SVC_DBT
    TYPE              = SERVICE
    DEFAULT_ROLE      = TRANSFORMER
    DEFAULT_WAREHOUSE = WH_TRANSFORM
    RSA_PUBLIC_KEY    = '<PASTE_PUBLIC_KEY_BODY>'
    COMMENT           = 'dbt login: local, Airflow, GitHub Actions';

USE ROLE SECURITYADMIN;

GRANT ROLE TRANSFORMER TO USER SVC_DBT;

-- CHECK. EXPECT RSA_PUBLIC_KEY_FP to start with SHA256:
USE ROLE ACCOUNTADMIN;
DESC USER SVC_DBT;
