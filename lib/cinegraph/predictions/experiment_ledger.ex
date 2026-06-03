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

  `Trainer.evaluate_cell/1` is the SOLE writer (the single-writer rule); reads go through the
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
      :run_at
    ])
    |> validate_required([:source_key, :model_class, :backtest_strategy, :granularity, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
