defmodule Cinegraph.Workers.HealthCacheWarmer do
  @moduledoc """
  Keeps `:health_cache` warm so `/admin/health` cold-paint is sub-second
  (#745 Phase 3.3).

  Without this worker, the first request after deploy or after a 5-minute
  Cachex TTL evicts every drift check — `Drift.run_all/2` fans out across
  4 domains' parallel queries, taking 10–30s on prod and tripping CDN
  504 timeouts.

  Strategy: re-run `Cinegraph.Health.Facade.compute_full_verdict/0` every 4
  minutes. Drift checks share `:health_cache` (5 min TTL), so warming
  every 4 min means each row is re-computed before it expires. Net effect:
  every `/admin/health` request hits warm cache.

  Plus a one-shot warm at app boot (see `Cinegraph.Application`).
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Health.Facade

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    started_at = System.monotonic_time(:millisecond)
    verdict = Facade.compute_full_verdict()
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    Logger.info(
      "HealthCacheWarmer: warmed in #{elapsed_ms}ms, status=#{verdict.status}"
    )

    {:ok, %{warmed_in_ms: elapsed_ms, status: verdict.status}}
  end
end
