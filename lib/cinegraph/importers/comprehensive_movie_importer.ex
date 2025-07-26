defmodule Cinegraph.Importers.ComprehensiveMovieImporter do
  @moduledoc """
  Comprehensive movie importer that fetches data from both TMDb and OMDb.
  Designed to be run repeatedly without duplicating data.
  """
  
  alias Cinegraph.Repo
  alias Cinegraph.Movies
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Services.{TMDb, OMDb}
  alias Cinegraph.ExternalSources.Rating
  
  import Ecto.Query
  require Logger
  
  @omdb_delay_ms 1000  # Free tier: max 1000/day, so we pace ourselves
  
  def import_popular_movies(pages \\ 5) do
    Logger.info("Starting comprehensive movie import...")
    
    # Ensure OMDb source exists
    omdb_source = OMDb.Transformer.get_or_create_source!()
    
    # Import from TMDb
    Logger.info("Fetching movies from TMDb...")
    movies = fetch_tmdb_movies(pages)
    
    Logger.info("Found #{length(movies)} movies from TMDb")
    
    # Process each movie
    Enum.each(movies, fn movie ->
      # Add OMDb data if we have IMDb ID
      if movie.imdb_id do
        Logger.info("Fetching OMDb data for #{movie.title} (#{movie.imdb_id})...")
        fetch_and_store_omdb_data(movie, omdb_source)
        
        # Rate limit for free tier
        Process.sleep(@omdb_delay_ms)
      else
        Logger.warning("No IMDb ID for #{movie.title} - skipping OMDb")
      end
    end)
    
    Logger.info("Import complete!")
  end
  
  def import_specific_movies(tmdb_ids) when is_list(tmdb_ids) do
    omdb_source = OMDb.Transformer.get_or_create_source!()
    
    Enum.each(tmdb_ids, fn tmdb_id ->
      case import_single_movie(tmdb_id, omdb_source) do
        {:ok, movie} ->
          Logger.info("Successfully imported #{movie.title}")
        {:error, reason} ->
          Logger.error("Failed to import TMDb ID #{tmdb_id}: #{inspect(reason)}")
      end
      
      Process.sleep(@omdb_delay_ms)
    end)
  end
  
  def import_single_movie(tmdb_id, omdb_source \\ nil) do
    omdb_source = omdb_source || OMDb.Transformer.get_or_create_source!()
    
    with {:ok, movie} <- Movies.fetch_and_store_movie_comprehensive(tmdb_id),
         :ok <- fetch_and_store_omdb_data(movie, omdb_source) do
      {:ok, movie}
    end
  end
  
  @doc """
  Enriches all existing movies in the database with OMDb data.
  Only processes movies with IMDb IDs that don't already have OMDb ratings.
  """
  def enrich_existing_movies_with_omdb do
    omdb_source = OMDb.Transformer.get_or_create_source!()
    
    # Find movies with IMDb IDs but no OMDb ratings
    movies_to_enrich = 
      from(m in Movie,
        where: not is_nil(m.imdb_id),
        left_join: r in Rating,
          on: r.movie_id == m.id and r.source_id == ^omdb_source.id,
        where: is_nil(r.id),
        select: m
      )
      |> Repo.all()
    
    Logger.info("Found #{length(movies_to_enrich)} movies to enrich with OMDb data")
    
    Enum.each(movies_to_enrich, fn movie ->
      Logger.info("Enriching #{movie.title} (#{movie.imdb_id})...")
      fetch_and_store_omdb_data(movie, omdb_source)
      Process.sleep(@omdb_delay_ms)
    end)
    
    Logger.info("Enrichment complete!")
  end
  
  # Private functions
  
  defp fetch_tmdb_movies(pages) do
    1..pages
    |> Enum.flat_map(fn page ->
      Logger.info("Fetching TMDb page #{page}...")
      
      case TMDb.get_popular_movies(page: page) do
        {:ok, %{"results" => movies}} ->
          movies
          |> Enum.map(fn basic_movie ->
            # Use the Movies context to fetch and store comprehensive data
            movie_id = basic_movie["id"]
            Logger.debug("Fetching comprehensive data for movie ID #{movie_id}...")
            
            case Movies.fetch_and_store_movie_comprehensive(movie_id) do
              {:ok, movie} -> 
                movie
              {:error, reason} ->
                Logger.warning("Failed to fetch comprehensive data for movie #{movie_id}: #{inspect(reason)}")
                nil
            end
          end)
          |> Enum.filter(& &1)
          
        {:error, reason} ->
          Logger.error("Failed to fetch TMDb page #{page}: #{inspect(reason)}")
          []
      end
    end)
  end
  
  # OMDb functions
  
  defp fetch_and_store_omdb_data(movie, omdb_source) do
    # Check if we already have OMDb data
    existing_ratings_count = 
      from(r in Rating,
        where: r.movie_id == ^movie.id and r.source_id == ^omdb_source.id,
        select: count(r.id)
      )
      |> Repo.one()
    
    if existing_ratings_count > 0 do
      Logger.debug("OMDb data already exists for #{movie.title} - skipping")
      :ok
    else
      # Fetch with extended Rotten Tomatoes data
      case OMDb.Client.get_movie_by_imdb_id(movie.imdb_id, tomatoes: true) do
        {:ok, omdb_data} ->
          store_omdb_data(omdb_data, movie, omdb_source)
          
        {:error, "Movie not found!"} ->
          Logger.warning("Movie not found in OMDb: #{movie.title} (#{movie.imdb_id})")
          :ok
          
        {:error, reason} ->
          Logger.error("Failed to fetch OMDb data for #{movie.title}: #{reason}")
          :error
      end
    end
  end
  
  defp store_omdb_data(omdb_data, movie, omdb_source) do
    # First, store the complete OMDb response in the movie record
    case movie
         |> Movie.changeset(%{omdb_data: omdb_data})
         |> Repo.update() do
      {:ok, updated_movie} ->
        Logger.debug("Stored complete OMDb response for #{updated_movie.title}")
        
        # Transform and store ratings
        ratings = OMDb.Transformer.transform_to_ratings(omdb_data, movie.id, omdb_source.id)
        
        Enum.each(ratings, fn rating_attrs ->
          case insert_or_update_rating(rating_attrs) do
            {:ok, rating} ->
              Logger.debug("Stored #{rating.rating_type} rating for #{movie.title}: #{rating.value}")
            {:error, changeset} ->
              Logger.error("Failed to store rating: #{inspect(changeset.errors)}")
          end
        end)
        
        # Now we have the complete OMDb data stored, we can parse additional fields later
        # For example: omdb_data["Plot"], omdb_data["Director"], omdb_data["Actors"], etc.
        
        Logger.info("Successfully stored OMDb data and ratings for #{movie.title}")
        :ok
        
      {:error, changeset} ->
        Logger.error("Failed to store OMDb data for #{movie.title}: #{inspect(changeset.errors)}")
        :error
    end
  end
  
  defp insert_or_update_rating(attrs) do
    # Try to find existing rating
    case Repo.get_by(Rating, 
      movie_id: attrs.movie_id,
      source_id: attrs.source_id,
      rating_type: attrs.rating_type
    ) do
      nil ->
        %Rating{}
        |> Rating.changeset(attrs)
        |> Repo.insert()
        
      existing ->
        existing
        |> Rating.changeset(attrs)
        |> Repo.update()
    end
  end
  
end