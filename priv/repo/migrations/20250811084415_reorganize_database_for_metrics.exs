defmodule Cinegraph.Repo.Migrations.ReorganizeDatabaseForMetrics do
  use Ecto.Migration

  def change do
    # Create external_metrics table for all volatile/subjective data
    create table(:external_metrics) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :source, :string, null: false, size: 50
      add :metric_type, :string, null: false, size: 100
      add :value, :float
      add :text_value, :text
      add :metadata, :map, default: %{}
      add :fetched_at, :utc_datetime, null: false
      add :valid_until, :utc_datetime

      timestamps()
    end

    create index(:external_metrics, [:movie_id])
    create index(:external_metrics, [:source, :metric_type])
    create index(:external_metrics, [:fetched_at])
    create unique_index(:external_metrics, [:movie_id, :source, :metric_type, :fetched_at])

    # Create simplified movie_recommendations table
    create table(:movie_recommendations) do
      add :source_movie_id, references(:movies, on_delete: :delete_all), null: false
      add :recommended_movie_id, references(:movies, on_delete: :delete_all), null: false
      add :source, :string, null: false, size: 50
      add :type, :string, null: false, size: 50
      add :rank, :integer
      add :score, :float
      add :metadata, :map, default: %{}
      add :fetched_at, :utc_datetime, null: false

      timestamps()
    end

    create index(:movie_recommendations, [:source_movie_id])
    create index(:movie_recommendations, [:recommended_movie_id])
    create index(:movie_recommendations, [:source, :type])

    create unique_index(:movie_recommendations, [
             :source_movie_id,
             :recommended_movie_id,
             :source,
             :type
           ])

    # Drop deprecated tables first
    drop_if_exists table(:external_recommendations)
    drop_if_exists table(:external_ratings)
    drop_if_exists table(:external_sources)

    # Remove volatile fields from movies table BEFORE creating the view
    alter table(:movies) do
      remove_if_exists :vote_average, :float
      remove_if_exists :vote_count, :integer
      remove_if_exists :popularity, :float
      remove_if_exists :budget, :bigint
      remove_if_exists :revenue, :bigint
      remove_if_exists :box_office_domestic, :bigint
      remove_if_exists :awards_text, :text
      remove_if_exists :awards, :map
    end

    # NOW create backward-compatible view for existing queries
    execute """
            CREATE OR REPLACE VIEW movies_with_metrics AS
            SELECT 
              m.*,
              -- Ratings
              (SELECT value FROM external_metrics 
               WHERE movie_id = m.id AND source = 'tmdb' AND metric_type = 'rating_average'
               ORDER BY fetched_at DESC LIMIT 1) as vote_average,
              (SELECT value FROM external_metrics 
               WHERE movie_id = m.id AND source = 'tmdb' AND metric_type = 'rating_votes'
               ORDER BY fetched_at DESC LIMIT 1) as vote_count,
              (SELECT value FROM external_metrics 
               WHERE movie_id = m.id AND source = 'tmdb' AND metric_type = 'popularity_score'
               ORDER BY fetched_at DESC LIMIT 1) as popularity,
              -- Financials
              (SELECT value FROM external_metrics 
               WHERE movie_id = m.id AND source = 'tmdb' AND metric_type = 'budget'
               ORDER BY fetched_at DESC LIMIT 1) as budget,
              (SELECT value FROM external_metrics 
               WHERE movie_id = m.id AND source = 'tmdb' AND metric_type = 'revenue_worldwide'
               ORDER BY fetched_at DESC LIMIT 1) as revenue,
              (SELECT value FROM external_metrics 
               WHERE movie_id = m.id AND source = 'omdb' AND metric_type = 'revenue_domestic'
               ORDER BY fetched_at DESC LIMIT 1) as box_office_domestic,
              -- Awards
              (SELECT text_value FROM external_metrics 
               WHERE movie_id = m.id AND source = 'omdb' AND metric_type = 'awards_summary'
               ORDER BY fetched_at DESC LIMIT 1) as awards_text
            FROM movies m
            """,
            "DROP VIEW IF EXISTS movies_with_metrics"
  end
end
