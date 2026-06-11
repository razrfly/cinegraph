defmodule Cinegraph.Workers.SurfaceAreaCacheWarmer do
  @moduledoc """
  Keeps the surface-area report warm in `:health_cache` so `/admin/homeostasis`
  cold-paint is sub-second (#1108 §10c).

  `Cinegraph.Health.SurfaceArea.report/0` is a multi-second `Repo.replica` scan
  across every source. Re-running it every 30 minutes (under the 35-min Cachex
  TTL) means each dashboard request hits warm cache instead of triggering the
  scan in the request path. Mirrors `HealthCacheWarmer`.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Health.SurfaceArea

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    started_at = System.monotonic_time(:millisecond)
    report = SurfaceArea.cached_report(bypass_cache: true)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    Logger.info(
      "SurfaceAreaCacheWarmer: warmed in #{elapsed_ms}ms (#{length(report.sources)} sources)"
    )

    {:ok, %{warmed_in_ms: elapsed_ms, sources: length(report.sources)}}
  end
end
