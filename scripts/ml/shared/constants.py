FEATURES_V1 = [
    "mob_score",
    "ivory_tower_score",
    "festival_recognition_score",
    "cultural_impact_score",
    "technical_innovation_score",
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
    "technical_innovation_score",
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

LABEL = "is_on_1001_list"

ACCURACY_TIERS = {50: "insufficient", 65: "marginal", 80: "good", 90: "strong"}

DB_URL = "postgresql://localhost/cinegraph_dev"

MLFLOW_TRACKING_URI = "mlruns"
