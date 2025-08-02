defmodule Cinegraph.Repo.Migrations.CreateImportProgressTable do
  use Ecto.Migration

  def change do
    create table(:import_progress) do
      add :import_type, :string, null: false # "full", "daily_update", "backfill"
      add :total_pages, :integer
      add :current_page, :integer
      add :movies_found, :integer, default: 0
      add :movies_imported, :integer, default: 0
      add :movies_failed, :integer, default: 0
      add :started_at, :utc_datetime, null: false
      add :completed_at, :utc_datetime
      add :status, :string, null: false # "running", "completed", "failed", "paused"
      add :metadata, :map, default: %{}
      timestamps()
    end

    create index(:import_progress, [:import_type])
    create index(:import_progress, [:status])
    create index(:import_progress, [:started_at])
  end
end