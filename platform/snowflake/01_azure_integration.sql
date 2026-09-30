-- ============================================================================
-- 01_azure_integration.sql  |  Let Snowflake read the Azure container
--
-- WHAT THIS IS
--   Snowflake and Azure are separate companies' clouds. Neither can grant
--   itself access to the other. So this is a handshake, and it has a manual
--   step in the middle that no script can do for you:
--
--     1. Snowflake creates an identity  (an app in YOUR Azure directory)
--     2. You consent to that app        (a browser click, once)
--     3. You give it a role on the storage account  (Azure side)
--     4. Snowflake can now read the container
--
--   Step 2 and 3 are why this file has a gap in the middle. Run section 1,
--   do the browser steps, then come back for section 4.
--
-- WHY NOT JUST USE A STORAGE KEY?
--   You could. A SAS token or account key in the stage definition works and
--   takes two minutes. It also means a long-lived secret sitting in Snowflake
--   that nobody rotates. A storage integration uses a managed identity - no
--   secret is stored anywhere, and access is revoked by removing a role
--   assignment in Azure. Same reason SVC_DBT uses a key pair, not a password.
-- ============================================================================


-- ============================================================================
-- 0. FILL THESE IN FIRST
--
-- Two values, both from your own environment. They are deliberately not
-- hardcoded: the storage account name contains a random suffix, so it changes
-- every time Terraform rebuilds the landing zone.
--
--   <STORAGE_ACCOUNT>  from:  terraform output -raw storage_account
--   <AZURE_TENANT_ID>  from:  az account show --query tenantId -o tsv
--
-- Paste them wherever the placeholders appear below.
-- ============================================================================


-- ============================================================================
-- 1. THE STORAGE INTEGRATION
--
-- This creates Snowflake's identity for talking to your Azure account.
-- ACCOUNTADMIN only - an integration crosses account boundaries, so Snowflake
-- will not let a lesser role create one.
--
-- STORAGE_ALLOWED_LOCATIONS is a whitelist. Snowflake can read that container
-- and nothing else, even if someone later writes a stage pointing elsewhere.
-- ============================================================================
USE ROLE ACCOUNTADMIN;

CREATE STORAGE INTEGRATION IF NOT EXISTS AZURE_LANDING
    TYPE                      = EXTERNAL_STAGE
    STORAGE_PROVIDER          = 'AZURE'
    AZURE_TENANT_ID           = '<AZURE_TENANT_ID>'
    ENABLED                   = TRUE
    STORAGE_ALLOWED_LOCATIONS = ('azure://<STORAGE_ACCOUNT>.blob.core.windows.net/landing')
    COMMENT                   = 'Reads the ADLS Gen2 landing container built by Terraform';


-- ============================================================================
-- 2. GET THE TWO VALUES YOU NEED FOR THE BROWSER STEPS
--
-- Run this and copy two rows out of the result:
--
--   AZURE_CONSENT_URL           a link you open in a browser
--   AZURE_MULTI_TENANT_APP_NAME looks like  snowflakepacint_1234567890123
--                               you only need the part BEFORE the underscore
-- ============================================================================
DESC STORAGE INTEGRATION AZURE_LANDING;


-- ============================================================================
-- 3. THE MANUAL BIT  (nothing to run here - do these in a browser)
--
-- 3a. Open AZURE_CONSENT_URL from the result above. Sign in as the Azure
--     account that owns the subscription. Click Accept.
--
--     This registers Snowflake's app in your Azure directory. It does not
--     grant access to anything yet - it only lets the app exist.
--
-- 3b. Give that app permission on the storage account. Portal route:
--
--       Storage accounts > <STORAGE_ACCOUNT>
--         > Access Control (IAM)
--         > Add > Add role assignment
--         > Role:    Storage Blob Data Reader
--         > Members: User, group, or service principal > Select members
--                    search the app name from AZURE_MULTI_TENANT_APP_NAME
--                    (the part before the underscore)
--         > Review + assign
--
--     READER, not Contributor. Snowflake only needs to read files for a stage
--     and a pipe. Write access would let it delete your raw data, and Bronze's
--     whole job is being the copy nothing can damage.
--
-- 3c. Wait a minute or two. Azure role assignments are not instant, and
--     section 6 failing with "access denied" usually just means too soon.
-- ============================================================================


-- ============================================================================
-- 3d. LET LOADER USE THE INTEGRATION
--
-- ACCOUNTADMIN created the integration, so ACCOUNTADMIN owns it. LOADER
-- cannot build a stage on top of something it has no rights to, and Phase 1
-- could not have granted this - the integration did not exist yet.
--
-- This is least privilege behaving normally, not a bug: every new shared
-- object needs an explicit grant. The alternative is running everything as
-- ACCOUNTADMIN, which is the thing Phase 1 set out to avoid.
-- ============================================================================
USE ROLE ACCOUNTADMIN;

GRANT USAGE ON INTEGRATION AZURE_LANDING TO ROLE LOADER;


-- ============================================================================
-- 4. FILE FORMAT
--
-- How to read the CSVs. Same settings as the old Bronze build, and the
-- unusual ones are deliberate:
--
--   TRIM_SPACE = FALSE            keep the messy whitespace, dbt conforms it
--   NULL_IF = ()                  keep '' as '', do not turn it into NULL
--   EMPTY_FIELD_AS_NULL = FALSE   same idea
--
-- Bronze keeps the data exactly as it arrived. Cleaning it here would destroy
-- the evidence before anyone can measure it.
-- ============================================================================
USE ROLE LOADER;
USE WAREHOUSE WH_LOAD;
USE SCHEMA RAW.INSURANCE;

CREATE FILE FORMAT IF NOT EXISTS RAW.INSURANCE.FF_CSV
    TYPE                         = 'CSV'
    FIELD_DELIMITER              = ','
    SKIP_HEADER                  = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    TRIM_SPACE                   = FALSE
    NULL_IF                      = ()
    EMPTY_FIELD_AS_NULL          = FALSE
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
    COMMENT = 'Reads the source CSVs without cleaning anything';


-- ============================================================================
-- 5. EXTERNAL STAGE
--
-- A stage is a pointer. An INTERNAL stage is storage Snowflake manages for
-- you; an EXTERNAL stage points at storage you own. Nothing is copied here -
-- the files stay in Azure, and Snowflake reads them where they sit.
--
-- The integration supplies the credentials, so this definition holds no
-- secret. That is the whole payoff of section 1.
-- ============================================================================
CREATE STAGE IF NOT EXISTS RAW.INSURANCE.STG_LANDING
    STORAGE_INTEGRATION = AZURE_LANDING
    URL                 = 'azure://<STORAGE_ACCOUNT>.blob.core.windows.net/landing'
    FILE_FORMAT         = RAW.INSURANCE.FF_CSV
    COMMENT             = 'ADLS Gen2 landing container';


-- ============================================================================
-- 6. PROVE IT WORKS
--
-- Expect: an empty result, and NO error.
--
-- Empty is correct - nothing has been uploaded yet, on purpose. Snowpipe
-- auto-ingest only fires for files that arrive AFTER the pipe exists, so
-- uploading now would mean the files sit there ignored.
--
-- What matters is that this returns nothing rather than failing. An error
-- means the handshake is incomplete:
--
--   "...not authorized..." / 403   -> role assignment missing, or too recent
--   "...container not found..."    -> storage account name typo in the URL
--   "...invalid tenant..."         -> wrong AZURE_TENANT_ID in section 1
-- ============================================================================
LIST @RAW.INSURANCE.STG_LANDING;
