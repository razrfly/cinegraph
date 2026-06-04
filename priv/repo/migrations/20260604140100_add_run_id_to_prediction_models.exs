defmodule Cinegraph.Repo.Migrations.AddRunIdToPredictionModels do
  @moduledoc """
  Link a promoted/committed model to the promote run that produced it (#1065 Session 2).

  Promote writes `prediction_models` (not the experiment ledger), so without this column promote runs
  can't appear in the unified runs history. Nullable — old rows stay null.
  """
  use Ecto.Migration

  def change do
    alter table(:prediction_models) do
      add :run_id, :string
    end

    create index(:prediction_models, [:run_id])
  end
end
