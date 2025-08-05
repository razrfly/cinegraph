defmodule Cinegraph.Repo.Migrations.CreateMovieLists do
  use Ecto.Migration

  def change do
    create table(:movie_lists) do
      # Basic Info
      add :source_key, :string, null: false
      add :name, :string, size: 500, null: false
      add :description, :text
      
      # Source Details (Generic)
      add :source_type, :string, size: 50, null: false
      add :source_url, :text, null: false
      add :source_id, :string
      
      # Configuration  
      add :category, :string
      add :active, :boolean, default: true
      
      # Award Tracking (Simple)
      add :tracks_awards, :boolean, default: false
      
      # Import Tracking
      add :last_import_at, :utc_datetime
      add :last_import_status, :string, size: 50
      add :last_movie_count, :integer, default: 0
      add :total_imports, :integer, default: 0
      
      # Metadata
      add :metadata, :map, default: %{}
      
      timestamps()
    end

    # Indexes
    create unique_index(:movie_lists, [:source_key])
    create index(:movie_lists, [:active])
    create index(:movie_lists, [:source_type])
    create index(:movie_lists, [:category])
  end
end