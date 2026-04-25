defmodule Cinegraph.Repo.Migrations.CreateCompletenessLog do
  use Ecto.Migration

  def change do
    create table(:completeness_log, primary_key: false) do
      add :captured_on, :date, primary_key: true, null: false
      add :payload, :map, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end
  end
end
