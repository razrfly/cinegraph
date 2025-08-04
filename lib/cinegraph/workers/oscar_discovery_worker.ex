defmodule Cinegraph.Workers.OscarDiscoveryWorker do
  @moduledoc """
  Worker to process Oscar ceremony data and queue movie creation jobs.
  
  This worker:
  1. Takes a ceremony record
  2. Processes each nominee
  3. Checks if the movie exists (by IMDb ID)
  4. Queues TMDbDetailsWorker if movie doesn't exist
  5. Creates/updates nomination records
  """
  
  use Oban.Worker,
    queue: :oscar_imports,
    max_attempts: 3,
    priority: 2
  
  alias Cinegraph.Repo
  alias Cinegraph.Cultural.{OscarCeremony, OscarCategory, OscarNomination}
  alias Cinegraph.Workers.TMDbDetailsWorker
  alias Cinegraph.Movies.{Movie, Person}
  alias Cinegraph.Services.TMDb
  import Ecto.Query
  require Logger
  
  @person_tracking_categories [
    "Actor in a Leading Role",
    "Actor in a Supporting Role", 
    "Actress in a Leading Role",
    "Actress in a Supporting Role",
    "Directing"
  ]
  
  @major_categories @person_tracking_categories ++ ["Best Picture"]
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ceremony_id" => ceremony_id}}) do
    case Repo.get(OscarCeremony, ceremony_id) do
      nil ->
        Logger.error("Ceremony #{ceremony_id} not found")
        {:error, :ceremony_not_found}
      ceremony ->
        Logger.info("Processing Oscar ceremony #{ceremony.year}")
        
        # First ensure ceremony is enhanced with IMDb data
        ceremony = ensure_imdb_enhancement(ceremony)
        
        # Process each category
        categories = ceremony.data["categories"] || []
        Logger.info("Processing #{length(categories)} categories for ceremony #{ceremony.year}")
        
        results = categories
        |> Enum.with_index()
        |> Enum.flat_map(fn {category, index} ->
          Logger.info("Processing category #{index + 1}/#{length(categories)}: #{category["category"] || "Unknown"}")
          category_results = process_category(category, ceremony)
          Logger.info("Category #{index + 1} processed with #{length(category_results)} results")
          category_results
        end)
        
        Logger.info("Total results from all categories: #{length(results)}")
        summary = summarize_results(results)
        Logger.info("Oscar discovery complete for #{ceremony.year}: #{inspect(summary)}")
        
        :ok
    end
  end
  
  defp ensure_imdb_enhancement(ceremony) do
    if ceremony.data["imdb_matched"] do
      ceremony
    else
      Logger.info("Enhancing ceremony #{ceremony.year} with IMDb data...")
      
      case Cinegraph.Scrapers.ImdbOscarScraper.enhance_ceremony_with_imdb(ceremony) do
        {:ok, enhanced_data} ->
          changeset = OscarCeremony.changeset(ceremony, %{data: enhanced_data})
          
          case Repo.update(changeset) do
            {:ok, updated} -> updated
            {:error, _} -> ceremony
          end
          
        {:error, _} ->
          Logger.error("Failed to enhance ceremony #{ceremony.year}")
          ceremony
      end
    end
  end
  
  defp process_category(category, ceremony) do
    category_name = category["category"]
    nominees = category["nominees"] || []
    
    Logger.info("Processing category '#{category_name}' with #{length(nominees)} nominees for ceremony #{ceremony.year}")
    
    # Ensure the category exists before processing nominees
    ensure_category_exists(category_name)
    
    results = nominees
    |> Enum.with_index()
    |> Enum.map(fn {nominee, index} ->
      Logger.info("Processing nominee #{index + 1}/#{length(nominees)} in #{category_name}: #{nominee["film"] || "Unknown"}")
      result = process_nominee(nominee, category_name, ceremony)
      Logger.info("Nominee #{index + 1} result: #{inspect(result)}")
      result
    end)
    
    Logger.info("Completed processing category '#{category_name}' - Results summary: #{inspect(results)}")
    results
  end
  
  defp process_nominee(nominee, category_name, ceremony) do
    film_imdb_id = nominee["film_imdb_id"]
    film_title = nominee["film"]
    
    Logger.info("Processing nominee: #{film_title} (IMDb: #{film_imdb_id}) in #{category_name} for #{ceremony.year}")
    
    # Skip song categories - these aren't films
    if String.contains?(category_name, ["Music (Original Song)", "Original Song"]) do
      Logger.info("Skipping '#{film_title}' - song category, not a film")
      %{action: :skipped, reason: :song_category, title: film_title}
    else
      cond do
        # Has IMDb ID - process normally
        !is_nil(film_imdb_id) ->
          Logger.info("Processing movie nominee: #{film_title} (#{film_imdb_id})")
          result = process_movie_nominee(film_imdb_id, nominee, category_name, ceremony)
          Logger.info("Movie nominee processing result for #{film_title}: #{inspect(result)}")
          result
        
        # No IMDb ID - try fuzzy search fallback
        is_nil(film_imdb_id) ->
          Logger.info("No IMDb ID for #{film_title} - attempting fuzzy search fallback")
          attempt_fuzzy_search_fallback(nominee, category_name, ceremony)
      end
    end
  end
  
  defp process_movie_nominee(imdb_id, nominee, category_name, ceremony) do
    film_title = nominee["film"]
    Logger.info("Checking if movie exists for IMDb ID #{imdb_id} (#{film_title})")
    
    # Check if movie exists by IMDb ID
    existing_movie = Repo.get_by(Movie, imdb_id: imdb_id)
    
    if existing_movie do
      # Movie exists - just create/update nomination record
      Logger.info("Movie #{film_title} (#{imdb_id}) already exists in database (ID: #{existing_movie.id})")
      create_nomination_record(existing_movie, nominee, category_name, ceremony)
      %{action: :updated, movie_id: existing_movie.id, title: existing_movie.title}
    else
      # Movie doesn't exist - queue creation via TMDb
      Logger.info("Movie #{film_title} (#{imdb_id}) does not exist - queuing for creation")
      result = queue_movie_creation(imdb_id, nominee, category_name, ceremony)
      Logger.info("Queue creation result for #{film_title} (#{imdb_id}): #{inspect(result)}")
      result
    end
  end
  
  defp queue_movie_creation(imdb_id, nominee, category_name, ceremony) do
    film_title = nominee["film"]
    Logger.info("Creating job args for #{film_title} (#{imdb_id})")
    
    # Queue TMDbDetailsWorker with IMDb ID
    # The details worker will handle the lookup and creation
    job_args = %{
      "imdb_id" => imdb_id,
      "source" => "oscar_import",
      "metadata" => %{
        "ceremony_year" => ceremony.year,
        "category" => category_name,
        "film_title" => nominee["film"],
        "winner" => nominee["winner"] || false
      }
    }
    
    Logger.info("Job args created for #{film_title}: #{inspect(job_args)}")
    
    Logger.info("Creating TMDbDetailsWorker job for #{film_title} (#{imdb_id})")
    job_result = job_args
         |> TMDbDetailsWorker.new()
         |> Oban.insert()
    
    Logger.info("Oban.insert result for #{film_title}: #{inspect(job_result)}")
    
    case job_result do
      {:ok, job} ->
        Logger.info("Successfully queued movie creation for #{film_title} (#{imdb_id}) - Job ID: #{job.id}")
        
        # We'll create the nomination record later when the movie exists
        # For now, track that we queued it
        %{action: :queued, imdb_id: imdb_id, title: film_title, job_id: job.id}
        
      {:error, reason} ->
        Logger.error("Failed to queue movie creation for #{film_title} (#{imdb_id}): #{inspect(reason)}")
        %{action: :error, reason: reason, title: film_title}
    end
  end
  
  defp create_nomination_record(movie, nominee, category_name, ceremony) do
    # Find the category
    category = Repo.get_by(OscarCategory, name: category_name)
    
    if category do
      # Check if nomination already exists
      # Use a query to handle multiple results gracefully
      existing_count = from(n in OscarNomination,
        where: n.ceremony_id == ^ceremony.id and
               n.category_id == ^category.id and
               n.movie_id == ^movie.id,
        select: count(n.id)
      ) |> Repo.one()
      
      if existing_count > 0 do
        Logger.debug("Nomination already exists for #{movie.title} in #{category_name} (found #{existing_count})")
      else
        # Determine if we should track person (only for actor/director categories)
        person_id = if category.tracks_person do
          find_or_create_person(nominee)
        else
          nil
        end
        
        # Create the nomination
        attrs = %{
          ceremony_id: ceremony.id,
          category_id: category.id,
          movie_id: movie.id,
          person_id: person_id,
          won: nominee["winner"] || false,
          details: %{
            "nominee_names" => nominee["name"],
            "person_imdb_ids" => nominee["person_imdb_ids"] || []
          }
        }
        
        case %OscarNomination{}
             |> OscarNomination.changeset(attrs)
             |> Repo.insert() do
          {:ok, _} ->
            Logger.info("Created nomination for #{movie.title} in #{category_name}")
          {:error, changeset} ->
            Logger.error("Failed to create nomination: #{inspect(changeset.errors)}")
        end
      end
    else
      Logger.error("Category not found: #{category_name}")
    end
  end
  
  defp find_or_create_person(nominee) do
    person_imdb_ids = nominee["person_imdb_ids"] || []
    person_name = nominee["name"]
    
    cond do
      # If we have an IMDb ID, try to find by that
      length(person_imdb_ids) == 1 ->
        imdb_id = hd(person_imdb_ids)
        case Repo.get_by(Person, imdb_id: imdb_id) do
          nil -> 
            # Skip person creation for now - we don't have TMDb ID
            # Person will be created later when TMDb data is processed
            Logger.debug("Skipping person creation for #{person_name} (#{imdb_id}) - no TMDb data")
            nil
            
          person -> 
            person.id
        end
      
      # Otherwise skip person tracking for now
      true ->
        nil
    end
  end
  
  defp ensure_category_exists(category_name) do
    case Repo.get_by(OscarCategory, name: category_name) do
      nil ->
        # Category doesn't exist - create it dynamically
        Logger.info("Creating new Oscar category: #{category_name}")
        
        attrs = %{
          name: category_name,
          category_type: classify_category_type(category_name),
          is_major: is_major_category?(category_name),
          tracks_person: tracks_person?(category_name)
        }
        
        case %OscarCategory{}
             |> OscarCategory.changeset(attrs)
             |> Repo.insert() do
          {:ok, category} ->
            Logger.info("Successfully created category: #{category_name}")
            category
          {:error, changeset} ->
            Logger.error("Failed to create category #{category_name}: #{inspect(changeset.errors)}")
            nil
        end
        
      category ->
        # Category already exists
        category
    end
  end
  
  defp classify_category_type(category_name) do
    cond do
      String.contains?(category_name, ["Actor", "Actress", "Directing", "Writing", "Screenplay"]) -> "person"
      String.contains?(category_name, ["Technical", "Sound", "Visual Effects", "Cinematography", "Editing", "Makeup", "Music", "Costume"]) -> "technical"
      true -> "film"
    end
  end
  
  defp is_major_category?(category_name) do
    category_name in @major_categories
  end
  
  defp tracks_person?(category_name) do
    category_name in @person_tracking_categories or
      String.contains?(category_name, ["Writing", "Screenplay"])
  end

  defp summarize_results(results) do
    Enum.reduce(results, %{
      updated: 0,
      queued: 0,
      skipped: 0,
      errors: 0,
      fuzzy_matched: 0
    }, fn result, acc ->
      case result.action do
        :updated -> %{acc | updated: acc.updated + 1}
        :queued -> %{acc | queued: acc.queued + 1}
        :skipped -> %{acc | skipped: acc.skipped + 1}
        :error -> %{acc | errors: acc.errors + 1}
        :fuzzy_matched -> %{acc | fuzzy_matched: acc.fuzzy_matched + 1}
      end
    end)
  end
  
  defp attempt_fuzzy_search_fallback(nominee, category_name, ceremony) do
    film_title = nominee["film"]
    
    # Handle country names in International Feature Film category
    actual_title = if is_country_name?(film_title) and category_name == "International Feature Film" do
      mapped_title = map_country_to_film_title(film_title, ceremony.year)
      if mapped_title do
        Logger.info("Mapped country '#{film_title}' to film title '#{mapped_title}'")
        mapped_title
      else
        Logger.info("No film mapping found for country '#{film_title}' in year #{ceremony.year}")
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
          create_nomination_record(movie, nominee, category_name, ceremony)
          %{action: :updated, movie_id: movie.id, title: movie.title, fuzzy_matched_local: true}
          
        {:error, :not_found} ->
          # Not in database, try TMDb fuzzy search
          case fuzzy_search_movie(actual_title, ceremony.year, category_name) do
            {:ok, tmdb_id} ->
              Logger.info("Fuzzy search successful for '#{actual_title}' - found TMDb ID: #{tmdb_id}")
              # Queue the movie creation with TMDb ID (not IMDb ID)
              queue_movie_creation_by_tmdb(tmdb_id, nominee, category_name, ceremony)
              
            {:error, reason} ->
              Logger.warning("Fuzzy search failed for '#{actual_title}': #{reason}")
              %{action: :skipped, reason: :fuzzy_search_failed, title: actual_title, details: reason}
          end
      end
    end
  end
  
  defp find_existing_movie_by_title(title, year) do
    # Clean the title for better matching
    clean_title = clean_title_for_search(title)
    
    # Query for movies with similar titles
    query = from m in Movie,
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
    year_ok = case extract_year(release_date || "") do
      {:ok, year} -> abs(year - target_year) <= 2
      _ -> true  # No release date, can't verify
    end
    
    title_similarity > 0.85 && year_ok
  end
  
  defp find_best_local_match(movies, title, year) do
    # Score movies and find best match
    scored = movies
    |> Enum.map(fn movie ->
      title_score = calculate_title_similarity(movie.title, title)
      year_score = case extract_year(movie.release_date || "") do
        {:ok, movie_year} -> 
          case abs(movie_year - year) do
            0 -> 1.0
            1 -> 0.8
            2 -> 0.5
            _ -> 0.0
          end
        _ -> 0.5
      end
      
      total_score = (title_score * 0.7) + (year_score * 0.3)
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
    Logger.info("Performing fuzzy search for '#{title}' (year: #{year}, category: #{category_name})")
    
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
    scored_results = results
    |> Enum.map(fn movie ->
      {movie, calculate_match_score(movie, original_title, target_year, category_name)}
    end)
    |> Enum.filter(fn {_movie, score} -> score > 0.85 end)  # 85% minimum threshold
    |> Enum.sort_by(fn {_movie, score} -> score end, :desc)
    
    case scored_results do
      [{movie, score} | _] when score > 0.9 ->
        Logger.info("Found high-confidence match: '#{movie["title"]}' (#{movie["release_date"]}) with score #{Float.round(score, 3)}")
        {:ok, movie}
        
      [{movie, score} | rest] when score > 0.85 ->
        # If multiple results above threshold, only accept if clear winner
        case rest do
          [] ->
            Logger.info("Found good match: '#{movie["title"]}' (#{movie["release_date"]}) with score #{Float.round(score, 3)}")
            {:ok, movie}
          [{_, second_score} | _] when score - second_score > 0.1 ->
            Logger.info("Found clear best match: '#{movie["title"]}' (#{movie["release_date"]}) with score #{Float.round(score, 3)}")
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
      String.contains?(category_name, "International") -> 0.9  # Can't validate well
      true -> 0.8  # Default score for other categories
    end
  end
  
  defp normalize_title(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")  # Remove punctuation
    |> String.trim()
  end
  
  defp clean_title_for_search(title) do
    # Remove common suffixes that might interfere with search
    title
    |> String.replace(~r/\s*:\s*.*$/, "")  # Remove subtitles after colon
    |> String.replace(~r/\s*-\s*.*$/, "")   # Remove subtitles after dash
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
      "Denmark", "Norway", "Sweden", "Finland", "Iceland",
      "France", "Germany", "Italy", "Spain", "Portugal",
      "Japan", "China", "South Korea", "India", "Thailand",
      "Mexico", "Brazil", "Argentina", "Chile", "Colombia",
      "Russia", "Poland", "Hungary", "Romania", "Turkey",
      "Egypt", "Morocco", "Tunisia", "Algeria", "South Africa",
      "Australia", "New Zealand", "Canada", "United Kingdom",
      "Bosnia and Herzegovina", "Czech Republic", "Hong Kong"
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
  
  defp queue_movie_creation_by_tmdb(tmdb_id, nominee, category_name, ceremony) do
    film_title = nominee["film"]
    Logger.info("Creating job args for #{film_title} (TMDb ID: #{tmdb_id}) via fuzzy match")
    
    # Queue TMDbDetailsWorker with TMDb ID directly
    job_args = %{
      "tmdb_id" => tmdb_id,
      "source" => "oscar_import",
      "fuzzy_matched" => true,
      "metadata" => %{
        "ceremony_year" => ceremony.year,
        "category" => category_name,
        "film_title" => nominee["film"],
        "winner" => nominee["winner"] || false,
        "original_search_title" => nominee["film"]
      }
    }
    
    Logger.info("Job args created for fuzzy match #{film_title}: #{inspect(job_args)}")
    
    Logger.info("Creating TMDbDetailsWorker job for fuzzy matched #{film_title} (TMDb ID: #{tmdb_id})")
    job_result = job_args
         |> TMDbDetailsWorker.new()
         |> Oban.insert()
    
    Logger.info("Oban.insert result for fuzzy matched #{film_title}: #{inspect(job_result)}")
    
    case job_result do
      {:ok, job} ->
        Logger.info("Successfully queued fuzzy matched movie creation for #{film_title} (TMDb ID: #{tmdb_id}) - Job ID: #{job.id}")
        %{action: :fuzzy_matched, tmdb_id: tmdb_id, title: film_title, job_id: job.id}
        
      {:error, reason} ->
        Logger.error("Failed to queue fuzzy matched movie creation for #{film_title} (TMDb ID: #{tmdb_id}): #{inspect(reason)}")
        %{action: :error, reason: reason, title: film_title}
    end
  end
end