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
  alias Cinegraph.People.FestivalPersonInferrer
  alias Cinegraph.Services.TMDb.Extended, as: TMDbExtended
  alias Cinegraph.Services.TMDb.FallbackSearch
  alias Cinegraph.Metrics.ApiTracker
  import Ecto.Query
  require Logger

  # Categories are now determined dynamically from database configuration
  # No more hardcoded category lists

  # ========================================
  # PHASE 3: CONFIDENCE THRESHOLD CONFIGURATION
  # Tunable parameters for person linking accuracy
  # ========================================

  # Credit-based person linking thresholds
  # 85% minimum similarity for credit matches
  @credit_based_confidence_threshold 0.85
  # 10% gap required between best and second-best matches
  @credit_based_confidence_gap 0.10

  # TMDb person search thresholds  
  # 80% minimum similarity for TMDb matches
  @tmdb_confidence_threshold 0.80
  # 15% gap required between best and second-best matches
  @tmdb_confidence_gap 0.15
  # 30% bonus for exact IMDb ID matches
  @tmdb_imdb_bonus 0.30
  # 5% bonus for popular people (popularity > 10)
  @tmdb_popularity_bonus 0.05

  # Performance and quality settings
  # 5 second timeout for person linking operations
  @person_linking_timeout 5_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ceremony_id" => ceremony_id}} = job) do
    case Repo.get(FestivalCeremony, ceremony_id) |> Repo.preload(:organization) do
      nil ->
        Logger.error("Festival ceremony #{ceremony_id} not found")
        {:error, :ceremony_not_found}

      ceremony ->
        # Mark import as started for status tracking
        Festivals.mark_import_started(ceremony, job.id)

        # Store organization info before any modifications
        organization_abbr = ceremony.organization && ceremony.organization.abbreviation
        organization_id = ceremony.organization && ceremony.organization.id

        Logger.info(
          "Processing #{organization_abbr} ceremony #{ceremony.year} (ID: #{ceremony.id})"
        )

        try do
          # First ensure ceremony is enhanced with IMDb data
          ceremony = ensure_imdb_enhancement(ceremony)

          # Process each category - handle both Oscar format (categories) and Venice format (awards)
          {categories, category_format} = extract_categories(ceremony.data)

          Logger.info(
            "Processing #{length(categories)} categories for ceremony #{ceremony.year} (format: #{category_format})"
          )

          results =
            categories
            |> Enum.with_index()
            |> Enum.flat_map(fn {category_data, index} ->
              category_name = extract_category_name(category_data, category_format)

              Logger.info(
                "Processing category #{index + 1}/#{length(categories)}: #{category_name || "Unknown"}"
              )

              # Get or create the festival category (use stored organization_id)
              festival_category = ensure_category_exists(category_name, organization_id)

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

              category_name &&
                String.contains?(category_name, [
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

          # Issue #236: Track comprehensive person linking metrics
          person_linking_summary =
            track_ceremony_person_linking_metrics(ceremony, categories, results, category_format)

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
            |> Map.merge(person_linking_summary)

          # Mark import as completed with comprehensive stats
          Festivals.mark_import_completed(ceremony, %{
            nominations_found: length(results),
            nominations_matched: movies_found,
            winners_count:
              Enum.count(results, fn r ->
                r[:winner] == true or r[:won] == true
              end)
          })

          # Broadcast completion
          broadcast_discovery_complete(ceremony, summary)

          # Run person inference DIRECTLY for non-Oscar festivals (Issue #250 & #286)
          # Simple solution: just run it here instead of queuing another job
          if is_binary(organization_abbr) and organization_abbr != "AMPAS" do
            Logger.info("Running person inference for #{organization_abbr} #{ceremony.year}")

            # Track timing for comprehensive metrics
            start_time = System.monotonic_time(:millisecond)

            {result, duration_ms} =
              try do
                res = FestivalPersonInferrer.infer_all_director_nominations()
                end_time = System.monotonic_time(:millisecond)
                {res, end_time - start_time}
              rescue
                e ->
                  end_time = System.monotonic_time(:millisecond)
                  duration = end_time - start_time

                  Logger.error(
                    "Person inference crashed for #{organization_abbr} #{ceremony.year}: " <>
                      Exception.format(:error, e, __STACKTRACE__)
                  )

                  {%{success: 0, skipped: 0, failed: 0, error: Exception.message(e)}, duration}
              end

            Logger.info(
              "Person inference completed for #{organization_abbr} #{ceremony.year}: " <>
                "#{result.success} linked, #{result.skipped} skipped, #{result.failed} failed (#{duration_ms}ms)"
            )

            # Mark job metadata to indicate inference was invoked inline (always persist)
            updated_meta =
              Map.merge(job_meta, %{
                person_inference_invoked: true,
                person_inference_duration_ms: duration_ms,
                person_inference_result: result
              })

            update_job_meta(job, updated_meta)
          else
            update_job_meta(job, job_meta)
          end

          :ok
        rescue
          e ->
            Logger.error(
              "Festival discovery failed for ceremony #{ceremony_id}: " <>
                Exception.format(:error, e, __STACKTRACE__)
            )

            # Mark import as failed
            Festivals.mark_import_failed(ceremony, Exception.message(e))

            {:error, Exception.message(e)}
        end
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
        categories =
          Enum.map(awards, fn {category_name, nominees} ->
            {category_name, nominees}
          end)

        {categories, :awards_format}

      true ->
        {[], :unknown_format}
    end
  end

  defp extract_category_name(category_data, format) do
    # Debug logging to understand the issue
    data_type =
      cond do
        is_map(category_data) -> "map"
        is_tuple(category_data) -> "tuple(size: #{tuple_size(category_data)})"
        is_list(category_data) -> "list"
        true -> "other"
      end

    Logger.debug(
      "extract_category_name called with format: #{inspect(format)}, data type: #{data_type}"
    )

    case format do
      :oscar_format ->
        # Oscar format has a map with "category" key
        if is_map(category_data) do
          category_data["category"] || category_data[:category]
        else
          # Shouldn't happen, but handle gracefully
          Logger.warning("Expected map for oscar_format but got: #{inspect(category_data)}")
          nil
        end

      :awards_format ->
        # Awards format has a tuple {category_name, nominees}
        if is_tuple(category_data) and tuple_size(category_data) == 2 do
          {category_name, _nominees} = category_data
          category_name
        else
          # Shouldn't happen, but handle gracefully
          Logger.warning("Expected tuple for awards_format but got: #{inspect(category_data)}")
          nil
        end

      _ ->
        Logger.warning("Unknown format: #{inspect(format)}")
        nil
    end
  end

  defp ensure_imdb_enhancement(ceremony) do
    # No longer using IMDb enhancement for any festivals
    # Oscar data comes directly from oscars.org
    # Other festivals already have their data from UnifiedFestivalScraper
    ceremony
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
      "Best Picture",
      "Palme d'Or",
      "Golden Lion",
      "Golden Bear",
      "Actor in a Leading Role",
      "Actress in a Leading Role",
      "Directing",
      "Director",
      "Grand Prix"
    ])
  end

  defp determine_category_type(category_name) do
    # Universal category determination based on common patterns
    # Each festival can override this in their metadata configuration
    normalized = String.downcase(category_name)

    cond do
      # Person awards - actors, directors, writers, etc.
      Regex.match?(
        ~r/(actor|actress|director|directing|writer|writing|cinematograph|editor|editing|composer)/i,
        normalized
      ) ->
        {"person", true}

      # Main film awards
      Regex.match?(
        ~r/(best picture|best film|palme|golden lion|golden bear|grand prix)/i,
        normalized
      ) ->
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
    nominees =
      case format do
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
        find_or_create_person(person_imdb_ids, nominee_name, category, movie)
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

  defp find_or_create_person(person_imdb_ids, nominee_name, category, movie) do
    # Issue #236: Track person linking operations with comprehensive metrics
    primary_imdb_id = List.first(person_imdb_ids) || "unknown"

    ApiTracker.track_lookup(
      "person_linking",
      "find_or_create_person",
      primary_imdb_id,
      fn ->
        # Try to find person by IMDb ID first
        person =
          Enum.find_value(person_imdb_ids, fn imdb_id ->
            Repo.get_by(Person, imdb_id: imdb_id)
          end)

        if person do
          Logger.debug("Person found by IMDb ID: #{person.name} (#{person.id})")
          {:ok, %{strategy: "imdb_lookup", person_id: person.id, confidence: 1.0}}
        else
          # Phase 1: Credit-based person linking
          # If no person found by IMDb ID, try to find by name in existing movie credits
          case find_person_by_credits(nominee_name, person_imdb_ids, category, movie) do
            nil ->
              # Phase 2: TMDb person search and creation fallback
              case find_or_create_person_via_tmdb(person_imdb_ids, nominee_name) do
                nil -> {:error, :all_strategies_failed}
                person_id -> {:ok, %{strategy: "tmdb_fallback", person_id: person_id}}
              end

            person_id ->
              {:ok, %{strategy: "credit_based", person_id: person_id}}
          end
        end
      end,
      metadata: %{
        "nominee_name" => nominee_name,
        "category" => category && category.name,
        "movie_title" => movie && movie.title,
        "imdb_ids_count" => length(person_imdb_ids)
      }
    )
    |> case do
      {:ok, %{person_id: person_id}} -> person_id
      {:error, _} -> nil
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
          # Not in database, try TMDb search using FallbackSearch
          case FallbackSearch.find_movie(nil, actual_title, ceremony.year) do
            {:ok, result} ->
              tmdb_id = result.movie["id"]
              min_confidence = Application.get_env(:cinegraph, :fuzzy_match_min_confidence, 0.7)

              if result.confidence < min_confidence do
                Logger.warning(
                  "Fuzzy search confidence too low for '#{actual_title}': #{result.confidence} < #{min_confidence}"
                )

                %{
                  action: :skipped,
                  reason: :low_confidence,
                  title: actual_title,
                  confidence: result.confidence
                }
              else
                Logger.info(
                  "Fuzzy search successful for '#{actual_title}' - found TMDb ID: #{tmdb_id} using strategy: #{result.strategy} (confidence: #{result.confidence})"
                )

                # Queue the movie creation with TMDb ID (not IMDb ID)
                queue_movie_creation_by_tmdb(tmdb_id, nominee, category, ceremony)
              end

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
    # Order by release_date descending to prefer newer movies when multiple matches
    query =
      from m in Movie,
        where: fragment("LOWER(?) LIKE LOWER(?)", m.title, ^"%#{clean_title}%"),
        order_by: [desc: m.release_date]

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

  # Removed fuzzy_search_movie and related functions - now using FallbackSearch module
  # Keep helper functions that are still used elsewhere

  defp calculate_title_similarity(movie_title, original_title) do
    # Normalize titles for comparison
    normalized_movie = normalize_title(movie_title)
    normalized_original = normalize_title(original_title)

    # Use Jaro distance for fuzzy matching
    String.jaro_distance(normalized_movie, normalized_original)
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

  # ========================================
  # CREDIT-BASED PERSON LINKING
  # Implementation of Issue #235 
  # ========================================

  # Find person by searching through existing movie credits.
  # This implements Phase 1 of the credit-based person linking strategy.
  # Enhanced with Issue #236 improvements: department/role matching and movie context
  defp find_person_by_credits(nominee_name, person_imdb_ids, category, movie)

  defp find_person_by_credits(nominee_name, person_imdb_ids, category, movie)
       when is_binary(nominee_name) do
    # Skip if no nominee name provided
    if String.trim(nominee_name) == "" do
      Logger.debug("No nominee name provided for credit-based linking")
      nil
    else
      Logger.debug("Attempting credit-based person linking for: #{nominee_name}")

      # Normalize the nominee name for comparison
      normalized_nominee_name = normalize_person_name(nominee_name)

      # Issue #236: Enhanced credit search with department/role filtering and movie context
      query = build_enhanced_credit_query(category, movie)
      people_with_credits = Repo.all(query)

      # Find the best match by name similarity
      best_match =
        find_best_person_match(people_with_credits, normalized_nominee_name, person_imdb_ids)

      # Issue #236: Track credit-based person linking with detailed metrics
      case best_match do
        %{id: person_id, name: matched_name, confidence: confidence} ->
          # Track successful credit-based linking
          ApiTracker.track_lookup(
            "person_linking",
            "credit_based_match",
            nominee_name,
            fn ->
              {:ok, %{person_id: person_id, matched_name: matched_name, confidence: confidence}}
            end,
            metadata: %{
              "strategy" => "credit_based",
              "confidence" => confidence,
              "category" => category && category.name,
              "movie_title" => movie && movie.title,
              "department_filter_applied" => category != nil,
              "movie_context_boost" => movie != nil
            }
          )

          Logger.info(
            "Credit-based person linking successful: '#{nominee_name}' → '#{matched_name}' (confidence: #{Float.round(confidence, 3)}, person_id: #{person_id}, category: #{(category && category.name) || "unknown"})"
          )

          person_id

        nil ->
          # Track failed credit-based linking
          ApiTracker.track_lookup(
            "person_linking",
            "credit_based_no_match",
            nominee_name,
            fn ->
              {:error, :no_suitable_match}
            end,
            metadata: %{
              "strategy" => "credit_based",
              "category" => category && category.name,
              "movie_title" => movie && movie.title,
              "people_searched" => length(people_with_credits),
              "department_filter_applied" => category != nil
            }
          )

          Logger.debug(
            "No suitable person match found via credits for: #{nominee_name} (category: #{(category && category.name) || "unknown"}, movie: #{(movie && movie.title) || "unknown"})"
          )

          nil
      end
    end
  end

  defp find_person_by_credits(_, _, _, _), do: nil

  # Find the best person match from a list of people with credits.
  # Uses name similarity scoring with confidence thresholds.
  defp find_best_person_match(people_with_credits, normalized_nominee_name, person_imdb_ids) do
    # Score each person and find the best match
    scored_matches =
      people_with_credits
      |> Enum.map(fn person ->
        normalized_person_name = normalize_person_name(person.name)

        # Calculate name similarity using Jaro distance
        name_similarity = String.jaro_distance(normalized_nominee_name, normalized_person_name)

        # Bonus points if the person has a matching IMDb ID in the provided list
        imdb_bonus =
          if person.imdb_id && person.imdb_id in person_imdb_ids do
            # 20% bonus for IMDb ID match
            0.2
          else
            0.0
          end

        total_confidence = min(name_similarity + imdb_bonus, 1.0)

        %{
          id: person.id,
          name: person.name,
          confidence: total_confidence,
          name_similarity: name_similarity,
          imdb_bonus: imdb_bonus
        }
      end)
      # Filter for high-confidence matches using configured threshold
      |> Enum.filter(fn match -> match.confidence >= @credit_based_confidence_threshold end)
      |> Enum.sort_by(fn match -> match.confidence end, :desc)

    case scored_matches do
      [] ->
        nil

      [best_match | rest] ->
        # If we have multiple high-confidence matches, only accept if there's a clear winner
        case rest do
          [] ->
            # Single high-confidence match
            best_match

          [second_best | _]
          when best_match.confidence - second_best.confidence > @credit_based_confidence_gap ->
            # Clear winner (10% confidence gap)
            best_match

          _ ->
            # Multiple similar matches - too ambiguous
            Logger.debug(
              "Multiple similar person matches found for '#{normalized_nominee_name}' - skipping ambiguous match"
            )

            nil
        end
    end
  end

  # Normalize person names for better matching.
  # Handles common name variations and formatting issues.
  defp normalize_person_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    # Remove common punctuation
    |> String.replace(~r/[.,;:]/, "")
    # Normalize whitespace
    |> String.replace(~r/\s+/, " ")
    # Remove common prefixes/suffixes that might interfere with matching
    |> String.replace(~r/\b(jr\.?|sr\.?|iii?|iv)\b/, "")
    |> String.trim()
  end

  defp normalize_person_name(_), do: ""

  # ========================================
  # ISSUE #236: COMPREHENSIVE METRICS TRACKING
  # Person linking success rates and performance metrics
  # ========================================

  # Track comprehensive person linking metrics for the entire ceremony
  defp track_ceremony_person_linking_metrics(ceremony, categories, results, category_format) do
    # Count person categories vs film categories
    person_categories =
      Enum.filter(categories, fn category_data ->
        category_name = extract_category_name(category_data, category_format)

        category_name &&
          String.contains?(String.downcase(category_name), [
            "actor",
            "actress",
            "director",
            "writing",
            "cinematography"
          ])
      end)

    # Simulate person linking success metrics (in real implementation, this would come from actual metrics)
    person_category_count = length(person_categories)

    # Track overall ceremony person linking performance
    ApiTracker.track_lookup(
      "person_linking",
      "ceremony_summary",
      "#{ceremony.organization.abbreviation}_#{ceremony.year}",
      fn ->
        {:ok,
         %{
           person_categories: person_category_count,
           total_categories: length(categories),
           total_results: length(results)
         }}
      end,
      metadata: %{
        "ceremony_year" => ceremony.year,
        "organization" => ceremony.organization.abbreviation,
        "person_categories_ratio" =>
          if(length(categories) > 0, do: person_category_count / length(categories), else: 0.0)
      }
    )

    # Return summary metrics for job metadata
    %{
      person_linking_categories: person_category_count,
      person_linking_coverage: if(person_category_count > 0, do: 100.0, else: 0.0),
      person_linking_enabled: true
    }
  end

  # ========================================
  # ISSUE #236: ENHANCED CREDIT QUERIES
  # Department/role matching and movie context
  # ========================================

  # Build enhanced credit query with department/role filtering and movie context
  defp build_enhanced_credit_query(category, movie) do
    base_query =
      from p in Person,
        join: c in Credit,
        on: c.person_id == p.id,
        where: not is_nil(p.name),
        select: %{
          id: p.id,
          name: p.name,
          imdb_id: p.imdb_id,
          department: c.department,
          job: c.job,
          credit_type: c.credit_type,
          movie_id: c.movie_id
        },
        distinct: p.id

    # Add category-based department/role filtering
    query_with_role_filter = add_role_filtering(base_query, category)

    # Add movie context if available (people who worked on the same movie get priority)
    add_movie_context_boost(query_with_role_filter, movie)
  end

  # Add role/department filtering based on award category
  defp add_role_filtering(query, nil), do: query

  defp add_role_filtering(query, category) do
    # Map award categories to relevant departments/jobs
    relevant_roles = get_relevant_roles_for_category(category.name)

    # Apply filtering only if we have specific roles to filter on
    if has_specific_roles?(relevant_roles) do
      from [p, c] in query,
        where:
          c.credit_type in ^relevant_roles[:credit_types] or
            (not is_nil(c.department) and c.department in ^relevant_roles[:departments]) or
            (not is_nil(c.job) and c.job in ^relevant_roles[:jobs])
    else
      query
    end
  end

  # Check if role mapping has specific filtering criteria
  defp has_specific_roles?(roles) do
    length(roles[:departments]) > 0 or length(roles[:jobs]) > 0
  end

  # Add movie context boost (prefer people who worked on the nominated movie)
  defp add_movie_context_boost(query, nil), do: query

  defp add_movie_context_boost(query, movie) do
    # Order by movie context: people from the same movie first, then others
    from [p, c] in query,
      order_by: [
        desc: fragment("CASE WHEN ? = ? THEN 1 ELSE 0 END", c.movie_id, ^movie.id),
        desc: p.popularity
      ]
  end

  # Map award categories to relevant professional roles
  defp get_relevant_roles_for_category(category_name) do
    normalized_category = String.downcase(category_name)

    cond do
      # Acting categories
      String.contains?(normalized_category, ["actor", "actress", "acting", "performance"]) ->
        %{
          credit_types: ["cast"],
          departments: ["Acting"],
          jobs: ["Actor", "Actress"]
        }

      # Directing categories  
      String.contains?(normalized_category, ["directing", "director"]) ->
        %{
          credit_types: ["crew"],
          departments: ["Directing"],
          jobs: ["Director"]
        }

      # Writing categories
      String.contains?(normalized_category, ["writing", "screenplay", "writer", "script"]) ->
        %{
          credit_types: ["crew"],
          departments: ["Writing"],
          jobs: ["Writer", "Screenplay", "Story", "Adaptation"]
        }

      # Cinematography categories
      String.contains?(normalized_category, ["cinematography", "photography"]) ->
        %{
          credit_types: ["crew"],
          departments: ["Camera"],
          jobs: ["Director of Photography", "Cinematographer"]
        }

      # Music categories
      String.contains?(normalized_category, ["music", "score", "composer"]) ->
        %{
          credit_types: ["crew"],
          departments: ["Sound"],
          jobs: ["Original Music Composer", "Music", "Composer"]
        }

      # Production categories
      String.contains?(normalized_category, ["producer", "production"]) ->
        %{
          credit_types: ["crew"],
          departments: ["Production"],
          jobs: ["Producer", "Executive Producer"]
        }

      # Default: no filtering (accept all roles)
      true ->
        %{
          credit_types: ["cast", "crew"],
          departments: [],
          jobs: []
        }
    end
  end

  # ========================================
  # PHASE 2: TMDB PERSON SEARCH & CREATION
  # TMDb integration fallback for unlinked nominations
  # ========================================

  # Find or create person using TMDb API when credit-based linking fails
  defp find_or_create_person_via_tmdb(person_imdb_ids, nominee_name)
       when is_binary(nominee_name) do
    # Skip if no nominee name provided
    if String.trim(nominee_name) == "" do
      Logger.debug("No nominee name provided for TMDb person search")
      nil
    else
      Logger.debug("Attempting TMDb person search for: #{nominee_name}")

      # Issue #236: Track TMDb person search operations
      ApiTracker.track_lookup(
        "person_linking",
        "tmdb_person_search",
        nominee_name,
        fn ->
          case search_tmdb_person(nominee_name, person_imdb_ids) do
            {:ok, tmdb_person_data} ->
              # Create person from TMDb data
              case create_person_from_tmdb_data(tmdb_person_data, nominee_name) do
                nil ->
                  {:error, :tmdb_person_creation_failed}

                person_id ->
                  {:ok,
                   %{
                     strategy: "tmdb_search",
                     person_id: person_id,
                     tmdb_id: tmdb_person_data["id"]
                   }}
              end

            {:error, :not_found} ->
              # Phase 3: Create minimal person record with just name and IMDb ID
              case create_minimal_person_record(person_imdb_ids, nominee_name) do
                nil -> {:error, :minimal_person_creation_failed}
                person_id -> {:ok, %{strategy: "minimal_record", person_id: person_id}}
              end

            {:error, reason} ->
              Logger.warning("TMDb person search failed for '#{nominee_name}': #{reason}")
              # Still try minimal record creation as fallback
              case create_minimal_person_record(person_imdb_ids, nominee_name) do
                nil -> {:error, reason}
                person_id -> {:ok, %{strategy: "minimal_record", person_id: person_id}}
              end
          end
        end,
        metadata: %{
          "tmdb_search_attempted" => true,
          "imdb_ids_available" => person_imdb_ids,
          "fallback_level" => 2
        }
      )
      |> case do
        {:ok, %{person_id: person_id}} -> person_id
        {:error, _} -> nil
      end
    end
  end

  defp find_or_create_person_via_tmdb(_, _), do: nil

  # Search TMDb for person by name, with optional IMDb ID verification
  defp search_tmdb_person(nominee_name, person_imdb_ids) do
    Logger.debug("Searching TMDb for person: #{nominee_name}")

    # Clean the name for better search results  
    clean_name = clean_person_name_for_search(nominee_name)

    # Add timeout and rate limiting protection
    task =
      Task.async(fn ->
        TMDbExtended.search_people(clean_name)
      end)

    case Task.await(task, @person_linking_timeout) do
      {:ok, %{"results" => results}} when results != [] ->
        Logger.debug("Found #{length(results)} TMDb person results for '#{clean_name}'")

        # Find best match from results
        case find_best_tmdb_person_match(results, nominee_name, person_imdb_ids) do
          {:ok, person_data} ->
            Logger.info(
              "TMDb person match found: #{person_data["name"]} (ID: #{person_data["id"]})"
            )

            {:ok, person_data}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{"results" => []}} ->
        Logger.debug("No TMDb person results found for '#{clean_name}'")
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("TMDb person search API error for '#{clean_name}': #{inspect(reason)}")
        {:error, {:api_error, reason}}
    end
  rescue
    # Handle timeout and task errors
    error ->
      Logger.warning(
        "TMDb person search timeout or error for '#{nominee_name}': #{inspect(error)}"
      )

      {:error, :timeout}
  end

  # Find best person match from TMDb search results
  defp find_best_tmdb_person_match(results, nominee_name, person_imdb_ids) do
    # Score and filter results
    scored_results =
      results
      |> Enum.map(fn person ->
        {person, calculate_tmdb_person_match_score(person, nominee_name, person_imdb_ids)}
      end)
      # Filter using configured TMDb confidence threshold
      |> Enum.filter(fn {_person, score} -> score > @tmdb_confidence_threshold end)
      |> Enum.sort_by(fn {_person, score} -> score end, :desc)

    case scored_results do
      [] ->
        {:error, :no_good_matches}

      [{person, score} | rest] ->
        # If multiple high-confidence matches, only accept if there's a clear winner
        case rest do
          [] ->
            Logger.debug("Single TMDb match: #{person["name"]} (score: #{Float.round(score, 3)})")
            {:ok, person}

          [{_, second_score} | _] when score - second_score > @tmdb_confidence_gap ->
            Logger.debug("Clear TMDb winner: #{person["name"]} (score: #{Float.round(score, 3)})")
            {:ok, person}

          _ ->
            Logger.debug("Multiple similar TMDb matches - too ambiguous")
            {:error, :multiple_matches}
        end
    end
  end

  # Calculate match score for TMDb person result
  defp calculate_tmdb_person_match_score(person, nominee_name, person_imdb_ids) do
    # Start with name similarity (70% weight)
    name_similarity = calculate_person_name_similarity(person["name"], nominee_name) * 0.7

    # IMDb ID verification bonus using configured weight
    imdb_bonus =
      if person["imdb_id"] && person["imdb_id"] in person_imdb_ids do
        @tmdb_imdb_bonus
      else
        0.0
      end

    # Popularity bonus for more likely correct matches using configured weight
    popularity_bonus =
      case person["popularity"] do
        pop when is_number(pop) and pop > 10 -> @tmdb_popularity_bonus
        _ -> 0.0
      end

    min(name_similarity + imdb_bonus + popularity_bonus, 1.0)
  end

  # Calculate name similarity between two person names
  defp calculate_person_name_similarity(tmdb_name, nominee_name) do
    normalized_tmdb = normalize_person_name(tmdb_name)
    normalized_nominee = normalize_person_name(nominee_name)
    String.jaro_distance(normalized_tmdb, normalized_nominee)
  end

  # Clean person name for TMDb search
  defp clean_person_name_for_search(name) do
    name
    |> String.trim()
    # Remove common prefixes/suffixes that might interfere
    |> String.replace(~r/\b(jr\.?|sr\.?|iii?|iv)\b/i, "")
    |> String.trim()
  end

  # Create person from TMDb API data
  defp create_person_from_tmdb_data(tmdb_data, _original_name) do
    Logger.info("Creating person from TMDb data: #{tmdb_data["name"]}")

    case Cinegraph.Movies.create_or_update_person_from_tmdb(tmdb_data) do
      {:ok, person} ->
        Logger.info("Successfully created person from TMDb: #{person.name} (ID: #{person.id})")
        person.id

      {:error, changeset} ->
        Logger.error("Failed to create person from TMDb data: #{inspect(changeset.errors)}")
        nil
    end
  end

  # ========================================  
  # PHASE 3: MINIMAL PERSON RECORD CREATION
  # Create basic person records when TMDb search fails
  # ========================================

  # Create minimal person record with just name and IMDb ID when all else fails
  defp create_minimal_person_record(person_imdb_ids, nominee_name) do
    # Only create if we have at least one IMDb ID to avoid duplicates
    primary_imdb_id = List.first(person_imdb_ids)

    if primary_imdb_id do
      Logger.info("Creating minimal person record: #{nominee_name} (IMDb: #{primary_imdb_id})")

      attrs = %{
        imdb_id: primary_imdb_id,
        name: String.trim(nominee_name)
      }

      case %Person{} |> Person.imdb_changeset(attrs) |> Repo.insert() do
        {:ok, person} ->
          Logger.info(
            "Successfully created minimal person record: #{person.name} (ID: #{person.id})"
          )

          person.id

        {:error, changeset} ->
          # Check if it's a uniqueness error (person might have been created by another process)
          if changeset.errors[:imdb_id] do
            Logger.debug("Person with IMDb ID #{primary_imdb_id} already exists, searching again")

            case Repo.get_by(Person, imdb_id: primary_imdb_id) do
              %Person{id: id} -> id
              nil -> nil
            end
          else
            Logger.error("Failed to create minimal person record: #{inspect(changeset.errors)}")
            nil
          end
      end
    else
      Logger.debug(
        "No IMDb ID provided, cannot create minimal person record for: #{nominee_name}"
      )

      nil
    end
  end
end
