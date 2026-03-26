# Experiment 02: Logistic Regression

## Hypothesis

Is XGBoost's tree-based complexity actually necessary to identify 1001-list membership, or is the decision boundary essentially linear in the lens score space?

A logistic regression baseline answers this: if LR matches XGBoost on clean features, the signal is linear and the tree complexity adds nothing. If XGBoost significantly outperforms, then interaction effects or non-linearities in the lens scores matter.

## Methodology

- **Features**: `FEATURES_V1_CLEAN` (5 lens scores, no leakage) and `FEATURES_V2_CLEAN` (+ metadata)
- **Pipeline**: `SimpleImputer(median) → StandardScaler → LogisticRegression(class_weight='balanced', max_iter=1000)`
- **C sweep**: 0.1, 1.0, 10.0 — 10-fold stratified CV AUC to select best regularization
- **Evaluation**: holdout AUC + cross-validated P@1001 (full dataset, 10-fold) for fair comparison to 48% baseline
- **SHAP**: `LinearExplainer` for feature importance

## Results

| Model | HO AUC | CV P@1001 | Notes |
|---|---|---|---|
| Baseline | — | 0.48 | current system |
| XGBoost V1 clean | TBD | TBD | 5 lens scores, no leakage |
| LR V1 clean | TBD | TBD | linear, 5 lens scores |
| LR V2 clean | TBD | TBD | linear, + metadata |

## Interpretation

*(Fill after running)*
