"""Train XGBoost models (V1: lens scores only, V1 clean: no leakage, V2: all features)."""

import sys
from pathlib import Path

import joblib
import numpy as np
from sklearn.model_selection import StratifiedKFold, cross_val_score
from xgboost import XGBClassifier

sys.path.insert(0, str(Path(__file__).parent.parent))
from shared.constants import FEATURES_V1, FEATURES_V1_CLEAN, FEATURES_V2, LABEL
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


def train_model(features, label, model_path):
    df, X, y, feat_names = load_and_prepare(features)

    n_positive = y.sum()
    n_negative = len(y) - n_positive
    scale_pos_weight = n_negative / n_positive
    print(f"\nLabel balance: {n_positive} positive / {n_negative} negative  (spw={scale_pos_weight:.2f})")

    params = {**XGB_PARAMS, "scale_pos_weight": scale_pos_weight, "features": ",".join(feat_names)}

    with start_run("cinegraph-1001-xgboost", model_path.stem, params):
        clf = XGBClassifier(**{**XGB_PARAMS, "scale_pos_weight": scale_pos_weight})

        cv = StratifiedKFold(n_splits=10, shuffle=True, random_state=42)
        cv_scores = cross_val_score(clf, X, y, cv=cv, scoring="roc_auc", n_jobs=-1)
        print(f"10-fold CV AUC: {cv_scores.mean():.4f} ± {cv_scores.std():.4f}")

        # Final model on full dataset
        clf.fit(X, y)
        joblib.dump(clf, model_path)
        print(f"Saved model → {model_path}")

        import mlflow
        mlflow.log_metric("cv_auc_mean", cv_scores.mean())
        mlflow.log_metric("cv_auc_std", cv_scores.std())

    return clf


if __name__ == "__main__":
    print("=== Training V1 (lens scores only, includes leaky cultural_impact_score) ===")
    train_model(FEATURES_V1, LABEL, RESULTS_DIR / "model_v1.pkl")

    print("\n=== Training V1 Clean (lens scores only, cultural_impact_score removed) ===")
    train_model(FEATURES_V1_CLEAN, LABEL, RESULTS_DIR / "model_v1_clean.pkl")

    print("\n=== Training V2 (all features) ===")
    train_model(FEATURES_V2, LABEL, RESULTS_DIR / "model_v2.pkl")
