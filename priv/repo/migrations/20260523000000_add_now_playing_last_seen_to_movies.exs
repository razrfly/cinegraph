defmodule Cinegraph.Repo.Migrations.AddNowPlayingLastSeenToMovies do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :now_playing_last_seen, :utc_datetime_usec, null: true
    end

    create index(:movies, [:now_playing_last_seen])
  end
end
