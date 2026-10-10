# Results

Result tables written by the pipeline. The trained models are in `models/`.

| File | What it is | Columns / contents |
|---|---|---|
| `customer_segments.csv` | one row per customer with every engineered feature and the assigned segment | `customer_id`, RFM (`recency`, `frequency`, `monetary`, `aov`), `tenure`, `active_span`, `category_diversity`, `pct_*` (category spend shares), `top_category`, `age`, `gender`, `country`, `acquisition_channel`, `signup_date`, `future_value`, `cluster`, `segment` |
| `clv_predictions.csv` | predicted vs actual next-12-month value, per customer | `customer_id`, `predicted_clv`, `actual_clv` |
| `clv_metrics.csv` | the held-out model scores | `metric`, `value` (test_rmse 23.94, test_mae 14.9, test_r2 0.9996) |
| `coupon_allocation.csv` | the optimal coupon plan, per segment | `segment`, `population`, `coupon`, `cost`, `net_revenue` |
| `results_summary.json` | the headline numbers in one small JSON file | `segment_sizes`, `clv_test_error`, `coupon_per_customer`, `expected_net_revenue` |
| `variable_analysis_and_budget_optimization.txt` | the R analysis report: plain text, each table and test followed by a short reading | produced by `scripts/variable_analysis_and_budget_optimization.R`; see below |

`scripts/customer_segmentation.py` and `scripts/solutions.ipynb` both write `customer_segments.csv`, with the same
columns.

If you run the prediction commands, these extra files also appear here:

| File | Produced by | What it is |
|---|---|---|
| `predicted_segments.csv` | `customer_segmentation.py --predict` | the segment assigned to each new customer |
| `predicted_clv.csv` | `clv_regression.py --predict` | the predicted value for each new customer |
| `new_customer_scores.csv` | `score_customers.py` | both at once: `customer_id`, `segment`, `predicted_clv` |

## The analysis report

`variable_analysis_and_budget_optimization.txt` is the full console output of the R analysis, saved
with `sink(split = TRUE)` so the console run and the file are identical. Each table is followed by a
"Reading it:" paragraph.

| Section | What it covers | Headline finding |
|---|---|---|
| Data overview | Distribution, shape and missingness of every numeric variable; frequency and share of every categorical one | No missing values. Age is roughly uniform (skew 0.06); `monetary` and `target_clv` are right-skewed (skew ≈ 2.1), with a thin tail of heavy spenders |
| Segments | Per-segment medians (recency, frequency, spend, AOV, age) and share of total value | The 148 VIPs are 14.8% of customers and hold 72.4% of next-year value. Median age varies by only 3 years across segments, so the segments are behavioural |
| Value drivers | Correlation of each driver with next-year value, plus a multiple regression and a spend-only baseline | `monetary` correlates 0.999 with value and alone gives R² = 0.9985. Adding everything else lifts it to 0.9989 |
| Age | Marginal vs conditional age effect, incremental R², value-per-dollar by age band, within-segment gaps, ANOVA | Age has a weak effect once spend is known. Marginal correlation 0.029; conditional 0.444; incremental R² +0.00027 (≈ \$1.41 per year of age). The effect disappears for VIPs (gap −\$202) and total value is flat across age bands (ANOVA p = 0.63), so age is not used for targeting |
| Channel economics | Per-channel revenue, commission paid, acquisition cost and net, sorted by net | Google leads on net (\$274,848) and Organic is free (\$0 cost, \$127,397 net). The whole mix nets \$617,763, about 27.4× the acquisition and commission spend |
| Product mix | Categories by average price, total spend, purchase count and share | Two price tiers: premium (Electronics ~\$90, Home ~\$82) and value (Fashion, Beauty ~\$41). Electronics leads both, with 30.7% of all spend |
| Retention and cadence | Median inter-purchase gap and median recency, by segment | VIPs buy every ~15 days, Occasional Shoppers every ~96. A churn trigger at roughly twice a segment's normal cadence would fit |
| Geography and demographics | Headcount vs value per customer, by country and by gender | Headcount varies widely, but value per customer ranges only \$638 to \$875 across countries and \$662 to \$859 across genders. Neither is used for targeting |
| Lapsed customers | Size, value and composition of the win-back pool (recency past the 90th percentile, 241 days) | 101 customers (10.1%) holding 1.6% of value, all of them Occasional Shoppers. Sports, Home and Fashion are over-represented |
| Hypothesis tests | Four formal tests: value by segment, value by age band, category mix by segment, age vs value | Value differs by segment (ANOVA p < 1e-16) and category mix differs by segment (χ² p < 1e-16). Value does not differ by age band (p = 0.633), and the age-value correlation is not significantly different from zero (p = 0.368) |
| Budget optimization | The optimal coupon per segment, solved as an integer linear program | VIPs \$20, Bargain Hunters \$5, Occasional Shoppers \$10: \$14,450 net on \$9,750 spent, \$250 unspent. Each \$1 of coupon returns about \$2.48 of incremental revenue |

Notes for comparing the report with the CSVs:

- The \$14,450 in the report and in `coupon_allocation.csv` already has the \$9,750 of coupon cost
  deducted: the objective is `population × (lift − coupon)`. Gross incremental revenue is \$24,200.
- The R report has segment counts 148 / 381 / 471 and the Python pipeline (`results_summary.json`)
  148 / 380 / 472. Two customers near a cluster boundary land differently under the two k-means
  implementations. The rest of this repository uses the Python figures. Part 3 uses the scenario's
  planning populations (150 / 350 / 500) in both.
