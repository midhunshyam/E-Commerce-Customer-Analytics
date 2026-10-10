#!/usr/bin/env python3
"""
Score NEW customers by reusing the saved models (no re-training).

Loads the segmentation model and the CLV model from --models-dir and writes one
row per new customer with their assigned segment and predicted next-12-month
value. Run the training scripts first so the models exist.

Example:
    python customer_segmentation.py --data-dir data     # train + save segmentation model
    python clv_regression.py        --data-dir data     # train + save value model
    python score_customers.py       --data-dir new_data # reuse both models on new customers
"""
import argparse, os
import numpy as np, pandas as pd, joblib
from feature_engineering import load_tables, build_customer_features, RFM_DRIVERS, CATEGORICAL

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def main():
    ap = argparse.ArgumentParser(description="Score new customers with the saved segmentation and CLV models.")
    ap.add_argument("--data-dir", default=os.path.join(ROOT, "data"), help="NEW data folder (customers.csv + transactions.csv)")
    ap.add_argument("--models-dir", default=os.path.join(ROOT, "models"), help="folder with the trained models")
    ap.add_argument("--output", default=os.path.join(ROOT, "outputs", "new_customer_scores.csv"), help="where to write the scores")
    a = ap.parse_args()

    customers, transactions, _ = load_tables(a.data_dir)
    feats = build_customer_features(customers, transactions)               # same feature engineering as training

    # 1) segment: assign to the nearest saved k-Means centre (in the log-scaled space)
    scaler = pd.read_csv(f"{a.models_dir}/rfm_scaler.csv"); cen = pd.read_csv(f"{a.models_dir}/segment_centroids.csv")
    z = (np.log1p(feats[RFM_DRIVERS].values) - scaler["mean"].values) / scaler["scale"].values
    feats["segment"] = cen["segment"].values[(((z[:, None, :] - cen[RFM_DRIVERS].values[None, :, :]) ** 2).sum(2)).argmin(1)]

    # 2) value: predict with the saved gradient-boosting model
    numeric = ["recency", "frequency", "monetary", "aov", "tenure", "active_span", "category_diversity", "age"] + [c for c in feats.columns if c.startswith("pct_")]
    model = joblib.load(f"{a.models_dir}/clv_gradient_boosting.joblib")
    feats["predicted_clv"] = model.predict(feats[numeric + CATEGORICAL]).round(2)

    os.makedirs(os.path.dirname(a.output), exist_ok=True)
    scores = feats[["customer_id", "segment", "predicted_clv"]]
    scores.to_csv(a.output, index=False)
    print(f"[score] scored {len(scores)} customers (segment + predicted value) -> {a.output}")
    print(scores.head().to_string(index=False))

if __name__ == "__main__":
    main()
