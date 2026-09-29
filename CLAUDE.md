# snowflake-medallion

*Context for Claude Code. Part of `~/Desktop/Career-Hub/`.*

## What this is

Bronze → Silver → Gold pipeline in Snowflake for P&C policy, claims and broker data. Raw CSV lands untyped, gets conformed and deduplicated, and is served as a dimensional model with an SCD Type 2 policy dimension.

**Stack:** Snowflake · SQL · Python · Airflow · GitHub Actions
**GitHub:** public

## Running it

**Read `CONTINUE.md` first.** Snowflake connection name is `medallion`; credentials are in `~/Library/Application Support/snowflake/config.toml`, deliberately not in this repo. Notes board: https://claude.ai/artifact/D7G4jnNkCtQsbYEHNGsRqW

## What it backs on the resume

The Tokio Marine row — medallion architecture, SCD2, and `automated validation and reconciliation`, your most-repeated resume claim.

## Know this before working on it

**Stages 0–3 verified. Stage 4 run but never verified. Stage 5 — the reconciliation gate — has never been run**, and the GitHub description already claims it. Full rebuild from Stage 0 first; the Stage 4/5 demos left extra rows in Bronze.

## House rules

- One instruction at a time. Write it and explain *why*; Mahesh runs it and reports back.
- Compute expected numbers from the source **before** running anything. That habit caught a silent 0-row load on the Snowflake build.
- Don't commit secrets. `.env` files stay local and gitignored, always.
- Portfolio root has `README.md` (structure), `PROJECTS.md` (this project in context) and `VOICE-GUIDE.md` (how anything written here gets worded).
