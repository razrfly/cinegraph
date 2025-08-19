defmodule Cinegraph.Repo.Migrations.CreatePredictionCache do
  use Ecto.Migration

  def change do
    create table(:prediction_cache) do
      add :decade, :integer, null: false
      add :profile_id, :bigint, null: false
      add :movie_scores, :jsonb, default: "{}", null: false
      add :statistics, :jsonb, default: "{}", null: false
      add :calculated_at, :utc_datetime, null: false
      add :metadata, :jsonb, default: "{}"
      
      timestamps()
    end

    create unique_index(:prediction_cache, [:decade, :profile_id])
    create index(:prediction_cache, :calculated_at)
    create index(:prediction_cache, :decade)

    # Create staleness tracking table
    create table(:prediction_staleness_tracking) do
      add :change_type, :string, null: false  # movie_updated, metric_updated, festival_added, etc.
      add :entity_id, :bigint
      add :entity_type, :string
      add :metadata, :jsonb, default: "{}"
      add :affected_decades, {:array, :integer}, default: []
      
      timestamps(updated_at: false)
    end

    create index(:prediction_staleness_tracking, :change_type)
    create index(:prediction_staleness_tracking, [:entity_type, :entity_id])
    create index(:prediction_staleness_tracking, :inserted_at)
    create index(:prediction_staleness_tracking, :affected_decades, using: :gin)
  end
end