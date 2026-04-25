defmodule Cinegraph.Health.Facade do
  @moduledoc """
  Orchestrates the I/O that `Verdict` (pure) cannot do.

  Used by `mix cinegraph.health` and `mix cinegraph.status`. Also the
  read path for `/admin/health` (#723).
  """

  import Ecto.Query

  alias Cinegraph.Health.{Activity, Queues, Verdict}
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  @cache_name :health_cache
  @task_supervisor Cinegraph.Health.TaskSupervisor
  @drift_timeout 120_000

  @doc """
  Run all 4 drift domains in parallel, roll them up via `Verdict.compute/1`.

  ## Options

    * `:bypass_cache` — when `true`, clears `:health_cache` before computing
      so every drift check runs fresh. Used by the LiveView's "Refresh now"
      button and by mix tasks.
  """
  def compute_full_verdict(opts \\ []) do
    if Keyword.get(opts, :bypass_cache, false) do
      Cachex.clear(@cache_name)
    end

    domains = [
      people: Cinegraph.Health.Drift.People,
      movies: Cinegraph.Health.Drift.Movies,
      festivals: Cinegraph.Health.Drift.Festivals,
      ratings: Cinegraph.Health.Drift.Ratings
    ]

    domain_results =
      @task_supervisor
      |> Task.Supervisor.async_stream_nolink(
        domains,
        fn {domain, mod} -> {domain, mod.all()} end,
        timeout: @drift_timeout,
        on_timeout: :kill_task,
        max_concurrency: length(domains)
      )
      |> Enum.zip(domains)
      |> Enum.map(fn
        {{:ok, {domain, checks}}, _} -> {domain, checks}
        {{:exit, reason}, {domain, _mod}} -> {domain, drift_failure(domain, reason)}
      end)
      |> Enum.into(%{})

    Verdict.compute(domain_results)
  end

  @doc """
  Snapshot for `mix cinegraph.status` — activity + queues + last sync timestamp.
  """
  def compute_status do
    %{
      generated_at: DateTime.utc_now(),
      activity_today: Activity.today(bypass_cache: true),
      queues: Queues.snapshot(bypass_cache: true),
      last_sync_at: last_sync_timestamp()
    }
  end

  defp last_sync_timestamp do
    Repo.replica().one(from(m in Movie, select: max(m.updated_at)))
  end

  # When a domain drift task crashes or times out we surface a single
  # blocked check rather than letting the EXIT propagate to the caller.
  defp drift_failure(domain, reason) do
    [
      %{
        generated_at: DateTime.utc_now(),
        domain: domain,
        check: :drift_runner,
        status: :unknown,
        total_population: 0,
        affected_count: 0,
        affected_pct: 0.0,
        examples: [],
        blocked_reason: "drift task failed: #{inspect(reason)}"
      }
    ]
  end
end
