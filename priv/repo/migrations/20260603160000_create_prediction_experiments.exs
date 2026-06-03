defmodule Cinegraph.Repo.Migrations.CreatePredictionExperiments do
  use Ecto.Migration

  def change do
    create table(:prediction_experiments) do
      add :source_key, :string, null: false
      add :model_class, :string, null: false
      add :backtest_strategy, :string
      add :feature_bucket, :string
      add :granularity, :string
      add :seed, :integer
      add :weights, :map, default: %{}
      add :metrics, :map, default: %{}
      add :grade, :string
      add :status, :string, null: false, default: "ok"
      add :error, :text
      add :holdout_spent, :boolean, null: false, default: false
      add :code_version, :string
      add :run_at, :utc_datetime
      timestamps()
    end

    # Append-only ledger — NO unique constraint: repeated runs of the same cell across time are
    # the audit trail, distinguished by run_at. These indexes serve the leaderboard reads.
    create index(:prediction_experiments, [:source_key, :model_class, :backtest_strategy])
    create index(:prediction_experiments, [:source_key, :grade])
    create index(:prediction_experiments, [:run_at])
  end
end
