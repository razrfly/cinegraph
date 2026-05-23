defmodule Cinegraph.Repo.Migrations.AddNowPlayingRegionLastSeenToMovies do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :now_playing_region_last_seen, :map, null: true
    end

    create index(:movies, [:now_playing_region_last_seen],
             using: :gin,
             name: :movies_now_playing_region_last_seen_gin_index
           )
  end
end
