# Recording notes — one short video per stage

Aim for **4–7 minutes per stage**. Long enough to show something real, short enough that people
finish it. Seven stages gives you a series, and a series is far more useful to you than one long
video nobody watches to the end.

**Format that works:** state the problem → run the thing → show the result → say why it matters.
Skip the intro music and the "hey guys." Open on the problem.

**Run everything in Snowsight**, not the terminal, for recording. Results render as tables people
can actually read on screen. Keep the CLI for the setup video only.

---

## The single most important habit

**Say why, not what.** "I'm creating a table with VARCHAR columns" is narration anyone can read off
the screen. "Every column is VARCHAR because if premium were NUMBER, one row containing 'N/A' would
fail the whole file — Bronze's job is to get data in the building, not to judge it" is the reason
someone watches.

Every `WORTH RECORDING` block in the SQL has that reasoning written into the comments. Read it,
then say it in your own words.

---

## Per stage

### Stage 0 — Setup *(3–4 min)*
Snowflake CLI, connection, warehouse, database, four schemas, stage, upload.

Worth mentioning: `AUTO_SUSPEND = 60` and why (per-second billing, 60-second minimum). And the
username-is-not-your-email trap that cost us — small, human, and genuinely useful to anyone
following along.

### Stage 1 — Bronze *(5–7 min)*
Three moments, all marked in `01_bronze.sql`:

1. **Everything landed** — counts matching what the generator printed. Your first reconciliation,
   done by eye.
2. **Bronze keeps the mess** — malformed dates, mangled casing, duplicate claims, orphan policy
   IDs, absurd amounts. All sitting there, nothing failed. That's the layer working correctly, and
   it sets up Stage 2 perfectly.
3. **Load idempotence** — rerun the `COPY INTO`, get zero rows. Snowflake tracks loaded files for
   64 days. This is the money shot of the episode: it's a real interview question and most people
   can't answer it.

### Stage 2 — Silver *(5–7 min)*
Dedupe with `ROW_NUMBER()`, `TRY_CAST` vs `CAST`, quarantining bad rows instead of dropping them.
End on the quarantine table — "we didn't throw anything away, we set it aside and counted it."

### Stage 3 — Gold *(6–8 min, the flagship)*
Say the **grain** out loud before writing any DDL: one row of `fact_claim` is one claim.

Then the demo that carries the whole series — change a policy's status in source, rerun, show the
same policy now has two rows: one closed with a `valid_to`, one current. **Have both queries ready
before you hit record** so the before/after is tight.

### Stage 4 — Streams and Tasks *(5 min)*
Run the pipeline twice with no new data, show nothing moves. Then insert one row and show only that
row promotes.

### Stage 5 — Reconciliation gate *(4–5 min)*
Deliberately corrupt a Silver row, run the check, watch the pipeline fail. Failing on purpose is
more convincing than passing.

### Stage 6 — Performance and cost *(5–7 min)*
Query profile, XSMALL vs SMALL on the same query, `WAREHOUSE_METERING_HISTORY`. Close the series
with what the whole project cost in credits — people love that number, and it shows you think about
spend.

---

## Practical

- **1080p, and zoom your editor and Snowsight to ~130%.** Default font sizes are unreadable on a
  phone, which is where most of this gets watched.
- **Dark mode in Snowsight**, easier on the eye in video.
- **Have queries pre-written** in the worksheet, run them live. Don't type SQL on camera.
- **Leave the mistakes in.** A rerun that returns zero rows because you forgot `FORCE = TRUE` is
  more instructive than a clean take, and far more watchable.
- **Screenshot the SCD2 before/after** while recording Stage 3 — it goes in the repo README too.

---

## Why this is worth the time

Two things, beyond the views.

**It forces real understanding.** You cannot narrate why Bronze is untyped without actually knowing
why. Explaining out loud is the fastest way to find the gaps, and the gaps are exactly what an
interviewer would have found instead.

**It's evidence.** "I built a Snowflake medallion pipeline" is a claim. A repo plus a video walking
through your own SCD2 implementation is proof — and it's the kind of proof that makes the Google
Cloud line on your resume, which has no employer row behind it, stop being a gap.
