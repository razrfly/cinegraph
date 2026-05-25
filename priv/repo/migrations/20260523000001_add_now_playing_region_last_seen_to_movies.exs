defmodule Cinegraph.Repo.Migrations.AddNowPlayingRegionLastSeenToMovies do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Column may already exist if a previous deploy was interrupted after the
    # ALTER TABLE committed but before the CONCURRENTLY index build finished.
    alter table(:movies) do
      add_if_not_exists :now_playing_region_last_seen, :map, null: true
    end

    # An interrupted CONCURRENTLY build leaves an INVALID index with the same
    # name. DROP IF EXISTS clears it so the subsequent CREATE can succeed.
    execute "DROP INDEX CONCURRENTLY IF EXISTS movies_now_playing_region_last_seen_gin_index"

    create_if_not_exists index(:movies, [:now_playing_region_last_seen],
                           using: :gin,
                           name: :movies_now_playing_region_last_seen_gin_index,
                           concurrently: true
                         )
  end

  def down do
    drop_if_exists index(:movies, [:now_playing_region_last_seen],
                     name: :movies_now_playing_region_last_seen_gin_index
                   )

    alter table(:movies) do
      remove_if_exists :now_playing_region_last_seen, :map
    end
  end
end
