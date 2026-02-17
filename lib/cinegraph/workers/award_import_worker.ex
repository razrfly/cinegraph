defmodule Cinegraph.Workers.AwardImportWorker do
  @moduledoc """
  Unified worker for importing award/festival data.

  Routes to appropriate importer based on organization:
  - AMPAS (Oscars): Uses direct scraping from oscars.org via Cultural module
  - Other festivals: Uses IMDb scraping via UnifiedFestivalWorker

  Supports both individual year imports and batch sync operations.
  """

  use Oban.Worker,
    queue: :scraping,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:args],
      keys: [:organization_id, :year],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Cinegraph.Events
  alias Cinegraph.Festivals
  alias Cinegraph.Festivals.FestivalOrganization
  alias Cinegraph.Cultural
  alias Cinegraph.Repo
  require Logger

  # Spacing between year imports in seconds (5 minutes)
  # This prevents overwhelming the system when batch-importing multiple years
  @year_import_spacing_seconds 300

  @doc """
  Queue an import job for a specific organization and year.
  """
  def queue_import(organization_id, year) do
    %{"organization_id" => organization_id, "year" => year}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Queue a sync operation to import all missing/failed years for an organization.
  """
  def queue_sync_missing(organization_id) do
    %{"organization_id" => organization_id, "action" => "sync_missing"}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Queue a resync operation to re-import ALL years for an organization, regardless of status.
  Useful for re-running discovery after movies have been created.
  """
  def queue_resync_all(organization_id) do
    %{"organization_id" => organization_id, "action" => "resync_all"}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Queue a resync operation to re-import the most recent N years for an organization.
  Useful for testing with a smaller subset of years.
  """
  def queue_resync_recent(organization_id, year_count) do
    %{
      "organization_id" => organization_id,
      "action" => "resync_recent",
      "year_count" => year_count
    }
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"organization_id" => org_id, "year" => year}} = job) do
    Logger.info("AwardImportWorker: Starting import for organization #{org_id}, year #{year}")

    # Handle synthetic negative IDs from the dashboard view
    # These are generated for festivals in festival_events that don't have organizations yet
    if org_id < 0 do
      handle_synthetic_org_id(org_id, year, job)
    else
      handle_real_org_id(org_id, year, job)
    end
  end

  # Batch import: sync missing years for an organization
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"organization_id" => org_id, "action" => "sync_missing"}}) do
    Logger.info("AwardImportWorker: Starting sync_missing for organization #{org_id}")

    # Find years with status 'not_started' or 'failed' from the view
    missing_statuses =
      Festivals.list_award_import_statuses(organization_id: org_id)
      |> Enum.filter(fn status ->
        status.status in ["not_started", "failed", "no_matches", "low_match"]
      end)

    if length(missing_statuses) == 0 do
      Logger.info("AwardImportWorker: No missing years found for organization #{org_id}")
      {:ok, %{queued: 0, message: "No missing years"}}
    else
      Logger.info(
        "AwardImportWorker: Found #{length(missing_statuses)} years to sync for organization #{org_id}"
      )

      # Queue individual import jobs with spacing to prevent overwhelming the system
      # Jobs are scheduled 5 minutes apart to allow each ceremony to complete processing
      jobs =
        missing_statuses
        |> Enum.sort_by(& &1.year, :desc)
        |> Enum.with_index()
        |> Enum.map(fn {status, index} ->
          schedule_delay = index * @year_import_spacing_seconds
          new(%{"organization_id" => org_id, "year" => status.year}, schedule_in: schedule_delay)
        end)

      results = Oban.insert_all(jobs)
      queued_count = if is_list(results), do: length(results), else: 0

      total_duration_minutes = div((queued_count - 1) * @year_import_spacing_seconds, 60)

      Logger.info(
        "AwardImportWorker: Queued #{queued_count} import jobs for organization #{org_id} " <>
          "(spaced #{div(@year_import_spacing_seconds, 60)} min apart, ~#{total_duration_minutes} min total)"
      )

      # Broadcast progress
      broadcast_progress(:sync_missing, %{
        organization_id: org_id,
        years_queued: queued_count,
        years: Enum.map(missing_statuses, & &1.year),
        spacing_seconds: @year_import_spacing_seconds,
        estimated_duration_minutes: total_duration_minutes
      })

      {:ok, %{queued: queued_count, spacing_seconds: @year_import_spacing_seconds}}
    end
  end

  # Batch import: resync ALL years for an organization (ignores status)
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"organization_id" => org_id, "action" => "resync_all"}}) do
    Logger.info("AwardImportWorker: Starting resync_all for organization #{org_id}")

    # Get ALL years for this organization, regardless of status
    all_statuses = Festivals.list_award_import_statuses(organization_id: org_id)

    if length(all_statuses) == 0 do
      Logger.info("AwardImportWorker: No years found for organization #{org_id}")
      {:ok, %{queued: 0, message: "No years found"}}
    else
      Logger.info(
        "AwardImportWorker: Found #{length(all_statuses)} years to resync for organization #{org_id}"
      )

      # Queue individual import jobs with spacing to prevent overwhelming the system
      # Jobs are scheduled 5 minutes apart to allow each ceremony to complete processing
      jobs =
        all_statuses
        |> Enum.sort_by(& &1.year, :desc)
        |> Enum.with_index()
        |> Enum.map(fn {status, index} ->
          schedule_delay = index * @year_import_spacing_seconds
          new(%{"organization_id" => org_id, "year" => status.year}, schedule_in: schedule_delay)
        end)

      results = Oban.insert_all(jobs)
      queued_count = if is_list(results), do: length(results), else: 0

      total_duration_minutes = div((queued_count - 1) * @year_import_spacing_seconds, 60)

      Logger.info(
        "AwardImportWorker: Queued #{queued_count} resync jobs for organization #{org_id} " <>
          "(spaced #{div(@year_import_spacing_seconds, 60)} min apart, ~#{total_duration_minutes} min total)"
      )

      # Broadcast progress
      broadcast_progress(:resync_all, %{
        organization_id: org_id,
        years_queued: queued_count,
        years: Enum.map(all_statuses, & &1.year),
        spacing_seconds: @year_import_spacing_seconds,
        estimated_duration_minutes: total_duration_minutes
      })

      {:ok, %{queued: queued_count, spacing_seconds: @year_import_spacing_seconds}}
    end
  end

  # Batch import: resync most recent N years for an organization
  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "organization_id" => org_id,
          "action" => "resync_recent",
          "year_count" => year_count
        }
      }) do
    Logger.info(
      "AwardImportWorker: Starting resync_recent for organization #{org_id}, last #{year_count} years"
    )

    # Get ALL years for this organization, sorted by year descending
    all_statuses =
      Festivals.list_award_import_statuses(organization_id: org_id)
      |> Enum.sort_by(& &1.year, :desc)
      |> Enum.take(year_count)

    if length(all_statuses) == 0 do
      Logger.info("AwardImportWorker: No years found for organization #{org_id}")
      {:ok, %{queued: 0, message: "No years found"}}
    else
      Logger.info(
        "AwardImportWorker: Found #{length(all_statuses)} recent years to resync for organization #{org_id}"
      )

      # Queue individual import jobs with spacing to prevent overwhelming the system
      # Jobs are already sorted by year desc from the query above
      jobs =
        all_statuses
        |> Enum.with_index()
        |> Enum.map(fn {status, index} ->
          schedule_delay = index * @year_import_spacing_seconds
          new(%{"organization_id" => org_id, "year" => status.year}, schedule_in: schedule_delay)
        end)

      results = Oban.insert_all(jobs)
      queued_count = if is_list(results), do: length(results), else: 0

      total_duration_minutes = div((queued_count - 1) * @year_import_spacing_seconds, 60)

      Logger.info(
        "AwardImportWorker: Queued #{queued_count} resync jobs for organization #{org_id} (recent years) " <>
          "(spaced #{div(@year_import_spacing_seconds, 60)} min apart, ~#{total_duration_minutes} min total)"
      )

      # Broadcast progress
      broadcast_progress(:resync_all, %{
        organization_id: org_id,
        years_queued: queued_count,
        years: Enum.map(all_statuses, & &1.year),
        spacing_seconds: @year_import_spacing_seconds,
        estimated_duration_minutes: total_duration_minutes
      })

      {:ok, %{queued: queued_count, spacing_seconds: @year_import_spacing_seconds}}
    end
  end

  # Handle synthetic (negative) organization IDs from the dashboard view
  # These festivals exist in festival_events but don't have a festival_organization yet
  defp handle_synthetic_org_id(org_id, year, job) do
    Logger.info("AwardImportWorker: Handling synthetic org_id #{org_id}, looking up abbreviation")

    # Look up the abbreviation from the award_import_status view
    case Festivals.get_award_import_status_by_org_id(org_id) do
      nil ->
        Logger.error("AwardImportWorker: Could not find festival for synthetic org_id #{org_id}")
        {:error, "Festival not found for synthetic org_id: #{org_id}"}

      status ->
        Logger.info(
          "AwardImportWorker: Found festival #{status.abbreviation} for synthetic org_id #{org_id}"
        )

        # Route based on abbreviation
        case status.abbreviation do
          "AMPAS" ->
            import_oscars(year, job)

          abbrev ->
            case abbreviation_to_festival_key(abbrev) do
              nil ->
                Logger.warning("AwardImportWorker: Unknown abbreviation: #{abbrev}")
                {:error, "Unknown festival abbreviation: #{abbrev}"}

              festival_key ->
                # Import directly via UnifiedFestivalWorker (will auto-create organization)
                import_festival_by_key(festival_key, abbrev, year, job)
            end
        end
    end
  end

  # Handle real (positive) organization IDs
  defp handle_real_org_id(org_id, year, job) do
    case Repo.get(FestivalOrganization, org_id) do
      nil ->
        Logger.error("AwardImportWorker: Organization #{org_id} not found")
        {:error, "Organization not found: #{org_id}"}

      organization ->
        # Route to appropriate importer based on organization
        case organization.abbreviation do
          "AMPAS" ->
            # Oscars use direct scraping from oscars.org
            import_oscars(year, job)

          abbrev ->
            # Try to find festival key mapping for this abbreviation
            case abbreviation_to_festival_key(abbrev) do
              nil ->
                Logger.warning("AwardImportWorker: Unknown organization abbreviation: #{abbrev}")

                {:error, "Unknown organization: #{abbrev}"}

              festival_key ->
                # Other festivals use IMDb scraping via UnifiedFestivalWorker
                import_festival_by_key(festival_key, abbrev, year, job)
            end
        end
    end
  end

  # Import Oscar ceremony via Cultural module
  defp import_oscars(year, _job) do
    Logger.info("AwardImportWorker: Importing Oscar year #{year}")

    case Cultural.import_oscar_year(year, create_movies: true) do
      {:ok, result} ->
        Logger.info(
          "AwardImportWorker: Oscar import #{year} queued successfully: #{inspect(result)}"
        )

        broadcast_progress(:import_started, %{
          organization: "AMPAS",
          year: year,
          job_id: result[:job_id],
          ceremony_id: result[:ceremony_id]
        })

        :ok

      {:error, reason} ->
        Logger.error("AwardImportWorker: Failed to import Oscar year #{year}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Import festival by key - used for both synthetic and real organization IDs
  defp import_festival_by_key(festival_key, abbreviation, year, _job) do
    Logger.info("AwardImportWorker: Importing #{abbreviation} (#{festival_key}) year #{year}")

    # Queue the UnifiedFestivalWorker job
    job_args = %{
      "festival" => festival_key,
      "year" => year
    }

    case Cinegraph.Workers.UnifiedFestivalWorker.new(job_args) |> Oban.insert() do
      {:ok, job} ->
        Logger.info(
          "AwardImportWorker: Queued UnifiedFestivalWorker job #{job.id} for #{abbreviation} #{year}"
        )

        broadcast_progress(:import_started, %{
          organization: abbreviation,
          year: year,
          job_id: job.id
        })

        :ok

      {:error, reason} ->
        Logger.error(
          "AwardImportWorker: Failed to queue festival import for #{abbreviation} #{year}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Map organization abbreviation to festival key (source_key in festival_events)
  # Queries the festival_events table dynamically so new events are automatically supported
  defp abbreviation_to_festival_key(abbreviation) do
    alias Cinegraph.Events

    case Events.get_by_abbreviation(abbreviation) do
      %{source_key: source_key} -> source_key
      nil -> nil
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
