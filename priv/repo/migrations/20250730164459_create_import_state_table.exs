defmodule Cinegraph.Repo.Migrations.CreateImportStateTable do
  use Ecto.Migration

  def change do
    create table(:import_state, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :text
      add :updated_at, :utc_datetime_usec, null: false
    end
    
    # Create useful indexes for import management (if they don't exist)
    create_if_not_exists index(:movies, [:tmdb_id], unique: true)
    create_if_not_exists index(:movies, [:imdb_id])
    create_if_not_exists index(:movies, [:popularity])
    create_if_not_exists index(:people, [:tmdb_id], unique: true)
  end
end