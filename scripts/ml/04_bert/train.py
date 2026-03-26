"""Train XGBoost V3 (tabular only) and V4 (tabular + 32 embedding PCs).

V3 fills the Step 2 gap — its CV AUC was measured but P@1001 was not.
V4 adds 32 MiniLM PCA components to V3's 20 tabular features.
"""

import sys
from pathlib import Path

import joblib
import numpy as np
from sklearn.model_selection import StratifiedKFold, cross_val_score
from xgboost import XGBClassifier

sys.path.insert(0, str(Path(__file__).parent.parent))
from shared.constants import FEATURES_V3, FEATURES_V4, LABEL
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
    print(f"\n  Label balance: {n_positive} positive / {n_negative} negative  (spw={scale_pos_weight:.2f})")

    params = {**XGB_PARAMS, "scale_pos_weight": scale_pos_weight, "features": ",".join(feat_names)}

    with start_run("cinegraph-1001-xgboost", model_path.stem, params):
        clf = XGBClassifier(**{**XGB_PARAMS, "scale_pos_weight": scale_pos_weight})

        cv = StratifiedKFold(n_splits=10, shuffle=True, random_state=42)
        cv_scores = cross_val_score(clf, X, y, cv=cv, scoring="roc_auc", n_jobs=-1)
        print(f"  10-fold CV AUC: {cv_scores.mean():.4f} ± {cv_scores.std():.4f}")

        clf.fit(X, y)
        joblib.dump(clf, model_path)
        print(f"  Saved model → {model_path}")

        import mlflow
        mlflow.log_metric("cv_auc_mean", cv_scores.mean())
        mlflow.log_metric("cv_auc_std", cv_scores.std())

    return clf


if __name__ == "__main__":
    print(f"=== Training XGBoost V3 ({len(FEATURES_V3)} tabular features) ===")
    train_model(FEATURES_V3, LABEL, RESULTS_DIR / "model_xgb_v3.pkl")

    print(f"\n=== Training XGBoost V4 ({len(FEATURES_V4)} features: tabular + 32 embedding PCs) ===")
    train_model(FEATURES_V4, LABEL, RESULTS_DIR / "model_xgb_v4.pkl")
