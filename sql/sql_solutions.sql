-- ============================================================================
-- E-commerce customer analytics: SQL  (Snowflake syntax)
-- Two queries: (1) Customer Profile Aggregator, (2) Marketing Channel ROI.
-- Notebook scripts/solutions.ipynb (Part 4) runs the SQLite equivalent and returns the same
-- results, with one documented exception: Organic's channel_rank in Query 2 differs between
-- engines because they sort NULLs oppositely under DESC (see sql/README.md).
-- Assumptions: transaction_date and signup_date are DATE columns, and
-- the historical dataset ends on 2026-06-30.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- QUERY 1: Customer Profile Aggregator
-- Returns ONE row per customer summarising their buying behaviour, for the CRM.
-- ----------------------------------------------------------------------------
WITH ranked AS (  -- step 1: number each customer's purchases oldest-to-newest
    SELECT
        customer_id,
        category,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY transaction_date ASC,
                     transaction_id ASC  -- tie-break on transaction_id
        ) AS purchase_order
    FROM transactions
),
first_category AS (  -- step 2: keep only that first purchase, to read its category
    SELECT
        customer_id,
        category AS first_category_purchased
    FROM ranked
    WHERE purchase_order = 1
)
SELECT
    t.customer_id,
    ROUND(SUM(t.amount), 2)              AS total_spend,
    COUNT(*)                             AS transaction_count,
    DATEDIFF('day',
             MAX(t.transaction_date),
             DATE '2026-06-30')          AS recency_days,
    fc.first_category_purchased
FROM transactions t
JOIN first_category fc
    ON fc.customer_id = t.customer_id
GROUP BY t.customer_id, fc.first_category_purchased
ORDER BY t.customer_id;


-- ----------------------------------------------------------------------------
-- QUERY 2: Marketing Channel ROI & Performance
-- Returns ONE row per acquisition channel with its cost, revenue and ROI.
-- Granularity note: a customer belongs to ONE channel but has MANY transactions,
-- so we count signups with DISTINCT customers and sum money over transactions,
-- which avoids double-counting the spend.
-- ----------------------------------------------------------------------------
WITH channel_txn AS (  -- step 1: tag every transaction with the channel that acquired its customer
    SELECT
        c.acquisition_channel,
        c.customer_id,
        t.amount
    FROM customers c
    JOIN transactions t
        ON t.customer_id = c.customer_id
),
per_channel AS (  -- step 2: roll those tagged transactions up to the channel level
    SELECT
        ct.acquisition_channel,
        COUNT(DISTINCT ct.customer_id)          AS total_signups,
        SUM(ct.amount)                          AS total_historical_spend,
        ch.cost_per_signup,
        ch.revenue_share_rate,
        SUM(ct.amount * ch.revenue_share_rate)  AS total_revenue_share_paid
    FROM channel_txn ct
    JOIN channels ch
        ON ch.channel_name = ct.acquisition_channel
    GROUP BY ct.acquisition_channel, ch.cost_per_signup, ch.revenue_share_rate
),
computed AS (  -- step 3: turn the aggregates into the required money figures
    SELECT
        acquisition_channel,
        total_signups,
        ROUND(total_signups * cost_per_signup, 2)   AS total_acquisition_cost,
        ROUND(total_historical_spend, 2)            AS total_historical_spend,
        ROUND(total_revenue_share_paid, 2)          AS total_revenue_share_paid,
        ROUND(total_historical_spend
              - total_signups * cost_per_signup
              - total_revenue_share_paid, 2)        AS net_channel_profit
    FROM per_channel
)
SELECT
    acquisition_channel,
    total_signups,
    total_acquisition_cost,
    total_historical_spend,
    total_revenue_share_paid,
    net_channel_profit,
    ROUND(net_channel_profit
          / NULLIF(total_acquisition_cost + total_revenue_share_paid, 0), 4)
                                                    AS channel_roi,
    RANK() OVER (
        ORDER BY net_channel_profit
                 / NULLIF(total_acquisition_cost + total_revenue_share_paid, 0) DESC
    )                                               AS channel_rank
FROM computed
ORDER BY channel_rank;
