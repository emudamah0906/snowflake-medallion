# Terminal setup — step by step

Snowflake CLI (`snow`) 3.17.1 is already installed. No connection is configured yet, so that's
Step 1.

Run these one at a time. Stop at the first thing that errors and don't push past it — each step
depends on the one before.

---

## Step 1 — Create the connection

```bash
snow connection add
```

Interactive. It asks for a series of values; the ones that matter:

| Prompt | What to enter |
|---|---|
| Connection name | `medallion` |
| Account identifier | `orgname-accountname` — see below |
| Username | your Snowflake login |
| Password | your password (typed by you, not stored in this repo) |
| Role | `ACCOUNTADMIN` |
| Warehouse | `WH_MEDALLION` — doesn't exist yet, that's fine |
| Database | `INSURANCE_DEMO` — doesn't exist yet, that's fine |
| Schema | leave blank |

Press Enter to skip anything else.

**Finding your account identifier.** In Snowsight, bottom-left account menu → hover your account →
**Copy account identifier**. It looks like `ABCDEFG-HI12345`. If you only have a URL like
`https://abcdefg-hi12345.snowflakecomputing.com`, the identifier is the part before
`.snowflakecomputing.com`.

Credentials land in `~/.snowflake/config.toml` with `0600` permissions. That file is outside this
repo and must never be committed.

---

## Step 2 — Test it

```bash
snow connection test -c medallion
```

Expect a table showing your account, user, role and region. If this fails, nothing after it will
work — fix it here.

Common failures:

- **`250001 Could not connect`** — account identifier is wrong. Re-copy it from Snowsight.
- **`Incorrect username or password`** — if your account has MFA, add `authenticator = "externalbrowser"`
  under `[connections.medallion]` in `~/.snowflake/config.toml`, then retry. It opens a browser to log in.
- **`Role 'ACCOUNTADMIN' not granted`** — use whatever role you do have; you only need it to create
  a warehouse.

---

## Step 3 — Build the environment

```bash
cd ~/Desktop/"Data Engineer Plan 2026"/04-Projects/snowflake-medallion
snow sql -c medallion -f sql/00_setup.sql
```

Creates the warehouse, database, four schemas, file format and stage. The last statement prints
your current warehouse, database and role — that's your confirmation.

Read the comments in that file as it runs. They explain *why* Bronze does no date parsing, which is
a real interview answer, not decoration.

---

## Step 4 — Generate the source data

```bash
python3 data/generate_data.py
```

Already run once, so the CSVs exist — but re-run it any time you want to start clean. It's seeded,
so you get identical data every time.

Expected output: 51 brokers, 5,025 rows per policy snapshot with 602 changed policies, 12,060 claims.

---

## Step 5 — Upload the CSVs to the stage

```bash
snow stage copy "data/*.csv" @INSURANCE_DEMO.BRONZE.STG_RAW -c medallion --overwrite
```

The glob **must** be quoted, or your shell expands it before `snow` sees it.

This is `PUT` under the hood — it compresses each file to `.gz` and uploads it to the internal
stage. Nothing is in a table yet; the stage is just Snowflake-managed file storage.

---

## Step 6 — Verify

```bash
snow sql -c medallion -q "LIST @INSURANCE_DEMO.BRONZE.STG_RAW;"
```

Expect four files, each with a `.gz` suffix:

```
brokers.csv.gz
claims.csv.gz
policies_snapshot_01.csv.gz
policies_snapshot_02.csv.gz
```

Four files listed means Stage 0 is done and Stage 1 (`COPY INTO`) can start.

---

## Useful afterwards

```bash
# Ad-hoc query
snow sql -c medallion -q "SELECT CURRENT_VERSION();"

# Run any script
snow sql -c medallion -f sql/01_bronze.sql

# What's on the stage
snow stage list-files @INSURANCE_DEMO.BRONZE.STG_RAW -c medallion

# Make this the default connection so you can drop -c
snow connection set-default medallion
```

**Suspend the warehouse if you step away.** `AUTO_SUSPEND = 60` handles it automatically, but it's
worth knowing the manual command:

```bash
snow sql -c medallion -q "ALTER WAREHOUSE WH_MEDALLION SUSPEND;"
```

---

## Cost

Effectively nothing. An XSMALL warehouse is 1 credit/hour, billed per-second with a 60-second
minimum, and it parks after a minute idle. This entire project — all six stages — should cost well
under a credit. Storage for ~1.4 MB of CSV is immaterial.
