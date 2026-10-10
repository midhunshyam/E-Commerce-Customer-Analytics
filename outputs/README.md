# Results

These are the results the pipeline produces (the answers, not the models).

| File | What it is | Columns / contents |
|---|---|---|
| `customer_segments.csv` | one row per customer with every engineered feature and the assigned segment | `customer_id`, RFM (`recency`, `frequency`, `monetary`, `aov`), `tenure`, `active_span`, `category_diversity`, `pct_*` (category spend shares), `top_category`, `age`, `gender`, `country`, `acquisition_channel`, `signup_date`, `future_value`, `cluster`, `segment` |
| `clv_predictions.csv` | predicted vs actual next-12-month value, per customer | `customer_id`, `predicted_clv`, `actual_clv` |
| `clv_metrics.csv` | the held-out model scores | `metric`, `value` (test_rmse 23.94, test_mae 14.9, test_r2 0.9996) |
| `coupon_allocation.csv` | the optimal coupon plan, per segment | `segment`, `population`, `coupon`, `cost`, `net_revenue` |
| `results_summary.json` | the headline numbers in one small JSON file | `segment_sizes`, `clv_test_error`, `coupon_per_customer`, `expected_net_revenue` |
| `variable_analysis_and_budget_optimization.txt` | the full written analysis report: plain text, every table and test with a plain-language reading under it | produced by `scripts/variable_analysis_and_budget_optimization.R`; see below |

The committed `customer_segments.csv` was written by `scripts/solutions.ipynb`. Running
`scripts/customer_segmentation.py` on its own writes the same customers, features and segments without
the `top_category` and `future_value` columns.

If you run the prediction commands, these extra files also appear here:

| File | Produced by | What it is |
|---|---|---|
| `predicted_segments.csv` | `customer_segmentation.py --predict` | the segment assigned to each new customer |
| `predicted_clv.csv` | `clv_regression.py --predict` | the predicted value for each new customer |
| `new_customer_scores.csv` | `score_customers.py` | both at once: `customer_id`, `segment`, `predicted_clv` |

## The analysis report

`variable_analysis_and_budget_optimization.txt` is the complete terminal output of the R analysis,
saved to disk via `sink(split = TRUE)` so the console run and the file are identical. It is written
for a non-technical reader: every table is followed by a "Reading it:" paragraph that says what the
numbers mean in words. Read it top to bottom, or jump to a section.

| Section | What it covers | Headline finding |
|---|---|---|
| Data overview | Distribution, shape and missingness of every numeric variable; frequency and share of every categorical one | No missing values anywhere. Age is flat (skew 0.06); `monetary` and `target_clv` are strongly right skewed (skew ≈ 2.1), with a thin tail of heavy spenders stretching both axes |
| Segments | Per-segment medians (recency, frequency, spend, AOV, age) and share of total value | Value is concentrated: 148 VIPs = 14.8% of customers but **72.4% of next-year value**. Median age varies only 3 years across segments, so these are behavioural tiers, not demographic ones |
| Value drivers | Correlation of each driver with next-year value, plus a multiple regression and a spend-only baseline | `monetary` correlates **0.999** with value and alone gives R² = 0.9985. Adding everything else lifts it to 0.9989 |
| Age, the full story | The flagship test: marginal vs conditional age effect, incremental R², value-per-dollar by age band, within-segment gaps, ANOVA | Age is a **weak second-order retention signal, not a targeting lever**. Marginal correlation 0.029; conditional 0.444; incremental R² only +0.00027 (≈ \$1.41 per year of age). It vanishes for VIPs (gap −\$202) and total value is flat across age bands (ANOVA p = 0.63) |
| Channel economics | Per-channel revenue, commission paid, acquisition cost and net, sorted by net | Google leads on net (\$274,848) and Organic is free (\$0 cost, \$127,397 net). Whole mix nets **\$617,763**, about 27.4× the money put at risk |
| Product mix | Categories by average price, total spend, purchase count and share | Two price tiers: premium (Electronics ~\$90, Home ~\$82) and value (Fashion, Beauty ~\$41). Electronics leads both: **30.7% of all spend** |
| Retention and cadence | Median inter-purchase gap and median recency, by segment | VIPs buy every ~15 days, Occasional Shoppers every ~96. Suggests a churn trigger at roughly twice a segment's normal cadence |
| Geography and demographics | Headcount vs value per customer, by country and by gender | Both are **volume stories, not value signals**: value per head moves only \$638–\$875 across countries and \$662–\$859 across genders. Do not target on either |
| Lapsed customers | Size, value and composition of the win-back pool (recency past the 90th percentile, 241 days) | Small and low value: 101 customers (10.1%) holding just **1.6% of value**, and 100% of them are Occasional Shoppers. Sports, Home and Fashion over-index. A modest roadmap item, not a headline |
| Hypothesis tests | Four formal tests: value by segment, value by age band, category mix by segment, age vs value | Segments are real (ANOVA p < 1e-16) and segments genuinely shop differently (χ² p < 1e-16), but **age bands do not separate on value** (p = 0.633) and the age-value correlation is indistinguishable from zero (p = 0.368) |
| Budget optimization | The optimal coupon per segment, solved as an integer linear program | VIPs \$20, Bargain Hunters \$5, Occasional Shoppers \$10 → **\$14,450 net on \$9,750 spent**, \$250 unspent. Every \$1 of coupon returns about \$2.48 of incremental revenue |

Two notes for anyone comparing the report against the CSVs:

- **Net is already net.** The `$14,450` in the report and in `coupon_allocation.csv` has the `$9,750`
  of coupon cost **already deducted**: the objective is `population × (lift − coupon)`. Gross
  incremental revenue is \$24,200; do not subtract the spend a second time.
- **Segment counts differ by one or two.** The R report shows 148 / 381 / 471 and the Python pipeline
  (`results_summary.json`) shows 148 / 380 / 472. Two customers sit on a cluster boundary and land
  differently under the two k-means implementations. Neither is wrong; the Python figures are the ones
  reported throughout this repository. Part 3 uses the scenario's planning populations (150 / 350 / 500)
  regardless.
