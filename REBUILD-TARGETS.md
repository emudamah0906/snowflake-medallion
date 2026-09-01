# Rebuild targets — computed from the source CSVs, 1 Sep 2026

Every number below was recomputed from `data/*.csv` in Python before the rebuild started, not
copied out of the old notes. The old notes were right. Both agree.

Use this to check each stage as you run it. If a number comes back different, stop and find out
why before moving to the next file.

---

## Source files, as they sit on disk

| File | Data rows |
|---|---|
| `brokers.csv` | 51 |
| `policies_snapshot_01.csv` | 5,025 |
| `policies_snapshot_02.csv` | 5,025 |
| `claims.csv` | 12,060 |

---

## Stage 1 — Bronze

Row counts: brokers **51**, policies **10,050**, claims **12,060**.

The five defect counts:

| Check | Expected |
|---|---|
| Malformed `start_date` | **248** |
| Distinct product spellings | **20** (5 real products) |
| Duplicate `claim_id` | **60**, each appearing exactly twice |
| Suspect amounts (`<= 0` or `> 1,000,000`) | **172** |
| Orphan claims (policy doesn't exist) | **129** |

The 248 malformed dates break down like this. If the total is right but the split is wrong, the
load read the file differently than expected:

| Value | Rows |
|---|---|
| `0000-00-00` | 60 |
| `N/A` | 50 |
| `` (empty string) | 49 |
| `31/12/2025` | 48 |
| `2026-13-45` | 41 |

Two of those look like real dates to a regex. Only a calendar parse rejects them, which is why
the check uses `TRY_TO_DATE` and not a pattern match.

---

## Stage 2 — Silver

Row counts: brokers **50**, policies **10,000** (5,000 per extract date), claims **11,887**.

Quarantined: **113** claims, all for `amount is zero or negative`.

Kept but flagged: **59** claims with `amount = 9,999,999.99`. That value is a sentinel, meaning a
placeholder written when the real amount was unknown. It is a real row with a bad number, so it
stays in Silver with `is_amount_outlier` set rather than being thrown away.

Control totals:

| Measure | Bronze (all raw rows) | Silver (deduplicated) |
|---|---|---|
| Premium | 127,861,219.71 | **127,248,528.88** |
| Claim amount | 1,063,624,699.09 | **1,063,516,068.75** |

The two columns are supposed to differ. The gap is the duplicate rows and the quarantined claims
coming out. Premium drops by 612,690.83 across the 50 duplicate policy rows. Claim amount drops
by 108,630.34 across the 60 duplicate claims and the 113 quarantined ones.

The three reconciliation checks at step 5 should each return `TRUE`. That is the statement that
every Bronze row is accounted for as either promoted, quarantined, or removed as a duplicate.

---

## Stage 3 — Gold

| Table | Expected |
|---|---|
| `DIM_BROKER` | **51** (50 real brokers plus the unknown member) |
| `DIM_DATE` | **1,462** |
| `DIM_POLICY` | **5,603** = 5,001 current + 602 closed |
| `FACT_CLAIM` | **11,887** |

**602** is the number of policies whose status or premium changed between the two snapshots. It
was recomputed by diffing the snapshots directly. The SCD Type 2 MERGE has to close exactly that
many old rows and open exactly that many new ones, in one statement.

`FACT_CLAIM` landing on 11,887, the same as Silver, is the proof that matters. The join from claim
to policy is version-aware, meaning it picks the policy row whose date range covers the claim date.
If that join were wrong, a claim would match more than one policy version and the count would come
back above 11,887. Matching Silver exactly means the grain held at one row per claim.

**Still to capture at heading 8:** the SCD2 before/after screenshot. One policy, two rows, one
closed and one current. This is the strongest single piece of evidence in the project and it is
still not in the README.

---

## Stage 4 — Streams and tasks

After the demo inserts, expect **11,889 / 11,889 / 114**. This was run once but never confirmed,
so treat the numbers as unproven until you see them.

---

## Stage 5 — Reconciliation gate

12 checks, all `PASSED`. Then break something on purpose and watch the gate `RAISE` instead of
letting the load through.

Sections 1 to 6 stand on their own. Sections 7 to 9 rewire the task tree and need Stage 4 working.

---

## Why we are not running `99_reset.sql`

`99_reset.sql` drops the whole database. The stage holding the 4 CSVs lives inside that database,
so a reset deletes the files and they have to be uploaded again.

The rebuild does not need that. Every table in stages 1 to 3 is `CREATE OR REPLACE`, which also
resets the `COPY INTO` load history so the same files load again rather than being skipped as
already-loaded. That is enough to clear the extra rows the Stage 4 and 5 demos left behind.

Keep `99_reset.sql` for the day you want to record Episode 0 from an empty account.
