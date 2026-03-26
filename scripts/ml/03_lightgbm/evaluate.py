"""Evaluate LightGBM V3 and compare against prior models."""

import sys
from pathlib import Path

import joblib
import matplotlib.pyplot as plt
import mlflow
import numpy as np
import shap
from sklearn.base import clone
from sklearn.model_selection import StratifiedKFold, StratifiedShuffleSplit, cross_val_predict

sys.path.insert(0, str(Path(__file__).parent.parent))
from shared.constants import FEATURES_V1_CLEAN, FEATURES_V2_CLEAN, FEATURES_V3, LABEL
from shared.data_loader import load_and_prepare
from shared.evaluator import auc_roc, precision_at_k, report
from shared.mlflow_utils import start_run, TRACKING_URI

RESULTS_DIR = Path(__file__).parent / "results"
XGB_RESULTS_DIR = Path(__file__).parent.parent / "01_xgboost" / "results"
BASELINE_ACCURACY = 0.48
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
    return precision_at_k(y, oof_proba[:, 1], k)


def cross_val_p_at_k_lgbm(model, X, y, k=1001, n_splits=10):
    """Like cross_val_p_at_k but uses raw log-odds for ranking.

    LightGBM with extreme scale_pos_weight saturates predict_proba to 1.0 for
    many rows, causing argsort tie-breaking to dominate P@k.  Raw log-odds are
    unbounded, preserve the true ranking, and avoid saturation entirely.
    """
    from sklearn.base import clone

    cv = StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=RANDOM_STATE)
    oof_scores = np.empty(len(y), dtype=np.float64)
    for train_idx, test_idx in cv.split(X, y):
        m = clone(model)
        m.fit(X[train_idx], y[train_idx])
        # raw_score=True returns log-odds (unbounded, no saturation)
        oof_scores[test_idx] = m.predict(X[test_idx], raw_score=True)
    return precision_at_k(y, oof_scores, k)


def plot_shap_summary(model, X, feature_names, out_path):
    rng = np.random.default_rng(42)
    idx = rng.choice(len(X), size=min(1000, len(X)), replace=False)
    explainer = shap.TreeExplainer(model)
    shap_values = explainer.shap_values(X[idx])
    # LightGBM TreeExplainer may return list for binary; use index 1 if so
    sv = shap_values[1] if isinstance(shap_values, list) else shap_values
    plt.figure(figsize=(10, 6))
    shap.summary_plot(sv, X[idx], feature_names=feature_names, show=False)
    plt.tight_layout()
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close()
    print(f"Saved → {out_path}")


def print_comparison_table(metrics):
    """metrics: list of (name, cv_auc, holdout_auc, cv_p1001, holdout_p1001)"""
    header = f"{'Model':<32} {'CV AUC':>8} {'HO AUC':>8} {'CV P@1001':>10} {'HO P@1001':>10}"
    sep = "=" * len(header)
    print(f"\n{sep}")
    print(header)
    print("-" * len(header))
    print(f"{'Baseline (hand)':32} {'N/A':>8} {'N/A':>8} {BASELINE_ACCURACY:>10.4f} {'N/A':>10}")
    for name, cv_auc, ho_auc, cv_p1001, ho_p1001 in metrics:
        cv_auc_s = f"{cv_auc:.4f}" if cv_auc is not None else "N/A"
        ho_auc_s = f"{ho_auc:.4f}" if ho_auc is not None else "N/A"
        cv_p_s = f"{cv_p1001:.4f}" if cv_p1001 is not None else "N/A"
        ho_p_s = f"{ho_p1001:.4f}" if ho_p1001 is not None else "N/A"
        print(f"{name:<32} {cv_auc_s:>8} {ho_auc_s:>8} {cv_p_s:>10} {ho_p_s:>10}")
    print(f"{sep}\n")


if __name__ == "__main__":
    # Load models
    model_v1c = load_model(XGB_RESULTS_DIR / "model_v1_clean.pkl")
    model_v2c = load_model(XGB_RESULTS_DIR / "model_v2_clean.pkl")
    model_lgbm = load_model(RESULTS_DIR / "model_lgbm_v3.pkl")

    # Load data
    df_v1c, X_v1c, y_v1c, _ = load_and_prepare(FEATURES_V1_CLEAN)
    df_v2c, X_v2c, y_v2c, _ = load_and_prepare(FEATURES_V2_CLEAN)
    df_v3, X_v3, y_v3, _ = load_and_prepare(FEATURES_V3)

    # Refit on train slice for unbiased holdout evaluation
    # (saved models were trained on full data; refitting gives a proper train/test split)
    train_idx_v1c, test_idx_v1c = holdout_split(X_v1c, y_v1c)
    train_idx_v2c, test_idx_v2c = holdout_split(X_v2c, y_v2c)
    train_idx_v3, test_idx_v3 = holdout_split(X_v3, y_v3)

    model_v1c.fit(X_v1c[train_idx_v1c], y_v1c[train_idx_v1c])
    model_v2c.fit(X_v2c[train_idx_v2c], y_v2c[train_idx_v2c])
    model_lgbm.fit(X_v3[train_idx_v3], y_v3[train_idx_v3])

    X_test_v1c, y_test_v1c = X_v1c[test_idx_v1c], y_v1c[test_idx_v1c]
    X_test_v2c, y_test_v2c = X_v2c[test_idx_v2c], y_v2c[test_idx_v2c]
    X_test_v3, y_test_v3 = X_v3[test_idx_v3], y_v3[test_idx_v3]
    df_test_v3 = df_v3.iloc[test_idx_v3].reset_index(drop=True)

    scores_v1c = model_v1c.predict_proba(X_test_v1c)[:, 1]
    scores_v2c = model_v2c.predict_proba(X_test_v2c)[:, 1]
    scores_v3 = model_lgbm.predict_proba(X_test_v3)[:, 1]

    mlflow.set_tracking_uri(TRACKING_URI)

    with start_run("cinegraph-1001-lgbm", "evaluate_lgbm_v3", {"features": "v3", "split": "holdout_20pct"}):
        report(df_test_v3, scores_v3, y_test_v3, "lgbm_v3", {"features": "v3", "split": "holdout_20pct"})
        plot_shap_summary(model_lgbm, X_test_v3, FEATURES_V3, RESULTS_DIR / "shap_lgbm_v3.png")
        mlflow.log_artifact(str(RESULTS_DIR / "shap_lgbm_v3.png"))

    # Cross-validated P@1001 — comparable to baseline
    print("\nComputing cross-val P@1001 (full dataset, 10-fold)...")
    print("  XGB V1 clean...")
    cv_p_v1c = cross_val_p_at_k(model_v1c, X_v1c, y_v1c)
    print(f"    CV P@1001: {cv_p_v1c:.4f}")

    print("  XGB V2 clean...")
    cv_p_v2c = cross_val_p_at_k(model_v2c, X_v2c, y_v2c)
    print(f"    CV P@1001: {cv_p_v2c:.4f}")

    print("  LightGBM V3 (raw log-odds ranking)...")
    cv_p_v3 = cross_val_p_at_k_lgbm(model_lgbm, X_v3, y_v3)
    print(f"    CV P@1001: {cv_p_v3:.4f}")

    print_comparison_table([
        (
            "XGBoost V1 clean",
            None,
            auc_roc(y_test_v1c, scores_v1c),
            cv_p_v1c,
            precision_at_k(y_test_v1c, scores_v1c, 1001),
        ),
        (
            "XGBoost V2 clean",
            None,
            auc_roc(y_test_v2c, scores_v2c),
            cv_p_v2c,
            precision_at_k(y_test_v2c, scores_v2c, 1001),
        ),
        (
            "LightGBM V3",
            None,
            auc_roc(y_test_v3, scores_v3),
            cv_p_v3,
            precision_at_k(y_test_v3, scores_v3, 1001),
        ),
    ])
