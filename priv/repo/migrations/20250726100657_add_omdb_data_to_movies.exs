defmodule Cinegraph.Repo.Migrations.AddOmdbDataToMovies do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :omdb_data, :map
    end
  end
end