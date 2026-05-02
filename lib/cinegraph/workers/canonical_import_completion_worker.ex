defmodule Cinegraph.Workers.CanonicalImportCompletionWorker do
  @moduledoc """
  Worker that monitors and finalizes canonical import completion.
  This worker is scheduled after all page jobs are queued to check when they complete
  and update the final statistics.
  """

  use Oban.Worker,
    queue: :scraping,
    max_attempts: 5,
    unique: [
      keys: [:list_key],
      # 5 minutes
      period: 300,
      states: [:available, :scheduled, :retryable]
    ]

  alias Cinegraph.Movies.MovieLists
  alias Cinegraph.Repo
  import Ecto.Query
  require Logger

  @doc false
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "list_key" => list_key,
      "expected_count" => expected_count,
      "total_pages" => total_pages
    } = args

    Logger.info("Checking completion status for #{list_key}")

    # Check if all page jobs are completed
    case check_page_jobs_completed(list_key, total_pages) do
      {:completed, _stats} ->
        # All pages completed - calculate final statistics
        finalize_import(list_key, expected_count)

      {:in_progress, stats} ->
        # Still processing - reschedule check
        Logger.info("Import still in progress for #{list_key}: #{inspect(stats)}")
        schedule_next_check(args)

      {:failed, reason} ->
        # Some pages failed
        Logger.error("Import failed for #{list_key}: #{inspect(reason)}")
        update_import_failed(list_key, reason)
    end
  end

  defp check_page_jobs_completed(list_key, total_pages) do
    # Query Oban jobs for this list
    page_jobs =
      from(j in "oban_jobs",
        where: j.worker == "Cinegraph.Workers.CanonicalPageWorker",
        where: fragment("? ->> 'list_key' = ?", j.args, ^list_key),
        select: %{
          state: j.state,
          page: fragment("(? ->> 'page')::int", j.args)
        }
      )
      |> Repo.all()

    total_jobs = length(page_jobs)
    completed = Enum.count(page_jobs, &(&1.state == "completed"))
    failed = Enum.count(page_jobs, &(&1.state in ["discarded", "cancelled"]))

    executing =
      Enum.count(page_jobs, &(&1.state in ["executing", "available", "scheduled", "retryable"]))

    stats = %{
      total: total_jobs,
      completed: completed,
      failed: failed,
      executing: executing,
      expected_pages: total_pages
    }

    cond do
      # All pages completed successfully
      completed == total_pages and failed == 0 ->
        {:completed, stats}

      # Some pages failed
      failed > 0 ->
        {:failed, "#{failed} pages failed to process"}

      # Still processing
      executing > 0 or completed + failed < total_pages ->
        {:in_progress, stats}

      # Edge case: we have all jobs but count doesn't match expected
      completed == total_jobs and total_jobs < total_pages ->
        Logger.warning("Completed jobs (#{completed}) less than expected pages (#{total_pages})")
        {:completed, stats}

      true ->
        {:in_progress, stats}
    end
  end

  defp finalize_import(list_key, expected_count) do
    Logger.info("Finalizing import for #{list_key}")

    # Count actual movies in database
    actual_count =
      Repo.one(
        from m in Cinegraph.Movies.Movie,
          where: fragment("? \\? ?", m.canonical_sources, ^list_key),
          select: count(m.id)
      )

    # Update the movie list with final statistics
    case MovieLists.get_active_by_source_key(list_key) do
      nil ->
        Logger.error("No movie list found for key: #{list_key}")
        {:error, :not_found}

      list ->
        status = completion_status(actual_count, expected_count)

        updated_metadata =
          (list.metadata || %{})
          |> Map.put("expected_movie_count", expected_count)
          |> Map.put("actual_movie_count", actual_count)
          |> Map.put("last_import_finished_at", DateTime.utc_now() |> DateTime.to_iso8601())
          |> maybe_put_error(status, actual_count, expected_count)

        attrs = %{
          last_import_at: DateTime.utc_now(),
          last_import_status: status,
          metadata: updated_metadata,
          total_imports: (list.total_imports || 0) + 1
        }

        case MovieLists.update_movie_list(list, attrs) do
          {:ok, updated_list} ->
            Logger.info(
              "Import #{status} for #{list_key}: #{actual_count} movies (expected: #{expected_count || "unknown"})"
            )

            # Broadcast completion
            Phoenix.PubSub.broadcast(
              Cinegraph.PubSub,
              "import_progress",
              {:canonical_progress,
               %{
                 list_key: list_key,
                 status: :completed,
                 import_status: status,
                 total_movies: actual_count,
                 expected_movies: expected_count,
                 timestamp: DateTime.utc_now()
               }}
            )

            {:ok, updated_list}

          {:error, changeset} ->
            Logger.error("Failed to update import stats: #{inspect(changeset.errors)}")
            {:error, changeset}
        end
    end
  end

  defp update_import_failed(list_key, reason) do
    case MovieLists.get_active_by_source_key(list_key) do
      nil ->
        :ok

      list ->
        metadata =
          (list.metadata || %{})
          |> Map.put("last_import_error", reason)
          |> Map.put("last_import_finished_at", DateTime.utc_now() |> DateTime.to_iso8601())

        MovieLists.update_movie_list(list, %{
          last_import_at: DateTime.utc_now(),
          last_import_status: "failed",
          metadata: metadata,
          total_imports: (list.total_imports || 0) + 1
        })
    end
  end

  defp completion_status(actual_count, expected_count)
       when is_integer(expected_count) and expected_count > 0 do
    cond do
      actual_count == 0 -> "failed"
      actual_count < expected_count -> "partial"
      true -> "success"
    end
  end

  defp completion_status(actual_count, _expected_count) do
    if actual_count > 0, do: "success", else: "failed"
  end

  defp maybe_put_error(metadata, "failed", actual_count, expected_count) do
    Map.put(
      metadata,
      "last_import_error",
      "actual movie count #{actual_count} did not satisfy expected count #{expected_count || "unknown"}"
    )
  end

  defp maybe_put_error(metadata, _status, _actual_count, _expected_count) do
    Map.delete(metadata, "last_import_error")
  end

  defp schedule_next_check(args) do
    # Re-enqueue with the full argument set so the next run has the data it expects
    args
    |> __MODULE__.new(schedule_in: 30)
    |> Oban.insert()

    :ok
  end
end
