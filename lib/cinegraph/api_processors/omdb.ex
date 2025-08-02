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
  alias Cinegraph.ExternalSources
  alias Cinegraph.ExternalSources.Rating
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
  def rate_limit_ms(), do: 1000  # Free tier: max 1000/day
  
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
    omdb_source = OMDb.Transformer.get_or_create_source!()
    
    if should_skip_processing?(movie, omdb_source, force_refresh) do
      Logger.info("OMDb data already exists for #{movie.title} (ID: #{movie.id})")
      {:ok, movie}
    else
      Logger.info("Fetching OMDb data for #{movie.title} (IMDb ID: #{movie.imdb_id})")
      
      case fetch_and_store_omdb_data(movie, omdb_source) do
        {:ok, updated_movie} ->
          Logger.info("Successfully processed OMDb data for #{movie.title}")
          {:ok, updated_movie}
          
        {:error, reason} = error ->
          Logger.error("Failed to fetch OMDb data for #{movie.title}: #{inspect(reason)}")
          error
      end
    end
  end
  
  defp should_skip_processing?(movie, omdb_source, force_refresh) do
    if force_refresh do
      false
    else
      # Check if we have the JSON data
      has_json = has_data?(movie)
      
      # Check if we have ratings (for backward compatibility)
      has_ratings = Repo.exists?(
        from r in Rating,
        where: r.movie_id == ^movie.id and r.source_id == ^omdb_source.id
      )
      
      has_json and has_ratings
    end
  end
  
  defp fetch_and_store_omdb_data(movie, omdb_source) do
    case OMDb.Client.get_movie_by_imdb_id(movie.imdb_id, tomatoes: true) do
      {:ok, omdb_data} ->
        store_omdb_data(omdb_data, movie, omdb_source)
        
      {:error, "Movie not found!"} ->
        Logger.warning("Movie not found in OMDb: #{movie.title} (#{movie.imdb_id})")
        {:ok, movie}  # Not really an error, just no data available
        
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  defp store_omdb_data(omdb_data, movie, omdb_source) do
    # Extract additional fields from OMDb
    movie_updates = %{
      omdb_data: omdb_data,
      awards_text: omdb_data["Awards"],
      box_office_domestic: parse_box_office(omdb_data["BoxOffice"])
    }
    
    # First, store the complete OMDb response and extracted fields in the movie record
    with {:ok, updated_movie} <- update_movie(movie, movie_updates),
         :ok <- store_ratings(omdb_data, updated_movie, omdb_source) do
      {:ok, updated_movie}
    end
  end
  
  defp update_movie(movie, updates) do
    movie
    |> Movie.changeset(updates)
    |> Repo.update()
  end
  
  defp store_ratings(omdb_data, movie, omdb_source) do
    # Transform and store ratings
    ratings = OMDb.Transformer.transform_to_ratings(omdb_data, movie.id, omdb_source.id)
    
    Enum.each(ratings, fn rating_attrs ->
      case ExternalSources.upsert_rating(rating_attrs) do
        {:ok, rating} ->
          Logger.debug("Stored #{rating.rating_type} rating for #{movie.title}: #{rating.value}")
        {:error, changeset} ->
          Logger.error("Failed to store rating: #{inspect(changeset.errors)}")
      end
    end)
    
    :ok
  end
  
  defp parse_box_office(nil), do: nil
  defp parse_box_office("N/A"), do: nil
  defp parse_box_office(box_office) when is_binary(box_office) do
    box_office
    |> String.replace("$", "")
    |> String.replace(",", "")
    |> String.trim()
    |> String.to_integer()
  rescue
    _ -> nil
  end
end