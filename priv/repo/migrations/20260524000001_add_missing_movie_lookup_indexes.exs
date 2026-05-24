defmodule Cinegraph.Repo.Migrations.AddMissingMovieLookupIndexes do
  use Ecto.Migration

  # CREATE INDEX CONCURRENTLY cannot run inside a transaction
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Every movie show page calls get_movie_by_slug!/1 → WHERE slug = $1
    # Without this index: ~2,000ms sequential scan on 1.1M rows
    create_if_not_exists unique_index(:movies, [:slug],
      concurrently: true,
      name: :movies_slug_index
    )

    # tmdb_id lookups (import workers, GraphQL, now-playing sweeper)
    # Without this index: ~3,600ms sequential scan on 1.1M rows
    create_if_not_exists unique_index(:movies, [:tmdb_id],
      concurrently: true,
      name: :movies_tmdb_id_index
    )

    # id lookups — Repo.get!(Movie, id) had no primary key to use
    create_if_not_exists unique_index(:movies, [:id],
      concurrently: true,
      name: :movies_id_unique_index
    )
  end

  def down do
    drop_if_exists index(:movies, [:slug], name: :movies_slug_index)
    drop_if_exists index(:movies, [:tmdb_id], name: :movies_tmdb_id_index)
    drop_if_exists index(:movies, [:id], name: :movies_id_unique_index)
  end
end
