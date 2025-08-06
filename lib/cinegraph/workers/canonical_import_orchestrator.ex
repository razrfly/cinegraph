defmodule Cinegraph.Workers.CanonicalImportOrchestrator do
  @moduledoc """
  Orchestrator worker that determines total pages and queues individual page workers.
  Follows the same pattern as TMDbDiscoveryWorker for consistency.
  """

  use Oban.Worker,
    queue: :imdb_scraping,
    max_attempts: 3,
    unique: [
      keys: [:list_key],
      # 5 minutes
      period: 300,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Cinegraph.Workers.{CanonicalPageWorker, CanonicalImportCompletionWorker}
  alias Cinegraph.Scrapers.ImdbCanonicalScraper
  alias Cinegraph.Movies.{MovieLists, MovieList}
  require Logger

  @doc """
  Returns all available lists from the database only.
  This replaces the previous hardcoded approach with database-managed lists.
  """
  def available_lists do
    # Get active lists from database only
    MovieLists.all_as_config()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "orchestrate_import", "list_key" => list_key}}) do
    with {:ok, list_config} <- get_list_config(list_key),
         {:ok, total_pages} <- get_total_pages(list_config.list_id) do
      Logger.info("Starting canonical import orchestration for #{list_config.name}")
      Logger.info("Total pages to process: #{total_pages}")

      # Get expected movie count
      expected_count = ImdbCanonicalScraper.get_expected_movie_count(list_config.list_id)
      Logger.info("Expected movie count: #{expected_count || "unknown"}")

      # Store expected count in movie list metadata if we got it
      if expected_count do
        case MovieLists.get_by_source_key(list_key) do
          %MovieList{} = movie_list ->
            updated_metadata =
              Map.put(movie_list.metadata, "expected_movie_count", expected_count)

            changeset = Ecto.Changeset.change(movie_list, metadata: updated_metadata)

            case Cinegraph.Repo.update(changeset) do
              {:ok, _} ->
                Logger.info("Updated expected count for #{list_key}: #{expected_count}")

              {:error, error} ->
                Logger.warning(
                  "Failed to update expected count for #{list_key}: #{inspect(error)}"
                )
            end

          nil ->
            Logger.warning("Movie list not found for key: #{list_key}")
        end
      end

      # Update import stats to mark as started
      update_import_started(list_key)

      # Broadcast start of import
      broadcast_progress(list_key, :orchestrating, %{
        list_name: list_config.name,
        total_pages: total_pages,
        expected_count: expected_count,
        status: "Queueing page jobs..."
      })

      # Queue individual page jobs
      jobs =
        Enum.map(1..total_pages, fn page ->
          %{
            "action" => "import_page",
            "list_key" => list_key,
            "list_id" => list_config.list_id,
            "page" => page,
            "total_pages" => total_pages,
            "source_key" => list_config.source_key,
            "list_name" => list_config.name,
            "metadata" => list_config.metadata
          }
          |> CanonicalPageWorker.new()
        end)

      # Insert all jobs
      jobs_list = Oban.insert_all(jobs)

      if is_list(jobs_list) and length(jobs_list) > 0 do
        Logger.info("Successfully queued #{length(jobs_list)} page jobs for #{list_config.name}")

        broadcast_progress(list_key, :queued, %{
          list_name: list_config.name,
          pages_queued: length(jobs_list),
          total_pages: total_pages,
          expected_count: expected_count,
          status: "#{length(jobs_list)} page jobs queued"
        })

        # Schedule completion check worker
        schedule_completion_check(list_key, expected_count, total_pages)

        :ok
      else
        Logger.error("Failed to queue page jobs - no jobs inserted")
        {:error, "No jobs inserted"}
      end
    else
      {:error, :list_not_found} ->
        Logger.error("List configuration not found for key: #{list_key}")
        update_import_failed(list_key, "List configuration not found")
        {:error, "List not found: #{list_key}"}

      {:error, reason} ->
        Logger.error("Failed to orchestrate import: #{inspect(reason)}")
        update_import_failed(list_key, inspect(reason))
        {:error, reason}
    end
  end

  defp get_list_config(list_key) do
    # Try database first, then fallback to hardcoded
    case MovieLists.get_config(list_key) do
      {:ok, config} -> {:ok, Map.put(config, :list_key, list_key)}
      {:error, _reason} -> {:error, :list_not_found}
    end
  end

  defp get_total_pages(list_id) do
    case ImdbCanonicalScraper.get_total_pages(list_id) do
      {:ok, total} when is_integer(total) and total > 0 ->
        {:ok, total}

      {:ok, _invalid} ->
        {:error, "Invalid page count returned"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp broadcast_progress(list_key, status, data) do
    Phoenix.PubSub.broadcast(
      Cinegraph.PubSub,
      "import_progress",
      {:canonical_progress,
       Map.merge(data, %{
         list_key: list_key,
         status: status,
         timestamp: DateTime.utc_now()
       })}
    )
  end

  defp update_import_started(list_key) do
    case MovieLists.get_active_by_source_key(list_key) do
      nil ->
        Logger.warning("No database record found for list #{list_key}")
        :ok

      list ->
        # Update to show import is in progress
        case MovieLists.update_import_stats(list, "pending", 0) do
          {:ok, _} ->
            Logger.info("Updated import stats for #{list_key} - marked as in progress")
            :ok

          {:error, reason} ->
            Logger.error("Failed to update import stats for #{list_key}: #{inspect(reason)}")
            # Don't fail the import due to stats update failure
            :ok
        end
    end
  end

  defp schedule_completion_check(list_key, expected_count, total_pages) do
    # Schedule the completion check to run in 30 seconds
    %{
      "list_key" => list_key,
      "expected_count" => expected_count,
      "total_pages" => total_pages
    }
    |> CanonicalImportCompletionWorker.new(schedule_in: 30)
    |> Oban.insert()

    Logger.info("Scheduled completion check for #{list_key}")
  end

  defp update_import_failed(list_key, reason) do
    case MovieLists.get_active_by_source_key(list_key) do
      nil ->
        Logger.warning("No database record found for list #{list_key}")
        :ok

      list ->
        # Update to show import failed
        case MovieLists.update_import_stats(list, "failed: #{reason}", 0) do
          {:ok, _} ->
            Logger.info("Updated import stats for #{list_key} - marked as failed: #{reason}")
            :ok

          {:error, update_error} ->
            Logger.error(
              "Failed to update import stats for #{list_key}: #{inspect(update_error)}"
            )

            # Don't fail the import due to stats update failure
            :ok
        end
    end
  end
end
