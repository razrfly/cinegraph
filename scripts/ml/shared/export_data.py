"""Export Postgres data to data/movies.parquet for ML training."""

import os
import sys
from pathlib import Path

import pandas as pd
import psycopg2

sys.path.insert(0, str(Path(__file__).parent.parent))
from shared.constants import DB_URL

SQL = """
WITH director_counts AS (
    SELECT
        mc.person_id,
        COUNT(DISTINCT mc.movie_id) AS film_count
    FROM movie_credits mc
    WHERE mc.credit_type = 'crew'
      AND mc.job = 'Director'
    GROUP BY mc.person_id
),
movie_directors AS (
    SELECT
        mc.movie_id,
        MAX(dc.film_count) AS director_film_count
    FROM movie_credits mc
    JOIN director_counts dc ON dc.person_id = mc.person_id
    WHERE mc.credit_type = 'crew'
      AND mc.job = 'Director'
    GROUP BY mc.movie_id
),
imdb_rating AS (
    SELECT movie_id, value::float AS imdb_rating
    FROM external_metrics
    WHERE source = 'imdb' AND metric_type = 'rating_average'
),
imdb_votes AS (
    SELECT movie_id, value::float AS imdb_votes
    FROM external_metrics
    WHERE source = 'imdb' AND metric_type = 'rating_votes'
)
SELECT
    m.id AS movie_id,
    m.title,
    EXTRACT(YEAR FROM m.release_date)::int AS release_year,
    -- Lens scores
    msc.mob_score,
    msc.critics_score        AS ivory_tower_score,
    msc.festival_recognition_score,
    msc.time_machine_score   AS cultural_impact_score,
    msc.box_office_score     AS technical_innovation_score,
    msc.auteurs_score        AS auteur_recognition_score,
    -- External metrics
    ir.imdb_rating,
    iv.imdb_votes,
    -- Canonical overlap (excluding 1001_movies key itself)
    (
        SELECT COUNT(*)
        FROM jsonb_each(m.canonical_sources)
        WHERE key != '1001_movies'
    ) AS canonical_overlap_count,
    -- Director experience
    COALESCE(md.director_film_count, 0) AS director_film_count,
    -- Label
    CASE WHEN m.canonical_sources ? '1001_movies' THEN 1 ELSE 0 END AS is_on_1001_list
FROM movies m
LEFT JOIN movie_score_caches msc ON msc.movie_id = m.id
LEFT JOIN imdb_rating ir ON ir.movie_id = m.id
LEFT JOIN imdb_votes iv ON iv.movie_id = m.id
LEFT JOIN movie_directors md ON md.movie_id = m.id
WHERE m.release_date IS NOT NULL
ORDER BY m.id
"""


def export():
    out_path = Path(__file__).parent.parent / "data" / "movies.parquet"
    out_path.parent.mkdir(exist_ok=True)

    print(f"Connecting to {DB_URL} ...")
    conn = psycopg2.connect(DB_URL)
    try:
        df = pd.read_sql(SQL, conn)
    finally:
        conn.close()

    print(f"Fetched {len(df):,} rows")
    print(f"Label distribution:\n{df['is_on_1001_list'].value_counts()}")

    df.to_parquet(out_path, index=False)
    print(f"Saved → {out_path}")


if __name__ == "__main__":
    export()
