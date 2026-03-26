"""Evaluate XGBoost V4 (baseline) and all 7 V5 models.

Metrics per model:
  - 20% holdout AUC
  - 10-fold CV P@1001 (full dataset)
    - XGBoost: cross_val_predict(..., method="predict_proba")[:, 1]
    - LightGBM: raw log-odds via clone-fit-predict loop (avoids saturation)

SHAP TreeExplainer for the highest CV P@1001 model.

Posts results as a comment on GitHub issue #682.
"""

import subprocess
import sys
from pathlib import Path

import joblib
import matplotlib.pyplot as plt
import numpy as np
import shap
from sklearn.base import clone
from sklearn.model_selection import StratifiedKFold, StratifiedShuffleSplit, cross_val_predict

sys.path.insert(0, str(Path(__file__).parent.parent))
from shared.constants import (
    FEATURES_V4,
    FEATURES_V5_32,
    FEATURES_V5_64,
    FEATURES_V5_128,
    FEATURES_V5_384,
)
from shared.data_loader import load_and_prepare
from shared.evaluator import auc_roc, precision_at_k

RESULTS_DIR = Path(__file__).parent / "results"
RESULTS_DIR.mkdir(exist_ok=True)

V4_RESULTS_DIR = Path(__file__).parent.parent / "04_bert" / "results"

BASELINE_CV_P1001 = 0.6683  # XGBoost V4 established in Step 3
TEST_SIZE = 0.2
RANDOM_STATE = 42


def load_model(path):
    return joblib.load(path)


def holdout_split(X, y):
    sss = StratifiedShuffleSplit(n_splits=1, test_size=TEST_SIZE, random_state=RANDOM_STATE)
    train_idx, test_idx = next(sss.split(X, y))
    return train_idx, test_idx


def cross_val_p_at_k(model, X, y, k=1001, n_splits=10):
    """P@k via cross-validated predict_proba (XGBoost)."""
    cv = StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=RANDOM_STATE)
    cloned = clone(model)
    if hasattr(cloned, "n_jobs"):
        cloned.set_params(n_jobs=1)
    oof_proba = cross_val_predict(cloned, X, y, cv=cv, method="predict_proba", n_jobs=-1)
    return precision_at_k(y, oof_proba[:, 1], k)


def cross_val_p_at_k_lgbm(model, X, y, k=1001, n_splits=10):
    """P@k via raw log-odds ranking (LightGBM — avoids predict_proba saturation).

    LightGBM with extreme scale_pos_weight saturates predict_proba to 1.0 for
    many rows, causing argsort tie-breaking to dominate P@k. Raw log-odds are
    unbounded and preserve the true ranking.
    """
    cv = StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=RANDOM_STATE)
    oof_scores = np.empty(len(y), dtype=np.float64)
    for train_idx, test_idx in cv.split(X, y):
        m = clone(model)
        m.fit(X[train_idx], y[train_idx])
        oof_scores[test_idx] = m.predict(X[test_idx], raw_score=True)
    return precision_at_k(y, oof_scores, k)


def plot_shap_summary(model, X, feature_names, out_path):
    rng = np.random.default_rng(42)
    idx = rng.choice(len(X), size=min(1000, len(X)), replace=False)
    explainer = shap.TreeExplainer(model)
    shap_values = explainer.shap_values(X[idx])
    sv = shap_values[1] if isinstance(shap_values, list) else shap_values
    plt.figure(figsize=(12, 8))
    shap.summary_plot(sv, X[idx], feature_names=feature_names, show=False, max_display=30)
    plt.tight_layout()
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close()
    print(f"  Saved SHAP → {out_path}")


def print_comparison_table(metrics):
    header = f"{'Model':<36} {'HO AUC':>8} {'CV P@1001':>10}"
    sep = "=" * len(header)
    print(f"\n{sep}")
    print(header)
    print("-" * len(header))
    print(f"{'XGBoost V4 (baseline)':36} {'N/A':>8} {BASELINE_CV_P1001:>10.4f}")
    for name, ho_auc, cv_p1001 in metrics:
        ho_auc_s = f"{ho_auc:.4f}" if ho_auc is not None else "N/A"
        cv_p_s = f"{cv_p1001:.4f}" if cv_p1001 is not None else "N/A"
        print(f"{name:<36} {ho_auc_s:>8} {cv_p_s:>10}")
    print(f"{sep}\n")
    return header, sep


def format_github_comment(metrics, best_model_name):
    lines = [
        "## Step 4 Results — Experiment 05: V5 Rich Text Embeddings",
        "",
        f"**Baseline (XGBoost V4):** CV P@1001 = {BASELINE_CV_P1001:.4f}",
        "",
        "| Model | HO AUC | CV P@1001 | Delta vs V4 |",
        "|---|---|---|---|",
        f"| XGBoost V4 (baseline) | N/A | {BASELINE_CV_P1001:.4f} | — |",
    ]
    for name, ho_auc, cv_p1001 in metrics:
        ho_s = f"{ho_auc:.4f}" if ho_auc is not None else "N/A"
        cv_s = f"{cv_p1001:.4f}" if cv_p1001 is not None else "N/A"
        delta = f"{cv_p1001 - BASELINE_CV_P1001:+.4f}" if cv_p1001 is not None else "N/A"
        lines.append(f"| {name} | {ho_s} | {cv_s} | {delta} |")
    lines += [
        "",
        f"**Best model:** {best_model_name}",
        "",
        "SHAP summary saved to `05_step4/results/shap_best.png`.",
    ]
    return "\n".join(lines)


def post_github_comment(body: str, issue: int = 682):
    result = subprocess.run(
        ["gh", "issue", "comment", str(issue), "--body", body],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        print(f"  Posted comment to issue #{issue}")
    else:
        print(f"  Failed to post comment: {result.stderr}")


if __name__ == "__main__":
    # --- Load data for each feature set ---
    print("Loading data...")
    df_v4,   X_v4,   y_v4,   _ = load_and_prepare(FEATURES_V4)
    df_v5_32, X_v5_32, y_v5_32, _ = load_and_prepare(FEATURES_V5_32)
    df_v5_64, X_v5_64, y_v5_64, _ = load_and_prepare(FEATURES_V5_64)
    df_v5_128, X_v5_128, y_v5_128, _ = load_and_prepare(FEATURES_V5_128)
    df_v5_384, X_v5_384, y_v5_384, _ = load_and_prepare(FEATURES_V5_384)

    # --- Load models ---
    print("Loading models...")
    model_v4       = load_model(V4_RESULTS_DIR / "model_xgb_v4.pkl")
    model_v5_32    = load_model(RESULTS_DIR / "model_xgb_v5_32.pkl")
    model_v5_64    = load_model(RESULTS_DIR / "model_xgb_v5_64.pkl")
    model_v5_128   = load_model(RESULTS_DIR / "model_xgb_v5_128.pkl")
    model_v5_384   = load_model(RESULTS_DIR / "model_xgb_v5_384.pkl")
    model_lgbm_50  = load_model(RESULTS_DIR / "model_lgbm_v5_spw50.pkl")
    model_lgbm_100 = load_model(RESULTS_DIR / "model_lgbm_v5_spw100.pkl")
    model_lgbm_200 = load_model(RESULTS_DIR / "model_lgbm_v5_spw200.pkl")

    # --- Holdout AUC ---
    print("\nComputing holdout AUC...")
    configs = [
        ("XGBoost V4",          model_v4,       X_v4,     y_v4),
        ("XGBoost V5_32",       model_v5_32,    X_v5_32,  y_v5_32),
        ("XGBoost V5_64",       model_v5_64,    X_v5_64,  y_v5_64),
        ("XGBoost V5_128",      model_v5_128,   X_v5_128, y_v5_128),
        ("XGBoost V5_384",      model_v5_384,   X_v5_384, y_v5_384),
        ("LightGBM V5 spw=50",  model_lgbm_50,  X_v5_64,  y_v5_64),
        ("LightGBM V5 spw=100", model_lgbm_100, X_v5_64,  y_v5_64),
        ("LightGBM V5 spw=200", model_lgbm_200, X_v5_64,  y_v5_64),
    ]

    # Refit a clone of each model on its train slice for unbiased holdout evaluation.
    # Clone so best_model_map and shap_best.png still reference the full-data model.
    ho_aucs = {}
    for name, model, X, y in configs:
        train_idx, test_idx = holdout_split(X, y)
        ho_model = clone(model)
        ho_model.fit(X[train_idx], y[train_idx])
        X_test, y_test = X[test_idx], y[test_idx]
        scores = ho_model.predict_proba(X_test)[:, 1]
        ho_auc = auc_roc(y_test, scores)
        ho_aucs[name] = ho_auc
        print(f"  {name}: HO AUC={ho_auc:.4f}")

    # --- CV P@1001 ---
    print("\nComputing 10-fold CV P@1001 (full dataset)...")
    cv_p1001s = {}

    xgb_configs = [
        ("XGBoost V5_32",  model_v5_32,  X_v5_32,  y_v5_32),
        ("XGBoost V5_64",  model_v5_64,  X_v5_64,  y_v5_64),
        ("XGBoost V5_128", model_v5_128, X_v5_128, y_v5_128),
        ("XGBoost V5_384", model_v5_384, X_v5_384, y_v5_384),
    ]
    lgbm_configs = [
        ("LightGBM V5 spw=50",  model_lgbm_50,  X_v5_64, y_v5_64),
        ("LightGBM V5 spw=100", model_lgbm_100, X_v5_64, y_v5_64),
        ("LightGBM V5 spw=200", model_lgbm_200, X_v5_64, y_v5_64),
    ]

    for name, model, X, y in xgb_configs:
        print(f"  {name} ...")
        p = cross_val_p_at_k(model, X, y)
        cv_p1001s[name] = p
        print(f"    CV P@1001: {p:.4f}")

    for name, model, X, y in lgbm_configs:
        print(f"  {name} (raw log-odds) ...")
        p = cross_val_p_at_k_lgbm(model, X, y)
        cv_p1001s[name] = p
        print(f"    CV P@1001: {p:.4f}")

    # --- SHAP for best model ---
    best_name = max(cv_p1001s, key=cv_p1001s.get)
    print(f"\nBest model by CV P@1001: {best_name} ({cv_p1001s[best_name]:.4f})")
    print("Generating SHAP summary...")

    best_model_map = {
        "XGBoost V5_32":       (model_v5_32,  X_v5_32,  FEATURES_V5_32),
        "XGBoost V5_64":       (model_v5_64,  X_v5_64,  FEATURES_V5_64),
        "XGBoost V5_128":      (model_v5_128, X_v5_128, FEATURES_V5_128),
        "XGBoost V5_384":      (model_v5_384, X_v5_384, FEATURES_V5_384),
        "LightGBM V5 spw=50":  (model_lgbm_50,  X_v5_64, FEATURES_V5_64),
        "LightGBM V5 spw=100": (model_lgbm_100, X_v5_64, FEATURES_V5_64),
        "LightGBM V5 spw=200": (model_lgbm_200, X_v5_64, FEATURES_V5_64),
    }
    best_model, best_X, best_features = best_model_map[best_name]
    plot_shap_summary(best_model, best_X, best_features, RESULTS_DIR / "shap_best.png")

    # --- Comparison table ---
    metrics = []
    all_names = [n for n, _, _, _ in configs if n != "XGBoost V4"]
    for name in all_names:
        metrics.append((name, ho_aucs.get(name), cv_p1001s.get(name)))

    print_comparison_table(metrics)

    # --- Post to GitHub issue #682 ---
    print("Posting results to GitHub issue #682 ...")
    comment_body = format_github_comment(metrics, best_name)
    post_github_comment(comment_body, issue=682)
