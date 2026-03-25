"""Thin MLflow wrapper for consistent experiment tracking."""

from contextlib import contextmanager
from pathlib import Path

import mlflow

TRACKING_URI = str(Path(__file__).parent.parent / "mlruns")


@contextmanager
def start_run(experiment_name: str, run_name: str, params: dict):
    mlflow.set_tracking_uri(TRACKING_URI)
    mlflow.set_experiment(experiment_name)
    with mlflow.start_run(run_name=run_name) as run:
        mlflow.log_params(params)
        yield run
