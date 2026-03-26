"""Export Postgres data to data/movies.parquet for ML training."""

import sys
from pathlib import Path
from urllib.parse import urlparse

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
),
director_avg_ratings AS (
    SELECT mc.person_id, AVG(er.value::float) AS avg_imdb_rating
    FROM movie_credits mc
    JOIN external_metrics er ON er.movie_id = mc.movie_id
        AND er.source = 'imdb' AND er.metric_type = 'rating_average'
    WHERE mc.credit_type = 'crew' AND mc.job = 'Director'
    GROUP BY mc.person_id
),
movie_director_avg_rating AS (
    SELECT mc.movie_id, AVG(dar.avg_imdb_rating) AS director_avg_imdb_rating
    FROM movie_credits mc
    JOIN director_avg_ratings dar ON dar.person_id = mc.person_id
    WHERE mc.credit_type = 'crew' AND mc.job = 'Director'
    GROUP BY mc.movie_id
),
movie_director_names AS (
    SELECT mc.movie_id, STRING_AGG(p.name, ' ' ORDER BY p.name, p.id) AS director_names
    FROM movie_credits mc
    JOIN people p ON p.id = mc.person_id
    WHERE mc.credit_type = 'crew' AND mc.job = 'Director'
    GROUP BY mc.movie_id
),
movie_cast_names AS (
    SELECT movie_id,
           STRING_AGG(name, ' ' ORDER BY cast_order) AS cast_names
    FROM (
        SELECT mc.movie_id, p.name, mc.cast_order,
               ROW_NUMBER() OVER (PARTITION BY mc.movie_id ORDER BY mc.cast_order) AS rn
        FROM movie_credits mc
        JOIN people p ON p.id = mc.person_id
        WHERE mc.credit_type = 'cast'
    ) sub
    WHERE rn <= 5
    GROUP BY movie_id
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
    msc.box_office_score     AS financial_performance_score,
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
    -- New V3 raw columns
    m.tmdb_data->>'original_language'                      AS original_language,
    m.tmdb_data->'genres'->0->>'name'                      AS primary_genre_raw,
    m.tmdb_data->'production_countries'->0->>'iso_3166_1'  AS origin_country,
    m.tmdb_data->>'tagline'                                AS tagline,
    m.tmdb_data->>'overview'                               AS overview,
    mdn.director_names,
    mcn.cast_names,
    (SELECT STRING_AGG(kw->>'name', ' ')
     FROM jsonb_array_elements(
         COALESCE(m.tmdb_data->'keywords'->'keywords', '[]'::jsonb)
     ) AS kw
    ) AS tmdb_keywords,
    mdar.director_avg_imdb_rating,
    -- Label
    CASE WHEN m.canonical_sources ? '1001_movies' THEN 1 ELSE 0 END AS is_on_1001_list
FROM movies m
LEFT JOIN movie_score_caches msc ON msc.movie_id = m.id
LEFT JOIN imdb_rating ir ON ir.movie_id = m.id
LEFT JOIN imdb_votes iv ON iv.movie_id = m.id
LEFT JOIN movie_directors md ON md.movie_id = m.id
LEFT JOIN movie_director_avg_rating mdar ON mdar.movie_id = m.id
LEFT JOIN movie_director_names mdn ON mdn.movie_id = m.id
LEFT JOIN movie_cast_names mcn ON mcn.movie_id = m.id
WHERE m.release_date IS NOT NULL
ORDER BY m.id
"""


def export():
    out_path = Path(__file__).parent.parent / "data" / "movies.parquet"
    out_path.parent.mkdir(exist_ok=True)

    parsed = urlparse(DB_URL)
    print(f"Connecting to {parsed.hostname}{parsed.path} ...")
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
