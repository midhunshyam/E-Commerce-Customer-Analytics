-- ============================================================================
-- E-commerce customer analytics: SQL  (Snowflake syntax)
-- Two queries: (1) Customer Profile Aggregator, (2) Marketing Channel ROI.
-- Notebook scripts/solutions.ipynb (Part 4) runs the SQLite equivalent and returns the same
-- results, with one documented exception: Organic's channel_rank in Query 2 differs between
-- engines because they sort NULLs oppositely under DESC (see sql/README.md).
-- Assumptions: transaction_date and signup_date are DATE columns, and
-- the historical dataset ends on 2026-06-30.
-- Reading guide: a "CTE" (each WITH ... AS block) is just a named intermediate
-- table used to build the final answer in clear, readable steps.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- QUERY 1: Customer Profile Aggregator
-- Returns ONE row per customer summarising their buying behaviour, for the CRM.
-- ----------------------------------------------------------------------------
WITH ranked AS (                                       -- step 1: number each customer's purchases oldest-to-newest
    SELECT
        customer_id,                                   -- who made the purchase
        category,                                      -- which product category it was
        ROW_NUMBER() OVER (                            -- ROW_NUMBER() hands out 1, 2, 3, ... in an order we choose
            PARTITION BY customer_id                   -- restart the counter separately for every customer
            ORDER BY transaction_date ASC,             -- the earliest purchase gets number 1
                     transaction_id ASC                -- tie-break: if two share the first day, the lower transaction_id wins
        ) AS purchase_order                            -- purchase_order = 1 therefore marks each customer's first-ever purchase
    FROM transactions
),
first_category AS (                                    -- step 2: keep only that first purchase, to read its category
    SELECT
        customer_id,
        category AS first_category_purchased           -- the category of the chronologically first purchase
    FROM ranked
    WHERE purchase_order = 1                            -- 1 = the first purchase identified above
)
SELECT
    t.customer_id,                                                      -- the unique customer identifier
    ROUND(SUM(t.amount), 2)              AS total_spend,                -- SUM() adds up every purchase amount; ROUND() keeps 2 decimals
    COUNT(*)                             AS transaction_count,          -- COUNT(*) counts how many purchase rows this customer has
    DATEDIFF('day',                                                     -- DATEDIFF() returns the whole number of days between two dates
             MAX(t.transaction_date),                                   -- the customer's most recent purchase date
             DATE '2026-06-30')          AS recency_days,               -- so recency_days = days from the last purchase to the end of the data
    fc.first_category_purchased                                         -- the first-purchase category, joined in from step 2
FROM transactions t
JOIN first_category fc                                                  -- attach each customer's single first-category value
    ON fc.customer_id = t.customer_id
GROUP BY t.customer_id, fc.first_category_purchased                     -- GROUP BY collapses all of a customer's rows into one summary row
ORDER BY t.customer_id;                                                 -- return the rows sorted by customer


-- ----------------------------------------------------------------------------
-- QUERY 2: Marketing Channel ROI & Performance
-- Returns ONE row per acquisition channel with its cost, revenue and ROI.
-- Granularity note: a customer belongs to ONE channel but has MANY transactions,
-- so we count signups with DISTINCT customers and sum money over transactions,
-- which avoids double-counting the spend.
-- ----------------------------------------------------------------------------
WITH channel_txn AS (                                  -- step 1: tag every transaction with the channel that acquired its customer
    SELECT
        c.acquisition_channel,                         -- the channel the customer came from
        c.customer_id,                                 -- the customer (used to count distinct signups later)
        t.amount                                       -- the purchase amount
    FROM customers c
    JOIN transactions t                                -- the join links each customer to all of their purchases
        ON t.customer_id = c.customer_id
),
per_channel AS (                                       -- step 2: roll those tagged transactions up to the channel level
    SELECT
        ct.acquisition_channel,
        COUNT(DISTINCT ct.customer_id)          AS total_signups,             -- DISTINCT counts each customer once, no matter how often they bought
        SUM(ct.amount)                          AS total_historical_spend,    -- SUM() adds every purchase amount for the channel
        ch.cost_per_signup,                                                   -- fixed cost to acquire one customer (from the channels table)
        ch.revenue_share_rate,                                                -- the commission fraction paid back to the channel
        SUM(ct.amount * ch.revenue_share_rate)  AS total_revenue_share_paid   -- commission = each amount times the rate, then summed
    FROM channel_txn ct
    JOIN channels ch                                                          -- bring in the cost and commission rate for the channel
        ON ch.channel_name = ct.acquisition_channel
    GROUP BY ct.acquisition_channel, ch.cost_per_signup, ch.revenue_share_rate  -- one group (one row) per channel
),
computed AS (                                          -- step 3: turn the aggregates into the required money figures
    SELECT
        acquisition_channel,
        total_signups,
        ROUND(total_signups * cost_per_signup, 2)   AS total_acquisition_cost,   -- signups times cost-per-signup = total acquisition cost
        ROUND(total_historical_spend, 2)            AS total_historical_spend,
        ROUND(total_revenue_share_paid, 2)          AS total_revenue_share_paid,
        ROUND(total_historical_spend                                            -- profit = money the customers spent ...
              - total_signups * cost_per_signup                                 -- ... minus what it cost to acquire them ...
              - total_revenue_share_paid, 2)        AS net_channel_profit        -- ... minus the commission paid to the channel
    FROM per_channel
)
SELECT
    acquisition_channel,                                                         -- the channel name
    total_signups,                                                              -- how many customers it acquired
    total_acquisition_cost,                                                      -- total money spent acquiring them
    total_historical_spend,                                                      -- total money those customers spent
    total_revenue_share_paid,                                                    -- total commission paid to the channel
    net_channel_profit,                                                          -- profit after both costs
    ROUND(net_channel_profit                                                     -- ROI = profit divided by the money put at risk ...
          / NULLIF(total_acquisition_cost + total_revenue_share_paid, 0), 4)     -- ... NULLIF(...,0) returns NULL instead of erroring for a free channel
                                                    AS channel_roi,              -- rounded to 4 decimals; 0.2541 means a 25.41% ROI
    RANK() OVER (                                                                -- RANK() puts the channels in order ...
        ORDER BY net_channel_profit
                 / NULLIF(total_acquisition_cost + total_revenue_share_paid, 0) DESC  -- ... from highest ROI down to lowest
    )                                               AS channel_rank              -- 1 = the best-ROI channel
FROM computed
ORDER BY channel_rank;                                                          -- present the best-ROI channel first
