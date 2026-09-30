# Handoff prompt: paste this into a new session

---

I'm building a production-style data pipeline on Snowflake, dbt and Azure, and recording every
phase as a short video for LinkedIn. Pick up where the last session (29 Sep 2026) left off.

## Where everything is

- **Project:** `~/Desktop/Career-Hub/Projects/snowflake-medallion/` (git repo, **public** on GitHub
  at `emudamah0906/snowflake-medallion`, branch `main`)
- **Career root:** `~/Desktop/Career-Hub/`. Read `VOICE-GUIDE.md` there for how anything spoken or
  written gets worded.
- **Read in this project first:** `CLAUDE.md`, then this file, then `recording/` for the phase we're
  on.
- **My notes board:** https://claude.ai/artifact/D7G4jnNkCtQsbYEHNGsRqW — stage/phase status and my
  own notes, in its database collection `board` (doc `general`). **Read it with the ArtifactData
  tool at the start of every session.** When a phase changes status or you learn a real number,
  update it or tell me to.

## The pivot — read this before anything else

Up to 12 Aug this was a single-account Snowflake medallion in hand-written SQL: seven **stages**,
`INSURANCE_DEMO` with BRONZE/SILVER/GOLD/OPS, everything run as ACCOUNTADMIN.

On **28 Sep it changed shape.** It is now a production-style platform, recorded in **phases**:

- **Azure** (ADLS Gen2) for landing, provisioned with **Terraform**
- **Snowflake on Azure canadacentral** — a new trial. The old GCP trial is left to expire.
- **dbt Core** owns Silver and Gold, replacing the hand-written `sql/02`–`sql/05`
- **Airflow / Cosmos** for orchestration, **GitHub Actions** for CI
- Least-privilege roles and a service user instead of ACCOUNTADMIN-and-a-password

"Stage" now means the old SQL numbering. "Phase" means a recorded video milestone. They are not the
same thing and mixing them up will confuse everyone.

## Snowflake

- Snowflake CLI `snow`, connection **`medallion`**
- **New Enterprise trial on Azure `canadacentral`, started 28 Sep 2026.** Check the days remaining
  at the start of each session — the old GCP trial expires around 21 Oct and is being abandoned.
- Databases **`RAW`** (Bronze) and **`ANALYTICS`** (Silver + Gold, built by dbt)
- Warehouses **`WH_LOAD`** and **`WH_TRANSFORM`** (XS, auto_suspend 60, both on `RM_MEDALLION`)
- Roles **`LOADER`** / **`TRANSFORMER`** / **`REPORTER`**, service user **`SVC_DBT`** (key pair, no
  password)
- Config at `~/Library/Application Support/snowflake/config.toml`. Private key at
  `~/.snowflake/keys/`, outside the repo. `.env` holds the env vars and is gitignored;
  `.env.example` shows what to set.

## Status

**Phase 1 — DONE and committed (`9aa7242`, pushed 29 Sep).**

`platform/snowflake/00_setup.sql` sections 1–6, all verified with a `SHOW` after each:
2 warehouses · 30-credit monthly cap (notify 50/75, suspend at 100) · RAW + ANALYTICS ·
grants LOADER 8 / TRANSFORMER 6 / REPORTER 2 / future 1 · `SVC_DBT` is TYPE SERVICE with no
password and a matching key fingerprint · dbt-core 1.11.15 + dbt-snowflake 1.11.6 in `.venv` ·
`dbt debug` passes as SVC_DBT / TRANSFORMER / WH_TRANSFORM / ANALYTICS.DEV.

Recording script written: `recording/phase-1-foundation.md`. **The video is not recorded yet.**

**Phase 2 — not started.** "The data lands in Azure and loads itself into Bronze."

Carried over from Phase 1, still to do:
- Record the Phase 1 video
- Point the `az` CLI at the new Azure account
- A $5 budget alert on the Azure subscription

Phase 2 proper:
1. **Terraform** — resource group, ADLS Gen2 storage account, container
2. **Snowflake → Azure** — storage integration (needs Azure tenant consent), external stage, file
   format
3. **Snowpipe with `AUTO_INGEST`** via an Azure Event Grid notification integration
4. Upload the CSVs to ADLS and watch them appear in `RAW.INSURANCE` with nothing run by hand

Tooling is already installed and working: az 2.85.0 · terraform 1.15.5 · dbt 1.11.15 · snow 3.17.1.

## Open question to settle early

**What happens to `sql/01`–`sql/05`?** They are the pre-pivot, hand-written medallion — Bronze load,
Silver transforms, Gold star schema with an SCD2 MERGE, streams and tasks, and the reconciliation
gate. Under the new architecture dbt owns Silver and Gold, so `02`–`05` are superseded.

Three options, none obviously right:
- Keep them in `sql/legacy/` as "how I did it before dbt" — honest, and the SCD2 MERGE is good
  interview material
- Delete them — cleaner repo, loses the evidence
- Port the reconciliation gate into dbt tests and drop the rest

**Decide this before Phase 3**, or the repo ends up with two contradictory pipelines and no
explanation.

## Honesty items outstanding

- **The public GitHub description claims the reconciliation gate.** It has never been run, in either
  architecture. Either run it or reword the description.
- The `README.md` status list still reflects the old stage numbering.

## Expected numbers (source data is unchanged)

Recomputed from `data/*.csv` on 1 Sep — see `REBUILD-TARGETS.md`. Source files: 51 brokers,
5,025 + 5,025 policy rows, 12,060 claims.

| Layer | Expect |
|---|---|
| Bronze | 51 · 10,050 · 12,060. Defects 248 / 20 / 60 / 172 / 129 |
| Silver | 50 · 10,000 · 11,887. 113 quarantined. `reconciled = TRUE` ×3 |
| Gold | dim_broker 51 · dim_date 1,462 · dim_policy 5,603 (5,001 current + 602 closed) · fact_claim 11,887 (128 on policy key -1) |

These were verified on the old architecture on 12 Aug. They are the targets dbt has to hit too —
if the dbt models land different numbers, the models are wrong, not the targets.

## How I want to work

- **I run the SQL, not you.** Write it and explain it. I run it and report back. Git is yours.
- **One instruction at a time.** One action, what to expect, why. Then wait.
- **Work out the expected numbers before I run anything.** This caught a silent 0-row load.
- Explain *why*. I need to defend all of this in interviews.
- I'm recording each phase. Flag the moments worth recording.
- Screenshots of the results grid are easier for me than typing numbers out.
- Re-paste each SQL file fresh from the repo into Snowsight — it keeps its own copy.

## Gotchas already hit

- **Hand-shortening a `CREATE` picks up Snowflake's defaults** (10-minute auto-suspend, a cap with
  no limit) and `IF NOT EXISTS` then skips your fix on a re-run. Drop and rebuild. End every step
  with a `SHOW`.
- **No `&` in SQL run through `snow`** — it parses `&NAME` as a template variable. `'P&C insurance'`
  fails with `'C' is undefined`.
- **The Snowflake username is not the login email.** Wrong username reports as "Incorrect username
  or password".
- **Snowsight Workspaces keeps its OWN copy of the SQL file.** Editing `sql/*.sql` on the Mac does
  not change the browser, and vice versa. Paste whole statements — hand-retyping one fragment
  produced a doubled `[[` and an extra `)` and cost a round trip.
- **`PATTERN` is anchored to the entire filename.** A near-miss matches *zero* files, not some.
- **"Copy executed with 0 files processed" is ambiguous** — either nothing matched the pattern (a
  bug) or every file was already loaded (correct idempotence). Check the row count to tell them
  apart.
- **`ROWS` is a Snowflake reserved word** — it can't be a column alias without quoting.
- **`TRY_TO_NUMBER(x)` defaults to `NUMBER(38,0)` and silently rounds.** Always
  `TRY_TO_DECIMAL(x, 38, 2)` for money.
- **dbt 1.12 install fails on this Mac** with an SSL certificate error while fetching an extra
  parser. Pinned to 1.11.15 in `requirements.txt`, and CI uses the same pins.
- Snowsight's context picker can sit on the wrong warehouse even though the script says
  `USE WAREHOUSE`. Check the top-right bar.
