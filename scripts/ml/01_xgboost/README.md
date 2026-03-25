# Experiment 01 — XGBoost Baseline

## Hypothesis

A gradient-boosted tree trained on the six Cinegraph lens scores plus basic metadata
(IMDb ratings, canonical overlap, director experience, decade) can significantly
outperform the current hand-tuned 48% Precision@1001 baseline.

XGBoost is an ideal starting point because:
- It handles missing values natively (many lens scores are sparse)
- It captures non-linear interactions between lens dimensions
- It provides SHAP-based feature importance for model interpretability

## Feature Sets

**V1 — Lens scores only:**
`mob_score`, `ivory_tower_score`, `festival_recognition_score`, `cultural_impact_score`,
`technical_innovation_score`, `auteur_recognition_score`

**V2 — All features:**
V1 + `canonical_overlap_count`, `imdb_votes_log`, `imdb_rating`, `decade`,
`has_festival_data`, `has_critic_data`, `director_film_count`, `years_since_release`

## Model Configuration

- XGBClassifier, `n_estimators=500`, `max_depth=6`, `learning_rate=0.1`
- `subsample=0.8`, `colsample_bytree=0.8`, `min_child_weight=5`
- `scale_pos_weight` computed from label distribution (~1001/total ratio)
- 10-fold stratified CV for stable AUC estimation

## Running

```bash
cd scripts/ml
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python shared/export_data.py        # → data/movies.parquet
python 01_xgboost/train.py          # → results/model_v1.pkl, model_v2.pkl
python 01_xgboost/evaluate.py       # → results/*.png + MLflow run
mlflow ui                           # browse at localhost:5000
```

## Results

| Model | AUC-ROC | Precision@500 | Precision@1001 |
|---|---|---|---|
| Baseline (hand-tuned) | N/A | N/A | 0.48 |
| XGBoost V1 | TBD | TBD | TBD |
| XGBoost V2 | TBD | TBD | TBD |

_Fill in after running evaluate.py_

## Interpretation

_To be filled in after results are available._

Key questions to answer:
- Which lens dimensions are most predictive?
- Does adding metadata (canonical overlap, IMDb data) improve over lens scores alone?
- Are there decade-specific patterns in misclassification?

## Accuracy Tier

_TBD — target: 90% (strong)_
