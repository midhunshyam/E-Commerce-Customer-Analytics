#!/usr/bin/env python3
"""
Customer lifetime value regression (Part 2): predict target_clv_next_12_months.

TRAIN (default): fit a Gradient Boosting model, then save it (plus a readable
linear-equation form and the driver importances) to --models-dir and the
predictions/metrics to --outputs-dir.

PREDICT (--predict <folder>): load the saved model and predict next-12-month
value for NEW customers, without re-training.

Examples:
    python clv_regression.py --data-dir data                 # train, save the model
    python clv_regression.py --max-depth 2 --data-dir data   # a more regularized model
    python clv_regression.py --predict new_data              # predict value for new customers
"""
import argparse, os
import numpy as np, pandas as pd, joblib
from sklearn.compose import ColumnTransformer
from sklearn.preprocessing import OneHotEncoder
from sklearn.pipeline import Pipeline
from sklearn.ensemble import GradientBoostingRegressor
from sklearn.linear_model import LinearRegression
from sklearn.model_selection import train_test_split
from sklearn.metrics import mean_squared_error, mean_absolute_error, r2_score
from sklearn.inspection import permutation_importance
from feature_engineering import load_tables, build_customer_features, CATEGORICAL

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = "target_clv_next_12_months"

def feature_columns(feats):
    """The model inputs: numeric behaviours + one demographic (age), plus the demographic categoricals."""
    numeric = ["recency", "frequency", "monetary", "aov", "tenure", "active_span", "category_diversity", "age"] + \
              [c for c in feats.columns if c.startswith("pct_")]
    return numeric, CATEGORICAL

def train(a):
    customers, transactions, clv = load_tables(a.data_dir)
    if clv is None:
        raise SystemExit("Training needs clv_targets.csv in --data-dir (the answer to learn from).")
    feats = build_customer_features(customers, transactions)
    df = feats.merge(clv, on="customer_id")
    numeric, categorical = feature_columns(feats)
    X, y = df[numeric + categorical], df[TARGET].values
    os.makedirs(a.models_dir, exist_ok=True); os.makedirs(a.outputs_dir, exist_ok=True)

    # numbers pass through; text columns become 0/1 one-hot columns the model can read
    prep = ColumnTransformer([("num", "passthrough", numeric), ("cat", OneHotEncoder(handle_unknown="ignore"), categorical)])
    model = Pipeline([("prep", prep), ("gb", GradientBoostingRegressor(random_state=a.seed, max_depth=a.max_depth))])
    Xtr, Xte, ytr, yte = train_test_split(X, y, test_size=a.test_size, random_state=a.seed)
    model.fit(Xtr, ytr); p = model.predict(Xte)
    rmse, mae, r2 = mean_squared_error(yte, p) ** 0.5, mean_absolute_error(yte, p), r2_score(yte, p)
    imp = permutation_importance(model, Xte, yte, n_repeats=20, random_state=a.seed, scoring="neg_root_mean_squared_error")
    model.fit(X, y)                                                          # refit on all customers for deployment

    lin_terms = ["monetary", "frequency", "aov", "age", "category_diversity", "recency", "active_span", "tenure"]
    lin = LinearRegression().fit(df[lin_terms].values, y)                    # readable linear-equation form

    M, O = a.models_dir, a.outputs_dir
    joblib.dump(model, f"{M}/clv_gradient_boosting.joblib")                  # deployed model (tree ensemble; joblib is its standard format)
    pd.DataFrame({"term": ["intercept"] + lin_terms, "coefficient": [lin.intercept_] + list(lin.coef_)}).to_csv(f"{M}/clv_linear_coefficients.csv", index=False)
    pd.Series(imp.importances_mean, index=numeric + categorical).sort_values(ascending=False).rename("rmse_added_if_shuffled").to_csv(f"{M}/clv_feature_importance.csv")
    pd.DataFrame({"customer_id": df["customer_id"], "predicted_clv": model.predict(X), "actual_clv": y}).to_csv(f"{O}/clv_predictions.csv", index=False)
    pd.DataFrame({"metric": ["test_rmse", "test_mae", "test_r2"], "value": [round(rmse, 2), round(mae, 2), round(r2, 4)]}).to_csv(f"{O}/clv_metrics.csv", index=False)
    print(f"[clv] held-out RMSE ${rmse:.2f}  MAE ${mae:.2f}  R2 {r2:.4f}  |  linear-equation R2 {r2_score(y, lin.predict(df[lin_terms].values)):.4f}")
    print(f"[clv] model saved to {M}/clv_gradient_boosting.joblib  |  predictions/metrics -> {O}/")

def predict(a):
    customers, transactions, _ = load_tables(a.predict)
    feats = build_customer_features(customers, transactions)
    numeric, categorical = feature_columns(feats)
    model = joblib.load(f"{a.models_dir}/clv_gradient_boosting.joblib")
    feats["predicted_clv"] = model.predict(feats[numeric + categorical])
    os.makedirs(a.outputs_dir, exist_ok=True)
    out = feats[["customer_id", "predicted_clv"]]
    out.to_csv(f"{a.outputs_dir}/predicted_clv.csv", index=False)
    print(f"[clv] predicted next-12-month value for {len(out)} new customers -> {a.outputs_dir}/predicted_clv.csv")

def main():
    ap = argparse.ArgumentParser(description="CLV regression: train the model, or --predict on new data.")
    ap.add_argument("--data-dir", default=os.path.join(ROOT, "data"), help="training data folder (needs clv_targets.csv)")
    ap.add_argument("--models-dir", default=os.path.join(ROOT, "models"), help="where the trained model is saved/loaded")
    ap.add_argument("--outputs-dir", default=os.path.join(ROOT, "outputs"), help="where result tables are written")
    ap.add_argument("--seed", type=int, default=42, help="random seed for reproducibility")
    ap.add_argument("--test-size", type=float, default=0.25, help="held-out fraction for evaluation")
    ap.add_argument("--max-depth", type=int, default=3, help="tree depth of the gradient boosting model (lower = more regularized)")
    ap.add_argument("--predict", default=None, metavar="FOLDER", help="predict value for NEW customers in this data folder")
    a = ap.parse_args()
    predict(a) if a.predict else train(a)

if __name__ == "__main__":
    main()
