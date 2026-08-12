"""
Generate synthetic P&C insurance source data for the medallion pipeline.

Deliberately messy: duplicates, nulls, malformed dates, inconsistent casing,
orphan foreign keys and out-of-range amounts. Every defect here exists so a
downstream layer has to deal with it.

Two policy snapshots are produced (a "daily extract" pattern). Between them some
policies change status or premium — that is what exercises SCD Type 2 in Gold.

Stdlib only. Run:  python3 generate_data.py
"""

import csv
import random
from datetime import date, timedelta
from pathlib import Path

random.seed(42)  # reproducible — reviewers can diff runs

OUT = Path(__file__).parent
N_BROKERS = 50
N_POLICIES = 5_000
N_CLAIMS = 12_000

PRODUCTS = ["Commercial Auto", "Property", "General Liability", "Marine", "Cyber"]
REGIONS = ["Ontario", "Quebec", "British Columbia", "Alberta", "Atlantic"]
STATUSES = ["ACTIVE", "LAPSED", "CANCELLED", "RENEWED"]

FIRST = ["Priya", "Daniel", "Amara", "Wei", "Sofia", "Omar", "Grace", "Liam",
         "Noor", "Chen", "Isabel", "Kwame", "Hana", "Diego", "Fatima"]
LAST = ["Sharma", "Okafor", "Tremblay", "Nguyen", "Rossi", "Haddad", "Chen",
        "Murphy", "Silva", "Kowalski", "Bergeron", "Ahmed", "Dubois", "Osei"]


def messy_date(d, defect_rate=0.02):
    """Return an ISO date string, or garbage a small fraction of the time."""
    if random.random() < defect_rate:
        return random.choice(["", "N/A", "0000-00-00", "2026-13-45", "31/12/2025"])
    return d.isoformat()


def messy_case(value, rate=0.08):
    """Randomly mangle casing and whitespace so Silver has to conform it."""
    if random.random() < rate:
        return random.choice([value.upper(), value.lower(), f"  {value} "])
    return value


# ----------------------------------------------------------------- brokers
brokers = []
for i in range(1, N_BROKERS + 1):
    brokers.append({
        "broker_id": f"BRK{i:04d}",
        "broker_name": f"{random.choice(FIRST)} {random.choice(LAST)}",
        "region": messy_case(random.choice(REGIONS)),
        # ~4% missing region — Silver must decide what to do with these
        "email": "" if random.random() < 0.04 else f"broker{i}@example.com",
    })

# a genuine duplicate row — dedupe has to catch it
brokers.append(dict(brokers[7]))

with open(OUT / "brokers.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(brokers[0].keys()))
    w.writeheader()
    w.writerows(brokers)


# ---------------------------------------------------------------- policies
base = date(2024, 1, 1)
policies = []
for i in range(1, N_POLICIES + 1):
    start = base + timedelta(days=random.randint(0, 900))
    policies.append({
        "policy_id": f"POL{i:06d}",
        "broker_id": f"BRK{random.randint(1, N_BROKERS):04d}",
        "product": messy_case(random.choice(PRODUCTS)),
        "start_date": messy_date(start),
        "end_date": messy_date(start + timedelta(days=365)),
        "premium": round(random.uniform(500, 25_000), 2),
        "status": random.choice(STATUSES),
    })


def write_snapshot(rows, extract_date, filename):
    out = []
    for r in rows:
        row = dict(r)
        row["extract_date"] = extract_date
        out.append(row)
    # duplicate ~0.5% of rows within the extract itself
    for _ in range(len(out) // 200):
        out.append(dict(random.choice(out)))
    random.shuffle(out)
    with open(OUT / filename, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(out[0].keys()))
        w.writeheader()
        w.writerows(out)
    return len(out)


n1 = write_snapshot(policies, "2026-08-01", "policies_snapshot_01.csv")

# --- second snapshot: 12% of policies change status and/or premium ---------
changed = 0
for p in policies:
    if random.random() < 0.12:
        p["status"] = random.choice(STATUSES)
        p["premium"] = round(p["premium"] * random.uniform(0.9, 1.25), 2)
        changed += 1

n2 = write_snapshot(policies, "2026-08-15", "policies_snapshot_02.csv")


# ------------------------------------------------------------------ claims
claims = []
for i in range(1, N_CLAIMS + 1):
    # ~1% orphans — claims pointing at policies that do not exist
    if random.random() < 0.01:
        pid = f"POL{random.randint(900_000, 999_999):06d}"
    else:
        pid = f"POL{random.randint(1, N_POLICIES):06d}"

    amount = round(random.uniform(100, 80_000), 2)
    if random.random() < 0.015:            # bad amounts to validate against
        amount = random.choice([0, -1 * amount, 9_999_999.99])

    claims.append({
        "claim_id": f"CLM{i:07d}",
        "policy_id": pid,
        "claim_date": messy_date(date(2024, 6, 1) + timedelta(days=random.randint(0, 780))),
        "amount": amount,
        "status": messy_case(random.choice(["OPEN", "CLOSED", "IN REVIEW", "DENIED"])),
    })

for _ in range(60):                        # explicit duplicate claims
    claims.append(dict(random.choice(claims)))
random.shuffle(claims)

with open(OUT / "claims.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(claims[0].keys()))
    w.writeheader()
    w.writerows(claims)


print(f"brokers.csv                 {len(brokers):>7,} rows  (1 duplicate)")
print(f"policies_snapshot_01.csv    {n1:>7,} rows")
print(f"policies_snapshot_02.csv    {n2:>7,} rows  ({changed:,} policies changed)")
print(f"claims.csv                  {len(claims):>7,} rows  (60 duplicates, ~1% orphans)")
print("\nDefects planted: duplicates, null regions/emails, malformed dates,")
print("inconsistent casing and whitespace, orphan policy_ids, zero/negative/outlier amounts.")
