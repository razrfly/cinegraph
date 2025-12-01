defmodule Cinegraph.Repo.Migrations.AddPhase1PerformanceIndexes do
  @moduledoc """
  Phase 1 Performance Optimization: Add missing database indexes.

  These indexes target the most frequently queried patterns on the movies page:
  - External metrics lookups (ratings, popularity, etc.)
  - Base movie queries with import_status and release_date
  - Canonical sources filtering
  - Festival nominations filtering
  - Movie credits filtering

  Expected impact: 20-30% query speed improvement
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Covering index for external_metrics lookups (most frequently queried)
    # This index includes the value column to avoid table lookups
    create_if_not_exists index(
                           :external_metrics,
                           [:movie_id, :source, :metric_type, :value, :fetched_at],
                           name: :idx_external_metrics_covering,
                           concurrently: true
                         )

    # Composite index for base movie queries with common sorting
    # Partial index only for 'full' import_status movies (most common query)
    create_if_not_exists index(
                           :movies,
                           [:import_status, :release_date],
                           name: :idx_movies_import_status_release_date,
                           where: "import_status = 'full'",
                           concurrently: true
                         )

    # Partial index for movies with canonical sources (used in list filtering)
    # Helps with queries checking if a movie belongs to any canonical list
    # Note: Using raw SQL for expression index
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_movies_has_canonical
    ON movies((canonical_sources != '{}'::jsonb))
    WHERE canonical_sources != '{}'::jsonb
    """)

    # Index for festival nominations filtering by winners
    # Partial index for award winners (common filter)
    create_if_not_exists index(
                           :festival_nominations,
                           [:movie_id, :won],
                           name: :idx_festival_nominations_movie_won,
                           where: "won = true",
                           concurrently: true
                         )

    # Composite index for movie credits with person and role filters
    # Supports queries filtering by person, credit type, and specific jobs
    create_if_not_exists index(
                           :movie_credits,
                           [:movie_id, :person_id, :credit_type, :job],
                           name: :idx_movie_credits_movie_person_type,
                           concurrently: true
                         )
  end

  def down do
    drop_if_exists index(
                     :external_metrics,
                     [:movie_id, :source, :metric_type, :value, :fetched_at],
                     name: :idx_external_metrics_covering,
                     concurrently: true
                   )

    drop_if_exists index(:movies, [:import_status, :release_date],
                     name: :idx_movies_import_status_release_date,
                     concurrently: true
                   )

    execute("DROP INDEX CONCURRENTLY IF EXISTS idx_movies_has_canonical")

    drop_if_exists index(:festival_nominations, [:movie_id, :won],
                     name: :idx_festival_nominations_movie_won,
                     concurrently: true
                   )

    drop_if_exists index(:movie_credits, [:movie_id, :person_id, :credit_type, :job],
                     name: :idx_movie_credits_movie_person_type,
                     concurrently: true
                   )
  end
end
