defmodule Cinegraph.Workers.CanonicalImportWorker do
  @moduledoc """
  Worker that imports a single canonical IMDb list.

  This is now the ONE canonical-list import path (the old orchestrator/page-worker fan-out
  was removed — see GitHub #1004). It runs `CanonicalImporter.import_canonical_list/5`
  (a single fetch that parses the page's embedded JSON) and owns the `movie_lists`
  import-status lifecycle that previously lived in the orchestrator + completion worker.
  """

  use Oban.Worker,
    queue: :scraping,
    max_attempts: 3,
    unique: [
      keys: [:list_key],
      period: 300,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Cinegraph.Cultural.CanonicalImporter
  alias Cinegraph.CanonicalLists
  alias Cinegraph.Movies.{MovieLists, Movie}
  alias Cinegraph.Repo
  import Ecto.Query
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "import_canonical_list", "list_key" => list_key}}) do
    # Route all Repo.replica() calls through the dedicated worker pool
    # so this job does not compete with web requests for Repo.Replica connections. (#1007)
    Cinegraph.Repo.route_to_worker()
    Logger.info("Starting canonical import for #{list_key}")

    case CanonicalLists.get(list_key) do
      {:error, reason} ->
        Logger.error("Unknown canonical list: #{list_key}")
        {:error, reason}

      {:ok, list_config} ->
        broadcast_progress(list_key, :started, %{
          list_name: list_config.name,
          status: "Starting import..."
        })

        mark_import_started(list_key)

        result =
          CanonicalImporter.import_canonical_list(
            list_config.list_id,
            list_config.source_key,
            list_config.name,
            [create_movies: true],
            list_config.metadata
          )

        case Map.get(result, :error) do
          nil ->
            status = finalize_import(list_key, result)

            broadcast_progress(list_key, :completed, %{
              list_name: list_config.name,
              import_status: status,
              movies_created: result.movies_created,
              movies_updated: result.movies_updated,
              movies_queued: result.movies_queued,
              movies_skipped: result.movies_skipped,
              total_movies: result.total_movies,
              expected_movies: result[:expected_count]
            })

            Logger.info(
              "Completed canonical import for #{list_key}: #{result.total_movies} movies (#{status})"
            )

            :ok

          reason ->
            mark_import_failed(list_key, inspect(reason))

            broadcast_progress(list_key, :completed, %{
              list_name: list_config.name,
              import_status: "failed",
              total_movies: 0
            })

            Logger.error("Canonical import failed for #{list_key}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  # Get available lists for UI
  def available_lists do
    CanonicalLists.all()
  end

  # --- movie_lists import-status lifecycle (ported from the removed orchestrator +
  # completion worker; now straight-line since the import is one synchronous job) ---

  defp mark_import_started(list_key) do
    case MovieLists.get_active_by_source_key(list_key) do
      nil ->
        :ok

      list ->
        metadata =
          Map.merge(list.metadata || %{}, %{"last_import_started_at" => iso_now()})

        persist(list_key, list, %{
          last_import_at: DateTime.utc_now(),
          last_import_status: "pending",
          metadata: metadata
        })

        :ok
    end
  end

  defp finalize_import(list_key, result) do
    expected = result[:expected_count]
    # Status is based on items PROCESSED this run (created + updated + queued), not on the
    # persisted canonical-row count: an all-new list queues TMDbDetailsWorker jobs and has 0
    # persisted rows yet, but the import succeeded. `actual` (persisted) is recorded separately
    # for the dashboard and catches up as those jobs run.
    processed =
      (result[:movies_created] || 0) +
        (result[:movies_updated] || 0) +
        (result[:movies_queued] || 0)

    actual = canonical_movie_count(list_key)
    status = completion_status(processed, expected)

    case MovieLists.get_active_by_source_key(list_key) do
      nil ->
        status

      list ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        metadata =
          (list.metadata || %{})
          |> Map.put("expected_movie_count", expected)
          |> Map.put("actual_movie_count", actual)
          |> Map.put("last_import_finished_at", DateTime.to_iso8601(now))
          |> maybe_put_error(status, processed, expected)

        persist(list_key, list, %{
          last_import_at: now,
          last_import_status: status,
          metadata: metadata,
          total_imports: (list.total_imports || 0) + 1
        })

        status
    end
  end

  defp mark_import_failed(list_key, reason) do
    case MovieLists.get_active_by_source_key(list_key) do
      nil ->
        :ok

      list ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        metadata =
          (list.metadata || %{})
          |> Map.put("last_import_error", reason)
          |> Map.put("last_import_finished_at", DateTime.to_iso8601(now))

        persist(list_key, list, %{
          last_import_at: now,
          last_import_status: "failed",
          metadata: metadata,
          total_imports: (list.total_imports || 0) + 1
        })

        :ok
    end
  end

  # Persist a movie_list update, logging (not raising) on failure so a stats-write problem
  # doesn't crash the import but also isn't lost silently.
  defp persist(list_key, list, attrs) do
    case MovieLists.update_movie_list(list, attrs) do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to update movie_list stats for #{list_key}: #{inspect(reason)}")
        :ok
    end
  end

  defp canonical_movie_count(list_key) do
    Repo.one(
      from m in Movie,
        where: fragment("? \\? ?", m.canonical_sources, ^list_key),
        select: count(m.id)
    )
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

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()

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
end
