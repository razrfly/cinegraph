defmodule Cinegraph.Workers.TMDbDetailsWorker do
  @moduledoc """
  Simplified details worker that doesn't use import progress tracking.
  """
  
  use Oban.Worker, 
    queue: :tmdb_details,
    max_attempts: 5,
    unique: [fields: [:args], keys: [:tmdb_id], period: 300]
    
  alias Cinegraph.{Repo, Movies}
  alias Cinegraph.Workers.{OMDbEnrichmentWorker, CollaborationWorker}
  alias Cinegraph.Imports.QualityFilter
  alias Cinegraph.Services.TMDb
  require Logger
  
  @impl Oban.Worker
  # Handle nested args format (legacy from broken OscarDiscoveryWorker)
  def perform(%Oban.Job{args: %{"args" => nested_args}} = job) do
    # Extract the nested args and call the correct function
    perform(%Oban.Job{job | args: nested_args})
  end
  
  # Handle IMDb ID lookup (e.g., from Oscar import)
  def perform(%Oban.Job{args: %{"imdb_id" => imdb_id} = args}) do
    Logger.info("Processing movie details for IMDb ID #{imdb_id}")
    
    # Check if movie already exists by IMDb ID
    case Repo.get_by(Movies.Movie, imdb_id: imdb_id) do
      nil ->
        # Look up TMDb ID from IMDb ID
        case TMDb.find_by_imdb_id(imdb_id) do
          {:ok, %{"movie_results" => [movie_data | _]}} ->
            # Found a match, process with TMDb ID but keep original args
            tmdb_id = movie_data["id"]
            Logger.info("Found TMDb ID #{tmdb_id} for IMDb ID #{imdb_id}")
            
            # Process the movie creation directly instead of recursive call
            process_tmdb_movie(tmdb_id, args)
            
          {:ok, %{"movie_results" => []}} ->
            Logger.warning("No TMDb match for IMDb ID #{imdb_id}")
            handle_no_tmdb_match(imdb_id, args)
            
          {:error, reason} ->
            Logger.error("TMDb API error for IMDb ID #{imdb_id}: #{inspect(reason)}")
            {:error, reason}
        end
        
      existing_movie ->
        Logger.info("Movie already exists for IMDb ID #{imdb_id}: #{existing_movie.title}")
        handle_post_creation_tasks(existing_movie.tmdb_id, args)
    end
  end
  
  def perform(%Oban.Job{args: %{"tmdb_id" => tmdb_id}} = job) do
    Logger.info("Processing movie details for TMDb ID #{tmdb_id}")
    process_tmdb_movie(tmdb_id, job.args)
  end
  
  defp process_tmdb_movie(tmdb_id, args) do
    # Skip if already exists
    if Movies.movie_exists?(tmdb_id) do
      Logger.info("Movie #{tmdb_id} already exists, skipping")
      handle_post_creation_tasks(tmdb_id, args)
    else
      # First, get basic movie info to evaluate quality
      case TMDb.get_movie(tmdb_id) do
        {:ok, movie_data} ->
          # Evaluate movie quality
          case QualityFilter.evaluate_movie(movie_data) do
            {:full_import, met_criteria} ->
              Logger.info("Movie #{movie_data["title"]} meets quality criteria: #{inspect(met_criteria)}")
              result = perform_full_import(tmdb_id, movie_data)
              handle_post_creation_tasks(tmdb_id, args)
              result
              
            {:soft_import, failed_criteria} ->
              Logger.info("Movie #{movie_data["title"]} failed quality criteria: #{inspect(failed_criteria)}")
              result = perform_soft_import(tmdb_id, movie_data)
              handle_post_creation_tasks(tmdb_id, args)
              result
          end
          
        {:error, reason} ->
          Logger.error("Failed to fetch movie #{tmdb_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
  
  defp perform_full_import(tmdb_id, _basic_data) do
    # Fetch and store comprehensive movie data with all relationships
    case Movies.fetch_and_store_movie_comprehensive(tmdb_id) do
      {:ok, movie} ->
        Logger.info("Successfully fully imported movie: #{movie.title} (#{movie.tmdb_id})")
        
        # Queue OMDb enrichment if we have an IMDb ID
        if movie.imdb_id do
          queue_omdb_enrichment(movie)
        else
          Logger.info("No IMDb ID for movie #{movie.title}, skipping OMDb enrichment")
        end
        
        # Queue collaboration building
        queue_collaboration_building(movie)
        
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to import movie #{tmdb_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp perform_soft_import(tmdb_id, movie_data) do
    # Create minimal movie record with basic data only
    case Movies.create_soft_import_movie(movie_data) do
      {:ok, movie} ->
        Logger.info("Successfully soft imported movie: #{movie.title} (#{movie.tmdb_id})")
        
        # Track the soft import for analytics
        track_soft_import(movie, movie_data)
        
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to soft import movie #{tmdb_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp queue_omdb_enrichment(movie) do
    %{
      "movie_id" => movie.id,
      "imdb_id" => movie.imdb_id,
      "title" => movie.title
    }
    |> OMDbEnrichmentWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _} ->
        Logger.info("Queued OMDb enrichment for #{movie.title}")
        :ok
      {:error, reason} ->
        Logger.error("Failed to queue OMDb enrichment: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp queue_collaboration_building(movie) do
    %{
      "movie_id" => movie.id
    }
    |> CollaborationWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _} ->
        Logger.info("Queued collaboration building for #{movie.title}")
        :ok
      {:error, reason} ->
        Logger.warning("Failed to queue collaboration building: #{inspect(reason)}")
        # Not critical, so we don't fail the import
        :ok
    end
  end
  
  defp track_soft_import(movie, movie_data) do
    # Track why this movie was soft imported
    analysis = QualityFilter.analyze_movie_failure(movie_data)
    
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:skipped_import, %Cinegraph.Imports.SkippedImport{
      tmdb_id: movie.tmdb_id,
      title: movie.title,
      reason: "quality_criteria",
      criteria_failed: analysis
    })
    |> Cinegraph.Repo.transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, _, _, _} -> 
        Logger.warning("Failed to track soft import for movie #{movie.id}")
        :ok
    end
  end
  
  defp handle_post_creation_tasks(tmdb_id, args) do
    Logger.info("Post-creation tasks for TMDb ID #{tmdb_id}, args: #{inspect(args)}")
    
    # Handle any post-creation tasks for movies
    cond do
      # Oscar import - create nominations
      args["source"] == "oscar_import" && args["metadata"] ->
        metadata = args["metadata"]
        Logger.info("Oscar import detected - metadata: #{inspect(metadata)}")
        
        if metadata["ceremony_year"] && metadata["category"] do
          Logger.info("Creating Oscar nomination for movie with TMDb ID #{tmdb_id}")
          result = create_oscar_nomination(tmdb_id, metadata)
          Logger.info("Oscar nomination creation result: #{inspect(result)}")
          result
        else
          Logger.error("Invalid Oscar metadata: missing ceremony_year or category. Metadata: #{inspect(metadata)}")
          {:error, :invalid_metadata}
        end
      
      # Canonical import - mark as canonical source  
      args["source"] == "canonical_import" && args["canonical_source"] ->
        canonical_source = args["canonical_source"]
        source_key = canonical_source["source_key"]
        metadata = canonical_source["metadata"]
        
        Logger.info("Marking movie with TMDb ID #{tmdb_id} as canonical in #{source_key}")
        mark_movie_canonical(tmdb_id, source_key, metadata)
      
      true ->
        # No special post-processing needed
        Logger.debug("No post-processing needed for TMDb ID #{tmdb_id}, source: #{args["source"]}")
        :ok
    end
  end
  
  defp create_oscar_nomination(tmdb_id, metadata) do
    Logger.info("Creating Oscar nomination for TMDb ID #{tmdb_id} with metadata: #{inspect(metadata)}")
    
    # Find the movie by TMDb ID
    case Repo.get_by(Movies.Movie, tmdb_id: tmdb_id) do
      nil ->
        Logger.error("Movie with TMDb ID #{tmdb_id} not found for Oscar nomination")
        {:error, :movie_not_found}
        
      movie ->
        Logger.info("Found movie: #{movie.title} (ID: #{movie.id})")
        
        # Find the ceremony and category
        ceremony_year = metadata["ceremony_year"]
        category_name = metadata["category"]
        
        Logger.info("Looking up ceremony year #{ceremony_year} and category '#{category_name}'")
        
        ceremony = Repo.get_by(Cinegraph.Cultural.OscarCeremony, year: ceremony_year)
        category = Repo.get_by(Cinegraph.Cultural.OscarCategory, name: category_name)
        
        Logger.info("Ceremony lookup result: #{inspect(ceremony)}")
        Logger.info("Category lookup result: #{inspect(category)}")
        
        if ceremony && category do
          Logger.info("Both ceremony and category found, creating nomination...")
          
          # Use insert with on_conflict option for idempotent operation
          attrs = %{
            ceremony_id: ceremony.id,
            category_id: category.id,
            movie_id: movie.id,
            person_id: nil,
            won: metadata["winner"] || false,
            details: %{
              "nominee_names" => metadata["film_title"],
              "person_imdb_ids" => []
            }
          }
          
          Logger.info("Nomination attributes: #{inspect(attrs)}")

          %Cinegraph.Cultural.OscarNomination{}
          |> Cinegraph.Cultural.OscarNomination.changeset(attrs)
          |> Repo.insert(
            on_conflict: :nothing,
            conflict_target: [:ceremony_id, :category_id, :movie_id]
          )
          |> case do
            {:ok, nomination} ->
              Logger.info("Successfully created Oscar nomination for #{movie.title} in #{category_name} (ID: #{nomination.id})")
              {:ok, nomination}
            {:error, changeset} ->
              Logger.error("Failed to create Oscar nomination: #{inspect(changeset.errors)}")
              {:error, changeset}
          end
        else
          ceremony_status = if ceremony, do: "found (ID: #{ceremony.id})", else: "NOT FOUND"
          category_status = if category, do: "found (ID: #{category.id})", else: "NOT FOUND"
          
          Logger.error("Lookup failed - Ceremony (#{ceremony_year}): #{ceremony_status}, Category (#{category_name}): #{category_status}")
          {:error, :lookup_failed}
        end
    end
  end
  
  defp mark_movie_canonical(tmdb_id, source_key, metadata) do
    # Use a transaction to handle concurrent updates safely
    canonical_data = Map.merge(%{"included" => true}, metadata)
    
    Repo.transaction(fn ->
      case Repo.get_by(Movies.Movie, tmdb_id: tmdb_id) do
        nil ->
          Logger.error("Movie with TMDb ID #{tmdb_id} not found for canonical marking")
          {:error, :not_found}
          
        movie ->
          current_sources = movie.canonical_sources || %{}
          updated_sources = Map.put(current_sources, source_key, canonical_data)
          
          case movie
               |> Movies.Movie.changeset(%{canonical_sources: updated_sources})
               |> Repo.update() do
            {:ok, _updated_movie} ->
              Logger.info("Successfully marked #{movie.title} as canonical in #{source_key}")
              :ok
              
            {:error, changeset} ->
              Logger.error("Failed to mark #{movie.title} as canonical: #{inspect(changeset.errors)}")
              {:error, changeset}
          end
      end
    end)
  end

  defp handle_no_tmdb_match(imdb_id, args) do
    # Extract relevant information based on source
    {title, year, source_key, metadata} = case args["source"] do
      "oscar_import" ->
        if is_map(args["metadata"]) do
          metadata = args["metadata"]
          {metadata["film_title"], nil, "oscar", metadata}
        else
          {"Unknown", nil, "oscar", %{}}
        end
        
      "canonical_import" ->
        if is_map(args["canonical_source"]) do
          canonical_source = args["canonical_source"]
          source_key = canonical_source["source_key"]
          metadata = canonical_source["metadata"] || %{}
          scraped_title = metadata["scraped_title"] || "Unknown"
          scraped_year = metadata["scraped_year"]
          {scraped_title, scraped_year, source_key, metadata}
        else
          {"Unknown", nil, "canonical", %{}}
        end
        
      _ ->
        {"Unknown", nil, args["source"] || "unknown", %{}}
    end
    
    # Create a skipped import record
    skipped_attrs = %{
      imdb_id: imdb_id,
      title: title,
      year: year,
      source: args["source"] || "unknown",
      source_key: source_key,
      reason: "no_tmdb_match",
      metadata: metadata
    }
    
    case Repo.insert(Cinegraph.Movies.FailedImdbLookup.changeset(%Cinegraph.Movies.FailedImdbLookup{}, skipped_attrs)) do
      {:ok, skipped_import} ->
        Logger.warning("Created skipped import record for '#{title}' (#{imdb_id}) - not found in TMDb")
        # Return an error so the job fails and is visible in Oban
        {:error, "Movie '#{title}' (#{imdb_id}) not found in TMDb - recorded as skipped import ##{skipped_import.id}"}
        
      {:error, changeset} ->
        # If it's a duplicate constraint error, still fail the job
        if Enum.any?(changeset.errors, fn {_field, {_msg, opts}} -> 
          Keyword.get(opts, :constraint) == :unique 
        end) do
          Logger.info("Skipped import already recorded for #{imdb_id}")
          {:error, "Movie '#{title}' (#{imdb_id}) not found in TMDb - already tracked as skipped"}
        else
          Logger.error("Failed to create skipped import record: #{inspect(changeset.errors)}")
          {:error, "Movie '#{title}' (#{imdb_id}) not found in TMDb and failed to track: #{inspect(changeset.errors)}"}
        end
    end
  end
end