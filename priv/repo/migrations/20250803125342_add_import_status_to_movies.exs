defmodule Cinegraph.Repo.Migrations.AddImportStatusToMovies do
  use Ecto.Migration

  def change do
    # Add import_status to movies table
    alter table(:movies) do
      add :import_status, :string, default: "full", null: false
    end
    
    # Create index for filtering
    create index(:movies, [:import_status])
    
    # Create table to track skipped imports for analytics
    create table(:skipped_imports) do
      add :tmdb_id, :integer, null: false
      add :title, :string
      add :reason, :string
      add :criteria_failed, :map
      add :checked_at, :utc_datetime_usec, default: fragment("NOW()")
      
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
    
    create index(:skipped_imports, [:tmdb_id])
    create index(:skipped_imports, [:checked_at])
  end
end