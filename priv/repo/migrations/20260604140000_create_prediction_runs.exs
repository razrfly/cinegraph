defmodule Cinegraph.Repo.Migrations.CreatePredictionRuns do
  @moduledoc """
  The run *lifecycle* record (#1065 Session 2) — the common parent the ledger lacks.

  `prediction_experiments` is an audit trail of *evaluated cells*; it can't say what a run *intended*
  to do, whether it's still alive, or whether it finished. This table is the header: matrix runs
  link their ledger rows via `prediction_experiments.run_id`; promote runs link their
  `prediction_models` rows the same way. Counters advance **live** during a run (the run process
  updates them per cell), so the dashboard reads progress straight from the row and `updated_at`
  doubles as a heartbeat for crash/stale detection (`status="running"` + stale `updated_at`).
  """
  use Ecto.Migration

  def change do
    create table(:prediction_runs) do
      add :run_id, :string, null: false
      add :kind, :string, null: false
      add :status, :string, null: false, default: "running"
      add :params, :map, default: %{}
      add :total_cells, :integer
      add :completed_cells, :integer, null: false, default: 0
      add :failed_cells, :integer, null: false, default: 0
      add :current_cell, :string
      add :error, :string
      add :node, :string
      add :code_version, :string
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps()
    end

    create unique_index(:prediction_runs, [:run_id])
    create index(:prediction_runs, [:status])
    create index(:prediction_runs, [:inserted_at])
  end
end
