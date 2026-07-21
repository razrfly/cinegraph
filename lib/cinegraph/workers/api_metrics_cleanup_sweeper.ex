defmodule Cinegraph.Workers.ApiMetricsCleanupSweeper do
  @moduledoc """
  Weekly sweep that applies the `api_lookup_metrics` retention policy (#1122),
  deleting rows older than 90 days while preserving the latest `import_state`
  per key. Runs on `:maintenance` (concurrency 1) so it serializes with the
  other sweepers.

  Wraps `Cinegraph.Maintenance.CleanupApiMetrics.run/1`.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Maintenance.CleanupApiMetrics

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case CleanupApiMetrics.run([]) do
      {:ok, %{deleted: deleted, retention_days: retention_days} = stats} ->
        Logger.info("ApiMetricsCleanupSweeper: deleted=#{deleted} (retention=#{retention_days}d)")

        {:ok, stats}
    end
  end
end
