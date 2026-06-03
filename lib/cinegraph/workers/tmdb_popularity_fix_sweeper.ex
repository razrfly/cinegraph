defmodule Cinegraph.Workers.TmdbPopularityFixSweeper do
  @moduledoc """
  One-shot/idempotent sweeper for the tmdb/popularity_score collision repair (#1036).

  Thin Oban wrapper over `Cinegraph.Maintenance.FixTmdbPopularityCollision` with a daily
  cap. On-demand (no cron) — trigger from `/admin/jobs`. Safe to run repeatedly: once the
  full population is repaired, `run/1` finds 0 and this is a no-op. Remove the worker +
  its JobRegistry entry once prod reports 0 remaining.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Maintenance.FixTmdbPopularityCollision
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, result} = FixTmdbPopularityCollision.run(limit: 5_000)
    Logger.info("TmdbPopularityFixSweeper: #{inspect(result)}")
    {:ok, result}
  end
end
