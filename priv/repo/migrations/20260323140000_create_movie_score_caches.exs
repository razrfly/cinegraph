defmodule Cinegraph.Repo.Migrations.CreateMovieScoreCaches do
  use Ecto.Migration

  def change do
    create table(:movie_score_caches) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false

      # 6 lens scores (0–10)
      add :mob_score, :float
      add :ivory_tower_score, :float
      add :industry_recognition_score, :float
      add :cultural_impact_score, :float
      add :people_quality_score, :float
      add :financial_performance_score, :float

      # Derived
      add :overall_score, :float
      add :score_confidence, :float
      add :disparity_score, :float
      add :disparity_category, :string
      add :unpredictability_score, :float

      # Cache metadata
      add :calculated_at, :utc_datetime, null: false
      add :calculation_version, :string, null: false, default: "1"

      timestamps()
    end

    create unique_index(:movie_score_caches, [:movie_id])
    create index(:movie_score_caches, [:disparity_category])
    create index(:movie_score_caches, [:disparity_score])
    create index(:movie_score_caches, [:unpredictability_score])
    create index(:movie_score_caches, [:overall_score])
  end
end
