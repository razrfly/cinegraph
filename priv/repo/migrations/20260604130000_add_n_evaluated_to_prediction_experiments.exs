defmodule Cinegraph.Repo.Migrations.AddNEvaluatedToPredictionExperiments do
  @moduledoc """
  Promote `n_evaluated` (the cell's scored pool size) to a first-class, indexed column (#1065
  Session 1, Phase 1 — review follow-up).

  It still lives in the `metrics` jsonb for the full report, but the cost model needs it as a
  queryable column: the ETA is `duration_ms ≈ k · n_evaluated`, so timing must join/aggregate on
  pool size cheaply. `Trainer.evaluate_cell/1` populates it at write time from the report; old rows
  (and `failed` rows) stay null.
  """
  use Ecto.Migration

  def change do
    alter table(:prediction_experiments) do
      add :n_evaluated, :integer
    end

    create index(:prediction_experiments, [:n_evaluated])
  end
end
