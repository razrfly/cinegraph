"""Generate rich-text MiniLM embeddings with PCA(128) and raw 384-dim output.

Rich text = title + tagline + overview + director_names + cast_names + tmdb_keywords

Reads: data/movies.parquet
Writes:
  data/pca_rich_model.pkl               (sklearn PCA object)
  data/embeddings_rich_pca128.parquet   (movie_id + emb_rpc_0..127, float32)
  data/embeddings_rich_raw384.parquet   (movie_id + emb_raw_0..383, float32)
"""

import shutil
import sys
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sentence_transformers import SentenceTransformer
from sklearn.decomposition import PCA

sys.path.insert(0, str(Path(__file__).parent.parent))
from shared.data_loader import DATA_PATH, EMBED_RICH_PCA_PATH, EMBED_RICH_RAW_PATH

DATA_DIR = Path(__file__).parent.parent / "data"
PCA_MODEL_PATH = DATA_DIR / "pca_rich_model.pkl"
N_COMPONENTS = 128
BATCH_SIZE = 256
MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"


def build_rich_texts(df: pd.DataFrame) -> list[str]:
    fields = ["title", "tagline", "overview", "director_names", "cast_names", "tmdb_keywords"]
    parts = []
    for col in fields:
        if col in df.columns:
            parts.append(df[col].fillna(""))
        else:
            parts.append(pd.Series([""] * len(df), index=df.index))
    combined = parts[0]
    for p in parts[1:]:
        combined = combined + " " + p
    return combined.str.strip().tolist()


def check_disk(path: Path, estimated_gb: float):
    stat = shutil.disk_usage(path.parent if path.parent.exists() else path.parent.parent)
    free_gb = stat.free / 1024**3
    print(f"  Disk free: {free_gb:.1f} GB  (need ~{estimated_gb:.1f} GB for raw embeddings)")
    if free_gb < estimated_gb + 0.5:
        raise RuntimeError(f"Insufficient disk space: {free_gb:.1f} GB free, need {estimated_gb+0.5:.1f} GB")


def main():
    print(f"Loading {DATA_PATH} ...")
    cols = ["movie_id", "title", "tagline", "overview", "director_names", "cast_names", "tmdb_keywords"]
    available = pd.read_parquet(DATA_PATH, columns=["movie_id"]).columns.tolist()
    # Read only columns that exist
    load_cols = [c for c in cols if c in pd.read_parquet(DATA_PATH, columns=cols[:1]).columns or c == "movie_id"]
    df = pd.read_parquet(DATA_PATH)
    # Keep only needed columns
    df = df[[c for c in cols if c in df.columns]]
    print(f"  {len(df):,} movies, columns: {list(df.columns)}")

    texts = build_rich_texts(df)
    print(f"  Sample text[0]: {texts[0][:120]!r}")

    print(f"\nEncoding with {MODEL_NAME} (batch_size={BATCH_SIZE}) ...")
    model = SentenceTransformer(MODEL_NAME)
    embeddings = model.encode(
        texts,
        batch_size=BATCH_SIZE,
        show_progress_bar=True,
        convert_to_numpy=True,
        normalize_embeddings=False,
    )
    print(f"  Embeddings shape: {embeddings.shape}")  # (N, 384)

    # PCA(128)
    print(f"\nFitting PCA(n_components={N_COMPONENTS}) ...")
    pca = PCA(n_components=N_COMPONENTS, random_state=42)
    pca_embeddings = pca.fit_transform(embeddings)

    evr = pca.explained_variance_ratio_
    for n in [32, 64, 128]:
        total = evr[:n].sum()
        print(f"  Explained variance ({n:3d} components): {total:.4f} ({total*100:.1f}%)")

    joblib.dump(pca, PCA_MODEL_PATH)
    print(f"  Saved PCA model → {PCA_MODEL_PATH}")

    # Save PCA embeddings (128 components; V5_32/V5_64 use first 32/64)
    cols_pca = {f"emb_rpc_{i}": pca_embeddings[:, i].astype(np.float32) for i in range(N_COMPONENTS)}
    emb_pca_df = pd.DataFrame({"movie_id": df["movie_id"].values, **cols_pca})
    emb_pca_df.to_parquet(EMBED_RICH_PCA_PATH, index=False)
    print(f"  Saved PCA embeddings → {EMBED_RICH_PCA_PATH}  {emb_pca_df.shape}")

    # Save raw 384-dim embeddings
    check_disk(EMBED_RICH_RAW_PATH, estimated_gb=1.5)
    cols_raw = {f"emb_raw_{i}": embeddings[:, i].astype(np.float32) for i in range(384)}
    emb_raw_df = pd.DataFrame({"movie_id": df["movie_id"].values, **cols_raw})
    emb_raw_df.to_parquet(EMBED_RICH_RAW_PATH, index=False)
    size_gb = EMBED_RICH_RAW_PATH.stat().st_size / 1024**3
    print(f"  Saved raw embeddings → {EMBED_RICH_RAW_PATH}  {emb_raw_df.shape}  ({size_gb:.2f} GB)")


if __name__ == "__main__":
    main()
