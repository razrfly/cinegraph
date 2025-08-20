defmodule Cinegraph.Repo.Migrations.CreatePredictionCache do
  use Ecto.Migration

  def change do
    create table(:prediction_cache) do
      add :decade, :integer, null: false
      add :profile_id, references(:metric_weight_profiles, on_delete: :delete_all), null: false
      add :movie_scores, :map, default: %{}
      add :statistics, :map, default: %{}
      add :calculated_at, :utc_datetime, null: false
      add :metadata, :map, default: %{}
      
      timestamps()
    end

    create unique_index(:prediction_cache, [:decade, :profile_id])
    create index(:prediction_cache, [:profile_id])
    create index(:prediction_cache, [:calculated_at])
  end
end