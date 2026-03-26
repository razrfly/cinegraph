# Cinegraph ML Experiments

Benchmarking effort to improve 1001-Movies-list prediction accuracy from 48% to 90%.
Each numbered directory is a self-contained experiment with its own `train.py`, `evaluate.py`, and `README.md`.

## Directory Structure

```
scripts/ml/
├── README.md               ← this file
├── requirements.txt        ← shared Python deps
├── .gitignore
├── shared/                 ← utilities shared across experiments
│   ├── constants.py        ← feature lists, label, DB URL
│   ├── export_data.py      ← Postgres → data/movies.parquet
│   ├── data_loader.py      ← parquet → (df, X, y, features)
│   ├── evaluator.py        ← AUC, Precision@K, per-decade accuracy
│   └── mlflow_utils.py     ← MLflow context manager
├── data/
│   └── movies.parquet      ← generated, gitignored
└── 01_xgboost/
    ├── train.py
    ├── evaluate.py
    ├── README.md
    └── results/            ← models + plots, gitignored
```

## Setup

```bash
cd scripts/ml
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

## Workflow

```bash
# 1. Export data (once per schema change)
python shared/export_data.py

# 2. Run an experiment
python 01_xgboost/train.py
python 01_xgboost/evaluate.py

# 3. Browse results
mlflow ui
```

## Experiments

| # | Name | Status | AUC | P@1001 |
|---|---|---|---|---|
| 01 | XGBoost | pending | — | — |

## Accuracy Tiers

| Threshold | Tier |
|---|---|
| < 50% | insufficient |
| 50–65% | marginal |
| 65–80% | good |
| 80–90% | very good |
| ≥ 90% | strong |
