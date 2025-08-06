defmodule Cinegraph.Workers.TMDbDetailsWorker do
  @moduledoc """
  Simplified details worker that doesn't use import progress tracking.
  """

  use Oban.Worker,
    queue: :tmdb_details,
    max_attempts: 5,
    unique: [fields: [:args], keys: [:tmdb_id, :imdb_id, :source_key], period: 300]

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
  def perform(%Oban.Job{args: %{"imdb_id" => imdb_id} = args} = job) do
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
            process_tmdb_movie(tmdb_id, args, job)

          {:ok, %{"movie_results" => []}} ->
            Logger.warning("No TMDb match for IMDb ID #{imdb_id}")
            handle_no_tmdb_match(imdb_id, args, job)

          {:error, reason} ->
            Logger.error("TMDb API error for IMDb ID #{imdb_id}: #{inspect(reason)}")
            {:error, reason}
        end

      existing_movie ->
        Logger.info("Movie already exists for IMDb ID #{imdb_id}: #{existing_movie.title}")
        # Still need to add canonical sources if this is a canonical import
        if args["source"] == "canonical_import" && args["canonical_sources"] do
          canonical_sources = args["canonical_sources"]

          Enum.each(canonical_sources, fn {source_key, canonical_data} ->
            Logger.info(
              "Adding canonical source #{source_key} to existing movie #{existing_movie.id}"
            )

            mark_movie_canonical(existing_movie.tmdb_id, source_key, canonical_data)
          end)
        end

        handle_post_creation_tasks(existing_movie.tmdb_id, args)
    end
  end

  def perform(%Oban.Job{args: %{"tmdb_id" => tmdb_id}} = job) do
    Logger.info("Processing movie details for TMDb ID #{tmdb_id}")
    process_tmdb_movie(tmdb_id, job.args, job)
  end

  defp process_tmdb_movie(tmdb_id, args, job) do
    # Skip if already exists
    if Movies.movie_exists?(tmdb_id) do
      Logger.info("Movie #{tmdb_id} already exists, skipping creation")
      # Still need to add canonical sources if this is a canonical import
      if args["source"] == "canonical_import" && args["canonical_sources"] do
        canonical_sources = args["canonical_sources"]

        Enum.each(canonical_sources, fn {source_key, canonical_data} ->
          Logger.info(
            "Adding canonical source #{source_key} to existing movie with TMDb ID #{tmdb_id}"
          )

          mark_movie_canonical(tmdb_id, source_key, canonical_data)
        end)
      end

      handle_post_creation_tasks(tmdb_id, args)
    else
      # First, get basic movie info to evaluate quality
      case TMDb.get_movie(tmdb_id) do
        {:ok, movie_data} ->
          # Evaluate movie quality
          case QualityFilter.evaluate_movie(movie_data) do
            {:full_import, met_criteria} ->
              Logger.info(
                "Movie #{movie_data["title"]} meets quality criteria: #{inspect(met_criteria)}"
              )

              result = perform_full_import(tmdb_id, movie_data, job)
              handle_post_creation_tasks(tmdb_id, args)
              result

            {:soft_import, failed_criteria} ->
              Logger.info(
                "Movie #{movie_data["title"]} failed quality criteria: #{inspect(failed_criteria)}"
              )

              result = perform_soft_import(tmdb_id, movie_data, failed_criteria, job)
              handle_post_creation_tasks(tmdb_id, args)
              result
          end

        {:error, reason} ->
          Logger.error("Failed to fetch movie #{tmdb_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp perform_full_import(tmdb_id, _basic_data, job) do
    # Fetch and store comprehensive movie data with all relationships
    # Use Task.async with timeout to prevent stuck jobs
    task =
      Task.async(fn ->
        Movies.fetch_and_store_movie_comprehensive(tmdb_id)
      end)

    # Wait up to 90 seconds for the comprehensive fetch
    case Task.yield(task, 90_000) || Task.shutdown(task) do
      {:ok, {:ok, movie}} ->
        Logger.info("Successfully fully imported movie: #{movie.title} (#{movie.tmdb_id})")

        # Queue OMDb enrichment if we have an IMDb ID
        if movie.imdb_id do
          queue_omdb_enrichment(movie)
        else
          Logger.info("No IMDb ID for movie #{movie.title}, skipping OMDb enrichment")
        end

        # Queue collaboration building
        queue_collaboration_building(movie)

        # Update job metadata
        update_job_meta(job, %{
          status: "imported",
          import_type: "full",
          movie_id: movie.id,
          movie_title: movie.title,
          imdb_id: movie.imdb_id,
          tmdb_id: movie.tmdb_id,
          enrichment_queued: not is_nil(movie.imdb_id),
          collaboration_queued: true
        })

        :ok

      {:ok, {:error, reason}} ->
        Logger.error("Failed to import movie #{tmdb_id}: #{inspect(reason)}")
        {:error, reason}

      nil ->
        Logger.error("Timeout importing movie #{tmdb_id} - took longer than 90 seconds")
        {:error, :timeout}
    end
  end

  defp perform_soft_import(tmdb_id, movie_data, failed_criteria, job) do
    # Create minimal movie record with basic data only
    case Movies.create_soft_import_movie(movie_data) do
      {:ok, movie} ->
        Logger.info("Successfully soft imported movie: #{movie.title} (#{movie.tmdb_id})")

        # Update job metadata with soft import details
        update_job_meta(job, %{
          status: "imported",
          import_type: "soft",
          movie_id: movie.id,
          movie_title: movie.title,
          tmdb_id: movie.tmdb_id,
          quality_criteria_failed: failed_criteria,
          reason: "quality_criteria"
        })

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

  defp handle_post_creation_tasks(tmdb_id, args) do
    Logger.info("Post-creation tasks for TMDb ID #{tmdb_id}, args: #{inspect(args)}")

    # Handle any post-creation tasks for movies
    cond do
      # Oscar import - nominations are handled by OscarImporter, not TMDbDetailsWorker
      args["source"] == "oscar_import" && args["metadata"] ->
        Logger.info(
          "Oscar import detected - skipping nomination creation (handled by OscarImporter)"
        )

        :ok

      # Canonical import - mark as canonical source  
      args["source"] == "canonical_import" && args["canonical_sources"] ->
        # canonical_sources is a map with source_key => canonical_data
        canonical_sources = args["canonical_sources"]

        # Process each canonical source (usually just one)
        Enum.each(canonical_sources, fn {source_key, canonical_data} ->
          Logger.info("Marking movie with TMDb ID #{tmdb_id} as canonical in #{source_key}")
          mark_movie_canonical(tmdb_id, source_key, canonical_data)
        end)

        :ok

      true ->
        # No special post-processing needed
        Logger.debug(
          "No post-processing needed for TMDb ID #{tmdb_id}, source: #{args["source"]}"
        )

        :ok
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

          Logger.info(
            "Current canonical sources for #{movie.title}: #{inspect(Map.keys(current_sources))}"
          )

          if Map.has_key?(current_sources, source_key) do
            Logger.warning(
              "Movie #{movie.title} already has canonical source #{source_key}, updating..."
            )
          end

          updated_sources = Map.put(current_sources, source_key, canonical_data)

          Logger.info(
            "Updating movie #{movie.id} with canonical source #{source_key}: #{inspect(canonical_data)}"
          )

          case movie
               |> Movies.Movie.changeset(%{canonical_sources: updated_sources})
               |> Repo.update() do
            {:ok, updated_movie} ->
              Logger.info("Successfully marked #{movie.title} as canonical in #{source_key}")
              # Verify the update
              final_sources = updated_movie.canonical_sources || %{}

              if Map.has_key?(final_sources, source_key) do
                Logger.info("Verified: #{source_key} is now in canonical_sources")
              else
                Logger.error("ERROR: #{source_key} was NOT added to canonical_sources!")
              end

              :ok

            {:error, changeset} ->
              Logger.error(
                "Failed to mark #{movie.title} as canonical: #{inspect(changeset.errors)}"
              )

              # Queue a retry
              Logger.info("Queueing retry for canonical source addition")

              case Cinegraph.Workers.CanonicalRetryWorker.queue_retry(
                     movie.id,
                     source_key,
                     canonical_data
                   ) do
                {:ok, _job} ->
                  Logger.info("Retry queued successfully")

                {:error, reason} ->
                  Logger.error("Failed to queue retry: #{inspect(reason)}")
              end

              {:error, changeset}
          end
      end
    end)
  end

  defp handle_no_tmdb_match(imdb_id, args, job) do
    # Extract relevant information based on source
    {title, year, source_key, metadata} =
      case args["source"] do
        "oscar_import" ->
          if is_map(args["metadata"]) do
            metadata = args["metadata"]
            {metadata["film_title"], nil, "oscar", metadata}
          else
            {"Unknown", nil, "oscar", %{}}
          end

        "canonical_import" ->
          if is_map(args["canonical_sources"]) do
            # Get the first canonical source (there should only be one)
            {source_key, canonical_data} =
              args["canonical_sources"] |> Map.to_list() |> List.first()

            scraped_title = canonical_data["scraped_title"] || "Unknown"
            scraped_year = canonical_data["scraped_year"]
            {scraped_title, scraped_year, source_key, canonical_data}
          else
            {"Unknown", nil, "canonical", %{}}
          end

        "festival_import" ->
          # Handle festival import source - extract title and year from args
          title = args["title"] || "Unknown"
          year = args["year"]
          source_key = args["source_key"] || "festival_import"
          metadata = Map.take(args, ["title", "year", "source_key"])
          {title, year, source_key, metadata}

        source_type ->
          # Log unhandled source types for debugging
          Logger.warning(
            "Unhandled source type '#{source_type}' in TMDbDetailsWorker, using fallback extraction"
          )

          title = args["title"] || "Unknown"
          year = args["year"]
          {title, year, source_type || "unknown", %{}}
      end

    # Update job metadata with failure details
    update_job_meta(job, %{
      status: "failed",
      failure_reason: "no_tmdb_match",
      imdb_id: imdb_id,
      title: title,
      year: year,
      source: args["source"] || "unknown",
      source_key: source_key,
      metadata: metadata
    })

    Logger.warning("Movie '#{title}' (#{imdb_id}) not found in TMDb")
    {:error, "Movie '#{title}' (#{imdb_id}) not found in TMDb"}
  end

  defp update_job_meta(job, meta) do
    import Ecto.Query

    from(j in "oban_jobs",
      where: j.id == ^job.id,
      update: [set: [meta: ^meta]]
    )
    |> Repo.update_all([])
  rescue
    error ->
      Logger.warning("Failed to update job meta: #{inspect(error)}")
  end
end
