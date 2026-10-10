#!/usr/bin/env python3
"""
Customer segmentation (Part 1): k-Means segments + a k-NN classifier.

TRAIN (default): learn behavioural segments from the RFM features, name them,
train the classifier, and save the segmentation model to --models-dir plus the
labelled customers to --outputs-dir.

PREDICT (--predict <folder>): load the saved model and assign segments to NEW
customers, without re-training.

Examples:
    python customer_segmentation.py --data-dir data                  # train, save the model
    python customer_segmentation.py --n-clusters 4 --data-dir data   # try a different number of segments
    python customer_segmentation.py --predict new_data               # score new customers with the saved model
"""
import argparse, os
import numpy as np, pandas as pd
from sklearn.preprocessing import StandardScaler, FunctionTransformer
from sklearn.cluster import KMeans
from sklearn.neighbors import KNeighborsClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import Pipeline
from sklearn.model_selection import train_test_split, StratifiedKFold, cross_val_score
from sklearn.metrics import accuracy_score, f1_score
from feature_engineering import load_tables, build_customer_features, RFM_DRIVERS

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def train(a):
    customers, transactions, _ = load_tables(a.data_dir)
    feats = build_customer_features(customers, transactions)
    os.makedirs(a.models_dir, exist_ok=True); os.makedirs(a.outputs_dir, exist_ok=True)

    scaler = StandardScaler().fit(np.log1p(feats[RFM_DRIVERS]))                # log1p tames skew, standardize equalises scale
    Xs = scaler.transform(np.log1p(feats[RFM_DRIVERS]))
    km = KMeans(n_clusters=a.n_clusters, random_state=a.seed, n_init=10).fit(Xs)
    feats["cluster"] = km.labels_
    # name each cluster from its profile (biggest spender = VIP; of the rest the most frequent = Bargain Hunters)
    med = feats.groupby("cluster")[RFM_DRIVERS].median(); vip = med["monetary"].idxmax()
    rest = [c for c in med.index if c != vip]; barg = max(rest, key=lambda c: med.loc[c, "frequency"]); occ = [c for c in rest if c != barg][0]
    names = {vip: "VIPs", barg: "Bargain Hunters", occ: "Occasional Shoppers"}
    for c in med.index:                                                       # any extra clusters (n > 3) keep a plain name
        names.setdefault(c, f"Segment {c}")
    feats["segment"] = feats["cluster"].map(names)

    # k-NN classifier: pick k by cross-validation, then measure held-out accuracy
    def knn(k): return Pipeline([("log", FunctionTransformer(np.log1p)), ("scale", StandardScaler()), ("knn", KNeighborsClassifier(n_neighbors=k))])
    Xtr, Xte, ytr, yte = train_test_split(feats[RFM_DRIVERS].values, feats["segment"].values, test_size=a.test_size, stratify=feats["segment"], random_state=a.seed)
    cv = StratifiedKFold(5, shuffle=True, random_state=a.seed)
    scores = [(k, cross_val_score(knn(k), Xtr, ytr, cv=cv, scoring="accuracy").mean()) for k in range(3, 26, 2)]
    K = min(k for k, s in scores if abs(s - max(v for _, v in scores)) < 1e-9)
    clf = knn(K).fit(Xtr, ytr); pred = clf.predict(Xte)
    logit = LogisticRegression(multi_class="multinomial", max_iter=2000).fit(Xs, feats["segment"].values)

    # ---- save the segmentation model (models/) and the labelled customers (outputs/) ----
    M, O = a.models_dir, a.outputs_dir
    pd.DataFrame({"feature": RFM_DRIVERS, "transform": "log1p", "mean": scaler.mean_, "scale": scaler.scale_}).to_csv(f"{M}/rfm_scaler.csv", index=False)
    cen = pd.DataFrame(km.cluster_centers_, columns=RFM_DRIVERS)
    cen.insert(0, "segment", [names[i] for i in range(a.n_clusters)]); cen.insert(0, "cluster", range(a.n_clusters))
    cen.to_csv(f"{M}/segment_centroids.csv", index=False)
    feats[["customer_id"] + RFM_DRIVERS + ["segment"]].to_csv(f"{M}/segment_knn_reference.csv", index=False)
    pd.DataFrame({"param": ["k", "preprocessing"], "value": [K, "log1p then standardize with rfm_scaler.csv"]}).to_csv(f"{M}/segment_knn_config.csv", index=False)
    eq = pd.DataFrame(logit.coef_, columns=[f"coef_z_{c}" for c in RFM_DRIVERS]); eq.insert(0, "intercept", logit.intercept_); eq.insert(0, "segment", logit.classes_)
    eq.to_csv(f"{M}/segment_logit_coefficients.csv", index=False)
    feats.to_csv(f"{O}/customer_segments.csv", index=False)
    print(f"[segmentation] sizes {feats['segment'].value_counts().to_dict()} | k-NN k={K}  test accuracy {accuracy_score(yte, pred):.3f}  macro-F1 {f1_score(yte, pred, average='macro'):.3f}")
    print(f"[segmentation] model saved to {M}/  |  labelled customers -> {O}/customer_segments.csv")

def predict(a):
    customers, transactions, _ = load_tables(a.predict)
    feats = build_customer_features(customers, transactions)
    scaler = pd.read_csv(f"{a.models_dir}/rfm_scaler.csv"); cen = pd.read_csv(f"{a.models_dir}/segment_centroids.csv")
    z = (np.log1p(feats[RFM_DRIVERS].values) - scaler["mean"].values) / scaler["scale"].values     # same preprocessing as training
    dist = ((z[:, None, :] - cen[RFM_DRIVERS].values[None, :, :]) ** 2).sum(2)                      # distance to each segment centre
    feats["segment"] = cen["segment"].values[dist.argmin(1)]                                        # nearest centre wins
    os.makedirs(a.outputs_dir, exist_ok=True)
    out = feats[["customer_id"] + RFM_DRIVERS + ["segment"]]
    out.to_csv(f"{a.outputs_dir}/predicted_segments.csv", index=False)
    print(f"[segmentation] assigned segments to {len(out)} new customers -> {a.outputs_dir}/predicted_segments.csv")
    print("  " + str(out["segment"].value_counts().to_dict()))

def main():
    ap = argparse.ArgumentParser(description="Customer segmentation: train the model, or --predict on new data.")
    ap.add_argument("--data-dir", default=os.path.join(ROOT, "data"), help="training data folder (customers.csv + transactions.csv)")
    ap.add_argument("--models-dir", default=os.path.join(ROOT, "models"), help="where the trained model is saved/loaded")
    ap.add_argument("--outputs-dir", default=os.path.join(ROOT, "outputs"), help="where result tables are written")
    ap.add_argument("--seed", type=int, default=42, help="random seed for reproducibility")
    ap.add_argument("--n-clusters", type=int, default=3, help="number of segments to create")
    ap.add_argument("--test-size", type=float, default=0.25, help="held-out fraction for evaluating the classifier")
    ap.add_argument("--predict", default=None, metavar="FOLDER", help="score NEW customers in this data folder using the saved model")
    a = ap.parse_args()
    predict(a) if a.predict else train(a)

if __name__ == "__main__":
    main()
