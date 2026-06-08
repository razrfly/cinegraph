defmodule Cinegraph.Workers.AlgorithmsCacheWarmer do
  @moduledoc """
  Keeps the `/algorithms` rankings warm server-side (#1084 A.1).

  The fatal flaw this fixes: the show/compare pages computed predictions inside a
  visitor-socket-tied `start_async`. On prod the pools run 8.9k–258k movies (~11.5ms/movie
  through `metric_values_view`), so a full ranking takes 4–50 minutes — every visitor's task
  died with their socket and the cache NEVER warmed. Nobody ever saw a prediction.

  Strategy: this worker owns the recompute. It runs

    * at boot (via `StartupWarmupWorker`),
    * after every `DisplayCache.bust/0` (promotion/demotion/import/catalog reseed),
    * on a 6h cron — inside the 12h `DisplayCache` rank TTL, so entries refresh before expiry.

  It warms each SERVED list's `next_additions` + `ranked_members` at the cache's canonical
  limit, smallest-pool-first (frontier cutoff year desc ≈ smaller pool — afi's frozen 1998
  frontier is the 258k monster and goes last), so most lists go live fast even if the big
  ones take an hour. Each list's compute is memory-bounded (`Candidates` scores in id-keyed
  batches, keeping only `{id, score}` pairs) — safe on the 16GB serving node.

  `queue: :maintenance` has concurrency 1, so a warm run can never stampede the DB.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    priority: 2,
    # Oban's `unique` window is time-bound: a period shorter than the warm runtime would let a
    # second job enqueue while the first is still :executing (a full warm runs 4–50 min on prod),
    # breaking the "at most one queued/executing" intent below. 1h exceeds the worst case + buffer.
    unique: [
      period: 3600,
      fields: [:worker, :queue],
      states: [:available, :scheduled, :executing]
    ]

  import Ecto.Query

  alias Cinegraph.Predictions.{DisplayCache, ListFrontier}
  alias Cinegraph.Repo

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    started_at = System.monotonic_time(:millisecond)

    results =
      for source_key <- served_source_keys() do
        list_started = System.monotonic_time(:millisecond)

        next = DisplayCache.next_additions(source_key)
        members = DisplayCache.ranked_members(source_key)

        elapsed_ms = System.monotonic_time(:millisecond) - list_started
        status = if match?({:ok, _}, next) and match?({:ok, _}, members), do: :ok, else: :error
        Logger.info("AlgorithmsCacheWarmer: #{source_key} #{status} in #{elapsed_ms}ms")
        {source_key, status, elapsed_ms}
      end

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    failed = for {sk, :error, _} <- results, do: sk

    Logger.info(
      "AlgorithmsCacheWarmer: warmed #{length(results) - length(failed)}/#{length(results)} " <>
        "lists in #{elapsed_ms}ms#{if failed != [], do: " (failed: #{Enum.join(failed, ", ")})"}"
    )

    {:ok, %{warmed: length(results) - length(failed), failed: failed, elapsed_ms: elapsed_ms}}
  end

  @doc """
  Enqueue a warm run (deduped — at most one queued/executing at a time). Fire-and-forget:
  callers like `DisplayCache.bust/0` must not fail when Oban is down or absent (tests).
  """
  def enqueue do
    %{}
    |> new()
    |> Oban.insert()
    |> case do
      {:ok, _job} = ok ->
        ok

      {:error, reason} = err ->
        Logger.warning("AlgorithmsCacheWarmer not enqueued: #{inspect(reason)}")
        err
    end
  rescue
    e ->
      Logger.warning("AlgorithmsCacheWarmer not enqueued: #{Exception.message(e)}")
      {:error, e}
  end

  # Served lists (active + a model pointer), smallest-pool-first: a later frontier cutoff
  # means fewer candidate movies, so newest cutoff first; no-cutoff lists (full pool) last.
  defp served_source_keys do
    Repo.all(
      from l in "movie_lists",
        where: l.active == true and not is_nil(l.active_prediction_model_id),
        select: l.source_key
    )
    |> Enum.sort_by(fn sk ->
      case ListFrontier.resolve(sk) do
        %{cutoff_year: year} when is_integer(year) -> -year
        _ -> 9999
      end
    end)
  end
end
