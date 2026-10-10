# How to run each script

Copy-paste ready commands for every script in this folder. Run them from the **project root**
(the repository folder), which is the parent of this `scripts/` folder.

Every command below uses `python3` (Python 3.9 or newer). If your setup uses `python`, substitute it.
The pipeline was last run end to end with Python 3.9.6, numpy 2.0.2, pandas 2.3.3, scikit-learn 1.6.1,
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
size, tenure, category shares, demographics). The three pipeline scripts and `score_customers.py` import
it. There is nothing to run on its own.

---

## customer_segmentation.py  (Part 1: k-Means segments + k-NN classifier)

```bash
# TRAIN: learn the segments, train the classifier, save the model to models/ and labels to outputs/
python3 scripts/customer_segmentation.py

# PREDICT: assign segments to NEW customers using the saved model (no retraining)
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
| `--predict FOLDER` | off | score NEW customers in this folder with the saved model, then exit |

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
# TRAIN: fit the Gradient Boosting value model, save it plus metrics and predictions
python3 scripts/clv_regression.py

# PREDICT: predict next-12-month value for NEW customers using the saved model
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
| `--predict FOLDER` | off | predict value for NEW customers in this folder, then exit |

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
# DEFAULT: solve the case-study scenario ($10,000 budget; VIPs 150 / Bargain 350 / Occasional 500)
python3 scripts/budget_optimization.py

# NEW BUDGET only: keep the default populations and lift, change just the budget
python3 scripts/budget_optimization.py --budget 8000

# NEW SCENARIO: override populations, coupons, lift, budget from a JSON file
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

Writes: `outputs/coupon_allocation.csv`. The **default run only** also refreshes
`outputs/results_summary.json` (a `--config` or `--budget` run leaves the summary file untouched,
so re-run the default afterward to restore the default plan).

---

## score_customers.py  (reuse both saved models on new customers)

```bash
# score NEW customers: assign a segment AND predict value, reusing the two saved models (no retraining)
python3 scripts/score_customers.py --data-dir path/to/new_data_folder
```

Requires that `customer_segmentation.py` and `clv_regression.py` have been trained first (so the models
exist in `models/`).

Arguments:

| Flag | Default | Meaning |
|---|---|---|
| `--data-dir DIR` | `data/` | NEW data folder (`customers.csv` + `transactions.csv`) |
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
Prints every table with a plain-language reading under it and saves the same report to
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
and Restart and Run All to see the same results with every figure rendered. The notebook rewrites
some of the same files in a slightly richer layout (for example `customer_segments.csv` gains the
`top_category` and `future_value` columns); the committed files are in that layout.

---

## presentation.ipynb  (deck verification only)

The audit trail for `Business-Presentation.pptx`. It writes nothing and trains nothing: it reads
`data/`, `outputs/` and `models/`, recomputes every figure quoted in the deck, and prints the deck's
claim next to the recomputed value so anyone can check the two agree. One section per slide, in
deck order: executive summary, segmentation, CLV insights, coupon strategy, roadmap.

One helper does the work: `check(label, data, deck)` prints the deck's wording on a `deck :` line and the
recomputed value on a `data :` line directly beneath it, so the two sit one above the other.

It also **redraws all 12 of the deck's figures from the data**, in the deck's own palette, so each chart
sits beside the numbers behind it. No screenshots and no image files are involved: every chart is
plotted from `data/`, `outputs/` and `models/`, and the three-question decision tree is refitted here so
its splits are the model's real thresholds.

**Self-contained.** It reads only `data/`, `outputs/` and `models/` from this repository, finds the
project root by walking up from wherever it is launched, and takes no arguments, so there is nothing to
edit and no external assets. It runs as-is on the committed `outputs/` and `models/`. If you regenerate
them, run `solutions.ipynb` as well as the three scripts: the deck checks read the `future_value` column
of `outputs/customer_segments.csv`, which only the notebook writes. Both of these work unchanged:

```bash
jupyter notebook scripts/presentation.ipynb   # from the project root
cd scripts && jupyter notebook presentation.ipynb   # or from inside scripts/
```
