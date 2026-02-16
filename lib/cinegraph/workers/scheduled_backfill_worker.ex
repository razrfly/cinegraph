defmodule Cinegraph.Workers.ScheduledBackfillWorker do
  @moduledoc """
  Cron-based worker for continuous movie backfill.

  Runs every hour as a health check and queues new movies for import
  based on the current queue state. This replaces the self-scheduling
  ContinuousBackfillWorker with a simpler, more robust approach.

  ## How It Works

  1. Cron triggers this worker every hour
  2. Worker checks how many TMDB jobs are pending
  3. If pending < threshold, queue more movies from the gap analysis
  4. If pending >= threshold, skip (queue is still processing)
  5. If no more missing movies, log completion

  ## Benefits Over Self-Scheduling

  - **Stateless**: Each run is independent, no chain to break
  - **Self-recovering**: Failures auto-recover on next cron trigger
  - **Simple**: No complex state management across jobs
  - **Observable**: Easy to monitor via cron logs

  ## Configuration

  Add to Oban cron config:

      {"0 * * * *", Cinegraph.Workers.ScheduledBackfillWorker}

  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    # Prevent duplicate jobs from cron/manual overlap (only among non-completed jobs)
    unique: [
      period: :timer.minutes(15),
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Services.TMDb.GapAnalysis
  alias Cinegraph.Workers.TMDbDetailsWorker
  require Logger

  # Queue more movies when pending jobs fall below this threshold
  @pending_threshold 5_000

  # Number of movies to queue per batch
  @batch_size 10_000

  # Minimum popularity for imports - set to 0 to import ALL movies
  @min_popularity 0.0

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("ScheduledBackfill: Starting hourly health check...")

    # Update baseline from TMDb export if stale (daily)
    maybe_update_baseline()

    pending = count_pending_tmdb_jobs()
    total_pending = pending.available + pending.scheduled + pending.executing + pending.retryable

    Logger.info(
      "ScheduledBackfill: Queue status - #{total_pending} total pending " <>
        "(#{pending.available} available, #{pending.scheduled} scheduled, " <>
        "#{pending.executing} executing, #{pending.retryable} retryable)"
    )

    cond do
      total_pending >= @pending_threshold ->
        Logger.info(
          "ScheduledBackfill: Queue healthy (#{total_pending} >= #{@pending_threshold}), skipping batch"
        )

        :ok

      true ->
        queue_batch(total_pending)
    end
  end

  # Update baseline if it's stale (older than 24 hours)
  defp maybe_update_baseline do
    alias Cinegraph.Imports.ImportStateV2

    case ImportStateV2.get("baseline_updated_at") do
      nil ->
        Logger.info("ScheduledBackfill: No baseline set, updating from TMDb export...")
        do_update_baseline()

      updated_at when is_binary(updated_at) ->
        case DateTime.from_iso8601(updated_at) do
          {:ok, dt, _} ->
            hours_ago = DateTime.diff(DateTime.utc_now(), dt, :hour)

            if hours_ago >= 24 do
              Logger.info("ScheduledBackfill: Baseline is #{hours_ago}h old, updating...")
              do_update_baseline()
            else
              Logger.debug("ScheduledBackfill: Baseline is fresh (#{hours_ago}h old)")
            end

          _ ->
            do_update_baseline()
        end

      _ ->
        do_update_baseline()
    end
  end

  defp do_update_baseline do
    case GapAnalysis.update_baseline() do
      {:ok, stats} ->
        Logger.info(
          "ScheduledBackfill: Updated baseline - #{stats.export_total} total movies in TMDb"
        )

      {:error, reason} ->
        Logger.warning("ScheduledBackfill: Failed to update baseline: #{inspect(reason)}")
    end
  end

  defp queue_batch(current_pending) do
    Logger.info(
      "ScheduledBackfill: Queue below threshold (#{current_pending} < #{@pending_threshold}), " <>
        "finding missing movies..."
    )

    case GapAnalysis.find_missing_ids(
           min_popularity: @min_popularity,
           limit: @batch_size,
           sort_by: :popularity
         ) do
      {:ok, []} ->
        Logger.info("ScheduledBackfill: No more missing movies! Backfill complete.")
        :ok

      {:ok, missing} ->
        queued_count = queue_movies(missing)

        Logger.info(
          "ScheduledBackfill: Queued #{queued_count} movies for import " <>
            "(#{length(missing)} found, popularity >= #{@min_popularity})"
        )

        :ok

      {:error, reason} ->
        Logger.error("ScheduledBackfill: Failed to find missing movies: #{inspect(reason)}")
        {:error, reason}
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
            "source" => "scheduled_backfill",
            "popularity" => movie.popularity,
            "original_title" => movie.original_title
          })
        end)

      case Oban.insert_all(jobs) do
        inserted when is_list(inserted) ->
          total + length(inserted)

        {:error, reason} ->
          Logger.warning("ScheduledBackfill: Failed to insert batch: #{inspect(reason)}")
          total
      end
    end)
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

    # Build counts map with defaults
    Enum.reduce(results, %{available: 0, scheduled: 0, executing: 0, retryable: 0}, fn r, acc ->
      Map.put(acc, String.to_atom(r.state), r.count)
    end)
  end

  @doc """
  Manually trigger a backfill check. Useful for testing or manual intervention.

  ## Examples

      iex> ScheduledBackfillWorker.run_now()
      {:ok, %Oban.Job{}}
  """
  def run_now do
    %{}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @doc """
  Returns current queue health status without queuing any jobs.

  ## Examples

      iex> ScheduledBackfillWorker.health_check()
      %{
        pending_jobs: 3500,
        threshold: 5000,
        would_queue: true,
        status: :below_threshold
      }
  """
  def health_check do
    pending = count_pending_tmdb_jobs()
    total = pending.available + pending.scheduled + pending.executing + pending.retryable

    %{
      pending_jobs: total,
      threshold: @pending_threshold,
      would_queue: total < @pending_threshold,
      status: if(total >= @pending_threshold, do: :healthy, else: :below_threshold),
      breakdown: pending
    }
  end
end
