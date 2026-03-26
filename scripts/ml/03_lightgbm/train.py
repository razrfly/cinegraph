"""Train LightGBM V3 model — sweeps num_leaves, uses FEATURES_V3."""

import sys
from pathlib import Path

import joblib
import numpy as np
from lightgbm import LGBMClassifier
from sklearn.model_selection import StratifiedKFold, cross_val_score

sys.path.insert(0, str(Path(__file__).parent.parent))
from shared.constants import FEATURES_V3, LABEL
from shared.data_loader import load_and_prepare
from shared.mlflow_utils import start_run

RESULTS_DIR = Path(__file__).parent / "results"
RESULTS_DIR.mkdir(exist_ok=True)

NUM_LEAVES_GRID = [31, 63, 127]

BASE_PARAMS = dict(
    n_estimators=500,
    learning_rate=0.1,
    subsample=0.8,
    colsample_bytree=0.8,
    min_child_samples=20,
    random_state=42,
    n_jobs=-1,
    verbose=-1,
)


def sweep_num_leaves(X, y, spw):
    """Return best num_leaves by 10-fold CV AUC."""
    cv = StratifiedKFold(n_splits=10, shuffle=True, random_state=42)
    best_leaves, best_score = None, -1.0
    for nl in NUM_LEAVES_GRID:
        clf = LGBMClassifier(**BASE_PARAMS, num_leaves=nl, scale_pos_weight=spw)
        scores = cross_val_score(clf, X, y, cv=cv, scoring="roc_auc", n_jobs=-1)
        mean = scores.mean()
        print(f"  num_leaves={nl:3d}  CV AUC={mean:.4f} ± {scores.std():.4f}")
        if mean > best_score:
            best_score, best_leaves = mean, nl
    print(f"  → Best num_leaves={best_leaves} (CV AUC={best_score:.4f})")
    return best_leaves, best_score


if __name__ == "__main__":
    print("=== Training LightGBM V3 ===")
    df, X, y, feat_names = load_and_prepare(FEATURES_V3)

    n_positive = y.sum()
    n_negative = len(y) - n_positive
    spw = n_negative / n_positive
    print(f"Label balance: {n_positive} positive / {n_negative} negative  (spw={spw:.2f})")

    print("\nSweeping num_leaves...")
    best_leaves, best_cv_auc = sweep_num_leaves(X, y, spw)

    params = {
        **BASE_PARAMS,
        "num_leaves": best_leaves,
        "scale_pos_weight": spw,
        "features": ",".join(feat_names),
    }

    model_path = RESULTS_DIR / "model_lgbm_v3.pkl"
    with start_run("cinegraph-1001-lgbm", "lgbm_v3", params):
        import mlflow

        clf = LGBMClassifier(**{k: v for k, v in params.items() if k != "features"})
        clf.fit(X, y)
        joblib.dump(clf, model_path)
        print(f"Saved model → {model_path}")

        mlflow.log_metric("best_cv_auc", best_cv_auc)
        mlflow.log_metric("best_num_leaves", best_leaves)
