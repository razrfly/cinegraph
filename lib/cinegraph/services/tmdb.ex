defmodule Cinegraph.Services.TMDb do
  @moduledoc """
  Main interface for TMDb API integration.
  Provides functions to fetch movie data, search, and explore TMDb's data structure.
  """

  alias Cinegraph.Services.TMDb.Client

  @doc """
  Fetches detailed information about a specific movie by ID.
  
  ## Options
    - `:append_to_response` - Additional data to fetch (credits, images, keywords, etc.)
  
  ## Examples
  
      iex> Cinegraph.Services.TMDb.get_movie(550)
      {:ok, %{"id" => 550, "title" => "Fight Club", ...}}
      
      iex> Cinegraph.Services.TMDb.get_movie(550, append_to_response: "credits,images")
      {:ok, %{"id" => 550, "title" => "Fight Club", "credits" => %{...}, ...}}
  """
  def get_movie(movie_id, opts \\ []) when is_integer(movie_id) or is_binary(movie_id) do
    params = 
      case Keyword.get(opts, :append_to_response) do
        nil -> %{}
        append -> %{append_to_response: append}
      end
      
    Client.get("/movie/#{movie_id}", params)
  end

  @doc """
  Fetches comprehensive movie data with all related information.
  Uses append_to_response to minimize API calls.
  """
  def get_movie_comprehensive(movie_id) do
    append = "credits,images,keywords,external_ids,release_dates,videos,recommendations,similar,alternative_titles,translations"
    get_movie(movie_id, append_to_response: append)
  end

  @doc """
  Searches for movies by title.
  
  ## Options
    - `:page` - Page number (default: 1)
    - `:year` - Release year
    - `:region` - ISO 3166-1 code to filter release dates
    
  ## Examples
  
      iex> Cinegraph.Services.TMDb.search_movies("Inception")
      {:ok, %{"results" => [%{"title" => "Inception", ...}], ...}}
  """
  def search_movies(query, opts \\ []) do
    params = 
      opts
      |> Keyword.take([:page, :year, :region])
      |> Enum.into(%{query: query})
      
    Client.get("/search/movie", params)
  end

  @doc """
  Discovers movies based on various criteria.
  
  ## Options
    - `:page` - Page number (default: 1)
    - `:sort_by` - Sort results by (popularity.desc, vote_average.desc, etc.)
    - `:year` - Primary release year
    - `:vote_count_gte` - Minimum vote count
    - `:vote_average_gte` - Minimum vote average
    
  ## Examples
  
      iex> Cinegraph.Services.TMDb.discover_movies(year: 2023, sort_by: "popularity.desc")
      {:ok, %{"results" => [...], ...}}
  """
  def discover_movies(opts \\ []) do
    params = 
      opts
      |> Keyword.take([:page, :sort_by, :year, :vote_count_gte, :vote_average_gte])
      |> Enum.into(%{})
      |> rename_keys()
      
    Client.get("/discover/movie", params)
  end

  @doc """
  Gets popular movies.
  """
  def get_popular_movies(opts \\ []) do
    params = opts |> Keyword.take([:page]) |> Enum.into(%{})
    Client.get("/movie/popular", params)
  end

  @doc """
  Gets top rated movies.
  """
  def get_top_rated_movies(opts \\ []) do
    params = opts |> Keyword.take([:page]) |> Enum.into(%{})
    Client.get("/movie/top_rated", params)
  end

  @doc """
  Explores the data structure of a movie by fetching and pretty-printing all available fields.
  Useful for understanding TMDb's data schema.
  """
  def explore_movie(movie_id) do
    with {:ok, movie} <- get_movie(movie_id) do
      IO.puts("\n🎬 Movie Data Structure for ID: #{movie_id}")
      IO.puts("=" <> String.duplicate("=", 60))
      
      pretty_print_data(movie)
      
      {:ok, movie}
    end
  end

  @doc """
  Fetches detailed information about a person by ID.
  """
  def get_person(person_id, opts \\ []) when is_integer(person_id) or is_binary(person_id) do
    params = 
      case Keyword.get(opts, :append_to_response) do
        nil -> %{}
        append -> %{append_to_response: append}
      end
      
    Client.get("/person/#{person_id}", params)
  end

  @doc """
  Fetches comprehensive person data with all related information.
  """
  def get_person_comprehensive(person_id) do
    append = "images,external_ids,combined_credits"
    get_person(person_id, append_to_response: append)
  end

  @doc """
  Fetches collection details by ID.
  """
  def get_collection(collection_id) when is_integer(collection_id) or is_binary(collection_id) do
    Client.get("/collection/#{collection_id}")
  end

  @doc """
  Fetches production company details by ID.
  """
  def get_company(company_id) when is_integer(company_id) or is_binary(company_id) do
    Client.get("/company/#{company_id}")
  end

  @doc """
  Tests the TMDb connection and displays configuration status.
  """
  def test_connection do
    IO.puts("\n🔍 Testing TMDb API Connection...")
    
    case get_movie(550) do  # Fight Club as test movie
      {:ok, movie} ->
        IO.puts("✅ Connection successful!")
        IO.puts("   Test movie: #{movie["title"]} (#{movie["release_date"]})")
        {:ok, :connected}
        
      {:error, :unauthorized} ->
        IO.puts("❌ Authentication failed. Check your API key.")
        {:error, :unauthorized}
        
      {:error, reason} ->
        IO.puts("❌ Connection failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private functions
  
  defp rename_keys(params) do
    params
    |> Enum.map(fn
      {:vote_count_gte, v} -> {"vote_count.gte", v}
      {:vote_average_gte, v} -> {"vote_average.gte", v}
      {k, v} -> {to_string(k), v}
    end)
    |> Enum.into(%{})
  end

  defp pretty_print_data(data, indent \\ 0) do
    padding = String.duplicate("  ", indent)
    
    case data do
      map when is_map(map) ->
        Enum.each(map, fn {key, value} ->
          IO.write("#{padding}#{key}: ")
          
          case value do
            v when is_map(v) or is_list(v) ->
              IO.puts("")
              pretty_print_data(v, indent + 1)
              
            nil ->
              IO.puts("null")
              
            v ->
              IO.puts(inspect(v))
          end
        end)
        
      list when is_list(list) ->
        Enum.with_index(list, fn item, index ->
          IO.puts("#{padding}[#{index}]:")
          pretty_print_data(item, indent + 1)
        end)
        
      value ->
        IO.puts("#{padding}#{inspect(value)}")
    end
  end
end