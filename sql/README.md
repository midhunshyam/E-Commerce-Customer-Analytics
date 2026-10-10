# Part 4: SQL (data aggregation and analysis)

Two executable queries in [`sql_solutions.sql`](sql_solutions.sql), written in **Snowflake** syntax and
commented line by line for non-SQL readers.

- **Query 1: Customer Profile Aggregator** (one row per customer, for the CRM).
- **Query 2: Marketing Channel ROI** (one row per acquisition channel).

## How to run

Run `sql_solutions.sql` in Snowflake against tables named `customers`, `transactions`, and `channels`.
Part 4 of the notebook (`scripts/solutions.ipynb`) also runs the **same file locally in SQLite**: it loads
the three CSVs into an in-memory database, slices the two queries out of the `.sql` file, and translates
the two dialect-specific pieces on the fly. `DATEDIFF('day', a, b)` becomes `julianday(b) - julianday(a)`
and the `DATE '2026-06-30'` literal becomes a plain string (in PostgreSQL the difference would be
`(b - a)`). The per-channel net profit it returns matches the channel economics table in the R report
(`outputs/variable_analysis_and_budget_optimization.txt`), which computes the same figures independently.

---

## Query 1: Customer Profile Aggregator

**Purpose.** Collapse the transaction log into one summary row per customer that a CRM can use directly.

**Output columns**

| Column | Meaning |
|---|---|
| `customer_id` | the customer |
| `total_spend` | `ROUND(SUM(amount), 2)`, all their purchases added up |
| `transaction_count` | `COUNT(*)`, how many purchases they made |
| `recency_days` | `DATEDIFF('day', MAX(transaction_date), 2026-06-30)`, days from the last purchase to the end of the data |
| `first_category_purchased` | the product category of their chronologically first purchase |

**Logic.** Two CTEs (named intermediate steps) keep it readable:

1. `ranked` numbers each customer's purchases oldest to newest with `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY transaction_date, transaction_id)`. Partitioning restarts the counter per customer, so number 1 is always that customer's first purchase. The `transaction_id` tie-break makes the result deterministic when two purchases share the earliest date.
2. `first_category` keeps only `purchase_order = 1` to read that first purchase's category.
3. The final query aggregates the transactions per customer (`SUM`, `COUNT`, `DATEDIFF`) and joins the single first-category value back in, grouping by `customer_id`.

**Assumptions.**

- `transaction_date` and `signup_date` are DATE columns.
- The historical dataset ends on **2026-06-30**, which is the reference date for recency.
- Every customer has at least one transaction (verified), so the aggregate returns exactly one row per customer.

---

## Query 2: Marketing Channel ROI and Performance

**Purpose.** Rank each acquisition channel by return on investment, netting off both the acquisition
cost and the commission paid back to the channel.

**Output columns**

| Column | Meaning |
|---|---|
| `acquisition_channel` | the channel name |
| `total_signups` | `COUNT(DISTINCT customer_id)`, customers acquired (each counted once) |
| `total_acquisition_cost` | `total_signups * cost_per_signup` |
| `total_historical_spend` | `SUM(amount)`, all money those customers spent |
| `total_revenue_share_paid` | `SUM(amount * revenue_share_rate)`, commission paid to the channel |
| `net_channel_profit` | spend minus acquisition cost minus commission |
| `channel_roi` | `net_channel_profit / (acquisition_cost + revenue_share_paid)`, rounded to 4 decimals |
| `channel_rank` | `RANK()` by ROI, highest first |

**Logic (and the granularity trap).** A customer belongs to **one** channel but has **many**
transactions, so joining customers to transactions multiplies the rows. To avoid double-counting,
signups are counted with `COUNT(DISTINCT customer_id)` while money is summed over the transaction rows.
Three CTEs build it up: `channel_txn` tags every transaction with its customer's channel, `per_channel`
rolls those up to the channel level (distinct signups, summed spend, summed commission), and `computed`
turns the aggregates into acquisition cost and net profit. The final SELECT derives ROI and ranks it.

**Assumptions.**

- Each customer maps to exactly one acquisition channel (the granularity assumption above).
- `revenue_share_rate` is a commission fraction the platform pays to the channel, so it is subtracted from spend when computing profit.
- The Organic channel has a `cost_per_signup` of 0 and a `revenue_share_rate` of 0, so its ROI denominator (acquisition cost plus commission) is 0, handled with `NULLIF(..., 0)` so the division returns `NULL` instead of erroring. Organic therefore has no ROI to be ranked on, and **the rank it receives is engine-dependent (see the note below the results table).**

**Result.**

| Rank | Channel | Signups | Acquisition cost | Net profit | ROI |
|---|---|---|---|---|---|
| 1 | Google | 404 | \$6,060 | \$274,848 | 23.3x |
| 2 | Facebook | 298 | \$5,960 | \$166,645 | 21.6x |
| 3 | Referral | 92 | \$460 | \$48,873 | 16.0x |
| n/a | Organic | 206 | \$0 | \$127,397 | free channel (NULL ROI, rank varies by engine) |

Organic is the second most profitable channel in absolute dollars (\$127k) despite having no ROI figure,
which is worth flagging to the business: it is free acquisition, so its value is the profit itself, not
a ratio.

### Known limitation: Organic's rank is engine-dependent

`channel_rank` is `RANK() OVER (ORDER BY <roi expression> DESC)` and Organic's ROI is `NULL`. The query
does not pin NULL placement with `NULLS FIRST` / `NULLS LAST`, so the rank Organic receives depends
entirely on how the engine sorts NULLs under `DESC`:

| Engine | Treats NULL as | Organic's rank |
|---|---|---|
| **Snowflake** (the declared dialect) | *higher* than any non-NULL | **1, printed first** |
| **SQLite** (the notebook's cross-check) | *lower* than any non-NULL | **4, printed last** |

Snowflake's `DEFAULT_NULL_ORDERING` parameter defaults to `LAST`, which is defined as "NULL values are
higher than any non-NULL values", so a descending sort returns them first
([ORDER BY docs](https://docs.snowflake.com/en/sql-reference/constructs/order-by)). SQLite documents the
reverse: "a value with storage class NULL is considered less than any other value"
([sort order](https://www.sqlite.org/datatype3.html)). Note this is a session parameter, so a Snowflake
account that has overridden `DEFAULT_NULL_ORDERING` to `FIRST` would match SQLite instead.

The results table above reports the SQLite figures. Run the same file in Snowflake and Organic appears at
the **top** of the report labelled rank 1, which reads as "best channel" when the truth is "ROI is
undefined". This also means the header claim in `sql_solutions.sql` that the SQLite run "returns the same
results" holds for query 1 and for every column of query 2 except `channel_rank`.

This is documented rather than changed, because the fix depends on a business decision that the data
cannot make. Ranking a zero-cost channel by a cost ratio is a category error in either direction: `NULLS LAST`
on the window's `ORDER BY` would pin both engines to rank 4; ranking by `net_channel_profit` instead
would put Organic third (\$127,397, behind Google and Facebook); treating an infinite return as best
would put it first. All three are defensible. What is not defensible is letting the engine pick silently,
so the caveat is stated here instead.

**Read Organic on its net profit, not its rank.** \$127,397 of profit for \$0 of spend is the second most
profitable channel in absolute dollars, and it cannot be scaled by bidding more: it is earned through
brand and SEO, which makes it a different kind of investment from Google or Facebook, not a competitor
on the same leaderboard.

### Two latent edge cases (no effect on this dataset)

- `channel_txn` reaches the customer population through an **inner** join to `transactions`, so
  `total_signups` counts only customers who purchased, and acquisition cost is charged only for them. In
  this data every one of the 1,000 customers has at least one transaction (404 / 298 / 206 / 92 matches
  `customers.csv` exactly), so the figures are unaffected, but on data with non-purchasing signups the
  acquisition cost would be understated.
- The row set is seeded by transactions rather than by the `channels` table, so a channel that was paid
  for but produced no purchases would vanish from the report instead of showing as a loss. All four
  channels have purchases here, so nothing is currently hidden.
