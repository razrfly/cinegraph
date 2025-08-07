defmodule Cinegraph.Workers.FestivalDiscoveryWorker do
  @moduledoc """
  Worker to process festival ceremony data and queue movie creation jobs.

  This worker:
  1. Takes a festival ceremony record
  2. Processes each nominee
  3. Checks if the movie exists (by IMDb ID)
  4. Queues TMDbDetailsWorker if movie doesn't exist
  5. Creates/updates nomination records

  This is the unified version that replaces OscarDiscoveryWorker
  and works with the festival_* tables instead of oscar_* tables.
  """

  use Oban.Worker,
    queue: :festival_import,
    max_attempts: 3,
    priority: 2

  alias Cinegraph.Repo
  alias Cinegraph.Festivals
  alias Cinegraph.Festivals.{FestivalCeremony, FestivalNomination}
  alias Cinegraph.Workers.TMDbDetailsWorker
  alias Cinegraph.Movies.{Movie, Person}
  alias Cinegraph.Services.TMDb
  import Ecto.Query
  require Logger

  # Categories are now determined dynamically from database configuration
  # No more hardcoded category lists

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ceremony_id" => ceremony_id}} = job) do
    case Repo.get(FestivalCeremony, ceremony_id) |> Repo.preload(:organization) do
      nil ->
        Logger.error("Festival ceremony #{ceremony_id} not found")
        {:error, :ceremony_not_found}

      ceremony ->
        Logger.info(
          "Processing #{ceremony.organization.abbreviation} ceremony #{ceremony.year} (ID: #{ceremony.id})"
        )

        # First ensure ceremony is enhanced with IMDb data
        ceremony = ensure_imdb_enhancement(ceremony)

        # Process each category - handle both Oscar format (categories) and Venice format (awards)
        {categories, category_format} = extract_categories(ceremony.data)
        Logger.info("Processing #{length(categories)} categories for ceremony #{ceremony.year} (format: #{category_format})")

        results =
          categories
          |> Enum.with_index()
          |> Enum.flat_map(fn {category_data, index} ->
            category_name = extract_category_name(category_data, category_format)

            Logger.info(
              "Processing category #{index + 1}/#{length(categories)}: #{category_name || "Unknown"}"
            )

            # Get or create the festival category
            festival_category = ensure_category_exists(category_name, ceremony.organization_id)

            # Process nominees if category was created successfully
            category_results =
              if festival_category do
                process_category(category_data, festival_category, ceremony, category_format)
              else
                Logger.error("Skipping category #{category_name} - failed to create category")
                []
              end

            Logger.info(
              "Category #{index + 1} processed with #{length(category_results)} results"
            )

            category_results
          end)

        Logger.info("Total results from all categories: #{length(results)}")
        summary = summarize_results(results)
        Logger.info("Festival discovery complete for #{ceremony.year}: #{inspect(summary)}")

        # Calculate enhanced business metadata
        movies_found =
          Enum.count(results, fn r ->
            r[:action] in [:queued_movie, :created_nomination, :existing, :updated]
          end)

        tmdb_jobs_queued = Enum.count(results, &(&1[:action] == :queued_movie))

        imdb_ids_without_tmdb =
          Enum.count(results, fn r ->
            r[:action] == :skipped and r[:reason] == :fuzzy_search_failed
          end)

        # Count person vs film nominations by checking category types
        person_nominations =
          Enum.count(categories, fn category_data ->
            category_name = extract_category_name(category_data, category_format)

            category_name && String.contains?(category_name, [
              "Actor",
              "Actress",
              "Directing",
              "Writing",
              "Cinematography"
            ])
          end)

        film_nominations = length(categories) - person_nominations

        fuzzy_matches_attempted = Enum.count(results, &(&1[:action] == :fuzzy_matched))

        fuzzy_matches_successful =
          Enum.count(results, fn r ->
            r[:action] == :fuzzy_matched or (r[:action] == :updated and r[:fuzzy_matched_local])
          end)

        # Save comprehensive job metadata
        job_meta =
          Map.merge(summary, %{
            ceremony_year: ceremony.year,
            categories_processed: length(categories),
            total_nominations: length(results),
            movies_found: movies_found,
            tmdb_jobs_queued: tmdb_jobs_queued,
            imdb_ids_without_tmdb: imdb_ids_without_tmdb,
            people_nominations: person_nominations,
            film_nominations: film_nominations,
            fuzzy_matches_attempted: fuzzy_matches_attempted,
            fuzzy_matches_successful: fuzzy_matches_successful
          })

        update_job_meta(job, job_meta)

        # Broadcast completion
        broadcast_discovery_complete(ceremony, summary)

        :ok
    end
  end

  defp extract_categories(data) do
    # Check for Oscar format categories first - but only if non-empty
    oscar_categories = data["categories"] || data[:categories] || []
    
    # Check for Venice/Festival format awards
    awards = data["awards"] || data[:awards] || %{}
    
    cond do
      # Oscar format: data["categories"] with nominees inside (and not empty)
      length(oscar_categories) > 0 ->
        {oscar_categories, :oscar_format}
      
      # Venice/Festival format: data["awards"] with categories as keys (and not empty)
      map_size(awards) > 0 ->
        # Convert to list of {category_name, nominees} tuples  
        categories = Enum.map(awards, fn {category_name, nominees} ->
          {category_name, nominees}
        end)
        {categories, :awards_format}
      
      true ->
        {[], :unknown_format}
    end
  end
  
  defp extract_category_name(category_data, format) do
    case format do
      :oscar_format ->
        category_data["category"] || category_data[:category]
      :awards_format ->
        {category_name, _nominees} = category_data
        category_name
      _ ->
        nil
    end
  end

  defp ensure_imdb_enhancement(ceremony) do
    # Only use IMDb enhancement for Oscars, not other festivals
    if ceremony.organization.abbreviation == "AMPAS" do
      if ceremony.data["imdb_matched"] do
        ceremony
      else
        Logger.info("Enhancing Oscar ceremony #{ceremony.year} with IMDb data...")

        case Cinegraph.Scrapers.ImdbOscarScraper.enhance_ceremony_with_imdb(ceremony) do
          {:ok, enhanced_data} ->
            # Update the ceremony with enhanced data
            changeset = FestivalCeremony.changeset(ceremony, %{data: enhanced_data})

            case Repo.update(changeset) do
              {:ok, updated} ->
                Logger.info("Successfully enhanced Oscar ceremony #{ceremony.year} with IMDb data")
                updated

              {:error, reason} ->
                Logger.error("Failed to update ceremony with enhanced data: #{inspect(reason)}")
                ceremony
            end

          {:error, reason} ->
            Logger.error("Failed to enhance Oscar ceremony #{ceremony.year}: #{inspect(reason)}")
            ceremony
        end
      end
    else
      # Non-Oscar festivals don't use IMDb enhancement
      ceremony
    end
  end

  defp ensure_category_exists(category_name, organization_id) do
    case Festivals.get_category(organization_id, category_name) do
      nil ->
        # Category doesn't exist - create it dynamically
        Logger.info(
          "Creating new festival category: #{category_name} for organization #{organization_id}"
        )

        {category_type, tracks_person} = determine_category_type(category_name)

        attrs = %{
          organization_id: organization_id,
          name: category_name,
          category_type: category_type,
          tracks_person: tracks_person,
          metadata: %{
            "is_major" => is_major_category?(category_name)
          }
        }

        case Festivals.create_category(attrs) do
          {:ok, category} ->
            Logger.info("Successfully created category: #{category_name}")
            category

          {:error, changeset} ->
            Logger.error(
              "Failed to create category #{category_name}: #{inspect(changeset.errors)}"
            )

            nil
        end

      category ->
        # Category already exists
        category
    end
  end

  defp is_major_category?(category_name) do
    # Determine if category is major based on common patterns
    # This can be overridden in database metadata for each festival
    String.contains?(category_name, [
      "Best Picture", "Palme d'Or", "Golden Lion", "Golden Bear",
      "Actor in a Leading Role", "Actress in a Leading Role",
      "Directing", "Director", "Grand Prix"
    ])
  end

  defp determine_category_type(category_name) do
    # Universal category determination based on common patterns
    # Each festival can override this in their metadata configuration
    normalized = String.downcase(category_name)
    
    cond do
      # Person awards - actors, directors, writers, etc.
      Regex.match?(~r/(actor|actress|director|directing|writer|writing|cinematograph|editor|editing|composer)/i, normalized) ->
        {"person", true}

      # Main film awards
      Regex.match?(~r/(best picture|best film|palme|golden lion|golden bear|grand prix)/i, normalized) ->
        {"film", false}

      # Technical awards
      Regex.match?(~r/(visual effects|sound|makeup|costume|design|score|song|music)/i, normalized) ->
        {"technical", false}

      # Genre-specific film awards
      Regex.match?(~r/(documentary|animated|animation|international|foreign)/i, normalized) ->
        {"film", false}
        
      # Special jury or other awards
      Regex.match?(~r/(jury|special|honorary)/i, normalized) ->
        {"special", false}

      # Default for unrecognized categories
      true ->
        {"film", false}
    end
  end

  defp extract_film_info(nominee) do
    cond do
      # Venice/Awards format: films array with movie data
      nominee["films"] || nominee[:films] ->
        films = nominee["films"] || nominee[:films] || []
        if length(films) > 0 do
          film = List.first(films)
          imdb_id = film["imdb_id"] || film[:imdb_id]
          title = film["title"] || film[:title]
          year = film["year"] || film[:year]
          {imdb_id, title, year}
        else
          {nil, nil, nil}
        end
      
      # Oscar format: film data directly in nominee
      true ->
        film_imdb_id = nominee["film_imdb_id"] || nominee[:film_imdb_id]
        film_title = nominee["film"] || nominee[:film] 
        film_year = nominee["film_year"] || nominee[:film_year]
        {film_imdb_id, film_title, film_year}
    end
  end

  defp process_category(category_data, fest_category, ceremony, format) do
    nominees = case format do
      :oscar_format ->
        category_data["nominees"] || category_data[:nominees] || []
      :awards_format ->
        {_category_name, nominees} = category_data
        nominees || []
      _ ->
        []
    end

    nominees
    |> Enum.map(fn nominee ->
      process_nominee(nominee, fest_category, ceremony)
    end)
  end

  defp process_nominee(nominee, category, ceremony) do
    # Handle different data formats
    {film_imdb_id, film_title, film_year} = extract_film_info(nominee)
    category_name = category.name

    Logger.info(
      "Processing nominee: #{film_title} (IMDb: #{film_imdb_id || "none"}) in #{category_name} for #{ceremony.year}"
    )

    # Skip song categories - these aren't films
    if String.contains?(category_name, ["Music (Original Song)", "Original Song"]) do
      Logger.info("Skipping '#{film_title}' - song category, not a film")
      %{action: :skipped, reason: :song_category, title: film_title}
    else
      cond do
        # Has IMDb ID - process normally
        !is_nil(film_imdb_id) ->
          Logger.info("Processing movie nominee: #{film_title} (#{film_imdb_id})")
          movie_result = ensure_movie_exists(film_imdb_id, film_title, film_year)

          case movie_result do
            {:ok, movie} ->
              # Create the nomination
              create_nomination(movie, nominee, category, ceremony)

            {:queued, job_id} ->
              # Movie creation queued
              %{action: :queued_movie, job_id: job_id, title: film_title}

            {:error, reason} ->
              Logger.error("Failed to process movie #{film_title}: #{inspect(reason)}")
              %{action: :error, reason: reason, title: film_title}
          end

        # No IMDb ID - try fuzzy search fallback
        is_nil(film_imdb_id) ->
          Logger.info("No IMDb ID for #{film_title} - attempting fuzzy search fallback")
          attempt_fuzzy_search_fallback(nominee, category, ceremony)
      end
    end
  end

  defp ensure_movie_exists(imdb_id, film_title, film_year) do
    case Repo.get_by(Movie, imdb_id: imdb_id) do
      nil ->
        # Movie doesn't exist, queue TMDbDetailsWorker
        Logger.info(
          "Movie not found for IMDb ID #{imdb_id} (#{film_title}), queuing creation job"
        )

        job_args = %{
          "imdb_id" => imdb_id,
          "source" => "festival_import",
          "metadata" => %{
            "film_title" => film_title,
            "film_year" => film_year
          }
        }

        case TMDbDetailsWorker.new(job_args) |> Oban.insert() do
          {:ok, job} ->
            Logger.info("Queued TMDbDetailsWorker job #{job.id} for #{film_title}")
            {:queued, job.id}

          {:error, reason} ->
            Logger.error("Failed to queue TMDbDetailsWorker: #{inspect(reason)}")
            {:error, reason}
        end

      movie ->
        # Movie exists
        Logger.debug("Movie found for IMDb ID #{imdb_id}: #{movie.title}")
        {:ok, movie}
    end
  end

  defp create_nomination(movie, nominee, category, ceremony) do
    # Handle both atom and string keys
    is_winner = nominee["winner"] || nominee[:winner] || false
    nominee_name = nominee["name"] || nominee[:name]
    person_imdb_ids = nominee["person_imdb_ids"] || nominee[:person_imdb_ids] || []

    # Try to find the person if this is a person category
    person_id =
      if category && category.tracks_person && person_imdb_ids != [] do
        find_or_create_person(person_imdb_ids, nominee_name)
      else
        nil
      end

    # Build nomination attributes
    attrs = %{
      ceremony_id: ceremony.id,
      category_id: category.id,
      movie_id: movie.id,
      person_id: person_id,
      won: is_winner,
      details: %{
        "nominee_names" => nominee_name,
        "person_imdb_ids" => person_imdb_ids
      }
    }

    # Check if nomination already exists using a query to avoid multiple results
    existing_count =
      from(n in FestivalNomination,
        where:
          n.ceremony_id == ^ceremony.id and
            n.category_id == ^category.id and
            n.movie_id == ^movie.id,
        select: count(n.id)
      )
      |> Repo.one()

    if existing_count > 0 do
      Logger.debug(
        "Nomination already exists for #{movie.title} in #{category.name} (found #{existing_count})"
      )

      %{action: :existing, movie_id: movie.id, title: movie.title}
    else
      case %FestivalNomination{}
           |> FestivalNomination.changeset(attrs)
           |> Repo.insert() do
        {:ok, _nomination} ->
          Logger.info("Created nomination for #{movie.title} in #{category.name}")
          %{action: :created_nomination, movie_id: movie.id, title: movie.title}

        {:error, changeset} ->
          Logger.error(
            "Failed to create nomination for #{movie.title}: #{inspect(changeset.errors)}"
          )

          %{action: :error, reason: changeset.errors, title: movie.title}
      end
    end
  end

  defp find_or_create_person(person_imdb_ids, _nominee_name) do
    # Try to find person by IMDb ID
    person =
      Enum.find_value(person_imdb_ids, fn imdb_id ->
        Repo.get_by(Person, imdb_id: imdb_id)
      end)

    if person do
      person.id
    else
      # For now, we'll leave person_id nil and let it be linked later
      # when the person data is imported from TMDb
      nil
    end
  end

  defp summarize_results(results) do
    %{
      movies_queued: Enum.count(results, &(&1[:action] == :queued_movie)),
      nominations_created: Enum.count(results, &(&1[:action] == :created_nomination)),
      existing: Enum.count(results, &(&1[:action] == :existing)),
      skipped: Enum.count(results, &(&1[:action] == :skipped)),
      errors: Enum.count(results, &(&1[:action] == :error)),
      fuzzy_matched: Enum.count(results, &(&1[:action] == :fuzzy_matched)),
      updated: Enum.count(results, &(&1[:action] == :updated))
    }
  end

  defp update_job_meta(job, metadata) do
    import Ecto.Query

    from(j in "oban_jobs",
      where: j.id == ^job.id,
      update: [set: [meta: ^metadata]]
    )
    |> Repo.update_all([])

    Logger.info("Job completed with metadata: #{inspect(metadata)}")
  rescue
    error ->
      Logger.warning("Failed to update job meta: #{inspect(error)}")
  end

  defp broadcast_discovery_complete(ceremony, summary) do
    Phoenix.PubSub.broadcast(
      Cinegraph.PubSub,
      "oscar_imports",
      {:discovery_complete,
       %{
         ceremony_year: ceremony.year,
         ceremony_id: ceremony.id,
         summary: summary
       }}
    )
  end

  # ========================================
  # FUZZY MATCHING SYSTEM
  # Ported from main branch OscarDiscoveryWorker
  # ========================================

  defp attempt_fuzzy_search_fallback(nominee, category, ceremony) do
    film_title = nominee["film"] || nominee[:film]
    category_name = category.name

    # Handle country names in International Feature Film category
    actual_title =
      if is_country_name?(film_title) and category_name == "International Feature Film" do
        mapped_title = map_country_to_film_title(film_title, ceremony.year)

        if mapped_title do
          Logger.info("Mapped country '#{film_title}' to film title '#{mapped_title}'")
          mapped_title
        else
          Logger.info(
            "No film mapping found for country '#{film_title}' in year #{ceremony.year}"
          )

          nil
        end
      else
        film_title
      end

    if is_nil(actual_title) do
      %{action: :skipped, reason: :no_country_mapping, title: film_title}
    else
      # First check if movie already exists in our database
      case find_existing_movie_by_title(actual_title, ceremony.year) do
        {:ok, movie} ->
          Logger.info("Found existing movie in database: '#{movie.title}' (ID: #{movie.id})")
          nomination_result = create_nomination(movie, nominee, category, ceremony)

          # Merge the results appropriately
          case nomination_result do
            %{action: :created_nomination} = result ->
              Map.merge(result, %{action: :updated, fuzzy_matched_local: true})

            other ->
              other
          end

        {:error, :not_found} ->
          # Not in database, try TMDb fuzzy search
          case fuzzy_search_movie(actual_title, ceremony.year, category_name) do
            {:ok, tmdb_id} ->
              Logger.info(
                "Fuzzy search successful for '#{actual_title}' - found TMDb ID: #{tmdb_id}"
              )

              # Queue the movie creation with TMDb ID (not IMDb ID)
              queue_movie_creation_by_tmdb(tmdb_id, nominee, category, ceremony)

            {:error, reason} ->
              Logger.warning("Fuzzy search failed for '#{actual_title}': #{reason}")

              %{
                action: :skipped,
                reason: :fuzzy_search_failed,
                title: actual_title,
                details: reason
              }
          end
      end
    end
  end

  defp find_existing_movie_by_title(title, year) do
    # Clean the title for better matching
    clean_title = clean_title_for_search(title)

    # Query for movies with similar titles
    query =
      from m in Movie,
        where: fragment("LOWER(?) LIKE LOWER(?)", m.title, ^"%#{clean_title}%"),
        order_by: [desc: m.vote_count]

    movies = Repo.all(query)

    case movies do
      [] ->
        {:error, :not_found}

      [movie] ->
        # Single match - verify it's reasonable
        if title_match_acceptable?(movie.title, title, year, movie.release_date) do
          {:ok, movie}
        else
          {:error, :not_found}
        end

      multiple ->
        # Multiple matches - find best one
        case find_best_local_match(multiple, title, year) do
          {:ok, movie} -> {:ok, movie}
          _ -> {:error, :not_found}
        end
    end
  end

  defp title_match_acceptable?(movie_title, search_title, target_year, release_date) do
    title_similarity = calculate_title_similarity(movie_title, search_title)

    year_ok =
      case extract_year(release_date || "") do
        {:ok, year} -> abs(year - target_year) <= 2
        # No release date, can't verify
        _ -> true
      end

    title_similarity > 0.85 && year_ok
  end

  defp find_best_local_match(movies, title, year) do
    # Score movies and find best match
    scored =
      movies
      |> Enum.map(fn movie ->
        title_score = calculate_title_similarity(movie.title, title)

        year_score =
          case extract_year(movie.release_date || "") do
            {:ok, movie_year} ->
              case abs(movie_year - year) do
                0 -> 1.0
                1 -> 0.8
                2 -> 0.5
                _ -> 0.0
              end

            _ ->
              0.5
          end

        total_score = title_score * 0.7 + year_score * 0.3
        {movie, total_score}
      end)
      |> Enum.filter(fn {_movie, score} -> score > 0.85 end)
      |> Enum.sort_by(fn {_movie, score} -> score end, :desc)

    case scored do
      [{movie, _score} | _] -> {:ok, movie}
      [] -> {:error, :no_good_match}
    end
  end

  defp fuzzy_search_movie(title, year, category_name) do
    Logger.info(
      "Performing fuzzy search for '#{title}' (year: #{year}, category: #{category_name})"
    )

    # Clean the title for better search results
    clean_title = clean_title_for_search(title)

    # Search with year constraint
    case TMDb.search_movies(clean_title, year: year) do
      {:ok, %{"results" => results}} when results != [] ->
        # Filter and validate results
        case find_best_match(results, title, year, category_name) do
          {:ok, movie} ->
            {:ok, movie["id"]}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{"results" => []}} ->
        # Try without year constraint as fallback
        case TMDb.search_movies(clean_title) do
          {:ok, %{"results" => results}} when results != [] ->
            case find_best_match(results, title, year, category_name) do
              {:ok, movie} ->
                {:ok, movie["id"]}

              {:error, reason} ->
                {:error, reason}
            end

          _ ->
            {:error, :no_results}
        end

      {:error, reason} ->
        {:error, {:api_error, reason}}
    end
  end

  defp find_best_match(results, original_title, target_year, category_name) do
    # Score and filter results
    scored_results =
      results
      |> Enum.map(fn movie ->
        {movie, calculate_match_score(movie, original_title, target_year, category_name)}
      end)
      # 85% minimum threshold
      |> Enum.filter(fn {_movie, score} -> score > 0.85 end)
      |> Enum.sort_by(fn {_movie, score} -> score end, :desc)

    case scored_results do
      [{movie, score} | _] when score > 0.9 ->
        Logger.info(
          "Found high-confidence match: '#{movie["title"]}' (#{movie["release_date"]}) with score #{Float.round(score, 3)}"
        )

        {:ok, movie}

      [{movie, score} | rest] when score > 0.85 ->
        # If multiple results above threshold, only accept if clear winner
        case rest do
          [] ->
            Logger.info(
              "Found good match: '#{movie["title"]}' (#{movie["release_date"]}) with score #{Float.round(score, 3)}"
            )

            {:ok, movie}

          [{_, second_score} | _] when score - second_score > 0.1 ->
            Logger.info(
              "Found clear best match: '#{movie["title"]}' (#{movie["release_date"]}) with score #{Float.round(score, 3)}"
            )

            {:ok, movie}

          _ ->
            {:error, :multiple_matches}
        end

      [] ->
        {:error, :no_good_matches}
    end
  end

  defp calculate_match_score(movie, original_title, target_year, category_name) do
    # Start with title similarity (60% weight)
    title_score = calculate_title_similarity(movie["title"], original_title) * 0.6

    # Year matching (30% weight)
    year_score = calculate_year_score(movie["release_date"], target_year) * 0.3

    # Category validation (10% weight)
    category_score = validate_category_match(movie, category_name) * 0.1

    # Bonus for high vote count (indicates real/notable film)
    vote_bonus = if movie["vote_count"] > 50, do: 0.05, else: 0

    min(title_score + year_score + category_score + vote_bonus, 1.0)
  end

  defp calculate_title_similarity(movie_title, original_title) do
    # Normalize titles for comparison
    normalized_movie = normalize_title(movie_title)
    normalized_original = normalize_title(original_title)

    # Use Jaro distance for fuzzy matching
    String.jaro_distance(normalized_movie, normalized_original)
  end

  defp calculate_year_score(release_date, target_year) when is_binary(release_date) do
    case extract_year(release_date) do
      {:ok, year} ->
        # Exact match = 1.0, ±1 year = 0.8, ±2 years = 0.5, beyond = 0
        case abs(year - target_year) do
          0 -> 1.0
          1 -> 0.8
          2 -> 0.5
          _ -> 0.0
        end

      _ ->
        0.0
    end
  end

  defp calculate_year_score(_, _), do: 0.0

  defp validate_category_match(movie, category_name) do
    genres = movie["genre_ids"] || []

    cond do
      String.contains?(category_name, "Animated") and 16 in genres -> 1.0
      String.contains?(category_name, "Documentary") and 99 in genres -> 1.0
      # Can't validate well
      String.contains?(category_name, "International") -> 0.9
      # Default score for other categories
      true -> 0.8
    end
  end

  defp normalize_title(title) do
    title
    |> String.downcase()
    # Remove punctuation
    |> String.replace(~r/[^\w\s]/, "")
    |> String.trim()
  end

  defp clean_title_for_search(title) do
    # Remove common suffixes that might interfere with search
    title
    # Remove subtitles after colon
    |> String.replace(~r/\s*:\s*.*$/, "")
    # Remove subtitles after dash
    |> String.replace(~r/\s*-\s*.*$/, "")
    |> String.trim()
  end

  defp extract_year(date_string) when is_binary(date_string) do
    case Regex.run(~r/^(\d{4})/, date_string) do
      [_, year_str] -> {:ok, String.to_integer(year_str)}
      _ -> {:error, :invalid_date}
    end
  end

  defp extract_year(%Date{year: year}), do: {:ok, year}

  defp extract_year(_), do: {:error, :invalid_date}

  defp is_country_name?(title) do
    # Common country names in International Feature Film category
    country_names = [
      "Denmark",
      "Norway",
      "Sweden",
      "Finland",
      "Iceland",
      "France",
      "Germany",
      "Italy",
      "Spain",
      "Portugal",
      "Japan",
      "China",
      "South Korea",
      "India",
      "Thailand",
      "Mexico",
      "Brazil",
      "Argentina",
      "Chile",
      "Colombia",
      "Russia",
      "Poland",
      "Hungary",
      "Romania",
      "Turkey",
      "Egypt",
      "Morocco",
      "Tunisia",
      "Algeria",
      "South Africa",
      "Australia",
      "New Zealand",
      "Canada",
      "United Kingdom",
      "Bosnia and Herzegovina",
      "Czech Republic",
      "Hong Kong"
    ]

    title in country_names
  end

  # Map country names to actual film titles for International Feature Film category
  defp map_country_to_film_title(country, year) do
    # This would ideally come from the ceremony data or a lookup table
    # For now, handle known cases
    case {country, year} do
      {"Denmark", 2021} -> "Another Round"
      {"Bosnia and Herzegovina", 2021} -> "Quo Vadis, Aida?"
      {"Hong Kong", 2021} -> "Better Days"
      {"Romania", 2021} -> "Collective"
      {"Tunisia", 2021} -> "The Man Who Sold His Skin"
      _ -> nil
    end
  end

  defp queue_movie_creation_by_tmdb(tmdb_id, nominee, category, ceremony) do
    film_title = nominee["film"] || nominee[:film]
    Logger.info("Creating job args for #{film_title} (TMDb ID: #{tmdb_id}) via fuzzy match")

    # Queue TMDbDetailsWorker with TMDb ID directly
    job_args = %{
      "tmdb_id" => tmdb_id,
      "source" => "festival_import",
      "fuzzy_matched" => true,
      "metadata" => %{
        "ceremony_year" => ceremony.year,
        "category" => category.name,
        "film_title" => film_title,
        "winner" => nominee["winner"] || nominee[:winner] || false,
        "original_search_title" => film_title
      }
    }

    Logger.info("Job args created for fuzzy match #{film_title}: #{inspect(job_args)}")

    Logger.info(
      "Creating TMDbDetailsWorker job for fuzzy matched #{film_title} (TMDb ID: #{tmdb_id})"
    )

    job_result =
      job_args
      |> TMDbDetailsWorker.new()
      |> Oban.insert()

    Logger.info("Oban.insert result for fuzzy matched #{film_title}: #{inspect(job_result)}")

    case job_result do
      {:ok, job} ->
        Logger.info(
          "Successfully queued fuzzy matched movie creation for #{film_title} (TMDb ID: #{tmdb_id}) - Job ID: #{job.id}"
        )

        %{action: :fuzzy_matched, tmdb_id: tmdb_id, title: film_title, job_id: job.id}

      {:error, reason} ->
        Logger.error(
          "Failed to queue fuzzy matched movie creation for #{film_title} (TMDb ID: #{tmdb_id}): #{inspect(reason)}"
        )

        %{action: :error, reason: reason, title: film_title}
    end
  end
end
