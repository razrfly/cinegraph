defmodule Cinegraph.Workers.YearDiscoveryWorker do
  @moduledoc """
  Worker for discovering available years from IMDb for festival events.

  Uses IMDb's `historyEventEditions` data to populate the `discovered_years`
  field in `festival_events`, replacing prediction with actual data.

  ## Usage

      # Discover years for a single festival by source_key
      YearDiscoveryWorker.queue_discovery("cannes")

      # Discover years for all festivals with imdb_event_id
      YearDiscoveryWorker.queue_discover_all()

  """

  use Oban.Worker,
    queue: :festival_import,
    max_attempts: 3,
    unique: [
      period: 3600,
      fields: [:args],
      keys: [:source_key],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Cinegraph.Events
  alias Cinegraph.Events.FestivalEvent
  alias Cinegraph.Repo
  alias Cinegraph.Scrapers.UnifiedFestivalScraper
  require Logger

  @doc """
  Queue year discovery for a specific festival by source_key.
  """
  def queue_discovery(source_key) when is_binary(source_key) do
    %{"source_key" => source_key}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Queue year discovery for all active festivals with IMDb event IDs.
  """
  def queue_discover_all do
    %{"action" => "discover_all"}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_key" => source_key}}) do
    Logger.info("YearDiscoveryWorker: Starting discovery for #{source_key}")

    case Events.get_active_by_source_key(source_key) do
      nil ->
        Logger.error("YearDiscoveryWorker: Festival not found: #{source_key}")
        {:error, "Festival not found: #{source_key}"}

      festival_event ->
        discover_years_for_event(festival_event)
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "discover_all"}}) do
    Logger.info("YearDiscoveryWorker: Starting discovery for all festivals")

    festivals = Events.list_active_events()
    results = Enum.map(festivals, &discover_years_for_event/1)

    successful = Enum.count(results, fn r -> match?({:ok, _}, r) end)
    failed = Enum.count(results, fn r -> match?({:error, _}, r) end)

    Logger.info(
      "YearDiscoveryWorker: Completed discover_all - #{successful} successful, #{failed} failed"
    )

    broadcast_progress(:discover_all_completed, %{
      successful: successful,
      failed: failed,
      total: length(results)
    })

    {:ok, %{successful: successful, failed: failed}}
  end

  defp discover_years_for_event(%FestivalEvent{} = festival_event) do
    # Get IMDb event ID from either the new field or source_config
    event_id = get_imdb_event_id(festival_event)

    if event_id do
      Logger.info(
        "YearDiscoveryWorker: Discovering years for #{festival_event.source_key} (#{event_id})"
      )

      case UnifiedFestivalScraper.fetch_available_years(event_id) do
        {:ok, years} ->
          update_discovered_years(festival_event, years, event_id)

        {:error, reason} ->
          Logger.error(
            "YearDiscoveryWorker: Failed to discover years for #{festival_event.source_key}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      Logger.warning(
        "YearDiscoveryWorker: No IMDb event ID for #{festival_event.source_key}, skipping"
      )

      {:ok, :skipped}
    end
  end

  defp get_imdb_event_id(%FestivalEvent{} = festival_event) do
    # First check the dedicated field, then fall back to source_config
    festival_event.imdb_event_id ||
      get_in(festival_event.source_config || %{}, ["event_id"]) ||
      get_in(festival_event.source_config || %{}, ["imdb_event_id"])
  end

  defp update_discovered_years(%FestivalEvent{} = festival_event, [] = _years, _event_id) do
    Logger.warning(
      "YearDiscoveryWorker: No years found for #{festival_event.source_key}, skipping update"
    )

    {:ok, :no_years}
  end

  defp update_discovered_years(%FestivalEvent{} = festival_event, years, event_id) do
    min_year = Enum.min(years)
    max_year = Enum.max(years)

    changeset =
      festival_event
      |> FestivalEvent.changeset(%{
        discovered_years: years,
        years_discovered_at: DateTime.utc_now(),
        imdb_event_id: event_id,
        # Also update min/max for backward compatibility
        min_available_year: min_year,
        max_available_year: max_year
      })

    case Repo.update(changeset) do
      {:ok, updated_event} ->
        Logger.info(
          "YearDiscoveryWorker: Updated #{festival_event.source_key} with #{length(years)} years (#{min_year}-#{max_year})"
        )

        broadcast_progress(:years_discovered, %{
          source_key: festival_event.source_key,
          years_count: length(years),
          min_year: min_year,
          max_year: max_year
        })

        {:ok, updated_event}

      {:error, changeset} ->
        Logger.error(
          "YearDiscoveryWorker: Failed to update #{festival_event.source_key}: #{inspect(changeset.errors)}"
        )

        {:error, changeset.errors}
    end
  end

  defp broadcast_progress(action, data) do
    Phoenix.PubSub.broadcast(
      Cinegraph.PubSub,
      "award_imports",
      {action, Map.merge(data, %{timestamp: DateTime.utc_now()})}
    )
  end
end
