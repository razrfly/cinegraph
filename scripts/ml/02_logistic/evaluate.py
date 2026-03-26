"""Evaluate Logistic Regression models and compare to XGBoost baseline."""

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
from shared.constants import FEATURES_V1_CLEAN, FEATURES_V2_CLEAN, LABEL
from shared.data_loader import load_and_prepare
from shared.evaluator import auc_roc, precision_at_k, per_decade_accuracy, report
from shared.mlflow_utils import TRACKING_URI

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
    """P@k using out-of-fold predictions on the full dataset.

    Denominator = k, so directly comparable to 48% baseline (P@1001 over all positives).
    """
    cv = StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=RANDOM_STATE)
    cloned = clone(model)
    if hasattr(cloned, "n_jobs"):
        cloned.set_params(n_jobs=1)
    oof_proba = cross_val_predict(cloned, X, y, cv=cv, method="predict_proba", n_jobs=-1)
    oof_scores = oof_proba[:, 1]
    return precision_at_k(y, oof_scores, k)


def plot_shap_linear(model, X, feature_names, out_path):
    """SHAP summary via LinearExplainer (appropriate for logistic regression pipelines)."""
    # Extract the underlying LR classifier from the pipeline
    clf = model.named_steps["clf"]
    scaler = model.named_steps["scaler"]
    imputer = model.named_steps["imputer"]

    X_imputed = imputer.transform(X)
    X_scaled = scaler.transform(X_imputed)

    rng = np.random.default_rng(42)
    idx = rng.choice(len(X_scaled), size=min(1000, len(X_scaled)), replace=False)

    explainer = shap.LinearExplainer(clf, X_scaled[idx], feature_perturbation="interventional")
    shap_values = explainer.shap_values(X_scaled[idx])

    plt.figure(figsize=(10, 6))
    shap.summary_plot(shap_values, X_scaled[idx], feature_names=feature_names, show=False)
    plt.tight_layout()
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close()
    print(f"Saved → {out_path}")


def print_comparison_table(metrics):
    """metrics: list of (name, ho_auc, cv_p1001, ho_p1001)"""
    header = f"{'Model':<30} {'HO AUC':>8} {'CV P@1001':>10} {'HO P@1001':>10}"
    print("\n" + "=" * len(header))
    print(header)
    print("-" * len(header))
    print(f"{'Baseline (hand)':30} {'N/A':>8} {'N/A':>10} {BASELINE_ACCURACY:>10.4f}")
    for name, ho_auc, cv_p1001, ho_p1001 in metrics:
        ho_auc_s = f"{ho_auc:.4f}" if ho_auc is not None else "N/A"
        cv_p1001_s = f"{cv_p1001:.4f}" if cv_p1001 is not None else "N/A"
        ho_p1001_s = f"{ho_p1001:.4f}" if ho_p1001 is not None else "N/A"
        print(f"{name:<30} {ho_auc_s:>8} {cv_p1001_s:>10} {ho_p1001_s:>10}")
    print("=" * len(header) + "\n")


if __name__ == "__main__":
    model_lr_v1 = load_model(RESULTS_DIR / "model_lr_v1.pkl")
    model_lr_v2 = load_model(RESULTS_DIR / "model_lr_v2.pkl")

    df_v1, X_v1, y_v1, _ = load_and_prepare(FEATURES_V1_CLEAN)
    df_v2, X_v2, y_v2, _ = load_and_prepare(FEATURES_V2_CLEAN)

    # Refit on train slice for unbiased holdout evaluation
    train_idx_v1, test_idx_v1 = holdout_split(X_v1, y_v1)
    train_idx_v2, test_idx_v2 = holdout_split(X_v2, y_v2)

    model_lr_v1.fit(X_v1[train_idx_v1], y_v1[train_idx_v1])
    model_lr_v2.fit(X_v2[train_idx_v2], y_v2[train_idx_v2])

    X_test_v1, y_test_v1 = X_v1[test_idx_v1], y_v1[test_idx_v1]
    X_test_v2, y_test_v2 = X_v2[test_idx_v2], y_v2[test_idx_v2]
    df_test_v1 = df_v1.iloc[test_idx_v1].reset_index(drop=True)
    df_test_v2 = df_v2.iloc[test_idx_v2].reset_index(drop=True)

    scores_test_v1 = model_lr_v1.predict_proba(X_test_v1)[:, 1]
    scores_test_v2 = model_lr_v2.predict_proba(X_test_v2)[:, 1]

    mlflow.set_tracking_uri(TRACKING_URI)
    mlflow.set_experiment("cinegraph-1001-logistic")

    with mlflow.start_run(run_name="evaluate_lr_v1"):
        report(df_test_v1, scores_test_v1, y_test_v1, "lr_v1_clean", {"features": "v1_clean", "split": "holdout_20pct"})

    with mlflow.start_run(run_name="evaluate_lr_v2"):
        report(df_test_v2, scores_test_v2, y_test_v2, "lr_v2_clean", {"features": "v2_clean", "split": "holdout_20pct"})
        plot_shap_linear(model_lr_v2, X_v2, FEATURES_V2_CLEAN, RESULTS_DIR / "shap_lr_v2.png")
        mlflow.log_artifact(str(RESULTS_DIR / "shap_lr_v2.png"))

    # Cross-validated P@1001 on full dataset
    print("\nComputing cross-val P@1001 (full dataset, 10-fold)...")
    print("  LR V1 clean...")
    cv_p1001_v1 = cross_val_p_at_k(model_lr_v1, X_v1, y_v1)
    print(f"    CV P@1001: {cv_p1001_v1:.4f}")

    print("  LR V2 clean...")
    cv_p1001_v2 = cross_val_p_at_k(model_lr_v2, X_v2, y_v2)
    print(f"    CV P@1001: {cv_p1001_v2:.4f}")

    # Also load XGBoost V1 clean for cross-experiment comparison
    xgb_v1c_path = XGB_RESULTS_DIR / "model_v1_clean.pkl"
    xgb_metrics = []
    if xgb_v1c_path.exists():
        model_xgb_v1c = load_model(xgb_v1c_path)
        xgb_train_idx, xgb_test_idx = holdout_split(X_v1, y_v1)
        model_xgb_v1c.fit(X_v1[xgb_train_idx], y_v1[xgb_train_idx])
        xgb_scores_ho = model_xgb_v1c.predict_proba(X_v1[xgb_test_idx])[:, 1]
        xgb_cv_p1001 = cross_val_p_at_k(model_xgb_v1c, X_v1, y_v1)
        xgb_metrics = [(
            "XGBoost V1 clean",
            auc_roc(y_v1[xgb_test_idx], xgb_scores_ho),
            xgb_cv_p1001,
            precision_at_k(y_v1[xgb_test_idx], xgb_scores_ho, 1001),
        )]

    print_comparison_table(xgb_metrics + [
        (
            "LR V1 clean",
            auc_roc(y_test_v1, scores_test_v1),
            cv_p1001_v1,
            precision_at_k(y_test_v1, scores_test_v1, 1001),
        ),
        (
            "LR V2 clean",
            auc_roc(y_test_v2, scores_test_v2),
            cv_p1001_v2,
            precision_at_k(y_test_v2, scores_test_v2, 1001),
        ),
    ])
