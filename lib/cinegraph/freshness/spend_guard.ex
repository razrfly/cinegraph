defmodule Cinegraph.Freshness.SpendGuard do
  @moduledoc """
  Lightweight gatekeeper for demand-driven (read-through) refresh (#1108 §4).

  Before enqueuing a background API-refresh job, `allow?/1` returns false when:

    1. the master flag `:read_through_enabled` is off (the default),
    2. the source's Oban queue has already completed its per-source daily cap, or
    3. the source's queue is backpressured (too many in-flight jobs).

  Deliberately **not** a budget ledger — the heavyweight #1090 Phase-4 governor
  was dropped (#1108 §4). The daily cap is an approximation via
  `ObanReader.count_completed_since/2`, which counts the *whole* queue (floor
  sweepers included) — so read-through **yields to the floor**: it's the first
  thing denied once the queue is busy. Both DB reads are memoized in Cachex
  (`:health_cache`, 30s) so a page-view storm can't become a query storm.
  """

  alias Cinegraph.Health.ObanReader

  @cache :health_cache
  @cache_ttl :timer.seconds(30)
  @backpressure_states [:available, :scheduled, :executing, :retryable]

  # ledger source → the Oban queue its refresh worker lands on
  @queue_for %{
    "tmdb_details" => :tmdb,
    "watch_providers" => :tmdb,
    "imdb_id" => :tmdb,
    "tmdb_person" => :tmdb,
    "omdb" => :omdb
  }

  @doc "Whether the read-through master flag is on (default false)."
  def enabled?, do: Application.get_env(:cinegraph, :read_through_enabled, false)

  @doc """
  True if a read-through refresh for `source` may be enqueued right now.
  `source` is a ledger source (atom or string); unknown sources return false.
  """
  def allow?(source) do
    with true <- enabled?(),
         queue when not is_nil(queue) <- queue_for(source) do
      not over_daily_cap?(queue) and not backpressured?(queue)
    else
      _ -> false
    end
  end

  defp queue_for(source), do: Map.get(@queue_for, to_string(source))

  defp over_daily_cap?(queue) do
    cap = daily_cap(queue)
    cap > 0 and completed_today(queue) >= cap
  end

  defp backpressured?(queue) do
    limit = Application.get_env(:cinegraph, :read_through_queue_limit, 1_000)
    queue_depth(queue) > limit
  end

  defp daily_cap(queue) do
    :cinegraph
    |> Application.get_env(:read_through_daily_caps, %{})
    |> Map.get(queue, 0)
  end

  defp completed_today(queue) do
    cached({:completed_today, queue}, fn ->
      ObanReader.count_completed_since(start_of_utc_day(), queue)
    end)
  end

  defp queue_depth(queue) do
    cached({:queue_depth, queue}, fn ->
      ObanReader.counts_by_queue_and_state([queue], @backpressure_states)
      |> Map.get(queue, %{})
      |> Map.values()
      |> Enum.sum()
    end)
  end

  defp start_of_utc_day do
    DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  # 30s memoization so a page-view storm collapses into one query per key.
  defp cached(key, fun) do
    case Cachex.fetch(@cache, {:spend_guard, key}, fn -> {:commit, fun.(), ttl: @cache_ttl} end) do
      {:ok, v} -> v
      {:commit, v} -> v
      _ -> fun.()
    end
  end
end
