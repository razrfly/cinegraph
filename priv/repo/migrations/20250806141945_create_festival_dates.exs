defmodule Cinegraph.Repo.Migrations.CreateFestivalDates do
  use Ecto.Migration

  def change do
    create table(:festival_dates) do
      add :festival_event_id, references(:festival_events, on_delete: :delete_all), null: false
      
      add :year, :integer, null: false
      add :start_date, :date
      add :end_date, :date
      add :status, :string, null: false, default: "upcoming"
      add :announcement_date, :date
      add :source, :string
      add :notes, :text
      
      # Metadata for ceremony/festival specific info
      add :metadata, :map, default: %{}
      
      timestamps()
    end
    
    # Indexes for common queries
    create unique_index(:festival_dates, [:festival_event_id, :year])
    create index(:festival_dates, [:year])
    create index(:festival_dates, [:status])
    create index(:festival_dates, [:start_date])
    
    # Check constraints
    execute """
    ALTER TABLE festival_dates 
    ADD CONSTRAINT status_check 
    CHECK (status IN ('upcoming', 'in_progress', 'completed', 'cancelled'))
    """, ""
    
    execute """
    ALTER TABLE festival_dates 
    ADD CONSTRAINT valid_date_range_check 
    CHECK (end_date IS NULL OR start_date IS NULL OR end_date >= start_date)
    """, ""
  end
end