defmodule Cinegraph.Repo.Migrations.RemoveUnusedTables do
  use Ecto.Migration

  def up do
    # Drop unused tables that have never been populated
    
    # skipped_imports - Was intended for tracking movies that didn't meet import criteria
    # but never actually used. The import_status field on movies table serves this purpose
    drop_if_exists table(:skipped_imports)
    
    # import_state - Was intended for tracking pagination state in TMDb imports
    # but the TMDbImporter module is not being used. Current import system uses
    # different mechanisms (import_progress table and Oban jobs)
    drop_if_exists table(:import_state)
    
    # person_relationships - Was intended for caching person connection paths
    # but never populated. The collaborations table and real-time path finding
    # serve this purpose without needing caching
    drop_if_exists table(:person_relationships)
  end

  def down do
    # Restore import_state table (ACTUALLY STILL USED BY TMDbImporter!)
    create table(:import_state, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :text
      add :updated_at, :utc_datetime_usec, null: false
    end

    # Restore skipped_imports table
    create table(:skipped_imports) do
      add :tmdb_id, :integer, null: false
      add :imdb_id, :string
      add :title, :string
      add :reason, :string, null: false
      add :criteria_failed, :map
      add :import_type, :string
      
      timestamps()
    end
    
    create unique_index(:skipped_imports, [:tmdb_id])
    create index(:skipped_imports, [:reason])

    # Restore person_relationships table  
    create table(:person_relationships) do
      add :person_id, references(:people, on_delete: :delete_all), null: false
      add :related_person_id, references(:people, on_delete: :delete_all), null: false
      add :relationship_type, :string, null: false
      add :details, :map
      
      timestamps()
    end
    
    create index(:person_relationships, [:person_id])
    create index(:person_relationships, [:related_person_id])
    create unique_index(:person_relationships, [:person_id, :related_person_id, :relationship_type])
  end
end