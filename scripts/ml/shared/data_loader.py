"""Load parquet data and prepare features/labels for training."""

import datetime
from pathlib import Path
from typing import List, Tuple

import numpy as np
import pandas as pd

DATA_PATH = Path(__file__).parent.parent / "data" / "movies.parquet"
EMBED_PATH = Path(__file__).parent.parent / "data" / "embeddings_pca32.parquet"
EMBED_RICH_PCA_PATH = Path(__file__).parent.parent / "data" / "embeddings_rich_pca128.parquet"
EMBED_RICH_RAW_PATH = Path(__file__).parent.parent / "data" / "embeddings_rich_raw384.parquet"
CURRENT_YEAR = datetime.date.today().year


def load_and_prepare(
    features: List[str],
    reference_year: int = CURRENT_YEAR,
) -> Tuple[pd.DataFrame, np.ndarray, np.ndarray, List[str]]:
    """
    Load movies.parquet, derive engineered features, return (df, X, y, features).

    NaN values are preserved for lens scores — XGBoost handles missing natively.

    Args:
        features: list of feature column names to use.
        reference_year: year used to compute `years_since_release`. Pass an explicit
            value (e.g. the training cutoff year) to make experiments reproducible
            across calendar years. Defaults to the current year.
    """
    df = pd.read_parquet(DATA_PATH)

    # Auto-load embeddings when emb_pc_* features are requested
    if any(f.startswith("emb_pc_") for f in features):
        emb = pd.read_parquet(EMBED_PATH)
        if emb["movie_id"].duplicated().any():
            raise ValueError("embeddings_pca32.parquet contains duplicate movie_id rows")
        df = df.merge(emb, on="movie_id", how="left")
    if any(f.startswith("emb_rpc_") for f in features):
        emb = pd.read_parquet(EMBED_RICH_PCA_PATH)
        if emb["movie_id"].duplicated().any():
            raise ValueError("embeddings_rich_pca128.parquet contains duplicate movie_id rows")
        df = df.merge(emb, on="movie_id", how="left")
    if any(f.startswith("emb_raw_") for f in features):
        emb = pd.read_parquet(EMBED_RICH_RAW_PATH)
        if emb["movie_id"].duplicated().any():
            raise ValueError("embeddings_rich_raw384.parquet contains duplicate movie_id rows")
        df = df.merge(emb, on="movie_id", how="left")

    # Derived features
    df["imdb_votes_log"] = np.log1p(df["imdb_votes"].fillna(0))
    df["decade"] = (df["release_year"] // 10) * 10
    df["has_festival_data"] = (df["festival_recognition_score"].notna()).astype(int)
    df["has_critic_data"] = (df["ivory_tower_score"].notna()).astype(int)
    df["years_since_release"] = reference_year - df["release_year"]

    # V3 derived features
    df["has_imdb_votes"] = (df["imdb_votes"].fillna(0) > 0).astype(int)

    for col, out in [("imdb_rating", "imdb_rating_decade_percentile"),
                     ("imdb_votes_log", "imdb_votes_decade_percentile")]:
        df[out] = df.groupby("decade")[col].rank(pct=True, na_option="keep")

    df["is_foreign_language"] = (df["original_language"].fillna("en") != "en").astype(int)

    GENRE_MAP = {
        "Drama": 0, "Comedy": 1, "Thriller": 2, "Action": 3, "Horror": 4,
        "Crime": 5, "Romance": 6, "Science Fiction": 7, "Adventure": 8,
        "Animation": 9, "Documentary": 10, "Mystery": 11, "War": 12,
        "Fantasy": 13, "History": 14, "Music": 15, "Family": 16, "Western": 17,
    }
    df["primary_genre_encoded"] = df["primary_genre_raw"].map(GENRE_MAP)

    CONTINENT_MAP = {
        "US": 0, "CA": 0, "MX": 0,
        "GB": 1, "FR": 1, "DE": 1, "IT": 1, "ES": 1, "SE": 1, "PL": 1,
        "RU": 1, "DK": 1, "NL": 1, "NO": 1, "FI": 1, "PT": 1, "AT": 1,
        "BE": 1, "CH": 1, "HU": 1, "CZ": 1, "RO": 1, "GR": 1,
        "JP": 2, "CN": 2, "KR": 2, "IN": 2, "TH": 2, "HK": 2,
        "TW": 2, "IR": 2, "TR": 2,
    }
    df["origin_continent"] = df["origin_country"].map(CONTINENT_MAP)

    # Subset to requested features only
    missing = [f for f in features if f not in df.columns]
    if missing:
        raise ValueError(f"Features not found in dataframe: {missing}")

    X = df[features].to_numpy(dtype=np.float32)
    y = df["is_on_1001_list"].to_numpy(dtype=int)

    return df, X, y, features
