# Trained model artifacts

These are the trained models, saved so a new customer can be scored later without re-running the whole
pipeline. The scripts in `scripts/` write them and reload them for prediction.

| File | What it is | Columns |
|---|---|---|
| `rfm_scaler.csv` | preprocessing weights for the four RFM features (log1p, then standardize) | `feature`, `transform`, `mean`, `scale` |
| `segment_centroids.csv` | each segment's centre in the scaled space; the nearest centre predicts the segment | `segment`, `recency`, `frequency`, `monetary`, `aov` |
| `segment_knn_reference.csv` | the labelled reference customers the k-NN classifier votes over | `customer_id`, `recency`, `frequency`, `monetary`, `aov`, `segment` |
| `segment_knn_config.csv` | the chosen k and the preprocessing used | `param`, `value` (k = 5) |
| `segment_logit_coefficients.csv` | the segment model as one linear score per segment (equation below) | `coef_z_*`, `intercept`, `segment` |
| `clv_gradient_boosting.joblib` | the deployed value model (a scikit-learn pipeline); load with `joblib.load`, call `.predict` | binary |
| `clv_linear_coefficients.csv` | the value model written as a plain linear equation (below) | `term`, `coefficient` |
| `clv_feature_importance.csv` | permutation importance: how much the held-out RMSE rises if a feature is shuffled (bigger = more important) | `feature`, `rmse_added_if_shuffled` |

## Value model (predicts next-12-month spend, in dollars)

The deployed model is Gradient Boosting (`clv_gradient_boosting.joblib`). For a readable summary,
`clv_linear_coefficients.csv` expresses the same relationship as a plain linear equation:

```text
predicted next-12-month spend =
    -16.39
    +  1.377 * monetary
    -  0.338 * frequency
    -  1.329 * aov
    +  1.444 * age
    - 10.353 * category_diversity
    +  0.010 * recency
    -  0.080 * active_span
    -  0.008 * tenure
```

Read it as a whole: total past spend (`monetary`) is the dominant driver. The negative `frequency` and
`aov` terms are not "buying more lowers value"; they are a multicollinearity artifact, because total
spend is roughly frequency times average order value, so once `monetary` is in the model those two only
carry leftover variation.

## Segment model (score each segment, then assign the highest)

`segment_logit_coefficients.csv` scores each segment from the scaled RFM features. First scale each
feature with `rfm_scaler.csv`:

```text
z = (log(1 + x) - mean) / scale        # per RFM feature, using rfm_scaler.csv
```

Then compute a score per segment and pick the largest:

```text
score(VIPs)                = -2.59 - 0.33 * z_recency + 1.32 * z_frequency + 1.73 * z_monetary + 1.17 * z_aov
score(Bargain Hunters)     = +1.20 - 1.32 * z_recency + 1.39 * z_frequency - 0.13 * z_monetary - 2.57 * z_aov
score(Occasional Shoppers) = +1.40 + 1.65 * z_recency - 2.72 * z_frequency - 1.59 * z_monetary + 1.40 * z_aov
```

This linear model is a readable stand-in. The classifier actually used to assign new customers is the
k-NN over `segment_knn_reference.csv` (k = 5, same log1p-then-standardize preprocessing).
