# The data generator, explained

Study notes for `data/generate_data.py` — written for someone who has not used Python before.
Read this beside the code.

Second half covers the question interviewers actually ask: **how does data get into Snowflake in
real life, and how is that different from what this project does?**

---

# Part 1 — The only Python you need to read this file

There are nine ideas in the whole script. That's it.

## 1. `import` — borrow tools someone else wrote

```python
import csv
import random
from datetime import date, timedelta
from pathlib import Path
```

Python ships with a standard library. `import csv` means "give me the CSV toolkit."
`from datetime import date` means "from the datetime toolkit, just give me the `date` tool."

Nothing was installed. **Stdlib only** — that's why this runs anywhere with no setup.

## 2. Variables and constants

```python
N_BROKERS = 50
N_POLICIES = 5_000
```

A name pointing at a value. `5_000` is just `5000` — the underscore is a thousands separator for
human eyes, ignored by Python.

ALL_CAPS is a convention meaning "this is a setting, don't change it while the program runs."
Python doesn't enforce it; programmers respect it.

## 3. List — an ordered collection, written `[ ]`

```python
PRODUCTS = ["Commercial Auto", "Property", "General Liability", "Marine", "Cyber"]
```

Like a column of values. `PRODUCTS[0]` is the first one (**counting starts at 0**, not 1).

## 4. Dictionary — key/value pairs, written `{ }` ← the important one

```python
{"broker_id": "BRK0001", "broker_name": "Priya Sharma", "region": "Ontario"}
```

**Think in SQL terms and this becomes easy:**

| Python | SQL |
|---|---|
| a **dictionary** | one **row** |
| the **keys** | the **column names** |
| a **list of dictionaries** | a **table** |

That's the entire data model of this script. `brokers` is a list of dicts = a table of brokers.
Everything else is filling those in and writing them out.

## 5. Loop — do something N times

```python
for i in range(1, N_BROKERS + 1):
```

`range(1, 51)` produces 1, 2, 3 … 50. **The end value is excluded**, which is why the code says
`+ 1` to actually reach 50. This is the single most common off-by-one mistake in Python.

## 6. f-string — build text with values inside it

```python
f"BRK{i:04d}"
```

The `f` before the quote means "look inside the `{ }` and substitute." So when `i` is 7:

| Piece | Meaning | Result |
|---|---|---|
| `BRK` | literal text | `BRK` |
| `{i` | the value of `i` | `7` |
| `:04d` | format it: pad with **0**, width **4**, as an integer (**d**) | `0007` |

→ **`BRK0007`**

Same idea makes `POL000042` (`:06d`) and `CLM0001344` (`:07d`). **Zero-padding keeps IDs the same
width so they sort correctly as text** — a real data-engineering habit, not decoration.

## 7. Function — a named, reusable block

```python
def messy_date(d, defect_rate=0.02):
    ...
    return d.isoformat()
```

`def` defines it. `d` and `defect_rate` are inputs. `defect_rate=0.02` is a **default** — if the
caller doesn't supply one, it's 2%. `return` hands a value back.

Indentation is not cosmetic in Python. **The indented lines are the body of the function.** Python
uses whitespace where SQL uses `BEGIN`/`END`.

## 8. Writing a file

```python
with open(OUT / "brokers.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(brokers[0].keys()))
    w.writeheader()
    w.writerows(brokers)
```

- `with open(...) as f` — open the file, and **close it automatically** when the block ends, even
  if something crashes.
- `"w"` — write mode (overwrite).
- `csv.DictWriter` — a writer that takes **dictionaries** and turns them into CSV lines.
- `fieldnames=list(brokers[0].keys())` — look at the first row, take its keys, use them as the
  header. So the CSV columns come from the dictionary keys automatically.
- `writeheader()` then `writerows(...)` — header line, then all the data.

## 9. Randomness that repeats — the most important line in the file

```python
random.seed(42)
```

Computer randomness is **pseudo**-random: a formula that produces an unpredictable-looking
sequence from a starting number. Fix that starting number — the *seed* — and you get **the exact
same "random" sequence every single time.**

**This is why your row counts are reproducible.** Anyone can clone the repo, run the script, and
get byte-identical files: the same 602 changed policies, the same 129 orphans, the same
$1,063,516,068.75 in claims.

Without the seed, every run produces different data, your README's numbers would be wrong within a
day, and your reconciliation gate would have nothing stable to check against.

**Interview line:** *"Seeded, so the whole thing is reproducible — the control totals in my README
can actually be verified by anyone who runs it."*

The three random helpers used:

| Call | Does |
|---|---|
| `random.random()` | a decimal between 0.0 and 1.0 → `if random.random() < 0.02` means **"2% of the time"** |
| `random.choice(a_list)` | pick one item at random |
| `random.randint(1, 50)` | whole number, 1 to 50, **both ends included** (unlike `range`) |
| `random.uniform(500, 25000)` | decimal in that range |
| `random.shuffle(a_list)` | reorder in place, so defects aren't clustered at the end of the file |

---

# Part 2 — Walking the script

## Setup

```python
OUT = Path(__file__).parent
```

`__file__` is this script's own path. `.parent` is the folder holding it. So output CSVs always
land **next to the script**, no matter which directory you run it from. Small thing that prevents
a very common category of bug.

## The two defect-injector functions

These exist so defects can be sprinkled anywhere without repeating the logic.

```python
def messy_date(d, defect_rate=0.02):
    if random.random() < defect_rate:
        return random.choice(["", "N/A", "0000-00-00", "2026-13-45", "31/12/2025"])
    return d.isoformat()
```

2% of the time, return garbage instead of a real date. **Look closely at the garbage list — it is
chosen carefully:**

| Value | Why it's here |
|---|---|
| `""` | empty string, not NULL — tests the `EMPTY_FIELD_AS_NULL = FALSE` setting in Bronze |
| `N/A` | obviously text, easy case |
| `0000-00-00` | **shaped like a valid date.** Passes a regex. Passes a length check |
| `2026-13-45` | **also shaped like one.** There is no month 13 or day 45 |
| `31/12/2025` | valid date, **wrong format** — day-first instead of ISO |

Those middle two are the whole argument for validating with `TRY_TO_DATE` rather than pattern
matching. This is a scripted moment in Episode 1.

```python
def messy_case(value, rate=0.08):
    if random.random() < rate:
        return random.choice([value.upper(), value.lower(), f"  {value} "])
    return value
```

8% of the time, mangle the text: `PROPERTY`, `property`, or `"  Property "` with spaces.
**This is why 5 products become 20 spellings in Bronze**, and why Silver has to `TRIM` and
`INITCAP` to get back to 5.

## Brokers → 51 rows

```python
for i in range(1, N_BROKERS + 1):
    brokers.append({...})

brokers.append(dict(brokers[7]))
```

50 generated, then **one exact duplicate appended** — a copy of row index 7.

`dict(brokers[7])` makes a **copy**. Writing `brokers[7]` alone would append a second reference to
the *same* dictionary, so editing one would change both. Copying is deliberate.

Also `"email": "" if random.random() < 0.04 else f"broker{i}@example.com"` — ~4% blank emails.
That's Python's one-line if/else: *value-if-true* `if` *condition* `else` *value-if-false*.

> **50 + 1 duplicate = 51 rows.** ✅ Matches Bronze.

## Policies → two snapshots of 5,025

5,000 policies are built once. Then `write_snapshot` is called **twice** against the same list.

```python
def write_snapshot(rows, extract_date, filename):
    out = []
    for r in rows:
        row = dict(r)
        row["extract_date"] = extract_date
        out.append(row)
    for _ in range(len(out) // 200):
        out.append(dict(random.choice(out)))
    random.shuffle(out)
```

- Copies each row and stamps it with `extract_date` — **this column is what makes two snapshots
  distinguishable** in Bronze, and it is the reason Silver dedupes on `policy_id + extract_date`
  rather than `policy_id` alone.
- `len(out) // 200` — `//` is **integer division**. 5000 ÷ 200 = **25** duplicate rows (0.5%).
- `_` as a variable name means *"I need to loop 25 times but don't care about the counter."*
- Shuffle so duplicates aren't all at the bottom of the file.

> **5,000 + 25 = 5,025 rows per snapshot. Two snapshots = 10,050.** ✅ Matches Bronze.

### The bit that makes SCD Type 2 possible

```python
n1 = write_snapshot(policies, "2026-08-01", "policies_snapshot_01.csv")

for p in policies:
    if random.random() < 0.12:
        p["status"] = random.choice(STATUSES)
        p["premium"] = round(p["premium"] * random.uniform(0.9, 1.25), 2)
        changed += 1

n2 = write_snapshot(policies, "2026-08-15", "policies_snapshot_02.csv")
```

Snapshot 1 is written first. Then **12% of the policies are edited in place** — status changes,
premium moves between −10% and +25%. Then snapshot 2 is written from the *same, now-modified* list.

This is exactly what a real daily extract looks like: the same policies, exported again two weeks
later, some of them different.

> With seed 42, 12% of 5,000 lands on **602 changed policies** — the number your Gold MERGE closes
> and reopens. That is where 602 comes from.

## Claims → 12,060 rows

```python
if random.random() < 0.01:
    pid = f"POL{random.randint(900_000, 999_999):06d}"
else:
    pid = f"POL{random.randint(1, N_POLICIES):06d}"
```

1% get an ID from the 900,000+ block. Real policies only go up to `POL005000`, so these
**reference nothing** — the 129 orphan foreign keys.

```python
amount = round(random.uniform(100, 80_000), 2)
if random.random() < 0.015:
    amount = random.choice([0, -1 * amount, 9_999_999.99])
```

Normally $100–$80,000. Then 1.5% get replaced by one of three bad values:

| Bad value | What it represents | Pipeline's answer |
|---|---|---|
| `0` | a claim that pays nothing | **Quarantine** — not a real claim |
| `-1 * amount` | negative payout | **Quarantine** |
| `9_999_999.99` | **the same maximum, repeatedly** | **Keep and flag** — a sentinel |

The third is the interesting one. Because it's a *fixed literal*, every one of them is identical.
Real catastrophe claims vary; an identical repeated maximum is a placeholder some upstream system
writes when it doesn't know the true amount. Dropping them erases the exposure; trusting them
invents it. So they're flagged and surfaced, and a human decides.

```python
for _ in range(60):
    claims.append(dict(random.choice(claims)))
```

60 exact duplicate claims.

> **12,000 + 60 = 12,060 rows.** ✅ Matches Bronze.

## The print block

```python
print(f"brokers.csv    {len(brokers):>7,} rows  (1 duplicate)")
```

`:>7,` = right-align in 7 characters, with thousand separators → `     51`.

**This output is your first reconciliation.** The generator states what it produced; Bronze must
agree. That habit — declare expected, then verify — runs through the whole project.

---

# Part 3 — Every defect, in one table

| Defect | Where planted | Rate | Count | Handled in |
|---|---|---|---|---|
| Duplicate broker | `brokers.append(dict(brokers[7]))` | 1 row | 1 | Silver dedupe |
| Blank email | `"" if random.random() < 0.04` | 4% | ~2 | Silver |
| Mangled casing / whitespace | `messy_case()` | 8% | 20 product spellings | Silver `TRIM` + `INITCAP` |
| Malformed dates | `messy_date()` | 2% | 248 | Silver `TRY_TO_DATE` |
| Duplicate policies (in-extract) | `len(out) // 200` | 0.5% | 25 per file | Silver `ROW_NUMBER` |
| **Changed policies (signal, not defect)** | 12% mutation loop | 12% | **602** | **Gold SCD2 MERGE** |
| Orphan `policy_id` | 900,000+ block | 1% | **129** | Kept + flagged → key `-1` |
| Zero / negative amounts | `[0, -amount, ...]` | part of 1.5% | 113 | **Quarantined** |
| Sentinel `9,999,999.99` | fixed literal | part of 1.5% | 59 | Kept + flagged |
| Duplicate claims | explicit loop of 60 | 60 rows | 60 | Silver dedupe |

**The row-count arithmetic, which you should be able to derive from the code on demand:**

```
brokers    50 + 1  dup      = 51
policies   5,000 + 25 dup   = 5,025  ×2 snapshots = 10,050
claims     12,000 + 60 dup  = 12,060
```

---

# Part 4 — How to talk about this honestly

You **ran** this generator; you did not write it from scratch. The accurate framing is about the
*design decisions*, which you can defend completely:

> *"The source data is synthetic — I generated it with a seeded Python script so the whole project
> is reproducible. The defects are deliberate: duplicates, malformed dates that are shaped like
> valid dates, orphan foreign keys, and sentinel amounts. Clean data would have meant every layer
> was doing nothing."*

Then be ready for **"why those specific defects?"** — that's the real question, and Part 3 is your
answer.

**To make it genuinely yours, change it.** Suggested exercises, easiest first:

1. Change `N_CLAIMS` to 20,000. Re-run. Predict the new row count *before* you look.
2. Change the orphan rate from `0.01` to `0.03`. Predict the new orphan count. Verify.
3. Add a sixth product to `PRODUCTS`. Work out what breaks downstream in Silver's conforming step.
4. Add a new defect: a `broker_id` on a policy that doesn't exist — a second orphan relationship.
5. Change `random.seed(42)` to `random.seed(1)` and watch **every documented number change.** Then
   change it back. That single experiment teaches what seeding means better than any explanation.

Do #1 and #5 and you will never be confused about seeding again.

---

# Part 5 — How data really gets into Snowflake

This is the scope question, and it's a fair one to be asked.

## What this project does

```
generate_data.py  →  CSVs on the laptop  →  PUT  →  INTERNAL STAGE  →  COPY INTO  →  BRONZE
```

`STG_RAW` is an **internal named stage** — storage Snowflake manages *inside your account*. You
pushed files up to it with `PUT` from your machine, by hand.

## What production does

The difference is **only the first two arrows.** Everything from the stage onward is identical.

```
source system  →  cloud bucket (S3 / GCS / Azure)  →  EXTERNAL STAGE  →  COPY INTO  →  BRONZE
                                                          ↑
                                              triggered automatically by Snowpipe
```

An **external stage** is not storage — it's a *pointer* to a bucket you already own, plus a
`STORAGE INTEGRATION` holding the cloud credentials so no secrets sit in the SQL.

```sql
CREATE STAGE ext_claims
  URL = 'gcs://insurance-landing/claims/'
  STORAGE_INTEGRATION = gcs_int
  FILE_FORMAT = FF_CSV;
```

Your `COPY INTO` barely changes. **That's the point worth making in an interview.**

## The main ingestion patterns, and when each is used

| Pattern | How it works | Latency | Used when |
|---|---|---|---|
| **`PUT` + `COPY INTO`** ← *this project* | Manual upload to an internal stage | Manual | Dev, one-offs, small loads |
| **External stage + scheduled `COPY INTO`** | Files land in a bucket; a task copies on a schedule | Minutes–hours | Standard batch |
| **Snowpipe (auto-ingest)** | Bucket event → notification queue → Snowflake copies automatically. Serverless | ~1 minute | Continuous file arrival |
| **Snowpipe Streaming** | Rows pushed via SDK, no files at all | Seconds | Genuine real-time |
| **Kafka connector** | Topics → tables | Seconds | Event streaming shops |
| **Managed connectors** (Fivetran, Airbyte) | Prebuilt SaaS/DB connectors, handle schema drift | Minutes–hours | Salesforce, Workday, Postgres |
| **CDC / log replication** | Reads the source DB's transaction log | Seconds–minutes | Mirroring an operational database |
| **External tables / Iceberg** | Query files in the bucket **without loading** | Query-time | Huge, rarely-touched data |
| **Data Sharing / Marketplace** | No copy at all — read another account's data live | Instant | Vendor and partner data |

**Where Python actually appears in real ingestion** — worth knowing, since it's on your resume:

- Calling an API and writing the response to cloud storage (`requests` + a cloud SDK)
- `snowflake-connector-python` to run SQL from a script
- `write_pandas()` to push a dataframe straight into a table
- Snowpark for transformations that run *inside* Snowflake
- Airflow DAGs — which are themselves written in Python

## The honest answer when asked

> *"In this build I used an internal stage and pushed the files up with `PUT`, because the source
> is synthetic and generated locally — it's a controlled dataset so the reconciliation numbers stay
> reproducible. In production the same `COPY INTO` runs against an external stage pointing at S3 or
> GCS, and instead of running it by hand you'd let Snowpipe auto-ingest fire it on a bucket
> notification. What changes is where the stage points and what triggers the load. The Bronze
> table, the file format, and the `COPY INTO` are the same."*

That answer is true, shows you know the production path, and doesn't claim you built it.

**Natural next step:** your Snowflake account runs on **GCP (us-east4)**, so a GCS external stage
is the obvious follow-on — and that is exactly what the empty `04-Projects/gcp-pipeline/` is for.
Same pipeline, real external ingestion, and it makes the Python bullet true.
