defmodule Cinegraph.Services.TMDb.FallbackSearch do
  @moduledoc """
  Progressive fallback search strategies for TMDb movie lookups.
  Implements multiple search strategies with confidence scoring to improve lookup success rates.
  """

  alias Cinegraph.Services.TMDb
  alias Cinegraph.Metrics.ApiTracker
  require Logger

  defp max_fallback_level do
    Application.get_env(:cinegraph, :tmdb_search, [])
    |> Keyword.get(:max_fallback_level, 3)
  end

  defp min_confidence do
    Application.get_env(:cinegraph, :tmdb_search, [])
    |> Keyword.get(:min_confidence, 0.7)
  end

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
    min_conf = min_confidence()

    strategies
    |> Enum.take(max_fallback_level())
    |> Enum.reduce_while({:error, :not_found}, fn strategy, _acc ->
      case execute_strategy(strategy) do
        {:ok, result} ->
          if result.confidence >= min_conf do
            {:halt, {:ok, result}}
          else
            {:cont, {:error, :not_found}}
          end

        {:error, _} ->
          {:cont, {:error, :not_found}}
      end
    end)
  end

  defp build_strategies(imdb_id, title, year, _opts) do
    [
      {imdb_id && imdb_id != "", 1, "direct_imdb", 1.0, fn -> find_by_imdb(imdb_id) end},
      {title && year, 2, "exact_title_year", 0.9, fn -> search_exact_title_year(title, year) end},
      {title, 3, "normalized_title", 0.8, fn -> search_normalized_title(title, year) end},
      {title && year, 4, "year_tolerant", 0.7, fn -> search_year_tolerant(title, year) end},
      {title, 5, "fuzzy_title", 0.6, fn -> search_fuzzy_title(title) end},
      {title, 6, "broad_search", 0.5, fn -> search_broad(title) end}
    ]
    |> Enum.filter(fn {condition, _, _, _, _} -> condition end)
    |> Enum.map(fn {_, level, name, confidence, fun} ->
      %{level: level, name: name, confidence: confidence, fn: fun}
    end)
  end

  defp execute_strategy(strategy) do
    Logger.debug("Executing TMDb search strategy: #{strategy.name} (level: #{strategy.level})")

    ApiTracker.track_lookup(
      "tmdb",
      "fallback_#{strategy.name}",
      "",
      fn ->
        case strategy.fn.() do
          {:ok, movie} ->
            {:ok,
             %{
               movie: movie,
               confidence: strategy.confidence,
               fallback_level: strategy.level,
               strategy: strategy.name
             }}

          error ->
            error
        end
      end,
      fallback_level: strategy.level,
      confidence: strategy.confidence,
      metadata: %{strategy: strategy.name}
    )
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
    years = [year - 1, year, year + 1]

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
    # Levenshtein distance based similarity
    # More accurate than simple character set overlap
    s1 = String.downcase(String.trim(str1 || ""))
    s2 = String.downcase(String.trim(str2 || ""))

    cond do
      s1 == s2 ->
        1.0

      s1 == "" or s2 == "" ->
        0.0

      true ->
        # Calculate Levenshtein distance
        distance = levenshtein_distance(s1, s2)
        max_len = max(String.length(s1), String.length(s2))

        if max_len == 0 do
          0.0
        else
          # Convert distance to similarity score (0.0 to 1.0)
          1.0 - distance / max_len
        end
    end
  end

  defp levenshtein_distance(s1, s2) do
    # Dynamic programming implementation of Levenshtein distance
    len1 = String.length(s1)
    len2 = String.length(s2)

    # Create a 2D array for dynamic programming
    # Use a map for simplicity
    initial_matrix =
      for i <- 0..len1, j <- 0..len2, into: %{} do
        cond do
          i == 0 -> {{i, j}, j}
          j == 0 -> {{i, j}, i}
          true -> {{i, j}, 0}
        end
      end

    # Fill in the matrix
    chars1 = String.graphemes(s1)
    chars2 = String.graphemes(s2)

    Enum.reduce(1..len1, initial_matrix, fn i, matrix ->
      Enum.reduce(1..len2, matrix, fn j, matrix2 ->
        char1 = Enum.at(chars1, i - 1)
        char2 = Enum.at(chars2, j - 1)

        cost = if char1 == char2, do: 0, else: 1

        val =
          min(
            # Deletion
            matrix2[{i - 1, j}] + 1,
            min(
              # Insertion
              matrix2[{i, j - 1}] + 1,
              # Substitution
              matrix2[{i - 1, j - 1}] + cost
            )
          )

        Map.put(matrix2, {i, j}, val)
      end)
    end)[{len1, len2}]
  end
end
