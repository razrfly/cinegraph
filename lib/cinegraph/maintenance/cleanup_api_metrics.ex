defmodule Cinegraph.Maintenance.CleanupApiMetrics do
  @moduledoc """
  Applies the retention policy to `api_lookup_metrics` (#1122). The table is
  append-only — the OMDb `RatingsRefreshWorker` alone writes ~100K rows/day — and
  its retention function had zero callers, so it grew to ~12M rows / 1.66 GB.

  Deletes rows older than `:retention_days` (default 90) while preserving the
  latest successful `import_state` record per `(source, target_identifier)` key.
  All dashboard readers use ≤24 h windows, so this only removes dead weight. The
  first run deletes ~62% of the table; steady state keeps it ~90-day capped.

  Reachable from:
  - `Cinegraph.Workers.ApiMetricsCleanupSweeper` (Oban Cron, weekly, :maintenance)
  - `bin/cinegraph eval "Cinegraph.Maintenance.CleanupApiMetrics.run([])"` (one-shot prod)

  ## Options
    * `:retention_days` (positive integer) — age cutoff in days (default 90).
    * `:dry_run` (boolean) — count only; delete nothing.

  ## Returns
  `{:ok, %{deleted: integer, retention_days: integer, dry_run: boolean}}`
  """

  alias Cinegraph.Metrics.ApiTracker

  require Logger

  @default_retention_days 90

  @spec run(keyword()) ::
          {:ok,
           %{
             deleted: non_neg_integer(),
             retention_days: pos_integer(),
             dry_run: boolean()
           }}
  def run(opts \\ []) when is_list(opts) do
    days =
      case Keyword.get(opts, :retention_days, @default_retention_days) do
        n when is_integer(n) and n > 0 ->
          n

        other ->
          raise ArgumentError,
                ":retention_days must be a positive integer, got: #{inspect(other)}"
      end

    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run? do
      count = ApiTracker.count_old_metrics(days)
      Logger.info("CleanupApiMetrics: dry-run would delete #{count} rows (retention=#{days}d)")
      {:ok, %{deleted: count, retention_days: days, dry_run: true}}
    else
      deleted = ApiTracker.cleanup_old_metrics(days)
      {:ok, %{deleted: deleted, retention_days: days, dry_run: false}}
    end
  end
end
