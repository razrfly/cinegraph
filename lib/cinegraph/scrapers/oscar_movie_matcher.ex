defmodule Cinegraph.Scrapers.OscarMovieMatcher do
  @moduledoc """
  Matches Oscar ceremony data to movies in our database.

  Inspired by oscar_data's approach but adapted for our needs:
  1. Try to find existing movies by title/year
  2. Search TMDb for movies we don't have
  3. Create new movie records as needed
  """

  require Logger
  alias Cinegraph.{Repo, Movies}
  alias Cinegraph.Services.TMDb.FallbackSearch
  import Ecto.Query

  @doc """
  Process an Oscar ceremony and match all films to our movie records.
  Returns a map of film titles to movie IDs.
  """
  def match_ceremony_films(ceremony) do
    year = ceremony.year
    categories = ceremony.data["categories"] || []

    # Extract all unique films from the ceremony
    films =
      categories
      |> Enum.flat_map(fn category ->
        category["nominees"]
        |> Enum.map(& &1["film"])
        |> Enum.reject(&is_nil/1)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    Logger.info("Found #{length(films)} unique films in #{year} ceremony")

    # Match each film
    film_matches =
      films
      |> Enum.map(fn film_title ->
        {film_title, match_film(film_title, year)}
      end)
      |> Map.new()

    # Report results
    matched = Enum.count(film_matches, fn {_, movie_id} -> movie_id != nil end)
    Logger.info("Matched #{matched}/#{length(films)} films to movie records")

    film_matches
  end

  @doc """
  Match a single film title to a movie in our database.
  Returns the movie ID if found/created, nil if not matchable.
  """
  def match_film(film_title, ceremony_year) do
    # Normalize the title for matching
    normalized_title = normalize_title(film_title)

    # Try different matching strategies
    cond do
      # 1. Exact title match in the ceremony year
      movie = find_movie_by_title_and_year(film_title, ceremony_year) ->
        Logger.debug("Found exact match for '#{film_title}' (#{ceremony_year})")
        movie.id

      # 2. Normalized title match in the ceremony year
      movie = find_movie_by_title_and_year(normalized_title, ceremony_year) ->
        Logger.debug("Found normalized match for '#{film_title}' (#{ceremony_year})")
        movie.id

      # 3. Try previous year (sometimes Oscar year != release year)
      movie = find_movie_by_title_and_year(film_title, ceremony_year - 1) ->
        Logger.debug("Found match in previous year for '#{film_title}' (#{ceremony_year - 1})")
        movie.id

      # 4. Search TMDb for the movie
      movie = search_and_create_from_tmdb(film_title, ceremony_year) ->
        Logger.info("Created new movie from TMDb for '#{film_title}'")
        movie.id

      # 5. Special handling for International Feature Film
      String.contains?(film_title, "(") ->
        # Extract country from parentheses
        handle_international_film(film_title, ceremony_year)

      true ->
        Logger.warning("Could not match film: '#{film_title}' (#{ceremony_year})")
        nil
    end
  end

  @doc """
  Normalize a film title for matching.
  Based on oscar_data's approach.
  """
  def normalize_title(title) do
    title
    |> String.trim()
    |> remove_leading_article()
    |> String.downcase()
  end

  # Remove leading "The", "A", "An" from titles
  defp remove_leading_article(title) do
    case Regex.run(~r/^(The|A|An)\s+(.+)$/i, title) do
      [_, _article, rest] -> rest
      _ -> title
    end
  end

  # Find movie by exact title and year
  defp find_movie_by_title_and_year(title, year) do
    # Look for movies released in the given year using date range for better index usage
    start_date = Date.new!(year, 1, 1)
    end_date = Date.new!(year + 1, 1, 1)

    from(m in Movies.Movie,
      where: m.title == ^title and m.release_date >= ^start_date and m.release_date < ^end_date,
      limit: 1
    )
    |> Repo.one()
  end

  # Search TMDb and create movie if found using fallback strategies
  defp search_and_create_from_tmdb(title, year) do
    case FallbackSearch.find_movie(nil, title, year) do
      {:ok, result} ->
        Logger.info("Found TMDb match for '#{title}' (#{year}) using #{result.strategy} (confidence: #{result.confidence})")
        create_movie_from_tmdb(result.movie)

      {:error, :not_found} ->
        Logger.warning("No TMDb match found for '#{title}' (#{year}) after exhausting fallback strategies")
        nil

      {:error, reason} ->
        Logger.error("TMDb search error for '#{title}' (#{year}): #{inspect(reason)}")
        nil
    end
  end


  # Create a movie from TMDb data
  defp create_movie_from_tmdb(tmdb_data) do
    attrs = %{
      tmdb_id: tmdb_data["id"],
      title: tmdb_data["title"],
      original_title: tmdb_data["original_title"],
      overview: tmdb_data["overview"],
      release_date: parse_date(tmdb_data["release_date"]),
      vote_average: tmdb_data["vote_average"],
      vote_count: tmdb_data["vote_count"],
      popularity: tmdb_data["popularity"],
      adult: tmdb_data["adult"] || false,
      backdrop_path: tmdb_data["backdrop_path"],
      poster_path: tmdb_data["poster_path"],
      original_language: tmdb_data["original_language"],
      tmdb_data: tmdb_data,
      import_status: "oscar_match"
    }

    Repo.transaction(fn ->
      case Movies.create_movie(attrs) do
        {:ok, movie} ->
          Logger.info("Created movie: #{movie.title} (TMDb ID: #{movie.tmdb_id})")
          movie

        {:error, changeset} ->
          Logger.error("Failed to create movie: #{inspect(changeset.errors)}")
          Repo.rollback(:movie_creation_failed)
      end
    end)
    |> case do
      {:ok, movie} -> movie
      {:error, _} -> nil
    end
  end

  # Parse date string to Date
  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  # Special handling for International Feature Film category
  # These often have format "Title (Country)"
  defp handle_international_film(title_with_country, year) do
    case Regex.run(~r/^(.+)\s+\(([^)]+)\)$/, title_with_country) do
      [_, title, _country] ->
        match_film(title, year)

      _ ->
        nil
    end
  end

  @doc """
  Generate a report of unmatched films from a ceremony.
  """
  def report_unmatched_films(ceremony) do
    film_matches = match_ceremony_films(ceremony)

    unmatched =
      film_matches
      |> Enum.filter(fn {_, movie_id} -> movie_id == nil end)
      |> Enum.map(fn {title, _} -> title end)
      |> Enum.sort()

    if length(unmatched) > 0 do
      Logger.info("\nUnmatched films from #{ceremony.year}:")

      Enum.each(unmatched, fn title ->
        Logger.info("  - #{title}")
      end)
    else
      Logger.info("All films from #{ceremony.year} were successfully matched!")
    end

    unmatched
  end
end
