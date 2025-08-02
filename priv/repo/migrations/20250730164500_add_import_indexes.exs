defmodule Cinegraph.Repo.Migrations.AddImportIndexes do
  use Ecto.Migration

  def change do
    # Movie indexes for faster lookups during import
    create_if_not_exists index(:movies, [:tmdb_id])
    create_if_not_exists index(:movies, [:imdb_id])
    create_if_not_exists index(:movies, [:popularity])
    
    # Import progress indexes
    create_if_not_exists index(:import_progress, [:status])
    create_if_not_exists index(:import_progress, [:import_type, :status])
    
    # People indexes
    create_if_not_exists index(:people, [:tmdb_id])
  end
end