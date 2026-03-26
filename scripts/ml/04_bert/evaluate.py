"""Evaluate XGBoost V2 clean, V3, and V4 — with SHAP for V4.

Metrics:
  - 20% holdout AUC + P@1001
  - 10-fold CV P@1001 (full dataset, comparable to 0.48 baseline)
  - SHAP TreeExplainer for V4 (top features including embedding PCs)
"""

import sys
from pathlib import Path

import joblib
import matplotlib.pyplot as plt
import numpy as np
import shap
from sklearn.base import clone
from sklearn.model_selection import StratifiedKFold, StratifiedShuffleSplit, cross_val_predict

sys.path.insert(0, str(Path(__file__).parent.parent))
from shared.constants import FEATURES_V2_CLEAN, FEATURES_V3, FEATURES_V4
from shared.data_loader import load_and_prepare
from shared.evaluator import auc_roc, precision_at_k

RESULTS_DIR = Path(__file__).parent / "results"
RESULTS_DIR.mkdir(exist_ok=True)

V1_RESULTS_DIR = Path(__file__).parent.parent / "01_xgboost" / "results"

BASELINE_ACCURACY = 0.6633  # V2 clean CV P@1001 established in Step 1
TEST_SIZE = 0.2
RANDOM_STATE = 42


def load_model(path):
    return joblib.load(path)


def holdout_split(X, y):
    sss = StratifiedShuffleSplit(n_splits=1, test_size=TEST_SIZE, random_state=RANDOM_STATE)
    train_idx, test_idx = next(sss.split(X, y))
    return train_idx, test_idx


def cross_val_p_at_k(model, X, y, k=1001, n_splits=10):
    """Compute P@k using cross-validated predictions on the full dataset."""
    cv = StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=RANDOM_STATE)
    cloned = clone(model)
    if hasattr(cloned, "n_jobs"):
        cloned.set_params(n_jobs=1)
    oof_proba = cross_val_predict(cloned, X, y, cv=cv, method="predict_proba", n_jobs=-1)
    oof_scores = oof_proba[:, 1]
    return precision_at_k(y, oof_scores, k)


def plot_shap_summary(model, X, feature_names, out_path):
    rng = np.random.default_rng(42)
    idx = rng.choice(len(X), size=min(1000, len(X)), replace=False)
    explainer = shap.TreeExplainer(model)
    shap_values = explainer.shap_values(X[idx])
    plt.figure(figsize=(12, 8))
    shap.summary_plot(shap_values, X[idx], feature_names=feature_names, show=False, max_display=30)
    plt.tight_layout()
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close()
    print(f"  Saved → {out_path}")


def print_comparison_table(metrics):
    header = f"{'Model':<32} {'CV AUC':>8} {'HO AUC':>8} {'CV P@1001':>10} {'HO P@1001':>10}"
    sep = "=" * len(header)
    print(f"\n{sep}")
    print(header)
    print("-" * len(header))
    print(f"{'Baseline (V2 clean CV P@1001)':32} {'N/A':>8} {'N/A':>8} {BASELINE_ACCURACY:>10.4f} {'N/A':>10}")
    for name, cv_auc, ho_auc, cv_p1001, ho_p1001 in metrics:
        cv_auc_s = f"{cv_auc:.4f}" if cv_auc is not None else "N/A"
        ho_auc_s = f"{ho_auc:.4f}" if ho_auc is not None else "N/A"
        cv_p1001_s = f"{cv_p1001:.4f}" if cv_p1001 is not None else "N/A"
        ho_p1001_s = f"{ho_p1001:.4f}" if ho_p1001 is not None else "N/A"
        print(f"{name:<32} {cv_auc_s:>8} {ho_auc_s:>8} {cv_p1001_s:>10} {ho_p1001_s:>10}")
    print(f"{sep}\n")


if __name__ == "__main__":
    # Load models
    model_v2c = load_model(V1_RESULTS_DIR / "model_v2_clean.pkl")
    model_v3 = load_model(RESULTS_DIR / "model_xgb_v3.pkl")
    model_v4 = load_model(RESULTS_DIR / "model_xgb_v4.pkl")

    # Load data
    print("Loading data...")
    df_v2c, X_v2c, y_v2c, _ = load_and_prepare(FEATURES_V2_CLEAN)
    df_v3, X_v3, y_v3, _ = load_and_prepare(FEATURES_V3)
    df_v4, X_v4, y_v4, _ = load_and_prepare(FEATURES_V4)

    # Refit on train slice for unbiased holdout evaluation
    # (saved models were trained on full data; refitting gives a proper train/test split)
    train_idx_v2c, test_idx_v2c = holdout_split(X_v2c, y_v2c)
    train_idx_v3, test_idx_v3 = holdout_split(X_v3, y_v3)
    train_idx_v4, test_idx_v4 = holdout_split(X_v4, y_v4)

    model_v2c.fit(X_v2c[train_idx_v2c], y_v2c[train_idx_v2c])
    model_v3.fit(X_v3[train_idx_v3], y_v3[train_idx_v3])
    model_v4.fit(X_v4[train_idx_v4], y_v4[train_idx_v4])

    X_test_v2c, y_test_v2c = X_v2c[test_idx_v2c], y_v2c[test_idx_v2c]
    X_test_v3, y_test_v3 = X_v3[test_idx_v3], y_v3[test_idx_v3]
    X_test_v4, y_test_v4 = X_v4[test_idx_v4], y_v4[test_idx_v4]

    scores_v2c = model_v2c.predict_proba(X_test_v2c)[:, 1]
    scores_v3 = model_v3.predict_proba(X_test_v3)[:, 1]
    scores_v4 = model_v4.predict_proba(X_test_v4)[:, 1]

    # CV P@1001 on full dataset
    print("\nComputing 10-fold CV P@1001 (full dataset)...")

    print("  XGBoost V2 clean ...")
    cv_p1001_v2c = cross_val_p_at_k(model_v2c, X_v2c, y_v2c)
    print(f"    V2 clean CV P@1001: {cv_p1001_v2c:.4f}")

    print("  XGBoost V3 ...")
    cv_p1001_v3 = cross_val_p_at_k(model_v3, X_v3, y_v3)
    print(f"    V3 CV P@1001: {cv_p1001_v3:.4f}")

    print("  XGBoost V4 ...")
    cv_p1001_v4 = cross_val_p_at_k(model_v4, X_v4, y_v4)
    print(f"    V4 CV P@1001: {cv_p1001_v4:.4f}")

    # SHAP for V4
    print("\nGenerating SHAP summary for V4 ...")
    plot_shap_summary(model_v4, X_test_v4, FEATURES_V4, RESULTS_DIR / "shap_summary_v4.png")

    # Comparison table
    print_comparison_table([
        (
            "XGBoost V2 clean (established)",
            None,
            auc_roc(y_test_v2c, scores_v2c),
            cv_p1001_v2c,
            precision_at_k(y_test_v2c, scores_v2c, 1001),
        ),
        (
            "XGBoost V3 (tabular only)",
            None,
            auc_roc(y_test_v3, scores_v3),
            cv_p1001_v3,
            precision_at_k(y_test_v3, scores_v3, 1001),
        ),
        (
            "XGBoost V4 (tabular + embeddings)",
            None,
            auc_roc(y_test_v4, scores_v4),
            cv_p1001_v4,
            precision_at_k(y_test_v4, scores_v4, 1001),
        ),
    ])
