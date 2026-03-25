"""Train Logistic Regression models on clean feature sets."""

import sys
from pathlib import Path

import joblib
import numpy as np
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import StratifiedKFold, cross_val_score
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

sys.path.insert(0, str(Path(__file__).parent.parent))
from shared.constants import FEATURES_V1_CLEAN, FEATURES_V2_CLEAN, LABEL
from shared.data_loader import load_and_prepare
from shared.mlflow_utils import start_run

RESULTS_DIR = Path(__file__).parent / "results"
RESULTS_DIR.mkdir(exist_ok=True)

C_VALUES = [0.1, 1.0, 10.0]


def make_pipeline(C):
    return Pipeline([
        ("imputer", SimpleImputer(strategy="median")),
        ("scaler", StandardScaler()),
        ("clf", LogisticRegression(
            C=C,
            class_weight="balanced",
            max_iter=1000,
            random_state=42,
        )),
    ])


def train_model(features, label, model_path):
    df, X, y, feat_names = load_and_prepare(features)

    n_positive = y.sum()
    n_negative = len(y) - n_positive
    print(f"\nLabel balance: {n_positive} positive / {n_negative} negative")

    cv = StratifiedKFold(n_splits=10, shuffle=True, random_state=42)

    best_auc = -1
    best_C = None
    print(f"  {'C':>8}  {'CV AUC':>10}")
    for C in C_VALUES:
        pipe = make_pipeline(C)
        scores = cross_val_score(pipe, X, y, cv=cv, scoring="roc_auc", n_jobs=-1)
        mean_auc = scores.mean()
        print(f"  {C:>8.1f}  {mean_auc:.4f} ± {scores.std():.4f}")
        if mean_auc > best_auc:
            best_auc = mean_auc
            best_C = C

    print(f"\n  Best C={best_C}  CV AUC={best_auc:.4f}")

    params = {"C": best_C, "features": ",".join(feat_names), "model": "logistic_regression"}
    with start_run("cinegraph-1001-logistic", model_path.stem, params):
        best_pipe = make_pipeline(best_C)
        best_pipe.fit(X, y)
        joblib.dump(best_pipe, model_path)
        print(f"  Saved model → {model_path}")

        import mlflow
        mlflow.log_metric("cv_auc_mean", best_auc)
        mlflow.log_metric("best_C", best_C)

    return best_pipe


if __name__ == "__main__":
    print("=== Training Logistic Regression V1 Clean (5 lens scores) ===")
    train_model(FEATURES_V1_CLEAN, LABEL, RESULTS_DIR / "model_lr_v1.pkl")

    print("\n=== Training Logistic Regression V2 Clean (lens + metadata) ===")
    train_model(FEATURES_V2_CLEAN, LABEL, RESULTS_DIR / "model_lr_v2.pkl")
