defmodule Cinegraph.Services.TMDb.Extended do
  @moduledoc """
  Extended TMDb API integration for critical missing endpoints.
  This module adds support for watch providers, trending, reviews, and more.
  """

  alias Cinegraph.Services.TMDb.Client

  # ========================================
  # CRITICAL MISSING ENDPOINTS
  # ========================================

  @doc """
  Gets watch provider information for a movie by region.
  Critical for understanding global streaming reach.
  
  ## Examples
      
      iex> Cinegraph.Services.TMDb.Extended.get_movie_watch_providers(550)
      {:ok, %{"results" => %{"US" => %{"flatrate" => [...], "rent" => [...], ...}}}}
  """
  def get_movie_watch_providers(movie_id) when is_integer(movie_id) or is_binary(movie_id) do
    Client.get("/movie/#{movie_id}/watch/providers")
  end

  @doc """
  Gets user reviews for a movie.
  Critical for sentiment analysis and engagement metrics.
  
  ## Options
    - `:page` - Page number (default: 1)
    
  ## Examples
      
      iex> Cinegraph.Services.TMDb.Extended.get_movie_reviews(550)
      {:ok, %{"results" => [%{"author" => "user123", "content" => "...", ...}]}}
  """
  def get_movie_reviews(movie_id, opts \\ []) when is_integer(movie_id) or is_binary(movie_id) do
    params = opts |> Keyword.take([:page]) |> Enum.into(%{})
    Client.get("/movie/#{movie_id}/reviews", params)
  end

  @doc """
  Gets lists that contain a specific movie.
  Useful for understanding movie categorization and curation.
  
  ## Options
    - `:page` - Page number (default: 1)
  """
  def get_movie_lists(movie_id, opts \\ []) when is_integer(movie_id) or is_binary(movie_id) do
    params = opts |> Keyword.take([:page]) |> Enum.into(%{})
    Client.get("/movie/#{movie_id}/lists", params)
  end

  @doc """
  Gets trending movies for a specific time window.
  Critical for real-time popularity metrics.
  
  ## Parameters
    - `time_window` - "day" or "week"
    
  ## Options
    - `:page` - Page number (default: 1)
    
  ## Examples
      
      iex> Cinegraph.Services.TMDb.Extended.get_trending_movies("day")
      {:ok, %{"results" => [...], "page" => 1, ...}}
  """
  def get_trending_movies(time_window \\ "day", opts \\ []) when time_window in ["day", "week"] do
    params = opts |> Keyword.take([:page]) |> Enum.into(%{})
    Client.get("/trending/movie/#{time_window}", params)
  end

  @doc """
  Gets trending people for a specific time window.
  Important for tracking cultural influencers.
  """
  def get_trending_people(time_window \\ "day", opts \\ []) when time_window in ["day", "week"] do
    params = opts |> Keyword.take([:page]) |> Enum.into(%{})
    Client.get("/trending/person/#{time_window}", params)
  end

  @doc """
  Gets movies currently playing in theaters.
  Critical for understanding current theatrical presence.
  
  ## Options
    - `:page` - Page number (default: 1)
    - `:region` - ISO 3166-1 code (e.g., "US")
  """
  def get_now_playing_movies(opts \\ []) do
    params = opts |> Keyword.take([:page, :region]) |> Enum.into(%{})
    Client.get("/movie/now_playing", params)
  end

  @doc """
  Gets upcoming movie releases.
  Important for tracking future releases and anticipation.
  
  ## Options
    - `:page` - Page number (default: 1)
    - `:region` - ISO 3166-1 code (e.g., "US")
  """
  def get_upcoming_movies(opts \\ []) do
    params = opts |> Keyword.take([:page, :region]) |> Enum.into(%{})
    Client.get("/movie/upcoming", params)
  end

  @doc """
  Gets the list of official certifications for movies.
  Useful for understanding content ratings globally.
  """
  def get_movie_certifications do
    Client.get("/certification/movie/list")
  end

  @doc """
  Gets a list of all available watch providers.
  Useful for understanding the streaming landscape.
  
  ## Options
    - `:watch_region` - ISO 3166-1 code (required)
  """
  def get_watch_providers(opts \\ []) do
    params = opts |> Keyword.take([:watch_region]) |> Enum.into(%{})
    Client.get("/watch/providers/movie", params)
  end

  @doc """
  Gets all available regions for watch providers.
  """
  def get_watch_provider_regions do
    Client.get("/watch/providers/regions")
  end

  @doc """
  Gets the list of official genres for movies.
  Essential for categorization.
  """
  def get_movie_genres do
    Client.get("/genre/movie/list")
  end

  @doc """
  Gets system configuration from TMDb.
  Contains image base URLs and sizes.
  """
  def get_configuration do
    Client.get("/configuration")
  end

  @doc """
  Gets the list of countries used in TMDb.
  """
  def get_countries do
    Client.get("/configuration/countries")
  end

  @doc """
  Gets the list of languages used in TMDb.
  """
  def get_languages do
    Client.get("/configuration/languages")
  end

  # ========================================
  # ENHANCED SEARCH FUNCTIONS
  # ========================================

  @doc """
  Searches for people by name.
  
  ## Options
    - `:page` - Page number (default: 1)
  """
  def search_people(query, opts \\ []) do
    params = 
      opts
      |> Keyword.take([:page])
      |> Enum.into(%{query: query})
      
    Client.get("/search/person", params)
  end

  @doc """
  Searches for production companies.
  
  ## Options
    - `:page` - Page number (default: 1)
  """
  def search_companies(query, opts \\ []) do
    params = 
      opts
      |> Keyword.take([:page])
      |> Enum.into(%{query: query})
      
    Client.get("/search/company", params)
  end

  @doc """
  Searches for keywords.
  
  ## Options
    - `:page` - Page number (default: 1)
  """
  def search_keywords(query, opts \\ []) do
    params = 
      opts
      |> Keyword.take([:page])
      |> Enum.into(%{query: query})
      
    Client.get("/search/keyword", params)
  end

  @doc """
  Multi-search across movies, TV shows, and people.
  
  ## Options
    - `:page` - Page number (default: 1)
  """
  def search_multi(query, opts \\ []) do
    params = 
      opts
      |> Keyword.take([:page])
      |> Enum.into(%{query: query})
      
    Client.get("/search/multi", params)
  end

  # ========================================
  # ENHANCED DISCOVER FUNCTION
  # ========================================

  @doc """
  Enhanced movie discovery with all available filters.
  Critical for cultural relevance queries.
  
  ## Options
    - `:page` - Page number
    - `:sort_by` - Sort results by
    - `:year` - Primary release year
    - `:primary_release_date_gte` - Movies released after this date
    - `:primary_release_date_lte` - Movies released before this date
    - `:release_date_gte` - Movies with any release after this date
    - `:release_date_lte` - Movies with any release before this date
    - `:vote_count_gte` - Minimum vote count
    - `:vote_count_lte` - Maximum vote count
    - `:vote_average_gte` - Minimum vote average
    - `:vote_average_lte` - Maximum vote average
    - `:with_genres` - Genre IDs (comma-separated or array)
    - `:without_genres` - Exclude genre IDs
    - `:with_keywords` - Keyword IDs (comma-separated or array)
    - `:without_keywords` - Exclude keyword IDs
    - `:with_companies` - Company IDs
    - `:with_people` - Person IDs (comma-separated)
    - `:with_cast` - Cast member IDs
    - `:with_crew` - Crew member IDs
    - `:with_original_language` - Original language ISO 639-1
    - `:with_runtime_gte` - Minimum runtime in minutes
    - `:with_runtime_lte` - Maximum runtime in minutes
    - `:region` - Release region
    - `:certification` - Certification rating
    - `:certification_country` - Country for certification
    - `:certification_gte` - Minimum certification
    - `:certification_lte` - Maximum certification
    - `:with_watch_providers` - Watch provider IDs
    - `:watch_region` - Watch provider region
    - `:with_watch_monetization_types` - Monetization types (flatrate|free|ads|rent|buy)
    
  ## Examples
      
      # Find highly-rated movies in Spanish
      discover_movies_enhanced(
        with_original_language: "es",
        vote_average_gte: 7.0,
        sort_by: "popularity.desc"
      )
      
      # Find movies with specific people
      discover_movies_enhanced(
        with_people: "1245,5678",
        primary_release_date_gte: "2023-01-01"
      )
      
      # Find movies available on Netflix in the US
      discover_movies_enhanced(
        with_watch_providers: "8",  # Netflix ID
        watch_region: "US",
        with_watch_monetization_types: "flatrate"
      )
  """
  def discover_movies_enhanced(opts \\ []) do
    params = 
      opts
      |> Enum.map(&transform_discover_param/1)
      |> Enum.into(%{})
      
    Client.get("/discover/movie", params)
  end

  # ========================================
  # PERSON ENDPOINTS
  # ========================================

  @doc """
  Gets popular people.
  Important for tracking influential figures.
  
  ## Options
    - `:page` - Page number (default: 1)
  """
  def get_popular_people(opts \\ []) do
    params = opts |> Keyword.take([:page]) |> Enum.into(%{})
    Client.get("/person/popular", params)
  end

  @doc """
  Gets the latest person added to TMDb.
  """
  def get_latest_person do
    Client.get("/person/latest")
  end

  @doc """
  Gets tagged images for a person.
  
  ## Options
    - `:page` - Page number (default: 1)
  """
  def get_person_tagged_images(person_id, opts \\ []) do
    params = opts |> Keyword.take([:page]) |> Enum.into(%{})
    Client.get("/person/#{person_id}/tagged_images", params)
  end

  # ========================================
  # COMPREHENSIVE FETCH FUNCTIONS
  # ========================================

  @doc """
  Fetches comprehensive movie data including all critical missing data.
  Extends the basic comprehensive fetch with watch providers and reviews.
  """
  def get_movie_ultra_comprehensive(movie_id) do
    # First get the standard comprehensive data
    append = "credits,images,keywords,external_ids,release_dates,videos,recommendations,similar,alternative_titles,translations,watch/providers,reviews,lists"
    
    case Client.get("/movie/#{movie_id}", %{append_to_response: append}) do
      {:ok, movie} ->
        # Watch providers might need separate call if not in append_to_response
        movie_with_providers = 
          case movie["watch/providers"] do
            nil ->
              case get_movie_watch_providers(movie_id) do
                {:ok, providers} -> Map.put(movie, "watch_providers", providers)
                _ -> movie
              end
            providers ->
              Map.put(movie, "watch_providers", providers)
          end
          
        {:ok, movie_with_providers}
        
      error -> error
    end
  end

  # ========================================
  # PRIVATE FUNCTIONS
  # ========================================

  defp transform_discover_param({key, value}) do
    # Transform parameter names and handle special cases
    case {key, value} do
      # Date parameters
      {:primary_release_date_gte, v} -> {"primary_release_date.gte", to_string(v)}
      {:primary_release_date_lte, v} -> {"primary_release_date.lte", to_string(v)}
      {:release_date_gte, v} -> {"release_date.gte", to_string(v)}
      {:release_date_lte, v} -> {"release_date.lte", to_string(v)}
      
      # Vote parameters
      {:vote_count_gte, v} -> {"vote_count.gte", to_string(v)}
      {:vote_count_lte, v} -> {"vote_count.lte", to_string(v)}
      {:vote_average_gte, v} -> {"vote_average.gte", to_string(v)}
      {:vote_average_lte, v} -> {"vote_average.lte", to_string(v)}
      
      # Runtime parameters
      {:with_runtime_gte, v} -> {"with_runtime.gte", to_string(v)}
      {:with_runtime_lte, v} -> {"with_runtime.lte", to_string(v)}
      
      # Certification parameters
      {:certification_gte, v} -> {"certification.gte", to_string(v)}
      {:certification_lte, v} -> {"certification.lte", to_string(v)}
      
      # Array parameters - join if list
      {:with_genres, v} when is_list(v) -> {"with_genres", Enum.join(v, ",")}
      {:without_genres, v} when is_list(v) -> {"without_genres", Enum.join(v, ",")}
      {:with_keywords, v} when is_list(v) -> {"with_keywords", Enum.join(v, ",")}
      {:without_keywords, v} when is_list(v) -> {"without_keywords", Enum.join(v, ",")}
      {:with_companies, v} when is_list(v) -> {"with_companies", Enum.join(v, ",")}
      {:with_watch_providers, v} when is_list(v) -> {"with_watch_providers", Enum.join(v, ",")}
      
      # Default - convert atom to string
      {k, v} -> {to_string(k), to_string(v)}
    end
  end
end