"""Generate MiniLM-L6-v2 embeddings and reduce to 32 PCA components.

Reads: data/movies.parquet  (title, tagline, overview columns)
Writes:
  data/pca_model.pkl              (sklearn PCA object for inspection/reuse)
  data/embeddings_pca32.parquet   (movie_id + emb_pc_0..emb_pc_31, float32)

NOTE: PCA is fitted on the full dataset here (global fit). This introduces a minor
form of information leakage when these embeddings are used in held-out evaluation
because the test set influenced the PCA projection directions. For a fully leak-free
setup, PCA should be fitted inside each cross-validation fold. The 05_step4 experiment
uses raw 384-dim embeddings (emb_raw_*) which avoid this issue entirely.
"""

import sys
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sentence_transformers import SentenceTransformer
from sklearn.decomposition import PCA

sys.path.insert(0, str(Path(__file__).parent.parent))
from shared.data_loader import DATA_PATH

DATA_DIR = Path(__file__).parent.parent / "data"
PCA_MODEL_PATH = DATA_DIR / "pca_model.pkl"
EMBED_PATH = DATA_DIR / "embeddings_pca32.parquet"
N_COMPONENTS = 32
BATCH_SIZE = 256
MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"


def build_texts(df: pd.DataFrame) -> list[str]:
    title = df["title"].fillna("")
    tagline = df.get("tagline", pd.Series([""] * len(df))).fillna("")
    overview = df.get("overview", pd.Series([""] * len(df))).fillna("")
    return (title + " " + tagline + " " + overview).str.strip().tolist()


def main():
    print(f"Loading {DATA_PATH} ...")
    df = pd.read_parquet(DATA_PATH, columns=["movie_id", "title", "tagline", "overview"])
    print(f"  {len(df):,} movies")

    texts = build_texts(df)

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

    print(f"\nFitting PCA(n_components={N_COMPONENTS}) ...")
    pca = PCA(n_components=N_COMPONENTS, random_state=42)
    pca_embeddings = pca.fit_transform(embeddings)
    explained = pca.explained_variance_ratio_.sum()
    print(f"  Explained variance (32 components): {explained:.4f} ({explained*100:.1f}%)")

    joblib.dump(pca, PCA_MODEL_PATH)
    print(f"  Saved PCA model → {PCA_MODEL_PATH}")

    cols = {f"emb_pc_{i}": pca_embeddings[:, i].astype(np.float32) for i in range(N_COMPONENTS)}
    emb_df = pd.DataFrame({"movie_id": df["movie_id"].values, **cols})
    emb_df.to_parquet(EMBED_PATH, index=False)
    print(f"  Saved embeddings → {EMBED_PATH}  ({emb_df.shape})")


if __name__ == "__main__":
    main()
