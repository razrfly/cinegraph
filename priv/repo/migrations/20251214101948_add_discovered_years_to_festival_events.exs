defmodule Cinegraph.Repo.Migrations.AddDiscoveredYearsToFestivalEvents do
  use Ecto.Migration

  def change do
    alter table(:festival_events) do
      # Array of years discovered from IMDb historyEventEditions
      # Stores actual years that have data, respecting historical gaps
      add :discovered_years, {:array, :integer}, default: []

      # IMDb event ID for festivals that can use IMDb for year discovery
      # e.g., "ev0000003" for Academy Awards, "ev0000147" for Cannes
      add :imdb_event_id, :string

      # Timestamp of last year discovery run
      add :years_discovered_at, :utc_datetime
    end

    # Index for efficient querying by imdb_event_id
    create index(:festival_events, [:imdb_event_id])
  end
end
