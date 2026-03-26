FEATURES_V1 = [
    "mob_score",
    "ivory_tower_score",
    "festival_recognition_score",
    "cultural_impact_score",
    "financial_performance_score",  # box_office_score from movie_score_caches
    "auteur_recognition_score",
]

FEATURES_V2 = FEATURES_V1 + [
    "canonical_overlap_count",
    "imdb_votes_log",
    "imdb_rating",
    "decade",
    "has_festival_data",
    "has_critic_data",
    "director_film_count",
    "years_since_release",
]

# cultural_impact_score excluded — confirmed leakage:
# time_machine_score = min(10, map_size(canonical_sources) * 2 + popularity * 5)
# It counts all list memberships including '1001_movies' itself.
FEATURES_V1_CLEAN = [
    "mob_score",
    "ivory_tower_score",
    "festival_recognition_score",
    "financial_performance_score",  # box_office_score from movie_score_caches
    "auteur_recognition_score",
]

FEATURES_V2_CLEAN = FEATURES_V1_CLEAN + [
    "canonical_overlap_count",
    "imdb_votes_log",
    "imdb_rating",
    "decade",
    "has_festival_data",
    "has_critic_data",
    "director_film_count",
    "years_since_release",
]

FEATURES_V3 = FEATURES_V2_CLEAN + [
    "has_imdb_votes",
    "imdb_rating_decade_percentile",
    "imdb_votes_decade_percentile",
    "is_foreign_language",
    "primary_genre_encoded",
    "origin_continent",
    "director_avg_imdb_rating",
]

FEATURES_V4 = FEATURES_V3 + [f"emb_pc_{i}" for i in range(32)]

FEATURES_V5_32  = FEATURES_V3 + [f"emb_rpc_{i}" for i in range(32)]
FEATURES_V5_64  = FEATURES_V3 + [f"emb_rpc_{i}" for i in range(64)]
FEATURES_V5_128 = FEATURES_V3 + [f"emb_rpc_{i}" for i in range(128)]
FEATURES_V5_384 = FEATURES_V3 + [f"emb_raw_{i}" for i in range(384)]

LABEL = "is_on_1001_list"

ACCURACY_TIERS = {50: "insufficient", 65: "marginal", 80: "good", 90: "strong"}

import os

DB_URL = os.environ.get("DATABASE_URL", "postgresql://localhost/cinegraph_dev")
MLFLOW_TRACKING_URI = os.environ.get("MLFLOW_TRACKING_URI", "mlruns")
