defmodule Cinegraph.Repo.Migrations.CreateApiLookupMetrics do
  use Ecto.Migration

  def change do
    create table(:api_lookup_metrics) do
      # "tmdb", "omdb", "imdb_scraper", "venice_scraper", etc.
      add :source, :string, null: false
      # "find_by_imdb", "search_movie", "fetch_ceremony", etc.
      add :operation, :string, null: false
      # IMDb ID, movie title, festival year, etc.
      add :target_identifier, :string
      add :success, :boolean, null: false
      # For fuzzy matches
      add :confidence_score, :float
      # Which strategy succeeded (1-5)
      add :fallback_level, :integer
      add :response_time_ms, :integer
      # "not_found", "rate_limit", "timeout", "parse_error"
      add :error_type, :string
      add :error_message, :text
      # Additional context (import source, job_id, etc.)
      add :metadata, :map

      timestamps()
    end

    create index(:api_lookup_metrics, [:source, :operation])
    create index(:api_lookup_metrics, [:success])
    create index(:api_lookup_metrics, [:inserted_at])
  end
end
