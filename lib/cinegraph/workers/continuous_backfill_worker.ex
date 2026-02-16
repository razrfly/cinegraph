defmodule Cinegraph.Workers.ContinuousBackfillWorker do
  @moduledoc """
  Self-scheduling worker for continuous backfill until all movies are imported.

  This worker implements Option A from issue #537: a fully automated backfill
  that queues batches and schedules itself when each batch completes.

  ## How It Works

  1. Queue a batch of movies (default 10K)
  2. Poll every 5 minutes to check batch completion
  3. When batch completes, check for more missing movies
  4. If more exist, schedule next batch
  5. If none, mark complete and stop

  ## Usage

  Start continuous backfill:
      mix tmdb.export continuous --start

  Check status:
      mix tmdb.export continuous --status

  Stop/pause:
      mix tmdb.export continuous --stop

  ## State Management

  Uses ImportStateV2 to track:
  - continuous_backfill_status: running/paused/completed
  - continuous_backfill_batch: current batch number
  - continuous_backfill_started: when started
  - continuous_backfill_total_queued: total movies queued
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 5,
    # Only prevent duplicates among non-completed jobs to allow self-scheduling
    unique: [
      period: 300,
      keys: [:action],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Services.TMDb.GapAnalysis
  alias Cinegraph.Workers.TMDbDetailsWorker
  alias Cinegraph.Imports.ImportStateV2
  require Logger

  # Default batch size (10K movies per batch)
  @default_batch_size 10_000
  # How often to check for batch completion (5 minutes)
  @poll_interval_seconds 300
  # Minimum popularity for standard tier
  @min_popularity 1.0

  @doc """
  Starts the continuous backfill process.
  """
  def start(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    min_popularity = Keyword.get(opts, :min_popularity, @min_popularity)

    # Check if already running
    case get_status() do
      "running" ->
        {:error, :already_running}

      _ ->
        # Queue first batch - only update state on success
        result =
          __MODULE__.new(%{
            "action" => "queue_batch",
            "batch_size" => batch_size,
            "min_popularity" => min_popularity
          })
          |> Oban.insert()

        case result do
          {:ok, job} ->
            # Initialize state only after successful insert
            ImportStateV2.set("continuous_backfill_status", "running")
            ImportStateV2.set("continuous_backfill_batch", 1)

            ImportStateV2.set(
              "continuous_backfill_started",
              DateTime.to_iso8601(DateTime.utc_now())
            )

            ImportStateV2.set("continuous_backfill_batch_size", batch_size)
            ImportStateV2.set("continuous_backfill_min_popularity", min_popularity)
            {:ok, job}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Stops/pauses the continuous backfill.
  """
  def stop do
    ImportStateV2.set("continuous_backfill_status", "paused")
    Logger.info("Continuous backfill paused")
    :ok
  end

  @doc """
  Resumes a paused continuous backfill.
  """
  def resume do
    case get_status() do
      "paused" ->
        batch_size =
          ImportStateV2.get_integer("continuous_backfill_batch_size", @default_batch_size)

        min_pop = ImportStateV2.get_float("continuous_backfill_min_popularity", @min_popularity)

        result =
          __MODULE__.new(%{
            "action" => "queue_batch",
            "batch_size" => batch_size,
            "min_popularity" => min_pop
          })
          |> Oban.insert()

        case result do
          {:ok, job} ->
            # Only update state after successful insert
            ImportStateV2.set("continuous_backfill_status", "running")
            {:ok, job}

          {:error, reason} ->
            {:error, reason}
        end

      "completed" ->
        {:error, :already_completed}

      "running" ->
        {:error, :already_running}

      _ ->
        {:error, :not_started}
    end
  end

  @doc """
  Gets the current status of the continuous backfill.
  """
  def get_status do
    ImportStateV2.get("continuous_backfill_status", "not_started")
  end

  @doc """
  Gets detailed status information.
  """
  def get_detailed_status do
    status = get_status()
    batch = ImportStateV2.get_integer("continuous_backfill_batch", 0)
    started = ImportStateV2.get("continuous_backfill_started")
    total_queued = ImportStateV2.get_integer("continuous_backfill_total_queued", 0)
    batch_size = ImportStateV2.get_integer("continuous_backfill_batch_size", @default_batch_size)

    # Get pending/executing job counts
    tmdb_jobs = count_pending_tmdb_jobs()

    # Get current missing count (cached or live)
    missing_count = get_cached_missing_count()

    %{
      status: status,
      current_batch: batch,
      started_at: started,
      total_queued: total_queued,
      batch_size: batch_size,
      pending_jobs: tmdb_jobs.pending,
      executing_jobs: tmdb_jobs.executing,
      estimated_remaining: missing_count,
      estimated_batches_remaining:
        if(missing_count > 0, do: ceil(missing_count / batch_size), else: 0)
    }
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "queue_batch"} = args}) do
    # Check if we should continue
    case get_status() do
      "running" ->
        batch_size = Map.get(args, "batch_size", @default_batch_size)
        min_popularity = Map.get(args, "min_popularity", @min_popularity)
        do_queue_batch(batch_size, min_popularity)

      status ->
        Logger.info("Continuous backfill not running (status: #{status}), skipping batch")
        :ok
    end
  end

  def perform(%Oban.Job{args: %{"action" => "check_completion"} = args}) do
    case get_status() do
      "running" ->
        batch_size = Map.get(args, "batch_size", @default_batch_size)
        min_popularity = Map.get(args, "min_popularity", @min_popularity)
        do_check_completion(batch_size, min_popularity)

      status ->
        Logger.info("Continuous backfill not running (status: #{status}), skipping check")
        :ok
    end
  end

  # Private implementation

  defp do_queue_batch(batch_size, min_popularity) do
    batch_num = ImportStateV2.get_integer("continuous_backfill_batch", 1)
    Logger.info("ContinuousBackfill: Starting batch #{batch_num} (size: #{batch_size})")

    # Check how many jobs are already pending
    pending = count_pending_tmdb_jobs()

    if pending.pending + pending.executing >= batch_size do
      # Already have enough jobs queued, just schedule a check
      Logger.info(
        "ContinuousBackfill: #{pending.pending + pending.executing} jobs already pending, scheduling check"
      )

      schedule_completion_check(batch_size, min_popularity)
      :ok
    else
      # Find missing movies and queue them
      case GapAnalysis.find_missing_ids(
             min_popularity: min_popularity,
             limit: batch_size,
             sort_by: :popularity
           ) do
        {:ok, []} ->
          # No more missing movies!
          Logger.info("ContinuousBackfill: No more missing movies! Marking complete.")
          ImportStateV2.set("continuous_backfill_status", "completed")

          ImportStateV2.set(
            "continuous_backfill_completed",
            DateTime.to_iso8601(DateTime.utc_now())
          )

          :ok

        {:ok, missing} ->
          queued = queue_movies(missing)
          Logger.info("ContinuousBackfill: Batch #{batch_num} queued #{queued} movies")

          # Update stats
          total = ImportStateV2.get_integer("continuous_backfill_total_queued", 0)
          ImportStateV2.set("continuous_backfill_total_queued", total + queued)

          ImportStateV2.set(
            "continuous_backfill_last_batch_at",
            DateTime.to_iso8601(DateTime.utc_now())
          )

          # Cache the missing count for status display
          ImportStateV2.set("continuous_backfill_missing_count", length(missing))

          # Schedule completion check
          schedule_completion_check(batch_size, min_popularity)
          :ok

        {:error, reason} ->
          Logger.error("ContinuousBackfill: Failed to find missing movies: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp do_check_completion(batch_size, min_popularity) do
    pending = count_pending_tmdb_jobs()
    total_pending = pending.pending + pending.executing

    Logger.info(
      "ContinuousBackfill: Checking completion - #{total_pending} jobs remaining (#{pending.pending} pending, #{pending.executing} executing)"
    )

    cond do
      total_pending > 1000 ->
        # Still lots of jobs, check again later
        Logger.info(
          "ContinuousBackfill: #{total_pending} jobs still pending, checking again in #{@poll_interval_seconds}s"
        )

        schedule_completion_check(batch_size, min_popularity)
        :ok

      total_pending > 0 and total_pending <= 1000 ->
        # Getting close, check more frequently
        Logger.info("ContinuousBackfill: #{total_pending} jobs remaining, checking again in 60s")
        schedule_completion_check(batch_size, min_popularity, 60)
        :ok

      true ->
        # Batch complete! Start next batch
        batch_num = ImportStateV2.get_integer("continuous_backfill_batch", 1)
        Logger.info("ContinuousBackfill: Batch #{batch_num} complete! Starting next batch...")

        # Increment batch number
        ImportStateV2.set("continuous_backfill_batch", batch_num + 1)

        # Queue next batch with proper error handling
        result =
          __MODULE__.new(%{
            "action" => "queue_batch",
            "batch_size" => batch_size,
            "min_popularity" => min_popularity
          })
          |> Oban.insert()

        case result do
          {:ok, job} ->
            Logger.info("ContinuousBackfill: Scheduled queue_batch job #{job.id}")
            :ok

          {:error, changeset} ->
            Logger.error(
              "ContinuousBackfill: FAILED to schedule queue_batch: #{inspect(changeset.errors)}"
            )

            # Retry by scheduling another check_completion to try again later
            schedule_completion_check(batch_size, min_popularity, 60)
            :ok
        end
    end
  end

  defp queue_movies(movies) do
    movies
    |> Enum.chunk_every(100)
    |> Enum.reduce(0, fn batch, total ->
      jobs =
        Enum.map(batch, fn movie ->
          TMDbDetailsWorker.new(%{
            "tmdb_id" => movie.id,
            "source" => "continuous_backfill",
            "popularity" => movie.popularity,
            "original_title" => movie.original_title
          })
        end)

      case Oban.insert_all(jobs) do
        inserted when is_list(inserted) ->
          total + length(inserted)

        {:error, _reason} ->
          total
      end
    end)
  end

  defp schedule_completion_check(
         batch_size,
         min_popularity,
         delay_seconds \\ @poll_interval_seconds
       ) do
    result =
      __MODULE__.new(
        %{
          "action" => "check_completion",
          "batch_size" => batch_size,
          "min_popularity" => min_popularity
        },
        schedule_in: delay_seconds
      )
      |> Oban.insert()

    case result do
      {:ok, job} ->
        Logger.info(
          "ContinuousBackfill: Scheduled check_completion job #{job.id} in #{delay_seconds}s"
        )

        result

      {:error, changeset} ->
        Logger.error(
          "ContinuousBackfill: Failed to schedule check_completion: #{inspect(changeset.errors)}"
        )

        result
    end
  end

  defp count_pending_tmdb_jobs do
    query =
      from(j in "oban_jobs",
        where:
          j.queue == "tmdb" and j.state in ["available", "scheduled", "executing", "retryable"],
        select: %{
          state: j.state,
          count: count(j.id)
        },
        group_by: j.state
      )

    results = Repo.all(query)

    # Sum up counts by state
    counts =
      Enum.reduce(results, %{available: 0, scheduled: 0, executing: 0, retryable: 0}, fn r, acc ->
        Map.put(acc, String.to_atom(r.state), r.count)
      end)

    %{
      pending: counts.available + counts.scheduled + counts.retryable,
      executing: counts.executing
    }
  end

  defp get_cached_missing_count do
    ImportStateV2.get_integer("continuous_backfill_missing_count", 0)
  end
end
