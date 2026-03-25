"""Load parquet data and prepare features/labels for training."""

from pathlib import Path
from typing import List, Tuple

import numpy as np
import pandas as pd

DATA_PATH = Path(__file__).parent.parent / "data" / "movies.parquet"
CURRENT_YEAR = 2026


def load_and_prepare(features: List[str]) -> Tuple[pd.DataFrame, np.ndarray, np.ndarray, List[str]]:
    """
    Load movies.parquet, derive engineered features, return (df, X, y, features).

    NaN values are preserved for lens scores — XGBoost handles missing natively.
    """
    df = pd.read_parquet(DATA_PATH)

    # Derived features
    df["imdb_votes_log"] = np.log1p(df["imdb_votes"].fillna(0))
    df["decade"] = (df["release_year"] // 10) * 10
    df["has_festival_data"] = (df["festival_recognition_score"].notna()).astype(int)
    df["has_critic_data"] = (df["ivory_tower_score"].notna()).astype(int)
    df["years_since_release"] = CURRENT_YEAR - df["release_year"]

    # Subset to requested features only
    missing = [f for f in features if f not in df.columns]
    if missing:
        raise ValueError(f"Features not found in dataframe: {missing}")

    X = df[features].to_numpy(dtype=np.float32)
    y = df["is_on_1001_list"].to_numpy(dtype=int)

    return df, X, y, features
