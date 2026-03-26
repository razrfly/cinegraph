"""Evaluate trained XGBoost models and generate artifacts."""

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
from shared.constants import FEATURES_V1, FEATURES_V1_CLEAN, FEATURES_V2, FEATURES_V2_CLEAN, LABEL
from shared.data_loader import load_and_prepare
from shared.evaluator import auc_roc, precision_at_k, per_decade_accuracy, report
from shared.mlflow_utils import start_run, TRACKING_URI

RESULTS_DIR = Path(__file__).parent / "results"
BASELINE_ACCURACY = 0.48  # current hand-tuned baseline
TEST_SIZE = 0.2
RANDOM_STATE = 42


def load_model(path):
    return joblib.load(path)


def holdout_split(X, y):
    sss = StratifiedShuffleSplit(n_splits=1, test_size=TEST_SIZE, random_state=RANDOM_STATE)
    train_idx, test_idx = next(sss.split(X, y))
    return train_idx, test_idx


def cross_val_p_at_k(model, X, y, k=1001, n_splits=10):
    """Compute P@k using cross-validated predictions on the full dataset.

    Uses all positives in the dataset as denominator, making the result
    directly comparable to the 48% baseline (P@1001 over all 1,256 positives).
    """
    cv = StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=RANDOM_STATE)
    # Clone and force n_jobs=1 on the estimator to avoid nested parallelism;
    # cross_val_predict's own n_jobs=-1 handles outer-fold parallelism.
    cloned = clone(model)
    if hasattr(cloned, "n_jobs"):
        cloned.set_params(n_jobs=1)
    oof_proba = cross_val_predict(cloned, X, y, cv=cv, method="predict_proba", n_jobs=-1)
    oof_scores = oof_proba[:, 1]
    return precision_at_k(y, oof_scores, k)


def plot_score_distribution(scores_v1, scores_v2, y_true, out_path):
    fig, axes = plt.subplots(1, 2, figsize=(12, 4))
    for ax, scores, label in zip(axes, [scores_v1, scores_v2], ["V1 (lens only)", "V2 (all features)"]):
        ax.hist(scores[y_true == 0], bins=50, alpha=0.6, label="Not on list", color="steelblue")
        ax.hist(scores[y_true == 1], bins=50, alpha=0.6, label="On 1001 list", color="tomato")
        ax.set_title(label)
        ax.set_xlabel("Predicted probability")
        ax.set_ylabel("Count")
        ax.legend()
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()
    print(f"Saved → {out_path}")


def plot_shap_summary(model, X, feature_names, out_path):
    # Sample for SHAP performance (1k rows is plenty)
    rng = np.random.default_rng(42)
    idx = rng.choice(len(X), size=min(1000, len(X)), replace=False)
    explainer = shap.TreeExplainer(model)
    shap_values = explainer.shap_values(X[idx])
    plt.figure(figsize=(10, 6))
    shap.summary_plot(shap_values, X[idx], feature_names=feature_names, show=False)
    plt.tight_layout()
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close()
    print(f"Saved → {out_path}")


def print_comparison_table(metrics):
    """metrics: list of (name, cv_auc, holdout_auc, cv_p1001, holdout_p1001)"""
    header = f"{'Model':<30} {'CV AUC':>8} {'HO AUC':>8} {'CV P@1001':>10} {'HO P@1001':>10}"
    print("\n" + "=" * len(header))
    print(header)
    print("-" * len(header))
    print(f"{'Baseline (hand)':30} {'N/A':>8} {'N/A':>8} {'N/A':>10} {BASELINE_ACCURACY:>10.4f}")
    for name, cv_auc, ho_auc, cv_p1001, ho_p1001 in metrics:
        cv_auc_s = f"{cv_auc:.4f}" if cv_auc is not None else "N/A"
        ho_auc_s = f"{ho_auc:.4f}" if ho_auc is not None else "N/A"
        cv_p1001_s = f"{cv_p1001:.4f}" if cv_p1001 is not None else "N/A"
        ho_p1001_s = f"{ho_p1001:.4f}" if ho_p1001 is not None else "N/A"
        print(f"{name:<30} {cv_auc_s:>8} {ho_auc_s:>8} {cv_p1001_s:>10} {ho_p1001_s:>10}")
    print("=" * len(header) + "\n")


if __name__ == "__main__":
    model_v1 = load_model(RESULTS_DIR / "model_v1.pkl")
    model_v1_clean = load_model(RESULTS_DIR / "model_v1_clean.pkl")
    model_v2 = load_model(RESULTS_DIR / "model_v2.pkl")
    model_v2_clean = load_model(RESULTS_DIR / "model_v2_clean.pkl")

    df_v1, X_v1, y_v1, _ = load_and_prepare(FEATURES_V1)
    df_v1c, X_v1c, y_v1c, _ = load_and_prepare(FEATURES_V1_CLEAN)
    df_v2, X_v2, y_v2, _ = load_and_prepare(FEATURES_V2)
    df_v2c, X_v2c, y_v2c, _ = load_and_prepare(FEATURES_V2_CLEAN)

    # Holdout split — refit each model on the train slice so holdout metrics are unbiased
    # (saved models were trained on full data; refitting here gives a proper train/test split)
    train_idx_v1, test_idx_v1 = holdout_split(X_v1, y_v1)
    train_idx_v1c, test_idx_v1c = holdout_split(X_v1c, y_v1c)
    train_idx_v2, test_idx_v2 = holdout_split(X_v2, y_v2)
    train_idx_v2c, test_idx_v2c = holdout_split(X_v2c, y_v2c)

    model_v1.fit(X_v1[train_idx_v1], y_v1[train_idx_v1])
    model_v1_clean.fit(X_v1c[train_idx_v1c], y_v1c[train_idx_v1c])
    model_v2.fit(X_v2[train_idx_v2], y_v2[train_idx_v2])
    model_v2_clean.fit(X_v2c[train_idx_v2c], y_v2c[train_idx_v2c])

    X_test_v1, y_test_v1 = X_v1[test_idx_v1], y_v1[test_idx_v1]
    X_test_v1c, y_test_v1c = X_v1c[test_idx_v1c], y_v1c[test_idx_v1c]
    X_test_v2, y_test_v2 = X_v2[test_idx_v2], y_v2[test_idx_v2]
    X_test_v2c, y_test_v2c = X_v2c[test_idx_v2c], y_v2c[test_idx_v2c]
    df_test_v1 = df_v1.iloc[test_idx_v1].reset_index(drop=True)
    df_test_v1c = df_v1c.iloc[test_idx_v1c].reset_index(drop=True)
    df_test_v2 = df_v2.iloc[test_idx_v2].reset_index(drop=True)
    df_test_v2c = df_v2c.iloc[test_idx_v2c].reset_index(drop=True)

    scores_test_v1 = model_v1.predict_proba(X_test_v1)[:, 1]
    scores_test_v1c = model_v1_clean.predict_proba(X_test_v1c)[:, 1]
    scores_test_v2 = model_v2.predict_proba(X_test_v2)[:, 1]
    scores_test_v2c = model_v2_clean.predict_proba(X_test_v2c)[:, 1]

    mlflow.set_tracking_uri(TRACKING_URI)
    mlflow.set_experiment("cinegraph-1001-xgboost")

    with mlflow.start_run(run_name="evaluate_v1"):
        report(df_test_v1, scores_test_v1, y_test_v1, "xgb_v1", {"features": "v1", "split": "holdout_20pct"})

    with mlflow.start_run(run_name="evaluate_v1_clean"):
        report(df_test_v1c, scores_test_v1c, y_test_v1c, "xgb_v1_clean", {"features": "v1_clean", "split": "holdout_20pct"})

    with mlflow.start_run(run_name="evaluate_v2"):
        report(df_test_v2, scores_test_v2, y_test_v2, "xgb_v2", {"features": "v2", "split": "holdout_20pct"})
        plot_shap_summary(model_v2, X_test_v2, FEATURES_V2, RESULTS_DIR / "shap_summary.png")
        mlflow.log_artifact(str(RESULTS_DIR / "shap_summary.png"))

    with mlflow.start_run(run_name="evaluate_v2_clean"):
        report(df_test_v2c, scores_test_v2c, y_test_v2c, "xgb_v2_clean", {"features": "v2_clean", "split": "holdout_20pct"})

    plot_score_distribution(scores_test_v1, scores_test_v2, y_test_v2, RESULTS_DIR / "score_distribution.png")

    # Cross-validated P@1001 on full dataset — comparable to 48% baseline
    print("\nComputing cross-val P@1001 (full dataset, 10-fold)...")
    print("  V1 (leaky)...")
    cv_p1001_v1 = cross_val_p_at_k(model_v1, X_v1, y_v1)
    print(f"    V1 CV P@1001: {cv_p1001_v1:.4f}")

    print("  V1 clean...")
    cv_p1001_v1c = cross_val_p_at_k(model_v1_clean, X_v1c, y_v1c)
    print(f"    V1 clean CV P@1001: {cv_p1001_v1c:.4f}")

    print("  V2 (leaky)...")
    cv_p1001_v2 = cross_val_p_at_k(model_v2, X_v2, y_v2)
    print(f"    V2 CV P@1001: {cv_p1001_v2:.4f}")

    print("  V2 clean...")
    cv_p1001_v2c = cross_val_p_at_k(model_v2_clean, X_v2c, y_v2c)
    print(f"    V2 clean CV P@1001: {cv_p1001_v2c:.4f}")

    print_comparison_table([
        (
            "XGBoost V1 (leaky)",
            None,
            auc_roc(y_test_v1, scores_test_v1),
            cv_p1001_v1,
            precision_at_k(y_test_v1, scores_test_v1, min(1001, len(y_test_v1))),
        ),
        (
            "XGBoost V1 clean",
            None,
            auc_roc(y_test_v1c, scores_test_v1c),
            cv_p1001_v1c,
            precision_at_k(y_test_v1c, scores_test_v1c, min(1001, len(y_test_v1c))),
        ),
        (
            "XGBoost V2 clean",
            None,
            auc_roc(y_test_v2c, scores_test_v2c),
            cv_p1001_v2c,
            precision_at_k(y_test_v2c, scores_test_v2c, min(1001, len(y_test_v2c))),
        ),
        (
            "XGBoost V2 (leaky)",
            None,
            auc_roc(y_test_v2, scores_test_v2),
            cv_p1001_v2,
            precision_at_k(y_test_v2, scores_test_v2, min(1001, len(y_test_v2))),
        ),
    ])
