# Phase 1 video: Foundation (about 3–4 minutes)

**Format:** walk through `00_setup.sql` and run the CHECK queries live. Everything is already
built, so you don't re-run the CREATEs. You show the proof. End on `dbt debug`.

**Before you hit record**
- Snowsight: dark mode, zoom about 130%, `00_setup.sql` open, role ACCOUNTADMIN
- Terminal: font big, `(.venv)` active, already in `dbt/`, `source ../.env` done
- Don't show `.env` or the `.p8` file on screen. The account identifier shows in `dbt debug`,
  so blur it in the edit or crop it out

---

## 1. The problem (0:00–0:20)
**Screen:** the top of `00_setup.sql`, the "WHAT WE BUILD" block.

> "Most Snowflake tutorials do everything as ACCOUNTADMIN, with a password.
> That's fine for learning. It's not how a real team runs it.
> So before any data moves, I set up the account properly. Here's what that looks like."

## 2. Warehouses (0:20–0:50)
**Screen:** section 1. Run `SHOW WAREHOUSES LIKE 'WH_%';`

> "Two warehouses. One for loading, one for dbt.
> That way the bill tells me what each job costs.
> Both switch off after 60 seconds idle. Snowflake's default is 10 minutes.
> That's 9 minutes of paying for nothing, after every query."

**Point at:** `auto_suspend 60`, owner `SYSADMIN`.

## 3. Spend cap (0:50–1:10)
**Screen:** section 2. Run `SHOW RESOURCE MONITORS;`

> "This is a spending limit. 30 credits a month.
> I get an email at 50 and 75 percent. At 100, it switches both warehouses off.
> So if a job gets stuck in a loop, it can't burn money all weekend."

## 4. Databases (1:10–1:30)
**Screen:** section 3.

> "Two databases. RAW is Bronze, the data exactly as it arrived.
> ANALYTICS is Silver and Gold, and dbt builds all of it.
> Each database has one writer. So 'who can change raw data?' has a one-word answer."

## 5. Roles and permissions (1:30–2:30), the main part
**Screen:** section 4, then run the grant checks one by one.

> "Three roles, one per job. LOADER loads, TRANSFORMER is dbt, REPORTER reads the finished tables."

Run `SHOW GRANTS TO ROLE LOADER;`
> "LOADER has exactly 8 permissions. Use its warehouse, and create tables in RAW. That's it."

Run `SHOW GRANTS TO ROLE TRANSFORMER;`
> "TRANSFORMER has 6. It can read RAW and build in ANALYTICS. It can't touch the load."

Run `SHOW FUTURE GRANTS IN SCHEMA RAW.INSURANCE;`
> "And this one's easy to miss. It's a future grant.
> When a new raw table shows up, dbt can read it straight away.
> Without it, the pipeline breaks the first time someone adds a table."

## 6. The service user (2:30–3:00)
**Screen:** section 6. Run `DESC USER SVC_DBT;`, scroll to TYPE, PASSWORD, RSA_PUBLIC_KEY_FP.

> "dbt doesn't log in as me. It's got its own user, and it's a service user.
> No password at all. It logs in with a key pair.
> Snowflake only keeps the public half. The private key never leaves the machine running dbt."

## 7. The proof (3:00–3:30)
**Screen:** terminal. Run `dbt debug`.

> "So let's check it all works together. dbt logs in with the key,
> as TRANSFORMER, on its own warehouse, into ANALYTICS."

Wait for `All checks passed!`

> "No passwords. Each job has its own access. And there's a spending cap.
> Next video, the data lands in Azure and loads itself into Bronze."

---

## Full read-through script (teleprompter)

[SCREEN: top of 00_setup.sql]

Hi, I'm Mahesh. I'm building a production-style data pipeline on Snowflake, dbt and Azure,
and I'm recording every phase.

This is Phase 1. The setup.

Most tutorials do everything as ACCOUNTADMIN, with a password. That's fine for learning.
But it's not how a real team runs Snowflake. So before any data moves, I set the account up
properly. Let me show you what's in here.

[SCREEN: section 1. Run SHOW WAREHOUSES LIKE 'WH_%';]

First, compute. I've got two warehouses. One for loading data, one for dbt.
Splitting them means the bill shows me what each job costs.

Both are extra small. That's plenty for this data.
And both switch off after 60 seconds idle. Snowflake's default is 10 minutes.
So that's up to 9 minutes of paying for nothing, after every single query.

[SCREEN: section 2. Run SHOW RESOURCE MONITORS;]

Next, a spending limit. Snowflake calls it a resource monitor.
It's set to 30 credits a month. I get an email at 50 percent, and again at 75.
At 100 percent, it switches both warehouses off.
So if a job gets stuck in a loop, it can't burn money all weekend.

[SCREEN: section 3]

Then storage. Two databases.
RAW is my Bronze layer. The data sits there exactly as it arrived.
ANALYTICS is Silver and Gold, and dbt builds everything in it.

Each database has one writer. Only the loader writes to RAW. Only dbt writes to ANALYTICS.
So if someone asks who can change the raw data, the answer's one word.

[SCREEN: section 4]

Now the part I think matters most. Access.
I've got three roles, one for each job.
LOADER loads the data. TRANSFORMER is dbt. REPORTER is for analysts and dashboards.

[SCREEN: Run SHOW GRANTS TO ROLE LOADER;]

Here's LOADER. It's got exactly 8 permissions.
It can use its own warehouse, and it can create tables in RAW. That's it.

[SCREEN: Run SHOW GRANTS TO ROLE TRANSFORMER;]

TRANSFORMER has 6. It can read RAW and build in ANALYTICS.
It can't touch the loading side at all.

[SCREEN: Run SHOW FUTURE GRANTS IN SCHEMA RAW.INSURANCE;]

And this one's easy to miss. It's called a future grant.
It means when a new raw table shows up, dbt can read it straight away.
Without it, the pipeline breaks the first time someone adds a table,
and somebody has to go and fix the permissions by hand.

[SCREEN: section 6. Run DESC USER SVC_DBT; and scroll to TYPE, PASSWORD, RSA_PUBLIC_KEY_FP]

Last piece. dbt doesn't log in as me. It's got its own user.
It's a service user, so there's no password at all. It logs in with a key pair.
Snowflake only keeps the public half.
The private key stays on the machine that runs dbt. Later, that'll be a GitHub secret.

[SCREEN: terminal. Run dbt debug]

So let's check it all works together.
dbt logs in with the key, as TRANSFORMER, on its own warehouse.

[wait for "All checks passed!"]

And there it is. All checks passed.

One thing that went wrong, because something always does.
I shortened a couple of CREATE statements by hand, and Snowflake filled in its defaults.
10-minute auto suspend, and a spending cap with no limit.
Running it again didn't fix it, because IF NOT EXISTS just skipped them.
So I dropped them and rebuilt them. Now I run a SHOW after every step.

So that's the foundation. No passwords, each job gets only the access it needs,
and there's a cap on spending.

Next video, the data lands in Azure and loads itself into Bronze.

---

## Caption for LinkedIn (edit freely)

Phase 1 of my Snowflake + dbt + Azure pipeline: the setup nobody films.

Before any data moves:
- 2 warehouses, one per job, 60s auto-suspend
- a 30-credit monthly spend cap
- 3 roles with least-privilege grants (8 / 6 / 2)
- dbt logs in as a service user with a key pair. No passwords.

The mistake I made: I shortened a CREATE statement by hand and got Snowflake's defaults.
IF NOT EXISTS then skipped my fix. Lesson learned: check with SHOW after every step.

#Snowflake #dbt #DataEngineering #Azure
