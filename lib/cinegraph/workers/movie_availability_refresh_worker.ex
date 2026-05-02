defmodule Cinegraph.Workers.MovieAvailabilityRefreshWorker do
  @moduledoc """
  Refreshes normalized movie watch availability from TMDb.
  """

  use Oban.Worker,
    queue: :tmdb,
    max_attempts: 5,
    unique: [
      fields: [:args],
      keys: [:movie_id, :regions],
      period: 3600,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Cinegraph.Movies.{Availability, Movie}
  alias Cinegraph.Repo
  alias Cinegraph.Services.TMDb

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"movie_id" => movie_id} = args}) do
    regions = Map.get(args, "regions", ["US"])
    force? = Map.get(args, "force", false)

    case Repo.get(Movie, movie_id) do
      nil ->
        {:ok, %{status: "missing_movie", movie_id: movie_id}}

      %Movie{tmdb_id: nil} = movie ->
        {:ok, %{status: "missing_tmdb_id", movie_id: movie.id}}

      movie ->
        refresh_movie(movie, regions: regions, force: force?)
    end
  end

  def perform(%Oban.Job{args: args}) do
    {:discard, {:missing_movie_id, args}}
  end

  def refresh_movie(%Movie{} = movie, opts \\ []) do
    regions = Keyword.get(opts, :regions, ["US"])
    force? = Keyword.get(opts, :force, false)
    fetch_fun = Keyword.get(opts, :fetch_fun, &TMDb.get_movie_watch_providers/1)

    if !force? && Availability.fresh_for_regions?(movie.id, regions) do
      {:ok, %{status: "fresh", movie_id: movie.id, regions: regions}}
    else
      case fetch_fun.(movie.tmdb_id) do
        {:ok, payload} ->
          case Availability.store_tmdb_watch_providers(movie, payload, regions: regions) do
            {:ok, results} ->
              {:ok, %{status: "refreshed", movie_id: movie.id, results: results}}

            {:error, reason} ->
              Availability.record_availability_error(movie, regions, reason)
              {:ok, %{status: "error", movie_id: movie.id, reason: reason}}
          end

        {:error, reason} ->
          Availability.record_availability_error(movie, regions, reason)

          Logger.warning(
            "MovieAvailabilityRefreshWorker: movie_id=#{movie.id} error=#{inspect(reason)}"
          )

          {:ok, %{status: "error", movie_id: movie.id, reason: reason}}
      end
    end
  end
end
