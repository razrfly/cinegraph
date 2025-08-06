defmodule Cinegraph.Repo.Migrations.AddDataSourceTrackingToFestivalCeremonies do
  use Ecto.Migration

  def change do
    alter table(:festival_ceremonies) do
      add :data_source, :string, size: 50, null: false, default: "unknown"
      add :source_url, :string
      add :scraped_at, :utc_datetime
      add :source_metadata, :map, default: %{}
    end

    # Add index for querying by data source
    create index(:festival_ceremonies, [:data_source])
  end
end
