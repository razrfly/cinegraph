defmodule Cinegraph.Maintenance.RefreshTmdbMovies do
  @moduledoc """
  Floor selection for the unified per-movie TMDb refresh (#1106). Selects movies
  due on `tmdb_details` OR `watch_providers` via the freshness ledger and enqueues
  one `TMDbMovieRefreshWorker` per movie (a movie due on *either* source gets the
  whole record refreshed in a single TMDb call).

  Reachable from `Cinegraph.Workers.TmdbMovieRefreshSweeper` (Oban cron) and
  `bin/cinegraph eval`. Options: `:limit` (cap), `:dry_run` (count only).
  """
  alias Cinegraph.Freshness
  alias Cinegraph.Workers.TMDbMovieRefreshWorker

  require Logger

  @insert_chunk_size 500
  @default_limit 5_000

  @doc """
  Select movies due on `tmdb_details`/`watch_providers` and enqueue one
  `TMDbMovieRefreshWorker` each. Options: `:limit` (cap, default #{@default_limit}),
  `:dry_run` (count only, enqueues nothing). Returns
  `{:ok, %{found:, enqueued:, failed:, dry_run:}}`.
  """
  def run(opts \\ []) when is_list(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    dry_run? = Keyword.get(opts, :dry_run, false)

    # Union of the two TMDb sources, deduped — one refresh covers both.
    ids =
      (Freshness.due("tmdb_details", limit) ++ Freshness.due("watch_providers", limit))
      |> Enum.uniq()
      |> Enum.take(limit)

    found = length(ids)

    if dry_run? do
      Logger.info("RefreshTmdbMovies: dry-run found #{found} movies due")
      {:ok, %{found: found, enqueued: 0, failed: 0, dry_run: true}}
    else
      {enqueued, failed} = enqueue_in_chunks(ids)
      Logger.info("RefreshTmdbMovies: enqueued #{enqueued} on :tmdb (#{failed} failed)")
      {:ok, %{found: found, enqueued: enqueued, failed: failed, dry_run: false}}
    end
  end

  defp enqueue_in_chunks(ids) do
    ids
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce({0, 0}, fn chunk, {ok, err} ->
      jobs = Enum.map(chunk, &TMDbMovieRefreshWorker.new(%{movie_id: &1}))

      try do
        case Oban.insert_all(jobs) do
          results when is_list(results) ->
            {ok + length(results), err}

          other ->
            Logger.error("RefreshTmdbMovies: Oban.insert_all returned #{inspect(other)}")
            {ok, err + length(chunk)}
        end
      rescue
        e ->
          Logger.error(
            "RefreshTmdbMovies: insert_all failed (#{length(chunk)}): #{Exception.message(e)}"
          )

          {ok, err + length(chunk)}
      end
    end)
  end
end
