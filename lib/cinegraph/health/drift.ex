defmodule Cinegraph.Health.Drift do
  @moduledoc """
  Shared drift result shape + cache + parallel-run helpers.

  Each check function returns the canonical `result/5` map. Verdict (#722
  PR 5) reads these and applies status thresholds — until then,
  `status: :unknown`.
  """

  @cache_name :health_cache

  @typedoc "Uniform drift check result"
  @type result :: %{
          generated_at: DateTime.t(),
          domain: atom(),
          check: atom(),
          status: atom(),
          total_population: non_neg_integer(),
          affected_count: non_neg_integer(),
          affected_pct: float(),
          examples: [map()],
          blocked_reason: String.t() | nil
        }

  @doc """
  Build a uniform result map. Status defaults to `:unknown`; Verdict colors it.
  """
  def result(domain, check, total, affected, examples \\ [], blocked_reason \\ nil) do
    %{
      generated_at: DateTime.utc_now(),
      domain: domain,
      check: check,
      status: :unknown,
      total_population: total,
      affected_count: affected,
      affected_pct: pct(affected, total),
      examples: examples,
      blocked_reason: blocked_reason
    }
  end

  @doc """
  Cache wrapper. Returns the cached value or computes via `fun` and caches
  with `ttl_ms`.
  """
  def cached(key, ttl_ms, fun) when is_function(fun, 0) do
    case Cachex.fetch(@cache_name, key, fn ->
           {:commit, fun.(), ttl: ttl_ms}
         end) do
      {:ok, value} -> value
      {:commit, value} -> value
      _ -> fun.()
    end
  end

  @doc """
  Run multiple zero-arity check functions in parallel. Returns a list of
  results in input order. Tasks that crash or time out yield a result-shaped
  error with `blocked_reason`.
  """
  def run_all(check_funs, opts \\ []) when is_list(check_funs) do
    # Per-check timeout. Reduced from 180_000 in #955 to align with the new
    # outer per-domain timeout of 20_000 in Facade. Checks that exceed 15s
    # surface as :unknown/blocked_reason rather than holding connections.
    timeout = Keyword.get(opts, :timeout, 15_000)
    # Reduced from 4 → 2 in #955: caps per-domain DB connections so
    # Repo.Worker pool (size 5) can serve 2 concurrent domains with headroom.
    max_concurrency = Keyword.get(opts, :max_concurrency, 2)
    # Propagate the job-repo process-dict key into each child task so that
    # Repo.replica() routes to Repo.Worker when called from the health warmer.
    job_repo = Process.get(:cinegraph_job_repo)

    check_funs
    |> Task.async_stream(
      fn fun ->
        if job_repo, do: Process.put(:cinegraph_job_repo, job_repo)

        try do
          {:ok, fun.()}
        rescue
          e -> {:raised, Exception.format(:error, e, __STACKTRACE__)}
        catch
          kind, reason -> {:caught, "#{kind}: #{inspect(reason)}"}
        end
      end,
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, {:ok, result}} -> result
      {:ok, {:raised, msg}} -> result(:unknown, :crashed, 0, 0, [], "task raised: #{msg}")
      {:ok, {:caught, msg}} -> result(:unknown, :crashed, 0, 0, [], "task threw: #{msg}")
      {:exit, reason} -> result(:unknown, :crashed, 0, 0, [], "task exited: #{inspect(reason)}")
    end)
  end

  @doc false
  def pct(_count, 0), do: 0.0

  def pct(count, total) when is_integer(count) and is_integer(total) do
    Float.round(count / total * 100, 2)
  end
end
