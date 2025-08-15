defmodule Cinegraph.Repo.Migrations.CreatePersonMetrics do
  use Ecto.Migration

  def change do
    create table(:person_metrics) do
      add :person_id, references(:people, on_delete: :delete_all), null: false
      add :metric_type, :string, null: false
      add :score, :float
      add :components, :map, default: %{}
      add :metadata, :map, default: %{}
      add :calculated_at, :utc_datetime, null: false
      add :valid_until, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:person_metrics, [:person_id, :metric_type])
    create index(:person_metrics, [:metric_type])
    create index(:person_metrics, [:score])
    create index(:person_metrics, [:calculated_at])
  end
end
