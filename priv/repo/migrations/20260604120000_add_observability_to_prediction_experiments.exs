defmodule Cinegraph.Repo.Migrations.AddObservabilityToPredictionExperiments do
  @moduledoc """
  Observability for prediction model runs (#1065 Session 1, Phase 1) — additive, no new tables.

  `duration_ms` is first-class per-cell wall-clock recorded by `Trainer.evaluate_cell/1` (old rows
  fall back to `inserted_at − run_at`). `run_id` groups one matrix/promote invocation's cells into a
  single "run" so progress + history can be queried as a unit. The shape index serves timing
  aggregation by `(model_class, backtest_strategy, feature_bucket)`.
  """
  use Ecto.Migration

  def change do
    alter table(:prediction_experiments) do
      add :duration_ms, :integer
      add :run_id, :string
    end

    create index(:prediction_experiments, [:run_id])
    create index(:prediction_experiments, [:model_class, :backtest_strategy, :feature_bucket])
  end
end
