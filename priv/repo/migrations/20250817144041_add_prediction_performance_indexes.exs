defmodule Cinegraph.Repo.Migrations.AddPredictionPerformanceIndexes do
  use Ecto.Migration

  def change do
    # Indexes for movie prediction queries

    # Index for finding 2020s movies not in 1001 list
    create index(:movies, [:release_date, :import_status],
             where: "import_status = 'full' AND canonical_sources IS NULL",
             name: :idx_movies_2020s_predictions
           )

    # Partial index for canonical sources lookup using GIN on the JSONB column
    create index(:movies, [:canonical_sources],
             where: "canonical_sources ? '1001_movies'",
             using: :gin,
             name: :idx_movies_1001_list
           )

    # External metrics index already created in earlier migration
    # Festival nominations index already created in earlier migration

    # Index for person quality scores
    create index(:person_metrics, [:person_id, :metric_type],
             where: "metric_type = 'quality_score'",
             name: :idx_person_quality_scores
           )

    # Index for movie credits person quality lookup
    create index(:movie_credits, [:movie_id, :person_id, :job],
             name: :idx_movie_credits_person_quality
           )

    # Index for historical validation decade queries
    # Using expression index for decade calculation
    execute """
            CREATE INDEX idx_movies_by_decade ON movies 
            ((FLOOR(EXTRACT(YEAR FROM release_date) / 10) * 10), import_status)
            WHERE release_date IS NOT NULL
            """,
            "DROP INDEX IF EXISTS idx_movies_by_decade"

    # Index for weight profiles lookup
    create index(:metric_weight_profiles, [:active, :name],
             where: "active = true",
             name: :idx_active_weight_profiles
           )
  end
end
