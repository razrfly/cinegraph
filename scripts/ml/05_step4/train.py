"""Train V5 models: 4 XGBoost variants (rich text, varying PCA dims) + 3 LightGBM SPW variants.

XGBoost:
  model_xgb_v5_32.pkl   — FEATURES_V5_32  (tabular + rich emb 32 PCA)
  model_xgb_v5_64.pkl   — FEATURES_V5_64  (tabular + rich emb 64 PCA)
  model_xgb_v5_128.pkl  — FEATURES_V5_128 (tabular + rich emb 128 PCA)
  model_xgb_v5_384.pkl  — FEATURES_V5_384 (tabular + rich raw 384-dim)

LightGBM (FEATURES_V5_64, num_leaves=63, SPW sweep):
  model_lgbm_v5_spw50.pkl
  model_lgbm_v5_spw100.pkl
  model_lgbm_v5_spw200.pkl
"""

import sys
from pathlib import Path

import joblib
import numpy as np
from lightgbm import LGBMClassifier
from sklearn.model_selection import StratifiedKFold, cross_val_score
from xgboost import XGBClassifier

sys.path.insert(0, str(Path(__file__).parent.parent))
from shared.constants import FEATURES_V5_32, FEATURES_V5_64, FEATURES_V5_128, FEATURES_V5_384, LABEL
from shared.data_loader import load_and_prepare
from shared.mlflow_utils import start_run

RESULTS_DIR = Path(__file__).parent / "results"
RESULTS_DIR.mkdir(exist_ok=True)

XGB_PARAMS = dict(
    n_estimators=500,
    max_depth=6,
    learning_rate=0.1,
    subsample=0.8,
    colsample_bytree=0.8,
    min_child_weight=5,
    eval_metric="auc",
    enable_categorical=False,
    random_state=42,
    n_jobs=-1,
)

LGBM_BASE_PARAMS = dict(
    n_estimators=500,
    num_leaves=63,
    learning_rate=0.1,
    subsample=0.8,
    colsample_bytree=0.8,
    min_child_samples=20,
    random_state=42,
    n_jobs=-1,
    verbose=-1,
)

SPW_GRID = [50, 100, 200]


def train_xgb(features, model_path, label=LABEL):
    df, X, y, feat_names = load_and_prepare(features)

    n_positive = y.sum()
    n_negative = len(y) - n_positive
    spw = n_negative / n_positive
    print(f"  Label balance: {n_positive} pos / {n_negative} neg  (spw={spw:.2f})")

    params = {**XGB_PARAMS, "scale_pos_weight": spw, "features": ",".join(feat_names)}

    with start_run("cinegraph-1001-xgboost", model_path.stem, params):
        clf = XGBClassifier(**{**XGB_PARAMS, "scale_pos_weight": spw})

        cv = StratifiedKFold(n_splits=10, shuffle=True, random_state=42)
        cv_scores = cross_val_score(clf, X, y, cv=cv, scoring="roc_auc", n_jobs=-1)
        print(f"  10-fold CV AUC: {cv_scores.mean():.4f} ± {cv_scores.std():.4f}")

        clf.fit(X, y)
        joblib.dump(clf, model_path)
        print(f"  Saved → {model_path}")

        import mlflow
        mlflow.log_metric("cv_auc_mean", cv_scores.mean())
        mlflow.log_metric("cv_auc_std", cv_scores.std())

    return clf


def train_lgbm(features, spw, model_path, label=LABEL):
    df, X, y, feat_names = load_and_prepare(features)

    params = {**LGBM_BASE_PARAMS, "scale_pos_weight": spw, "features": ",".join(feat_names)}

    with start_run("cinegraph-1001-lgbm", model_path.stem, params):
        clf = LGBMClassifier(**{k: v for k, v in params.items() if k != "features"})

        cv = StratifiedKFold(n_splits=10, shuffle=True, random_state=42)
        cv_scores = cross_val_score(clf, X, y, cv=cv, scoring="roc_auc", n_jobs=-1)
        print(f"  10-fold CV AUC: {cv_scores.mean():.4f} ± {cv_scores.std():.4f}")

        clf.fit(X, y)
        joblib.dump(clf, model_path)
        print(f"  Saved → {model_path}")

        import mlflow
        mlflow.log_metric("cv_auc_mean", cv_scores.mean())
        mlflow.log_metric("cv_auc_std", cv_scores.std())

    return clf


if __name__ == "__main__":
    # XGBoost V5 variants
    xgb_configs = [
        (FEATURES_V5_32,  "model_xgb_v5_32"),
        (FEATURES_V5_64,  "model_xgb_v5_64"),
        (FEATURES_V5_128, "model_xgb_v5_128"),
        (FEATURES_V5_384, "model_xgb_v5_384"),
    ]
    for features, name in xgb_configs:
        print(f"\n=== XGBoost {name} ({len(features)} features) ===")
        train_xgb(features, RESULTS_DIR / f"{name}.pkl")

    # LightGBM V5 SPW sweep (FEATURES_V5_64)
    print(f"\n=== LightGBM V5 SPW sweep (FEATURES_V5_64, {len(FEATURES_V5_64)} features) ===")
    # Load data once to show label balance
    df, X_lgbm, y_lgbm, _ = load_and_prepare(FEATURES_V5_64)
    n_positive = y_lgbm.sum()
    n_negative = len(y_lgbm) - n_positive
    print(f"  Label balance: {n_positive} pos / {n_negative} neg")

    for spw in SPW_GRID:
        name = f"model_lgbm_v5_spw{spw}"
        print(f"\n  --- LightGBM spw={spw} ---")
        train_lgbm(FEATURES_V5_64, spw, RESULTS_DIR / f"{name}.pkl")
