defmodule Cinegraph.Services.TMDb.FallbackSearch do
  @moduledoc """
  Progressive fallback search strategies for TMDb movie lookups.
  Implements multiple search strategies with confidence scoring to improve lookup success rates.
  """

  alias Cinegraph.Services.TMDb
  alias Cinegraph.Metrics.ApiTracker
  require Logger

  @max_fallback_level Application.compile_env(:cinegraph, [:tmdb_search, :max_fallback_level], 3)
  @min_confidence Application.compile_env(:cinegraph, [:tmdb_search, :min_confidence], 0.7)

  @doc """
  Attempts to find a movie using progressive fallback strategies.
  
  ## Parameters
    - `imdb_id` - The IMDb ID to search for (optional)
    - `title` - The movie title
    - `year` - The release year (optional)
    - `opts` - Additional options
    
  ## Returns
    - `{:ok, movie, confidence}` - Movie found with confidence score
    - `{:error, :not_found}` - No movie found above minimum confidence
  """
  def find_movie(imdb_id, title, year \\ nil, opts \\ []) do
    strategies = build_strategies(imdb_id, title, year, opts)
    
    strategies
    |> Enum.take(@max_fallback_level)
    |> Enum.reduce_while({:error, :not_found}, fn strategy, _acc ->
      case execute_strategy(strategy) do
        {:ok, result} when result.confidence >= @min_confidence ->
          {:halt, {:ok, result}}
        {:ok, _low_confidence} ->
          {:cont, {:error, :not_found}}
        {:error, _} ->
          {:cont, {:error, :not_found}}
      end
    end)
  end

  defp build_strategies(imdb_id, title, year, _opts) do
    strategies = []
    
    # Strategy 1: Direct IMDb lookup (confidence: 1.0)
    strategies = 
      if imdb_id && imdb_id != "" do
        [%{
          level: 1,
          name: "direct_imdb",
          confidence: 1.0,
          fn: fn -> find_by_imdb(imdb_id) end
        } | strategies]
      else
        strategies
      end
    
    # Strategy 2: Exact title + year match (confidence: 0.9)
    strategies = 
      if title && year do
        strategies ++ [%{
          level: 2,
          name: "exact_title_year",
          confidence: 0.9,
          fn: fn -> search_exact_title_year(title, year) end
        }]
      else
        strategies
      end
    
    # Strategy 3: Normalized title match (confidence: 0.8)
    strategies = 
      if title do
        strategies ++ [%{
          level: 3,
          name: "normalized_title",
          confidence: 0.8,
          fn: fn -> search_normalized_title(title, year) end
        }]
      else
        strategies
      end
    
    # Strategy 4: Year-tolerant match (confidence: 0.7)
    strategies = 
      if title && year do
        strategies ++ [%{
          level: 4,
          name: "year_tolerant",
          confidence: 0.7,
          fn: fn -> search_year_tolerant(title, year) end
        }]
      else
        strategies
      end
    
    # Strategy 5: Fuzzy title match (confidence: 0.6)
    strategies = 
      if title do
        strategies ++ [%{
          level: 5,
          name: "fuzzy_title",
          confidence: 0.6,
          fn: fn -> search_fuzzy_title(title) end
        }]
      else
        strategies
      end
    
    # Strategy 6: Broad search (confidence: 0.5)
    strategies = 
      if title do
        strategies ++ [%{
          level: 6,
          name: "broad_search",
          confidence: 0.5,
          fn: fn -> search_broad(title) end
        }]
      else
        strategies
      end
    
    strategies
  end

  defp execute_strategy(strategy) do
    Logger.debug("Executing TMDb search strategy: #{strategy.name} (level: #{strategy.level})")
    
    ApiTracker.track_lookup("tmdb", "fallback_#{strategy.name}", "", fn ->
      case strategy.fn.() do
        {:ok, movie} ->
          {:ok, %{
            movie: movie,
            confidence: strategy.confidence,
            fallback_level: strategy.level,
            strategy: strategy.name
          }}
        error ->
          error
      end
    end, [
      fallback_level: strategy.level,
      confidence: strategy.confidence,
      metadata: %{strategy: strategy.name}
    ])
  end

  # Strategy implementations
  
  defp find_by_imdb(imdb_id) do
    case TMDb.find_by_imdb_id(imdb_id) do
      {:ok, %{"movie_results" => [movie | _]}} ->
        {:ok, movie}
      {:ok, %{"movie_results" => []}} ->
        {:error, :not_found}
      error ->
        error
    end
  end

  defp search_exact_title_year(title, year) do
    case TMDb.search_movies(title, year: year) do
      {:ok, %{"results" => results}} ->
        find_exact_match(results, title, year)
      error ->
        error
    end
  end

  defp search_normalized_title(title, year) do
    normalized = normalize_title(title)
    
    opts = if year, do: [year: year], else: []
    
    case TMDb.search_movies(normalized, opts) do
      {:ok, %{"results" => results}} ->
        find_normalized_match(results, normalized, year)
      error ->
        error
    end
  end

  defp search_year_tolerant(title, year) do
    years = [(year - 1), year, (year + 1)]
    
    results = 
      Enum.flat_map(years, fn y ->
        case TMDb.search_movies(title, year: y) do
          {:ok, %{"results" => res}} -> res
          _ -> []
        end
      end)
    
    find_year_tolerant_match(results, title, year)
  end

  defp search_fuzzy_title(title) do
    case TMDb.search_movies(title) do
      {:ok, %{"results" => results}} ->
        find_fuzzy_match(results, title)
      error ->
        error
    end
  end

  defp search_broad(title) do
    # Extract main keywords from title
    keywords = extract_keywords(title)
    
    case TMDb.search_movies(keywords) do
      {:ok, %{"results" => results}} ->
        find_broad_match(results, title)
      error ->
        error
    end
  end

  # Matching helpers

  defp find_exact_match([], _title, _year), do: {:error, :not_found}
  defp find_exact_match([movie | rest], title, year) do
    movie_year = extract_year(movie)
    
    if String.downcase(movie["title"] || "") == String.downcase(title) &&
       movie_year == year do
      {:ok, movie}
    else
      find_exact_match(rest, title, year)
    end
  end

  defp find_normalized_match([], _title, _year), do: {:error, :not_found}
  defp find_normalized_match([movie | _rest], _title, _year) do
    # Take the first result after normalization
    {:ok, movie}
  end

  defp find_year_tolerant_match([], _title, _year), do: {:error, :not_found}
  defp find_year_tolerant_match([movie | _rest], _title, _year) do
    # Take the first result within year tolerance
    {:ok, movie}
  end

  defp find_fuzzy_match([], _title), do: {:error, :not_found}
  defp find_fuzzy_match([movie | rest], title) do
    similarity = calculate_similarity(movie["title"] || "", title)
    
    if similarity > 0.7 do
      {:ok, movie}
    else
      find_fuzzy_match(rest, title)
    end
  end

  defp find_broad_match([], _title), do: {:error, :not_found}
  defp find_broad_match([movie | _rest], _title) do
    # Take the first result from broad search
    {:ok, movie}
  end

  # Utility functions

  defp normalize_title(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.trim()
  end

  defp extract_year(%{"release_date" => date}) when is_binary(date) do
    case String.split(date, "-") do
      [year | _] -> String.to_integer(year)
      _ -> nil
    end
  rescue
    _ -> nil
  end
  defp extract_year(_), do: nil

  defp extract_keywords(title) do
    # Remove common articles and get main words
    title
    |> String.replace(~r/\b(the|a|an)\b/i, "")
    |> String.split()
    |> Enum.take(3)
    |> Enum.join(" ")
  end

  defp calculate_similarity(str1, str2) do
    # Simple Jaro-Winkler similarity
    # For production, consider using a proper string similarity library
    s1 = String.downcase(str1)
    s2 = String.downcase(str2)
    
    if s1 == s2 do
      1.0
    else
      # Simplified similarity based on common characters
      chars1 = String.graphemes(s1) |> MapSet.new()
      chars2 = String.graphemes(s2) |> MapSet.new()
      
      common = MapSet.intersection(chars1, chars2) |> MapSet.size()
      total = max(MapSet.size(chars1), MapSet.size(chars2))
      
      if total == 0, do: 0.0, else: common / total
    end
  end
end