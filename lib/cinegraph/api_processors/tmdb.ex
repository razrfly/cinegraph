defmodule Cinegraph.ApiProcessors.TMDb do
  @moduledoc """
  API processor for The Movie Database (TMDb).
  
  Fetches comprehensive movie data including cast, crew, keywords,
  videos, release dates, and more.
  """
  
  @behaviour Cinegraph.ApiProcessors.Behaviour
  
  alias Cinegraph.Repo
  alias Cinegraph.Movies
  alias Cinegraph.Movies.Movie
  require Logger
  
  @impl true
  def process_movie(movie_id, opts \\ []) do
    with {:ok, movie} <- get_movie(movie_id),
         {:ok, movie} <- fetch_and_update_movie(movie, opts) do
      {:ok, movie}
    end
  end
  
  @impl true
  def can_process?(%Movie{tmdb_id: tmdb_id}) when not is_nil(tmdb_id), do: true
  def can_process?(_), do: false
  
  @impl true
  def required_identifier(), do: :tmdb_id
  
  @impl true
  def name(), do: "TMDb"
  
  @impl true
  def data_field(), do: :tmdb_data
  
  @impl true
  def has_data?(%Movie{tmdb_data: data}) when not is_nil(data) and map_size(data) > 0, do: true
  def has_data?(_), do: false
  
  @impl true
  def rate_limit_ms(), do: 100  # TMDb allows 40 requests per 10 seconds
  
  @impl true
  def validate_config() do
    case Application.get_env(:cinegraph, Cinegraph.Services.TMDb.Client)[:api_key] do
      nil -> {:error, "TMDB_API_KEY not configured"}
      "" -> {:error, "TMDB_API_KEY is empty"}
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
    
    if has_data?(movie) and not force_refresh do
      Logger.info("TMDb data already exists for #{movie.title} (ID: #{movie.id})")
      {:ok, movie}
    else
      Logger.info("Fetching TMDb data for #{movie.title} (TMDb ID: #{movie.tmdb_id})")
      
      case Movies.fetch_and_store_movie_comprehensive(movie.tmdb_id) do
        {:ok, updated_movie} ->
          Logger.info("Successfully processed TMDb data for #{movie.title}")
          {:ok, updated_movie}
          
        {:error, reason} = error ->
          Logger.error("Failed to fetch TMDb data for #{movie.title}: #{inspect(reason)}")
          error
      end
    end
  end
end