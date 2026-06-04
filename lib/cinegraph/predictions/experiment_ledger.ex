defmodule Cinegraph.Predictions.ExperimentLedger do
  @moduledoc """
  The experiment ledger (#1061 Session 1) — one **append-only** row per evaluated cell.

  A "cell" is a `{source_key, model_class, backtest_strategy, feature_bucket, granularity, seed}`
  evaluation produced holdout-free by `Trainer.evaluate_cell/1`. Where `prediction_models` stores
  only the *promoted* serving artifact (and spends a sacred holdout), this table records **every**
  comparison run — winners, losers, and failures — so "which model/strategy/features wins which
  list" is a query, not a re-run.

  Intentionally append-only: there is **no unique constraint**. Re-running the same cell over time
  is the audit trail (`run_at` + `code_version` give provenance). `status` is `"ok"` for a
  completed evaluation or `"failed"` (with `error`) when the cell couldn't be evaluated — recorded,
  never silently dropped, so the leaderboard can't be flattered by survivorship.

  `Trainer.evaluate_cell/1` is the writer for every cell it completes (the single-writer rule). The
  one documented exception (#1065 Session 1) is `Trainer.run_cells/3`'s `record_failed_cell/3`: when
  a worker is killed (per-cell timeout / brutal kill) before `evaluate_cell` can write its own row,
  `run_cells` attributes a `failed` row for the known cell so no cell vanishes. Reads go through the
  `mix predictions.leaderboard` task. The `metrics` map carries the normalized report
  (recall_at_k, objective_recall_at_k, pr_auc, baselines, …); `weights` carries the model's
  learned weight map for weight-map classes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(ok failed)

  schema "prediction_experiments" do
    field :source_key, :string
    field :model_class, :string
    field :backtest_strategy, :string
    field :feature_bucket, :string
    field :granularity, :string
    field :seed, :integer
    field :weights, :map, default: %{}
    field :metrics, :map, default: %{}
    field :grade, :string
    field :status, :string, default: "ok"
    field :error, :string
    field :holdout_spent, :boolean, default: false
    field :code_version, :string
    field :run_at, :utc_datetime

    # Observability (#1065 Session 1): per-cell wall-clock + the run that produced this cell, and
    # the scored pool size promoted out of `metrics` so the cost model can query it cheaply.
    field :duration_ms, :integer
    field :run_id, :string
    field :n_evaluated, :integer

    timestamps()
  end

  @doc false
  def changeset(ledger, attrs) do
    ledger
    |> cast(attrs, [
      :source_key,
      :model_class,
      :backtest_strategy,
      :feature_bucket,
      :granularity,
      :seed,
      :weights,
      :metrics,
      :grade,
      :status,
      :error,
      :holdout_spent,
      :code_version,
      :run_at,
      :duration_ms,
      :run_id,
      :n_evaluated
    ])
    |> validate_required([:source_key, :model_class, :backtest_strategy, :granularity, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
