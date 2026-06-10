defmodule Cinegraph.Workers.TMDbMovieRefreshWorker do
  @moduledoc """
  Unified per-movie TMDb refresh (#1106): ONE `append_to_response` call
  re-hydrates an existing movie's details + ratings/metrics + credits + watch
  providers, and touches the freshness ledger for `tmdb_details` and
  `watch_providers` in the same pass. Replaces the siloed per-source TMDb fetches
  and closes the one-shot-details gap (#1010 grade-D).

  Enqueued by `TmdbMovieRefreshSweeper` (the floor) selecting via `Freshness.due/2`.
  Read-through and uncapping are gated on the Phase 4 budget governor (#1090 Phase 4).
  """
  use Oban.Worker,
    queue: :tmdb,
    max_attempts: 3,
    unique: [fields: [:args], keys: [:movie_id], period: 3600]

  alias Cinegraph.{Freshness, Movies, Repo}
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Services.TMDb

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"movie_id" => movie_id}}) do
    # Route replica reads through the worker pool so this doesn't compete with web. (#1007)
    Repo.route_to_worker()
    refresh(movie_id)
  end

  @doc """
  Refresh one existing movie. `opts[:fetch_fun]` is injectable for tests
  (default `&TMDb.get_movie_for_refresh/1`), mirroring `MovieAvailabilityRefreshWorker`.
  """
  def refresh(movie_id, opts \\ []) do
    fetch_fun = Keyword.get(opts, :fetch_fun, &TMDb.get_movie_for_refresh/1)

    case Repo.get(Movie, movie_id) do
      nil ->
        {:cancel, :movie_not_found}

      %Movie{tmdb_id: nil} = movie ->
        # No TMDb id → can never refresh from TMDb (precondition-ineligible, #1010 §6).
        Freshness.touch("movie", movie.id, "tmdb_details", :ineligible)
        {:cancel, :missing_tmdb_id}

      movie ->
        do_refresh(movie, fetch_fun)
    end
  end

  defp do_refresh(%Movie{} = movie, fetch_fun) do
    base = movie.release_date

    case fetch_fun.(movie.tmdb_id) do
      {:ok, data} ->
        case Movies.refresh_movie_from_tmdb(movie, data) do
          {:ok, %{watch_present?: present?}} ->
            Freshness.touch("movie", movie.id, "tmdb_details", :ok, base_date: base)

            watch_status = if present?, do: :ok, else: :empty
            Freshness.touch("movie", movie.id, "watch_providers", watch_status, base_date: base)

            {:ok, %{movie_id: movie.id, watch_present?: present?}}

          {:error, reason} ->
            Logger.error(
              "TMDbMovieRefreshWorker store failed for #{movie.id}: #{inspect(reason)}"
            )

            touch_error(movie, base, reason)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("TMDbMovieRefreshWorker fetch failed for #{movie.id}: #{inspect(reason)}")
        touch_error(movie, base, reason)
        {:error, reason}
    end
  end

  defp touch_error(movie, base, reason) do
    err = inspect(reason)
    Freshness.touch("movie", movie.id, "tmdb_details", :error, base_date: base, error_reason: err)

    Freshness.touch("movie", movie.id, "watch_providers", :error,
      base_date: base,
      error_reason: err
    )
  end
end
