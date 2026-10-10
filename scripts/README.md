# How to run each script

Commands for every script in this folder. Run them from the project root (the repository folder,
the parent of `scripts/`).

Every command below uses `python3` (Python 3.9 or newer). If your setup uses `python`, substitute it.
The committed outputs were produced with Python 3.9.6, numpy 2.0.2, pandas 2.3.3, scikit-learn 1.6.1,
scipy 1.13.1, matplotlib 3.9.4, seaborn 0.13.2 and joblib 1.5.3.

## Prerequisites

```bash
python3 -m venv .venv                     # create the environment in .venv/
source .venv/bin/activate                 # Windows: .venv\Scripts\activate
python3 -m pip install --upgrade pip
python3 -m pip install pandas numpy scikit-learn scipy matplotlib seaborn joblib jupyter
# for the R script only: Rscript installs lpSolve automatically on first run
```

## Where files go by default

Each script derives the project root as the parent of this `scripts/` folder, so by default it reads
data from `data/` and writes trained models to `models/` and result tables to `outputs/` at the
project root (never inside `scripts/`). Every default can be overridden with the flags listed per
script. Relative paths you pass (for example `--predict data` or `--config scripts/scenario.json`) are
resolved from your current directory, so run from the project root.

---

## feature_engineering.py  (shared module, not run directly)

Turns the raw `customers.csv` + `transactions.csv` into one leak-safe row per customer (RFM, basket
size, tenure, category shares, demographics). `customer_segmentation.py`, `clv_regression.py` and `score_customers.py` import
it. There is nothing to run on its own.

---

## customer_segmentation.py  (Part 1: k-Means segments + k-NN classifier)

```bash
# train: learn the segments and the classifier; model to models/, labels to outputs/
python3 scripts/customer_segmentation.py

# predict: assign segments to new customers with the saved model (no retraining)
python3 scripts/customer_segmentation.py --predict path/to/new_data_folder
```

Arguments:

| Flag | Default | Meaning |
|---|---|---|
| `--data-dir DIR` | `data/` | training data folder (needs `customers.csv` + `transactions.csv`) |
| `--models-dir DIR` | `models/` | where the trained model is saved (train) or loaded (predict) |
| `--outputs-dir DIR` | `outputs/` | where result tables are written |
| `--seed INT` | `42` | random seed for reproducibility |
| `--n-clusters INT` | `3` | number of segments to create |
| `--test-size FLOAT` | `0.25` | held-out fraction for evaluating the classifier |
| `--predict FOLDER` | off | score new customers in this folder with the saved model, then exit |

```bash
# examples
python3 scripts/customer_segmentation.py --n-clusters 4            # try four segments
python3 scripts/customer_segmentation.py --seed 7 --test-size 0.3  # different seed and split
python3 scripts/customer_segmentation.py --data-dir data --models-dir models --outputs-dir outputs
```

Writes (train): `models/rfm_scaler.csv`, `models/segment_centroids.csv`, `models/segment_knn_reference.csv`,
`models/segment_knn_config.csv`, `models/segment_logit_coefficients.csv`, `outputs/customer_segments.csv`.
Writes (predict): `outputs/predicted_segments.csv`.

---

## clv_regression.py  (Part 2: customer lifetime value model)

```bash
# train: fit the gradient boosting value model; save it with metrics and predictions
python3 scripts/clv_regression.py

# predict: next-12-month value for new customers with the saved model
python3 scripts/clv_regression.py --predict path/to/new_data_folder
```

Arguments:

| Flag | Default | Meaning |
|---|---|---|
| `--data-dir DIR` | `data/` | training data folder (needs `clv_targets.csv` as the answer to learn from) |
| `--models-dir DIR` | `models/` | where the trained model is saved (train) or loaded (predict) |
| `--outputs-dir DIR` | `outputs/` | where result tables are written |
| `--seed INT` | `42` | random seed for reproducibility |
| `--test-size FLOAT` | `0.25` | held-out fraction for evaluation |
| `--max-depth INT` | `3` | tree depth of the gradient boosting model (lower = more regularized) |
| `--predict FOLDER` | off | predict value for new customers in this folder, then exit |

```bash
# examples
python3 scripts/clv_regression.py --max-depth 2      # a more regularized model
python3 scripts/clv_regression.py --seed 7 --test-size 0.3
```

Writes (train): `models/clv_gradient_boosting.joblib`, `models/clv_linear_coefficients.csv`,
`models/clv_feature_importance.csv`, `outputs/clv_predictions.csv`, `outputs/clv_metrics.csv`.
Writes (predict): `outputs/predicted_clv.csv`.

---

## budget_optimization.py  (Part 3: coupon allocation under a budget)

```bash
# default scenario: $10,000 budget; VIPs 150 / Bargain 350 / Occasional 500
python3 scripts/budget_optimization.py

# change only the budget; keep the default populations and lift
python3 scripts/budget_optimization.py --budget 8000

# new scenario: populations, coupons, lift and budget from a JSON file
python3 scripts/budget_optimization.py --config scripts/scenario.json
```

Arguments:

| Flag | Default | Meaning |
|---|---|---|
| `--config FILE` | off | JSON scenario file (populations, coupons, lift, budget); overrides only the keys it lists |
| `--budget INT` | off | override just the budget, in dollars |
| `--outputs-dir DIR` | `outputs/` | where the coupon plan is written |

The scenario JSON schema (see `scripts/scenario.json`) supports any number of segments and coupon levels:

```json
{
  "budget": 15000,
  "populations": {"VIPs": 200, "Bargain Hunters": 400, "Occasional Shoppers": 600},
  "coupons": [0, 5, 10, 15, 20],
  "lift": {"VIPs": {"0": 0, "5": 15, "10": 35, "15": 48, "20": 60}, "...": "..."}
}
```

Writes: `outputs/coupon_allocation.csv`. Only the default run also refreshes
`outputs/results_summary.json` (a `--config` or `--budget` run leaves the summary file untouched,
so re-run the default afterward to restore the default plan).

---

## score_customers.py  (reuse both saved models on new customers)

```bash
# assign a segment and predict value for new customers with the two saved models (no retraining)
python3 scripts/score_customers.py --data-dir path/to/new_data_folder
```

Requires that `customer_segmentation.py` and `clv_regression.py` have been trained first (so the models
exist in `models/`).

Arguments:

| Flag | Default | Meaning |
|---|---|---|
| `--data-dir DIR` | `data/` | folder with the new customers (`customers.csv` + `transactions.csv`) |
| `--models-dir DIR` | `models/` | folder with the trained models |
| `--output FILE` | `outputs/new_customer_scores.csv` | where the scores are written |

Writes: one row per customer with `customer_id`, `segment`, `predicted_clv`.

---

## variable_analysis_and_budget_optimization.R  (R alternative)

```bash
# variable analysis (RFM, correlations, linear model) + the coupon LP via lpSolve
Rscript scripts/variable_analysis_and_budget_optimization.R
```

No arguments. Run from the project root or from inside `scripts/`; it finds `data/` either way.
Prints every table with a short reading under it and saves the same report to
`outputs/variable_analysis_and_budget_optimization.txt`.

---

## Run the whole pipeline

```bash
python3 scripts/customer_segmentation.py     # Part 1
python3 scripts/clv_regression.py            # Part 2
python3 scripts/budget_optimization.py       # Part 3 (also refreshes results_summary.json)
```

After these three runs, `models/` and `outputs/` hold every Python result and
`outputs/results_summary.json` holds the headline numbers. Open `scripts/solutions.ipynb`
and Restart and Run All to see the same results with every figure rendered.

---

## presentation.ipynb  (deck verification only)

Checks the numbers in `Business-Presentation.pptx`. It writes nothing and trains no saved model: it reads
`data/`, `outputs/` and `models/`, recomputes every figure quoted in the deck, and prints the deck's
claim next to the recomputed value. One section per slide, in deck order: executive summary,
segmentation, CLV insights, coupon strategy, roadmap.

One helper does the work: `check(label, data, deck)` prints the deck's wording on a `deck :` line and the
recomputed value on a `data :` line directly beneath it.

It also redraws all 12 of the deck's figures from `data/`, `outputs/` and `models/` in the deck's
palette, and refits the three-question decision tree so its splits are the model's thresholds.

It finds the project root by walking up from wherever it is launched and takes no arguments. It runs
as-is on the committed `outputs/` and `models/`, or on ones regenerated by the three scripts. Both of these work:

```bash
jupyter notebook scripts/presentation.ipynb   # from the project root
cd scripts && jupyter notebook presentation.ipynb   # or from inside scripts/
```
