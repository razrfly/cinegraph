defmodule Cinegraph.Workers.MoviesCacheWarmer do
  @moduledoc """
  Oban worker that warms the movies page cache with popular queries.

  This worker runs periodically (every 10 minutes by default) to ensure
  that frequently accessed movie searches are cached and fast.

  ## Scheduling

  The worker is scheduled via Oban's cron plugin in the application config.
  It can also be manually triggered:

      Cinegraph.Workers.MoviesCacheWarmer.schedule()

  ## What it does

  - Warms cache for default homepage view
  - Pre-caches popular sort orders (release_date, rating, popularity)
  - Pre-caches common filters (decades, rating presets, festivals)
  - Logs the number of queries warmed
  """

  use Oban.Worker,
    queue: :cache_warming,
    max_attempts: 3,
    priority: 2

  require Logger
  alias Cinegraph.Movies.{Cache, Search}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("[MoviesCacheWarmer] Starting cache warming job")

    start_time = System.monotonic_time(:millisecond)

    # Warm the cache with popular queries
    warmed_keys =
      Cache.warm_popular_queries(fn params ->
        Search.search_movies_uncached(params)
      end)

    elapsed = System.monotonic_time(:millisecond) - start_time

    Logger.info(
      "[MoviesCacheWarmer] Cache warming completed: " <>
        "#{length(warmed_keys)} queries warmed in #{elapsed}ms"
    )

    {:ok, %{warmed_count: length(warmed_keys), elapsed_ms: elapsed}}
  end

  @doc """
  Schedule a cache warming job to run immediately.
  Useful for manual cache warming after data changes.
  """
  def schedule do
    %{}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Schedule a cache warming job to run after a delay.
  """
  def schedule_in(seconds) when is_integer(seconds) do
    %{}
    |> new(schedule_in: seconds)
    |> Oban.insert()
  end
end
