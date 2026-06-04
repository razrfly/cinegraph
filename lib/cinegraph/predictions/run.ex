defmodule Cinegraph.Predictions.Run do
  @moduledoc """
  A prediction *run* lifecycle record (#1065 Session 2) — the header the ledger lacks.

  One row per `mix predictions.matrix` / `predictions.promote --commit` invocation. Where
  `prediction_experiments` audits each evaluated cell, this row answers "what did we *intend* to run,
  with what params, is it still alive, did it finish, and how far along is it?" Counters
  (`completed_cells`/`failed_cells`/`current_cell`) advance **live** during a run via
  `Cinegraph.Predictions.RunReporter`, so the dashboard reads progress straight from here and
  `updated_at` doubles as a heartbeat (a `running` row with a stale `updated_at` = a dead run).

  Matrix runs join their cells via `prediction_experiments.run_id`; promote runs join their committed
  artifacts via `prediction_models.run_id`. `done = completed_cells + failed_cells`; the progress-bar
  denominator is `total_cells`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(matrix promote train)
  @statuses ~w(running completed failed cancelled)

  schema "prediction_runs" do
    field :run_id, :string
    field :kind, :string
    field :status, :string, default: "running"
    field :params, :map, default: %{}
    field :total_cells, :integer
    field :completed_cells, :integer, default: 0
    field :failed_cells, :integer, default: 0
    field :current_cell, :string
    field :error, :string
    field :node, :string
    field :code_version, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :run_id,
      :kind,
      :status,
      :params,
      :total_cells,
      :completed_cells,
      :failed_cells,
      :current_cell,
      :error,
      :node,
      :code_version,
      :started_at,
      :finished_at
    ])
    |> validate_required([:run_id, :kind, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:run_id)
  end
end
