defmodule Cinegraph.Workers.TMDbDetailsWorker do
  @moduledoc """
  Simplified details worker that doesn't use import progress tracking.
  """

  use Oban.Worker,
    queue: :tmdb,
    max_attempts: 5,
    unique: [fields: [:args], keys: [:tmdb_id, :imdb_id, :source_key], period: 300]

  alias Cinegraph.{Freshness, Movies, Repo}
  alias Cinegraph.Workers.OMDbEnrichmentWorker
  alias Cinegraph.Imports.QualityFilter
  alias Cinegraph.Services.TMDb
  alias Cinegraph.Services.TMDb.FallbackSearch
  require Logger

  @impl Oban.Worker
  # Handle nested args format (legacy from broken OscarDiscoveryWorker)
  def perform(%Oban.Job{args: %{"args" => nested_args}} = job) do
    # Extract the nested args and call the correct function
    perform(%Oban.Job{job | args: nested_args})
  end

  # Handle IMDb ID lookup (e.g., from Oscar import)
  def perform(%Oban.Job{args: %{"imdb_id" => imdb_id} = args} = job) do
    # Route all Repo.replica() calls in this process through the dedicated worker pool
    # so this job does not compete with web requests for Repo.Replica connections. (#1007)
    Cinegraph.Repo.route_to_worker()
    Logger.info("Processing movie details for IMDb ID #{imdb_id}")

    # Use Movies.get_movie_by_imdb_id/1 (LIMIT 1) instead of Repo.get_by to avoid
    # Ecto.MultipleResultsError when duplicate imdb_id rows exist (#1013).
    case Movies.get_movie_by_imdb_id(imdb_id) do
      nil ->
        # Use fallback search to find movie by IMDb ID with progressive strategies
        # For festival imports, title and year are in metadata
        title = get_in(args, ["metadata", "film_title"]) || Map.get(args, "title", "")
        year = get_in(args, ["metadata", "film_year"]) || Map.get(args, "year")

        case FallbackSearch.find_movie(imdb_id, title, year) do
          {:ok, result} ->
            # Found a match using fallback search
            tmdb_id = result.movie["id"]

            Logger.info(
              "Found TMDb ID #{tmdb_id} for IMDb ID #{imdb_id} using #{result.strategy} (confidence: #{result.confidence})"
            )

            # Process the movie creation directly
            process_tmdb_movie(tmdb_id, args, job)

          {:error, :not_found} ->
            Logger.warning(
              "No TMDb match for IMDb ID #{imdb_id} after exhausting all fallback strategies"
            )

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
    # Route all Repo.replica() calls in this process through the dedicated worker pool
    # so this job does not compete with web requests for Repo.Replica connections. (#1007)
    Cinegraph.Repo.route_to_worker()
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
    case Movies.fetch_and_store_movie_comprehensive(tmdb_id) do
      {:ok, movie} ->
        Logger.info("Successfully fully imported movie: #{movie.title} (#{movie.tmdb_id})")
        # #1096 Phase B: first freshness signal for TMDb details (previously one-shot,
        # grade-D in the §4b provenance audit).
        Freshness.touch("movie", movie.id, "tmdb_details", :ok, base_date: movie.release_date)
        # imdb_id rides the same response (#1109) — :ok if present, else source-absent.
        Freshness.touch("movie", movie.id, "imdb_id", imdb_status(movie.imdb_id),
          base_date: movie.release_date
        )

        enrichment_queued =
          if movie.imdb_id do
            case queue_omdb_enrichment(movie) do
              :ok ->
                true

              {:error, _reason} ->
                false
            end
          else
            Logger.info("No IMDb ID for movie #{movie.title}, skipping OMDb enrichment")
            false
          end

        # Update job metadata
        update_job_meta(job, %{
          status: "imported",
          import_type: "full",
          movie_id: movie.id,
          movie_title: movie.title,
          imdb_id: movie.imdb_id,
          tmdb_id: movie.tmdb_id,
          enrichment_queued: enrichment_queued,
          collaboration_rebuild_requested: true
        })

        :ok

      {:error, reason} ->
        Logger.error("Failed to import movie #{tmdb_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp perform_soft_import(tmdb_id, movie_data, failed_criteria, job) do
    # Create minimal movie record with basic data only
    case Movies.create_soft_import_movie(movie_data) do
      {:ok, movie} ->
        Logger.info("Successfully soft imported movie: #{movie.title} (#{movie.tmdb_id})")
        Freshness.touch("movie", movie.id, "tmdb_details", :ok, base_date: movie.release_date)

        Freshness.touch("movie", movie.id, "imdb_id", imdb_status(movie.imdb_id),
          base_date: movie.release_date
        )

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

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(90)

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
        Logger.error("Failed to queue OMDb enrichment for #{movie.title}: #{inspect(reason)}")
        {:error, reason}
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
          # Handle festival import source - extract title and year from metadata first, then args
          title = get_in(args, ["metadata", "film_title"]) || args["title"] || "Unknown"
          year = get_in(args, ["metadata", "film_year"]) || args["year"]
          source_key = args["source_key"] || "festival_import"
          metadata = args["metadata"] || Map.take(args, ["title", "year", "source_key"])
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

    Logger.warning(
      "Movie '#{title}' (#{imdb_id}) not found in TMDb after all fallback strategies"
    )

    # {:cancel, ...} tells Oban to discard the job immediately (no retries), which is correct
    # here — if every TMDb strategy failed, retrying won't find the movie (#1014).
    {:cancel, "no_tmdb_match — #{title} (#{imdb_id})"}
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

  # imdb_id source-absent classification (#1109): present → :ok, null/blank → :empty.
  defp imdb_status(imdb_id) when is_binary(imdb_id),
    do: if(String.trim(imdb_id) != "", do: :ok, else: :empty)

  defp imdb_status(_), do: :empty
end
