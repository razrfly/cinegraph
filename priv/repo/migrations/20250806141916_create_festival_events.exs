defmodule Cinegraph.Repo.Migrations.CreateFestivalEvents do
  use Ecto.Migration

  def change do
    create table(:festival_events) do
      # Basic Info
      add :source_key, :string, null: false
      add :name, :string, null: false
      add :abbreviation, :string
      add :country, :string
      add :founded_year, :integer
      add :website, :string

      # Multi-Source Configuration
      add :primary_source, :string, null: false, default: "imdb"
      add :source_config, :map, default: %{}
      add :fallback_sources, {:array, :map}, default: []

      # Date Management
      add :typical_start_month, :integer
      add :typical_start_day, :integer
      add :typical_duration_days, :integer
      add :timezone, :string, default: "UTC"

      # Year Range Management
      add :min_available_year, :integer
      add :max_available_year, :integer
      add :current_year_status, :string

      # Import Configuration
      add :active, :boolean, default: true
      add :import_priority, :integer, default: 0
      add :auto_detect_new_years, :boolean, default: true

      # Statistics & Reliability
      add :last_successful_import, :utc_datetime
      add :total_successful_imports, :integer, default: 0
      add :reliability_score, :float, default: 0.0
      add :last_error, :text

      # Event Type Classification
      add :ceremony_vs_festival, :string
      add :tracks_nominations, :boolean, default: true
      add :tracks_winners_only, :boolean, default: false
      add :categories_structure, :string, default: "hierarchical"

      # Metadata
      add :metadata, :map, default: %{}

      timestamps()
    end

    # Indexes for common queries
    create unique_index(:festival_events, [:source_key])
    create index(:festival_events, [:active])
    create index(:festival_events, [:primary_source])
    create index(:festival_events, [:typical_start_month])
    create index(:festival_events, [:import_priority])
    create index(:festival_events, [:reliability_score])

    # Check constraints
    execute """
            ALTER TABLE festival_events 
            ADD CONSTRAINT primary_source_check 
            CHECK (primary_source IN ('imdb', 'official', 'api', 'custom'))
            """,
            ""

    execute """
            ALTER TABLE festival_events 
            ADD CONSTRAINT ceremony_vs_festival_check 
            CHECK (ceremony_vs_festival IN ('ceremony', 'festival') OR ceremony_vs_festival IS NULL)
            """,
            ""

    execute """
            ALTER TABLE festival_events 
            ADD CONSTRAINT current_year_status_check 
            CHECK (current_year_status IN ('upcoming', 'in_progress', 'completed', 'cancelled') OR current_year_status IS NULL)
            """,
            ""

    execute """
            ALTER TABLE festival_events 
            ADD CONSTRAINT reliability_score_check 
            CHECK (reliability_score >= 0.0 AND reliability_score <= 1.0)
            """,
            ""
  end
end
