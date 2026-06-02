defmodule Cinegraph.Workers.ConnectionMonitorWorker do
  @moduledoc """
  Periodic connection-health check over `pg_stat_activity` (#1018 Session 5).

  Runs every 5 minutes, logs a one-line snapshot, and escalates on threshold
  breach so the next saturation/runaway is caught early instead of by a failed
  deploy (the original incident). `:warn` → `Logger.warning`; `:crit` →
  `Logger.error`, which surfaces automatically in Honeybadger/AppSignal.

  See `Cinegraph.Database.Monitoring.snapshot/1` for the thresholds. PgBouncer
  `cl_waiting` isn't included (admin console not app-queryable); queueing shows up
  as app-side DBConnection timeouts.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Database.Monitoring

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    snapshot = Monitoring.snapshot()

    summary =
      "ConnectionMonitor: #{snapshot.total_backends}/#{snapshot.max_connections} backends " <>
        "(#{snapshot.usage_pct}%), status=#{snapshot.status}, " <>
        "by_db=#{inspect(Enum.map(snapshot.by_database, &{&1.datname, &1.count}))}"

    case snapshot.status do
      :crit -> Logger.error("#{summary} — #{Enum.join(snapshot.warnings, "; ")}")
      :warn -> Logger.warning("#{summary} — #{Enum.join(snapshot.warnings, "; ")}")
      :ok -> Logger.info(summary)
    end

    {:ok, snapshot}
  end
end
