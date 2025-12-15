defmodule Cinegraph.Workers.DataRepairWorker do
  @moduledoc """
  Background worker for repairing data quality issues.

  Currently supports:
  - missing_director_credits: Fetches credits from TMDb for movies missing director data
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    # Compare full args for uniqueness - allows batched jobs with different last_id
    unique: [period: 600]

  alias Cinegraph.{Repo, Movies, Repairs}
  alias Cinegraph.Services.TMDb
  require Logger

  @batch_size 50
  @rate_limit_delay 250

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"repair_type" => "missing_director_credits"} = args} = job) do
    last_id = args["last_id"] || 0
    batch_size = args["batch_size"] || @batch_size
    total = args["total"] || 0

    Logger.info("DataRepairWorker: Processing batch after id #{last_id}")

    # Get batch of movies missing directors
    movies = Repairs.get_movies_missing_directors(last_id, batch_size)

    if movies == [] do
      # Done!
      update_job_meta(job, %{
        status: "completed",
        processed: last_id,
        total: total,
        completed_at: DateTime.utc_now()
      })

      Logger.info("DataRepairWorker: Completed missing_director_credits repair")
      :ok
    else
      # Process this batch
      {success_count, error_count} = process_batch(movies)

      # Get the last ID processed
      new_last_id = List.last(movies).id

      # Update progress
      update_job_meta(job, %{
        status: "in_progress",
        last_id: new_last_id,
        batch_success: success_count,
        batch_errors: error_count,
        total: total
      })

      Logger.info(
        "DataRepairWorker: Batch complete. Success: #{success_count}, Errors: #{error_count}"
      )

      # Schedule next batch
      schedule_next_batch(args, new_last_id)
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("DataRepairWorker: Unknown repair type: #{inspect(args)}")
    {:error, "Unknown repair type"}
  end

  defp process_batch(movies) do
    movies
    |> Enum.reduce({0, 0}, fn movie, {success, errors} ->
      # Rate limiting
      Process.sleep(@rate_limit_delay)

      case fetch_and_store_credits(movie) do
        :ok ->
          {success + 1, errors}

        {:error, reason} ->
          Logger.warning(
            "DataRepairWorker: Failed to fetch credits for movie #{movie.id} (#{movie.title}): #{inspect(reason)}"
          )

          {success, errors + 1}
      end
    end)
  end

  defp fetch_and_store_credits(%{tmdb_id: tmdb_id, id: movie_id, title: title}) do
    Logger.debug("DataRepairWorker: Fetching credits for #{title} (TMDb: #{tmdb_id})")

    # Fetch movie data with credits from TMDb
    case TMDb.get_movie(tmdb_id, append_to_response: "credits") do
      {:ok, %{"credits" => credits}} when is_map(credits) ->
        # Get the movie struct
        movie = Repo.get!(Movies.Movie, movie_id)

        # Process credits using existing function - this will create person records and credits
        Movies.process_movie_credits_public(movie, credits)

        Logger.info("DataRepairWorker: Updated credits for #{title}")
        :ok

      {:ok, data} ->
        Logger.warning(
          "DataRepairWorker: No credits in response for #{title}: #{inspect(Map.keys(data))}"
        )

        {:error, :no_credits_in_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp schedule_next_batch(args, new_last_id) do
    %{
      "repair_type" => args["repair_type"],
      "last_id" => new_last_id,
      "batch_size" => args["batch_size"] || @batch_size,
      "total" => args["total"]
    }
    |> __MODULE__.new(schedule_in: 5)
    |> Oban.insert()

    :ok
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
      Logger.warning("DataRepairWorker: Failed to update job meta: #{inspect(error)}")
  end
end
