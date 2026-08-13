# Handoff prompt — paste this into a new session

---

I'm building a Snowflake medallion pipeline as a portfolio project. Pick up where the last session
left off.

## Where everything is

- **Project:** `~/Desktop/Data Engineer Plan 2026/04-Projects/snowflake-medallion/` (git repo, 4 commits)
- **Career plan root:** `~/Desktop/Data Engineer Plan 2026/`
  - `00-Master-Resume/` — master resume + `build_resume.js` + `PROFILE-CONSISTENCY.md`
  - `02-Study-Materials/Snowflake/WEEK-01.md` — the 8-stage build plan for this project
  - `03-Interview-Materials/` — `STUDY_PLAN.md`, `HINDUJA_DOMAIN_BRIEF.md`
  - `04-Projects/` — this project, plus `gcp-pipeline/` (not started)

Read `README.md`, `SETUP.md`, `RECORDING.md` and `WEEK-01.md` in the project before doing anything.

## Snowflake

- Snowflake CLI `snow` 3.17.1, connection **`medallion`** is the default (no `-c` needed)
- Account `<your-account-locator>` · user `<YOUR_SNOWFLAKE_USER>` · ACCOUNTADMIN · Enterprise · GCP us-east4
- Database `INSURANCE_DEMO`, schemas `BRONZE` / `SILVER` / `GOLD` / `OPS`, warehouse `WH_MEDALLION`
  (XSMALL, AUTO_SUSPEND 60)
- Config at `~/Library/Application Support/snowflake/config.toml` (macOS path, not `~/.snowflake/`)

## Status

- **Stage 0 — DONE.** Environment built, 4 CSVs generated and staged in `@BRONZE.STG_RAW`.
- **Stage 1 — DONE and verified (2026-08-12).** Bronze holds 51 brokers, 10,050 policies
  (two snapshots), 12,060 claims. Every defect count matched the source exactly: 248 malformed
  start_dates, 20 product spellings, 60 duplicate claim_ids, 172 suspect amounts, 129 orphans.
  Reran the claims `COPY INTO` — 0 files processed, count unchanged at 12,060. Idempotence proven.
- **Stage 2 — DONE and verified (2026-08-12).** SILVER holds 50 brokers, 10,000 policy-snapshots
  (5,000 per extract date), 11,887 claims. 113 claims quarantined in `OPS.QUARANTINE` for
  zero/negative amounts. Step 5 reconciliation returned `TRUE` on all three tables — every Bronze
  row accounted for as Silver, quarantined, or removed duplicate. Products 20 → 5, regions 12 → 5.
  Silver totals: premium **127,248,528.88**, claim amount **1,063,516,068.75**.
- **Stage 3 — DONE and verified (2026-08-12).** GOLD holds `DIM_BROKER` 51, `DIM_DATE` 1,462,
  `DIM_POLICY` **5,603** (5,001 current + **602 closed**), `FACT_CLAIM` **11,887**. The SCD Type 2
  MERGE closed and reopened exactly 602 changed policies in one statement. `FACT_CLAIM` matching
  Silver's 11,887 exactly proves the version-aware date-range join did not fan out — grain holds at
  one row per claim.
- **Stage 4 — BUILT AND RUN, NOT VERIFIED.** `sql/04_streams_tasks.sql`. Append-only streams on all
  three Bronze tables, a four-task tree for the claims path. The demo output was never reported
  back, so unlike Stages 1–3 there is no confirmation the counts landed at 11,889 / 11,889 / 114.
  **Re-verify before building on it.**
- **Stage 5 — SQL WRITTEN, NOT RUN.** `sql/05_reconciliation.sql`. Two stored procedures, 12 checks.
  Sections 1–6 stand alone and do not need Stage 4's tasks; sections 7–9 rewire the task tree and
  do.
- **Stages 6–7 — not started.**

**Everything suspended 2026-08-12** to stop credit burn — task tree root suspended, both warehouses
suspended. Trial stood at **$397 of $400 with 70 days left**, so four stages cost roughly $3.

**Next action — a FULL REBUILD from Stage 0, then continue.**

The Stage 4 and Stage 5 demos inserted up to 5 extra claims into `BRONZE.RAW_CLAIMS`, so counts
would read 12,065 rather than the documented 12,060. Rebuilding restores the exact numbers before
recording. Every table is `CREATE OR REPLACE`, which also resets COPY INTO load history so the
files reload rather than being skipped as already-loaded.

1. **`00_setup.sql`** — top to bottom. Safe to re-run.
2. **`01_bronze.sql`** — expect 51 · 10,050 · 12,060, defects 248/20/60/172/129.
3. **`02_silver.sql`** — expect 50 · 10,000 · 11,887, 113 quarantined, `reconciled = TRUE` ×3.
4. **`03_gold.sql`** — expect 51 · 1,462 · 5,603 (5,001 current + 602 closed) · 11,887.
   **Capture the SCD2 screenshot at heading 8 this time.**
5. **`04_streams_tasks.sql`** — verify sections 8 and 9 properly this round.
6. **`05_reconciliation.sql`** — 12 checks PASSED, then break it and watch the gate RAISE.
7. Then Stage 6 (performance and cost) and Stage 7 (ship it).

**Re-paste every file fresh from the repo into Snowsight.** All six had their comments rewritten
2026-08-13 — shorter, plainer, expected values on the heading line for reading mid-take. The SQL
is byte-identical to what was verified, only comments changed. Snowsight keeps its own copies, so
the browser still has the old versions.

**Replacing the Bronze tables makes the Stage 4 streams stale.** Expected — Stage 4 recreates them
with `CREATE OR REPLACE STREAM`. Don't panic if a stream errors before you get there.

**`SCRIPT.md`** is the recording script: spoken lines plus stage directions, episodes 0–3 fully
written, 4–7 outlined. The deep reasoning moved there from the SQL comments.

**Still outstanding from Stage 3:** capture the SCD2 before/after screenshot (heading 8 of
`03_gold.sql` — one policy, two rows, one closed and one current) and put it in the README. It is
the strongest single piece of evidence in the project and it is not yet captured.

## The stages

0 setup · 1 Bronze · 2 Silver · 3 Gold (star schema + SCD2) · 4 Streams/Tasks · 5 reconciliation
gate · 6 performance and cost · 7 ship it

## Why this project exists

It's built to defend the Tokio Marine row on my resume, bullet by bullet:

| Resume bullet | Stage |
|---|---|
| ELT into Snowflake with Python; policy, claims, broker data | 1 |
| Medallion architecture, conformed dimensional models in Gold | 1–3 |
| Validation and reconciliation on control totals, blocking promotion on variance | 5 |
| Warehouse sizing and query tuning for credit consumption | 6 |

Source data is synthetic, generated by `data/generate_data.py` (stdlib, seeded), with deliberate
defects: duplicates, malformed dates, inconsistent casing, orphan FKs, bad amounts. Policies arrive
as **two dated snapshots** with 602 changed policies — that's what exercises SCD Type 2 at Stage 3.

## How I want to work

- **I run the SQL, not you.** Write it and explain it; I execute in Snowsight and report back. I
  want the hands-on experience — don't run things against my account for me.
- I'm **recording each stage as a short video**, so flag the moments worth demoing. See
  `RECORDING.md`.
- Explain *why*, not just what. I need to defend this in interviews.
- **Act as a coach. One instruction at a time.** I have 6 years of ETL behind me on Oracle and SQL
  Server, so SQL itself is familiar — it's the *Snowflake* concepts that are new, and this is my
  first time doing it hands-on. Multi-part answers with three things at once lose me. Give me one
  action, let me do it, then the next.
- **Compute the expected numbers from the source CSVs before I run anything.** Having a real target
  to check against has been the single most useful thing — it turns "looks fine" into a real check,
  and it caught a silent 0-row load.
- I work in the **Snowsight Workspaces** UI, running statement by statement with ⌘+Enter. Screenshots
  of the results grid are easier for me than transcribing numbers — ask for those.

## Gotchas already hit

- **No `&` in SQL run through `snow`** — it parses `&NAME` as a template variable. `'P&C insurance'`
  fails with `'C' is undefined`.
- **Snowflake username is not the login email** — it's `<YOUR_SNOWFLAKE_USER>`, not `<your-login-email>`.
  Wrong username reports as "Incorrect username or password".
- First run of `00_setup.sql` needed `--database SNOWFLAKE` because `INSURANCE_DEMO` didn't exist yet.
- **Snowsight Workspaces keeps its OWN copy of the SQL file.** Editing `sql/*.sql` on the Mac does
  *not* change what's open in the browser, and vice versa. When a fix is needed, paste the whole
  statement in — hand-retyping one fragment produced a doubled `[[` and an extra `)` and cost a
  round trip. Re-paste the file from the repo at the start of each stage.
- **`PATTERN` is anchored to the entire filename.** A near-miss matches *zero* files, not some. The
  `.gz`-only pattern silently landed 0 policy rows; it's now `'.*policies_snapshot_.*[.]csv([.]gz)?'`
  which tolerates both.
- **"Copy executed with 0 files processed" is ambiguous** — it means either *nothing matched the
  pattern* (a bug) or *every file was already loaded* (correct idempotence). Check the table's row
  count to tell them apart.
- **`ROWS` is a Snowflake reserved word** — it can't be used as a column alias without quoting.
- **`TRY_TO_NUMBER(x)` defaults to `NUMBER(38,0)` and silently rounds.** Always
  `TRY_TO_DECIMAL(x, 38, 2)` for money, or control totals drift by hundreds of dollars.
- The Snowsight context picker can sit on `COMPUTE_WH` even though the script says
  `USE WAREHOUSE WH_MEDALLION`. Check the top-right bar — Stage 6's cost comparison needs
  `WH_MEDALLION`.

---
