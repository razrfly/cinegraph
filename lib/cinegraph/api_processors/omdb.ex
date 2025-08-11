defmodule Cinegraph.ApiProcessors.OMDb do
  @moduledoc """
  API processor for Open Movie Database (OMDb).

  Fetches movie data including ratings, awards, box office information,
  and additional metadata not available in TMDb.
  """

  @behaviour Cinegraph.ApiProcessors.Behaviour

  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Services.OMDb
  alias Cinegraph.Metrics
  import Ecto.Query
  require Logger

  @impl true
  def process_movie(movie_id, opts \\ []) do
    with {:ok, movie} <- get_movie(movie_id),
         {:ok, movie} <- fetch_and_update_movie(movie, opts) do
      {:ok, movie}
    end
  end

  @impl true
  def can_process?(%Movie{imdb_id: imdb_id}) when not is_nil(imdb_id), do: true
  def can_process?(_), do: false

  @impl true
  def required_identifier(), do: :imdb_id

  @impl true
  def name(), do: "OMDb"

  @impl true
  def data_field(), do: :omdb_data

  @impl true
  def has_data?(%Movie{omdb_data: data}) when not is_nil(data) and map_size(data) > 0, do: true
  def has_data?(_), do: false

  @impl true
  # Free tier: max 1000/day
  def rate_limit_ms(), do: 1000

  @impl true
  def validate_config() do
    case Application.get_env(:cinegraph, Cinegraph.Services.OMDb.Client)[:api_key] do
      nil -> {:error, "OMDB_API_KEY not configured"}
      "" -> {:error, "OMDB_API_KEY is empty"}
      _ -> :ok
    end
  end

  # Private functions

  defp get_movie(movie_id) do
    case Repo.get(Movie, movie_id) do
      nil -> {:error, :movie_not_found}
      movie -> {:ok, movie}
    end
  end

  defp fetch_and_update_movie(movie, opts) do
    force_refresh = Keyword.get(opts, :force_refresh, false)

    # Validate IMDb ID format
    if not valid_imdb_id?(movie.imdb_id) do
      Logger.warning("Invalid IMDb ID format for #{movie.title}: #{movie.imdb_id}")
      {:error, :invalid_imdb_id}
    else
      if should_skip_processing?(movie, force_refresh) do
        Logger.info("OMDb data already exists for #{movie.title} (ID: #{movie.id})")
        {:ok, movie}
      else
        Logger.info("Fetching OMDb data for #{movie.title} (IMDb ID: #{movie.imdb_id})")

        case fetch_and_store_omdb_data(movie) do
          {:ok, updated_movie} ->
            Logger.info("Successfully processed OMDb data for #{movie.title}")
            {:ok, updated_movie}

          {:error, reason} = error ->
            Logger.error("Failed to fetch OMDb data for #{movie.title}: #{inspect(reason)}")
            error
        end
      end
    end
  end

  defp should_skip_processing?(movie, force_refresh) do
    if force_refresh do
      false
    else
      # Check if we have the JSON data and metrics
      has_json = has_data?(movie)

      # Check if we have metrics in the new external_metrics table
      has_metrics =
        Repo.exists?(
          from m in Cinegraph.Movies.ExternalMetric,
            where: m.movie_id == ^movie.id and m.source == "omdb"
        )

      has_json and has_metrics
    end
  end

  defp fetch_and_store_omdb_data(movie) do
    case OMDb.Client.get_movie_by_imdb_id(movie.imdb_id, tomatoes: true) do
      {:ok, omdb_data} ->
        store_omdb_data(omdb_data, movie)

      {:error, "Movie not found!"} ->
        Logger.warning("Movie not found in OMDb: #{movie.title} (#{movie.imdb_id})")
        # Not really an error, just no data available
        {:ok, movie}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_omdb_data(omdb_data, movie) do
    # Store the complete OMDb response in the movie record
    movie_updates = %{
      omdb_data: omdb_data
    }

    # First, update the movie with the raw OMDb data
    with {:ok, updated_movie} <- update_movie(movie, movie_updates),
         # Then store all metrics using the new Metrics module
         :ok <- Metrics.store_omdb_metrics(updated_movie, omdb_data) do
      {:ok, updated_movie}
    end
  end

  defp update_movie(movie, updates) do
    movie
    |> Movie.changeset(updates)
    |> Repo.update()
  end

  # Box office parsing is now handled by Metrics.store_omdb_metrics

  # Validate IMDb ID format (tt followed by 7+ digits)
  defp valid_imdb_id?(nil), do: false

  defp valid_imdb_id?(imdb_id) do
    Regex.match?(~r/^tt\d{7,}$/, imdb_id)
  end
end
