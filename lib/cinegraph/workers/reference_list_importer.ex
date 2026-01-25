defmodule Cinegraph.Workers.ReferenceListImporter do
  @moduledoc """
  Oban worker for importing reference list data from external sources.

  Supports importing from:
  - IMDb Top 250 (via TMDb API lookup)
  - AFI 100 (hardcoded canonical list)
  - 1001 Movies (via Wikipedia/external sources)
  """
  use Oban.Worker,
    queue: :imports,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  require Logger
  import Ecto.Query

  alias Cinegraph.Repo
  alias Cinegraph.Calibration
  alias Cinegraph.Calibration.{ReferenceList, Reference}
  alias Cinegraph.Movies.Movie

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"list_slug" => slug}}) do
    Logger.info("Starting reference list import: #{slug}")

    case slug do
      "imdb-top-250" -> import_imdb_top_250()
      "afi-100" -> import_afi_100()
      "sight-and-sound-2022" -> import_sight_and_sound()
      "1001-movies" -> import_1001_movies()
      _ -> {:error, "Unknown list slug: #{slug}"}
    end
  end

  @doc """
  Enqueues import jobs for all known reference lists.
  """
  def import_all do
    ReferenceList.known_lists()
    |> Map.keys()
    |> Enum.map(fn slug ->
      %{list_slug: slug}
      |> __MODULE__.new()
      |> Oban.insert()
    end)
  end

  @doc """
  Import IMDb Top 250 by matching against our existing movie database.
  Since we don't scrape IMDb directly, we use our existing IMDb data.
  """
  def import_imdb_top_250 do
    # Ensure the reference list exists
    {:ok, list} = Calibration.upsert_known_list("imdb-top-250")

    # Get top 250 movies by IMDb rating from our database
    query = """
    SELECT DISTINCT ON (m.id)
      m.id as movie_id,
      m.title,
      EXTRACT(YEAR FROM m.release_date)::integer as year,
      m.imdb_id,
      em.value as imdb_rating,
      (SELECT value FROM external_metrics WHERE movie_id = m.id AND source = 'imdb' AND metric_type = 'rating_votes') as votes
    FROM movies m
    JOIN external_metrics em ON em.movie_id = m.id
    WHERE em.source = 'imdb'
      AND em.metric_type = 'rating_average'
      AND em.value IS NOT NULL
      AND em.value > 0
      AND (SELECT value FROM external_metrics WHERE movie_id = m.id AND source = 'imdb' AND metric_type = 'rating_votes') > 1000
    ORDER BY m.id, em.value DESC
    """

    case Repo.query(query, []) do
      {:ok, %{rows: rows}} ->
        # Sort by rating and take top 250
        ranked_movies =
          rows
          |> Enum.sort_by(fn [_, _, _, _, rating, votes] ->
            # Use Bayesian average for ranking
            r = to_float(rating) || 0
            v = to_float(votes) || 0
            m = 1000
            c = 6.5
            -(v / (v + m) * r + m / (v + m) * c)
          end)
          |> Enum.take(250)
          |> Enum.with_index(1)

        # Wrap delete and import in a transaction for atomicity
        result =
          Repo.transaction(fn ->
            Reference
            |> where([r], r.reference_list_id == ^list.id)
            |> Repo.delete_all()

            # Insert new references
            references =
              Enum.map(ranked_movies, fn {[movie_id, title, year, imdb_id, rating, _votes], rank} ->
                %{
                  reference_list_id: list.id,
                  movie_id: movie_id,
                  rank: rank,
                  external_score: to_float(rating),
                  external_id: imdb_id,
                  external_title: title,
                  external_year: year,
                  match_confidence: Decimal.new("1.0")
                }
              end)

            Calibration.import_references(list.id, references)

            length(references)
          end)

        case result do
          {:ok, count} ->
            # Update list metadata
            Calibration.update_reference_list(list, %{
              total_items: count,
              last_synced_at: DateTime.utc_now()
            })

            Logger.info("Imported #{count} movies to IMDb Top 250 reference list")
            {:ok, count}

          {:error, reason} ->
            Logger.error("Failed to import IMDb Top 250 (transaction failed): #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to import IMDb Top 250: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Import AFI's 100 Years...100 Movies list.
  This is a static canonical list that we hardcode.
  """
  def import_afi_100 do
    {:ok, list} = Calibration.upsert_known_list("afi-100")

    # AFI 100 (2007 10th Anniversary Edition)
    afi_movies = [
      {1, "Citizen Kane", 1941},
      {2, "The Godfather", 1972},
      {3, "Casablanca", 1942},
      {4, "Raging Bull", 1980},
      {5, "Singin' in the Rain", 1952},
      {6, "Gone with the Wind", 1939},
      {7, "Lawrence of Arabia", 1962},
      {8, "Schindler's List", 1993},
      {9, "Vertigo", 1958},
      {10, "The Wizard of Oz", 1939},
      {11, "City Lights", 1931},
      {12, "The Searchers", 1956},
      {13, "Star Wars", 1977},
      {14, "Psycho", 1960},
      {15, "2001: A Space Odyssey", 1968},
      {16, "Sunset Boulevard", 1950},
      {17, "The Graduate", 1967},
      {18, "The General", 1926},
      {19, "On the Waterfront", 1954},
      {20, "It's a Wonderful Life", 1946},
      {21, "Chinatown", 1974},
      {22, "Some Like It Hot", 1959},
      {23, "The Grapes of Wrath", 1940},
      {24, "E.T. the Extra-Terrestrial", 1982},
      {25, "To Kill a Mockingbird", 1962},
      {26, "Mr. Smith Goes to Washington", 1939},
      {27, "High Noon", 1952},
      {28, "All About Eve", 1950},
      {29, "Double Indemnity", 1944},
      {30, "Apocalypse Now", 1979},
      {31, "The Maltese Falcon", 1941},
      {32, "The Godfather Part II", 1974},
      {33, "One Flew Over the Cuckoo's Nest", 1975},
      {34, "Snow White and the Seven Dwarfs", 1937},
      {35, "Annie Hall", 1977},
      {36, "The Bridge on the River Kwai", 1957},
      {37, "The Best Years of Our Lives", 1946},
      {38, "The Treasure of the Sierra Madre", 1948},
      {39, "Dr. Strangelove", 1964},
      {40, "The Sound of Music", 1965},
      {41, "King Kong", 1933},
      {42, "Bonnie and Clyde", 1967},
      {43, "Midnight Cowboy", 1969},
      {44, "The Philadelphia Story", 1940},
      {45, "Shane", 1953},
      {46, "It Happened One Night", 1934},
      {47, "A Streetcar Named Desire", 1951},
      {48, "Rear Window", 1954},
      {49, "Intolerance", 1916},
      {50, "The Lord of the Rings: The Fellowship of the Ring", 2001},
      {51, "West Side Story", 1961},
      {52, "Taxi Driver", 1976},
      {53, "The Deer Hunter", 1978},
      {54, "M*A*S*H", 1970},
      {55, "North by Northwest", 1959},
      {56, "Jaws", 1975},
      {57, "Rocky", 1976},
      {58, "The Gold Rush", 1925},
      {59, "Nashville", 1975},
      {60, "Duck Soup", 1933},
      {61, "Sullivan's Travels", 1941},
      {62, "American Graffiti", 1973},
      {63, "Cabaret", 1972},
      {64, "Network", 1976},
      {65, "The African Queen", 1951},
      {66, "Raiders of the Lost Ark", 1981},
      {67, "Who's Afraid of Virginia Woolf?", 1966},
      {68, "Unforgiven", 1992},
      {69, "Tootsie", 1982},
      {70, "A Clockwork Orange", 1971},
      {71, "Saving Private Ryan", 1998},
      {72, "The Shawshank Redemption", 1994},
      {73, "Butch Cassidy and the Sundance Kid", 1969},
      {74, "The Silence of the Lambs", 1991},
      {75, "In the Heat of the Night", 1967},
      {76, "Forrest Gump", 1994},
      {77, "All the President's Men", 1976},
      {78, "Modern Times", 1936},
      {79, "The Wild Bunch", 1969},
      {80, "The Apartment", 1960},
      {81, "Spartacus", 1960},
      {82, "Sunrise: A Song of Two Humans", 1927},
      {83, "Titanic", 1997},
      {84, "Easy Rider", 1969},
      {85, "A Night at the Opera", 1935},
      {86, "Platoon", 1986},
      {87, "12 Angry Men", 1957},
      {88, "Bringing Up Baby", 1938},
      {89, "The Sixth Sense", 1999},
      {90, "Swing Time", 1936},
      {91, "Sophie's Choice", 1982},
      {92, "Goodfellas", 1990},
      {93, "The French Connection", 1971},
      {94, "Pulp Fiction", 1994},
      {95, "The Last Picture Show", 1971},
      {96, "Do the Right Thing", 1989},
      {97, "Blade Runner", 1982},
      {98, "Yankee Doodle Dandy", 1942},
      {99, "Toy Story", 1995},
      {100, "Ben-Hur", 1959}
    ]

    # Wrap delete and import in a transaction for atomicity
    result =
      Repo.transaction(fn ->
        Reference
        |> where([r], r.reference_list_id == ^list.id)
        |> Repo.delete_all()

        # Match each movie to our database
        references =
          Enum.map(afi_movies, fn {rank, title, year} ->
            movie = find_movie_by_title_year(title, year)

            %{
              reference_list_id: list.id,
              movie_id: movie && movie.id,
              rank: rank,
              external_title: title,
              external_year: year,
              match_confidence: if(movie, do: Decimal.new("1.0"), else: nil)
            }
          end)

        Calibration.import_references(list.id, references)

        Enum.count(references, & &1.movie_id)
      end)

    case result do
      {:ok, matched_count} ->
        Calibration.update_reference_list(list, %{
          total_items: 100,
          last_synced_at: DateTime.utc_now()
        })

        Logger.info("Imported AFI 100: #{matched_count}/100 movies matched")
        {:ok, matched_count}

      {:error, reason} ->
        Logger.error("Failed to import AFI 100: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Import Sight & Sound 2022 Greatest Films list.
  """
  def import_sight_and_sound do
    {:ok, list} = Calibration.upsert_known_list("sight-and-sound-2022")

    # Top 100 from Sight & Sound 2022 Critics' Poll
    ss_movies = [
      {1, "Jeanne Dielman, 23 quai du Commerce, 1080 Bruxelles", 1975},
      {2, "Vertigo", 1958},
      {3, "Citizen Kane", 1941},
      {4, "Tokyo Story", 1953},
      {5, "In the Mood for Love", 2000},
      {6, "2001: A Space Odyssey", 1968},
      {7, "Beau Travail", 1999},
      {8, "Mulholland Drive", 2001},
      {9, "Man with a Movie Camera", 1929},
      {10, "Singin' in the Rain", 1952},
      {11, "Sunrise: A Song of Two Humans", 1927},
      {12, "The Godfather", 1972},
      {13, "La Règle du jeu", 1939},
      {14, "Cléo from 5 to 7", 1962},
      {15, "Close-Up", 1990},
      {16, "The Passion of Joan of Arc", 1928},
      {17, "Persona", 1966},
      {18, "Rashomon", 1950},
      {19, "8½", 1963},
      {20, "Do the Right Thing", 1989},
      {21, "Stalker", 1979},
      {22, "Sherlock Jr.", 1924},
      {23, "Meshes of the Afternoon", 1943},
      {24, "The Searchers", 1956},
      {25, "Psycho", 1960},
      {26, "Wanda", 1970},
      {27, "A Brighter Summer Day", 1991},
      {28, "L'Atalante", 1934},
      {29, "Barry Lyndon", 1975},
      {30, "Bicycle Thieves", 1948},
      {31, "Daughters of the Dust", 1991},
      {32, "Seven Samurai", 1954},
      {33, "Some Like It Hot", 1959},
      {34, "Daisies", 1966},
      {35, "The 400 Blows", 1959},
      {36, "Au Hasard Balthazar", 1966},
      {37, "News from Home", 1977},
      {38, "Portrait of a Lady on Fire", 2019},
      {39, "Killer of Sheep", 1978},
      {40, "Blade Runner", 1982},
      {41, "Battleship Potemkin", 1925},
      {42, "Histoire(s) du cinéma", 1998},
      {43, "Pather Panchali", 1955},
      {44, "M", 1931},
      {45, "Sátántangó", 1994},
      {46, "Boyhood", 2014},
      {47, "City Lights", 1931},
      {48, "The Spirit of the Beehive", 1973},
      {49, "A Man Escaped", 1956},
      {50, "Andrei Rublev", 1966}
    ]

    # Wrap delete and import in a transaction for atomicity
    result =
      Repo.transaction(fn ->
        Reference
        |> where([r], r.reference_list_id == ^list.id)
        |> Repo.delete_all()

        references =
          Enum.map(ss_movies, fn {rank, title, year} ->
            movie = find_movie_by_title_year(title, year)

            %{
              reference_list_id: list.id,
              movie_id: movie && movie.id,
              rank: rank,
              external_title: title,
              external_year: year,
              match_confidence: if(movie, do: Decimal.new("1.0"), else: nil)
            }
          end)

        Calibration.import_references(list.id, references)

        Enum.count(references, & &1.movie_id)
      end)

    case result do
      {:ok, matched_count} ->
        Calibration.update_reference_list(list, %{
          total_items: 50,
          last_synced_at: DateTime.utc_now()
        })

        Logger.info("Imported Sight & Sound 2022: #{matched_count}/50 movies matched")
        {:ok, matched_count}

      {:error, reason} ->
        Logger.error("Failed to import Sight & Sound 2022: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Import 1001 Movies You Must See Before You Die.
  Queries movies from the canonical_sources field where '1001_movies' key exists.
  """
  def import_1001_movies do
    {:ok, list} = Calibration.upsert_known_list("1001-movies")

    # Query movies that have 1001_movies in their canonical_sources
    query = """
    SELECT
      m.id as movie_id,
      m.title,
      EXTRACT(YEAR FROM m.release_date)::integer as year,
      m.canonical_sources->'1001_movies'->>'list_position' as position,
      (SELECT value FROM external_metrics em
       WHERE em.movie_id = m.id AND em.source = 'imdb' AND em.metric_type = 'rating_average'
       LIMIT 1) as imdb_rating
    FROM movies m
    WHERE m.canonical_sources ? '1001_movies'
    ORDER BY
      COALESCE((m.canonical_sources->'1001_movies'->>'list_position')::integer, 9999),
      m.title
    """

    case Repo.query(query, []) do
      {:ok, %{rows: rows}} ->
        # Clear existing references for this list
        Reference
        |> where([r], r.reference_list_id == ^list.id)
        |> Repo.delete_all()

        # Build references from canonical_sources data
        references =
          rows
          |> Enum.with_index(1)
          |> Enum.map(fn {[movie_id, title, year, position, imdb_rating], idx} ->
            # Use list_position if available, otherwise use index
            rank = if position, do: String.to_integer(position), else: idx

            %{
              reference_list_id: list.id,
              movie_id: movie_id,
              rank: rank,
              external_score: to_float(imdb_rating),
              external_title: title,
              external_year: year,
              match_confidence: Decimal.new("1.0")
            }
          end)

        Calibration.import_references(list.id, references)

        Calibration.update_reference_list(list, %{
          total_items: length(references),
          last_synced_at: DateTime.utc_now()
        })

        Logger.info("Imported 1001 Movies: #{length(references)} movies from canonical_sources")
        {:ok, length(references)}

      {:error, reason} ->
        Logger.error("Failed to import 1001 Movies: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp find_movie_by_title_year(title, year) do
    # Try exact match first
    exact =
      Movie
      |> where([m], ilike(m.title, ^title))
      |> where([m], fragment("EXTRACT(YEAR FROM ?)", m.release_date) == ^year)
      |> limit(1)
      |> Repo.one()

    if exact do
      exact
    else
      # Try flexible year match (±1 year)
      flexible_year =
        Movie
        |> where([m], ilike(m.title, ^title))
        |> where(
          [m],
          fragment("EXTRACT(YEAR FROM ?)", m.release_date) >= ^(year - 1) and
            fragment("EXTRACT(YEAR FROM ?)", m.release_date) <= ^(year + 1)
        )
        |> limit(1)
        |> Repo.one()

      if flexible_year do
        flexible_year
      else
        # Try partial match with contains pattern
        partial_pattern = "%#{title}%"

        Movie
        |> where([m], ilike(m.title, ^partial_pattern))
        |> where(
          [m],
          fragment("EXTRACT(YEAR FROM ?)", m.release_date) >= ^(year - 1) and
            fragment("EXTRACT(YEAR FROM ?)", m.release_date) <= ^(year + 1)
        )
        |> limit(1)
        |> Repo.one()
      end
    end
  end

  defp to_float(nil), do: nil
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1.0
  defp to_float(_), do: nil
end
