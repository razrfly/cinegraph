defmodule Cinegraph.Repo.Migrations.CreateApiLookupMetrics do
  use Ecto.Migration

  def change do
    create table(:api_lookup_metrics) do
      add :source, :string, null: false         # "tmdb", "omdb", "imdb_scraper", "venice_scraper", etc.
      add :operation, :string, null: false      # "find_by_imdb", "search_movie", "fetch_ceremony", etc.
      add :target_identifier, :string           # IMDb ID, movie title, festival year, etc.
      add :success, :boolean, null: false
      add :confidence_score, :float             # For fuzzy matches
      add :fallback_level, :integer             # Which strategy succeeded (1-5)
      add :response_time_ms, :integer
      add :error_type, :string                  # "not_found", "rate_limit", "timeout", "parse_error"
      add :error_message, :text
      add :metadata, :map                       # Additional context (import source, job_id, etc.)
      
      timestamps()
    end

    create index(:api_lookup_metrics, [:source, :operation])
    create index(:api_lookup_metrics, [:success])
    create index(:api_lookup_metrics, [:inserted_at])
  end
end