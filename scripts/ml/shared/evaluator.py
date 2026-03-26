"""Evaluation utilities for ML experiments."""

from typing import Dict

import numpy as np
import pandas as pd
from sklearn.metrics import roc_auc_score


def auc_roc(y_true: np.ndarray, y_scores: np.ndarray) -> float:
    return roc_auc_score(y_true, y_scores)


def precision_at_k(y_true: np.ndarray, y_scores: np.ndarray, k: int) -> float:
    if k <= 0:
        raise ValueError(f"k must be positive, got {k}")
    if len(y_true) != len(y_scores):
        raise ValueError(f"y_true and y_scores must have the same length ({len(y_true)} vs {len(y_scores)})")
    actual_k = min(k, len(y_true))
    top_k_idx = np.argsort(y_scores)[::-1][:actual_k]
    return y_true[top_k_idx].sum() / actual_k


def per_decade_accuracy(df: pd.DataFrame, y_scores: np.ndarray, label_col: str = "is_on_1001_list") -> Dict[int, float]:
    """Recovery rate (recall) of 1001-list movies per decade."""
    tmp = df.copy()
    tmp["_score"] = y_scores
    tmp["_label"] = tmp[label_col]
    tmp["_decade"] = (tmp["release_year"] // 10) * 10

    results = {}
    for decade, group in tmp.groupby("_decade"):
        positives = group[group["_label"] == 1]
        if len(positives) == 0:
            continue
        # recovery: fraction of true positives ranked in top-N for the decade
        # using score threshold = median score of positives globally
        threshold = np.median(y_scores[tmp["_label"].values == 1])
        recovered = (positives["_score"] >= threshold).sum()
        results[int(decade)] = recovered / len(positives)

    return results


def report(df: pd.DataFrame, y_scores: np.ndarray, y_true: np.ndarray, name: str, params: dict) -> None:
    """Print evaluation table and log metrics to MLflow if a run is active."""
    auc = auc_roc(y_true, y_scores)
    p500 = precision_at_k(y_true, y_scores, 500)
    p1001 = precision_at_k(y_true, y_scores, 1001)
    decade_acc = per_decade_accuracy(df, y_scores)

    print(f"\n{'='*50}")
    print(f"Model: {name}")
    print(f"  AUC-ROC:          {auc:.4f}")
    print(f"  Precision@500:    {p500:.4f}")
    print(f"  Precision@1001:   {p1001:.4f}")
    print(f"  Decade recovery:")
    for decade in sorted(decade_acc):
        print(f"    {decade}s: {decade_acc[decade]:.2%}")
    print(f"{'='*50}\n")

    # Log to MLflow if a run is active
    try:
        import mlflow

        if mlflow.active_run():
            mlflow.log_params(params)
            mlflow.log_metric(f"{name}_auc", auc)
            mlflow.log_metric(f"{name}_precision_at_500", p500)
            mlflow.log_metric(f"{name}_precision_at_1001", p1001)
            for decade, rate in decade_acc.items():
                mlflow.log_metric(f"{name}_decade_{decade}", rate)
    except ImportError:
        pass
