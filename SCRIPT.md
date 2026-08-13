# Recording script

Spoken lines are in `>` blocks. Everything else is a stage direction — what to have on screen.

Don't read these word for word. Read them once, then say it your way. A script you're reciting
sounds like a script; a script you've absorbed sounds like you know the thing.

**Format for every episode:** problem → run it → show the result → why it matters.
No intro music. No "hey guys." Open on the problem.

**Honesty rule for the whole series.** This is a personal build on synthetic data. Say so in
episode 0 and never blur it. If someone asks in the comments, the answer is "synthetic data I
generated with deliberate defects, so every layer had real work to do." The build is what proves
the skill — pretending it's production work would throw that away for nothing.

---

## Series intro — say once, at the top of episode 0 (~30 seconds)

> I'm building an insurance data pipeline in Snowflake, end to end, in seven parts.
>
> Policies, claims and brokers — Bronze, Silver, Gold — a star schema with slowly changing
> dimensions, and a reconciliation gate that blocks bad data from reaching the reporting layer.
>
> The data is synthetic. I generated it myself with deliberate defects in it — duplicate rows,
> malformed dates, orphan foreign keys, amounts that make no sense — because clean data teaches you
> nothing. Everything else is real: real Snowflake account, real SQL, real mistakes.
>
> Let's start with the environment.

---

# Episode 0 — Setup (3–4 min)

**On screen:** terminal, then Snowsight.

> Before any data moves, three things have to exist: somewhere to compute, somewhere to store, and
> somewhere for files to land.

Run `00_setup.sql`, warehouse block.

> This is a warehouse. And the first confusing thing about Snowflake is that a warehouse is not a
> data warehouse. It's compute — a cluster of servers that runs your queries. Nothing is stored in
> it.
>
> That's the single most important idea in the platform. In Oracle or SQL Server, storage and
> compute are the same box. If you need more CPU you buy a bigger machine, and the data comes with
> it. Here they're completely separate.
>
> Which means I can turn compute off and pay nothing, while my data stays exactly where it is.
> Auto-suspend sixty — it parks after a minute idle. Billing is per-second with a sixty-second
> minimum, so a low auto-suspend genuinely saves money.

Run the database and schemas block.

> Now storage. One database, four schemas — Bronze, Silver, Gold, and an OPS schema for quarantine
> and reconciliation.
>
> That's the whole architecture, expressed as folders. Anyone who opens this database sees the
> design immediately.

Run the file format block.

> This is how Snowflake should read my CSVs. Like a SQL*Loader control file, but stored in the
> database and reusable.
>
> Look at what these three settings do — which is nothing. Don't trim spaces. Don't turn empty
> strings into nulls. That's deliberate. Bronze keeps the mess exactly as it arrived. Silver decides
> what's valid later.

Run the stage block, then `LIST @STG_RAW`.

> A stage is just a folder Snowflake manages. Files live there, they're not tables yet.
>
> And look at the sizes. Every one is a few bytes bigger than the file on my laptop — and every
> one is an exact multiple of sixteen.
>
> That's not corruption. Snowflake encrypts files at rest in an internal stage, and `LIST` reports
> the encrypted size, padded up to the AES block boundary. The data is byte-identical.
>
> Worth knowing, because if you're reconciling file sizes to prove nothing got truncated in
> transit, the raw number won't tie and you'll go hunting for a bug that doesn't exist.

**Close:**

> Compute, storage, parsing rules, landing area. Next: getting the data in without letting the bad
> rows kill the load.

---

# Episode 1 — Bronze (5–7 min)

**On screen:** Snowsight, `01_bronze.sql`.

**Open on the problem:**

> Here's a row from my source data. The start date says "N slash A". Here's another one — the
> premium field is fine but the date says zero-zero-zero-zero dash zero-zero.
>
> If I load this into a table where `start_date` is a DATE column, the load fails. Not that row —
> the whole file. I lose ten thousand good rows because of forty bad ones.
>
> So Bronze doesn't have a DATE column. Bronze doesn't have any typed columns at all.

Run the `CREATE TABLE` block. Point at the columns.

> Every single column is VARCHAR. Premium is text. Dates are text.
>
> Bronze's job is to get the data in the building, not to judge it. Silver judges it.
>
> And these three underscore columns are load metadata — which file, which line of that file, what
> time it landed. Six months from now when a number looks wrong, that's how I trace it back to the
> exact line of the exact extract.

Run steps 2, 3, 4. Let the `COPY INTO` results show.

> Two things worth pointing at here. `COPY INTO` reading from a SELECT — that's what lets me attach
> the filename and row number as it loads.
>
> And this one loads two files into one table. Two dated snapshots of the same policies, two weeks
> apart. Bronze is append-only, so I keep every extract I've ever received. That's what makes
> slowly changing dimensions possible in episode three — if the second load overwrote the first,
> there'd be no history to detect.

Run step 5.

> Fifty-one brokers, ten thousand and fifty policies, twelve thousand and sixty claims. That matches
> what the generator printed.
>
> That's a reconciliation, done by eye. In episode five I automate exactly this comparison and make
> it block the pipeline when it doesn't match.

Run step 6, all five queries.

> Now — this is Bronze working correctly.
>
> Two hundred and forty-eight malformed dates. Twenty different spellings of five products. Sixty
> duplicate claims. A hundred and seventy-two amounts that are zero, negative, or absurd. A hundred
> and twenty-nine claims pointing at policies that don't exist.
>
> All of it landed. Nothing failed.

Point at `0000-00-00` and `2026-13-45` in the results.

> And look at these two. They're shaped like valid dates. Four digits, dash, two digits, dash, two
> digits. A regex passes them. A length check passes them. Only an actual calendar parse rejects
> them — there's no month thirteen and no day forty-five.
>
> That's why you validate with `TRY_TO_DATE` and not a pattern match.

Run step 7 — the rerun.

> Now watch this. Same `COPY INTO`, run again.
>
> Zero files processed. Count unchanged.
>
> Snowflake keeps sixty-four days of load history per table and skips files it's already ingested.
> So if this pipeline dies halfway at three in the morning, I restart it and nothing double-counts.
>
> "How do you make your loads idempotent" is a real interview question. Most people describe
> building it themselves. Snowflake does it natively, and `FORCE = TRUE` is the escape hatch.

**Close:**

> Everything landed, the mess is intact and counted, and reruns are safe.
>
> Those five defect numbers? That's next episode's to-do list.

---

# Episode 2 — Silver (5–7 min)

**Open on the problem:** have the Stage 1 defect results on screen.

> Bronze answered one question: did the data arrive? Silver answers a harder one — which of it can
> we trust, and what happened to the rest?
>
> That second half is what separates a pipeline from a script.

Run step 1, the quarantine table.

> This is the table most pipelines don't have. Rejected rows come here. They don't get deleted.
>
> Three reasons. Someone will eventually ask "where did claim one-two-three-four go", and "we
> dropped it" is not an answer. Reject counts climbing is the earliest signal a source system
> changed — a silent DELETE hides that completely. And control totals only tie if you can account
> for what you removed.
>
> The raw record column stores the entire original row as JSON, so I can replay it after fixing
> the rule.

Run step 2. Highlight the `ROW_NUMBER` block.

> This is the most commonly asked SQL question in a data engineering interview, so it's worth
> saying slowly.
>
> `PARTITION BY broker_id` restarts the numbering for each broker. `ORDER BY loaded_at descending`
> puts the newest row at number one. Then keep only number one.
>
> Why not `GROUP BY`? Because `GROUP BY` collapses rows, and then I need an aggregate for every
> other column. `ROW_NUMBER` keeps one whole real row intact. That's the distinction they're
> testing.

Run step 3. **Slow down here.**

> Now the most important decision in this whole file.
>
> I'm partitioning by policy_id **and extract_date**. Not policy_id alone.
>
> If I deduped on policy_id alone, I'd keep one row per policy and throw the other snapshot away.
> It would look tidier and it would destroy the project. Six hundred and two policies changed their
> status or premium between the first of August and the fifteenth. Collapse them and episode three
> has nothing to detect.
>
> The duplicates I'm removing are accidental repeats inside a single extract. Those are noise. The
> repeats across extracts are signal.

Point at the `TRY_TO_DECIMAL` line.

> Small thing that isn't small — precision and scale, thirty-eight and two.
>
> Bare `TRY_TO_NUMBER` defaults to zero decimal places. It silently rounds every value to a whole
> number. Across ten thousand premiums that moves the total by hundreds of dollars, and then the
> reconciliation gate fires on variance that doesn't exist.

Run step 4.

> Claims. Three different defects, three deliberately different responses.
>
> Amounts of zero or below — quarantined. A claim can't pay zero. The row can't go forward.
>
> Orphan policy IDs — kept, and flagged. A claim pointing at a policy I don't have is still a real
> claim with real money. Dropping it understates exposure and breaks the control total. In
> dimensional modelling you never throw away a fact because its dimension is missing.
>
> And this one is interesting.

Show the 59 rows at `9999999.99`.

> Fifty-nine claims at nine million, nine hundred ninety-nine thousand, nine hundred ninety-nine
> ninety-nine.
>
> Not fifty-nine different large numbers. The same number, fifty-nine times.
>
> Real catastrophe claims vary. An identical repeated maximum is a sentinel — a placeholder some
> upstream system writes when it doesn't know the real amount.
>
> So I don't drop them, because that erases five hundred and ninety million of apparent exposure.
> And I don't silently trust them, because that invents five hundred and ninety million. I flag
> them and surface them, and the business makes the call.
>
> That's a judgement call, not a fact. Knowing the difference is the point.

Run step 5 — the reconciliation.

> And here's the payoff.
>
> Twelve thousand and sixty claims arrived. Eleven thousand eight hundred and eighty-seven are in
> Silver. A hundred and thirteen are in quarantine with a reason. Sixty were duplicates.
>
> Reconciled: true. On all three tables.
>
> Anyone can write a `SELECT DISTINCT` and call it cleaning. This says where every single row went.

**Close:**

> Typed, deduped, conformed. Twenty product spellings down to five. Nothing dropped silently.
>
> Next: turning this into something the business can actually query.

---

# Episode 3 — Gold (6–8 min) — the flagship

**Open with the grain. Before any SQL is on screen.**

> Before I write a single line of DDL, I'm going to say what one row of my fact table means.
>
> One row of `FACT_CLAIM` is one claim.
>
> That's the grain. Get it wrong and every number downstream double-counts, and no amount of clever
> SQL fixes it afterwards. So you decide it first, out loud.

Show the star diagram from the file header.

> Four tables. A broker dimension, a date dimension, a policy dimension, and the claim fact in the
> middle.

Run steps 1 and 2.

> Surrogate keys first — and this is a guaranteed interview question.
>
> The natural key is policy_id. It can't be the primary key of my dimension, because under slowly
> changing dimensions the same policy_id will exist on several rows, one per version. I need
> something that identifies a *version*, not a policy.
>
> And every dimension gets an unknown member at key minus one. That's not a hack. A fact whose
> dimension row is missing still has to join to something, or an inner join silently drops it and
> the totals stop tying.

Run step 3.

> A generated calendar. `GENERATOR` manufactures rows out of nothing and `SEQ4` numbers them.
>
> Why have a date table when you can just call `MONTH()` on a date? Because a date dimension holds
> what a date function can't know — fiscal calendars, public holidays, which week belongs to which
> reporting period.

Run step 4. **Slow down on `valid_from`.**

> Initial load. Five thousand policies, all current.
>
> And this line matters more than it looks. `valid_from` is nineteen hundred, not the extract date.
>
> My claims run from June 2024 to July 2026 — all of them *before* the first extract in August
> 2026. If version one were only valid from the extract date, every single claim would fall outside
> every version's window, and every policy key in my fact table would be minus one.
>
> The load would succeed. The fact table would fill. And it would be completely wrong.

Run step 5 — the MERGE. **This is the moment.**

> Now the money shot.
>
> Before: five thousand and one rows.

Run it. Let the result show.

> Six hundred and two updated, six hundred and two inserted. One statement.
>
> Six hundred and two policies changed. Each one had its old version closed and a new version
> opened, in a single MERGE.
>
> The trick is that a MERGE can only take one action per matched row, but a Type 2 change needs
> two — close the old and insert the new. So I feed the source in twice. One pass carries the real
> join key and matches, and closes the row. The other pass carries a NULL join key, so it can never
> match, and falls through to the insert.

Run the two queries in step 8. **This is the closing shot.**

> One policy. Two rows.
>
> The first one — status LAPSED, closed on the fifteenth of August, is_current false.
> The second — status CANCELLED, valid from the fifteenth, is_current true.
>
> The history is there. I can ask what this policy looked like on any date.

Run step 6, the fact load. Point at the join.

> And this is why that matters.
>
> I'm not joining the fact to the current version of the policy. I'm joining on the natural key
> **and** the claim date falling inside the version's validity window.
>
> I'm not asking what this policy looks like now. I'm asking what it looked like on the day of the
> claim. That is the entire reason the dimension keeps history. If you point the fact at
> is_current, you built Type 2 for nothing.
>
> Greater-than-or-equal on one side, strictly-less-than on the other. Never `BETWEEN` — `BETWEEN`
> is inclusive at both ends, so a claim on the exact changeover date would match two versions and
> duplicate the row.

Run the grain check in step 7.

> No rows. One claim, one fact row. The grain held.
>
> And the fact table has exactly eleven thousand eight hundred and eighty-seven rows — the same as
> Silver. If that date-range join had fanned out, this would be higher and every sum in Gold would
> be silently wrong.

Run the queries in step 9.

> And here's what all of it was for.
>
> Claims paid by product by quarter. Against Bronze that needed casts, a dedupe and a date parse.
> Here it's one join and a `GROUP BY`.

**Close:**

> Grain declared first. Surrogate keys. Type 2 history in one MERGE. A fact that resolves to the
> right version of the policy.
>
> Next: making it incremental, so it doesn't rebuild everything every run.

---

# Episodes 4–7 — outlines

Fill these in after each stage is run and verified. Don't script a result you haven't seen.

## Episode 4 — Streams and Tasks (5 min)

- **Open:** "Everything so far rebuilds the whole table every run. Fine at twelve thousand rows.
  Ruinous at twelve million."
- Streams are a bookmark, not a copy.
- The offset rule: **reading a stream inside DML advances it.** A plain SELECT doesn't. That's why
  the batch table exists — a stream can only be consumed once.
- Run with no new data → the root task shows SKIPPED. Say it precisely: *it didn't run and change
  nothing — it didn't run at all. No warehouse started.*
- Insert three rows → two through to Gold, one quarantined, no rebuild.
- Children resume before the root, or the root fires before its children exist and silently moves
  nothing.

## Episode 5 — The reconciliation gate (5 min)

- **Open:** "This is the difference between a report and a gate. A report tells you afterwards that
  yesterday was wrong."
- Twelve checks, two gates.
- Tolerances: zero for structural, one cent for money, two percent for rates — and *why* each.
- **The demo:** move one claim by a thousand dollars. Out of 1.06 billion. Nothing else changes.
- Gate fails. Gold task never runs. Gold keeps yesterday's good data.
- "A gate nobody trusts gets switched off within a week — that's why money has a tolerance."

## Episode 6 — Performance and cost (5 min)

- Run the heaviest query on XSMALL, then SMALL. Compare duration *and* credits.
- Read the query profile, find the most expensive node.
- Micro-partitions and pruning. When a clustering key earns its cost and when it's waste.
- **Multi-cluster is for concurrency, not for making one query faster.** Say it — it's a common trap.
- Query `QUERY_HISTORY` and `WAREHOUSE_METERING_HISTORY`.

## Episode 7 — Ship it (4 min)

- Walk the README: problem, architecture, grain, how SCD2 works, how the gate blocks promotion.
- Show the SCD2 before/after screenshot.
- What you'd do differently — have a real answer. It reads as judgement, not modesty.

---

# Delivery notes

- **Say why, not what.** "I'm creating a VARCHAR table" is narration anyone can read off the screen.
  Nobody watches for that.
- **Run it once before you record.** Nobody nails a take on the first run of something new.
- **Have both queries ready before you hit record** for the Stage 3 before/after. Fumbling for a
  policy_id on camera kills the moment.
- **Leave the mistakes in** where they're instructive. The `.gz` pattern that matched zero files is
  a better teaching moment than a clean run — it's the exact bug that would waste someone's evening.
- **Don't apologise for synthetic data.** Say it once, plainly, and move on. The defects are the
  point.
- Results render as readable tables in Snowsight. Record there, not in the terminal.
