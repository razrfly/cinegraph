defmodule Cinegraph.Workers.AwardImportOrchestratorWorker do
  @moduledoc """
  Orchestrator worker for batch operations across all festival organizations.

  Handles high-level operations like:
  - Syncing all missing years across all organizations
  - Discovering coverage gaps without importing
  - Reporting on overall import status

  This worker coordinates with `AwardImportWorker` for actual imports.
  """

  use Oban.Worker,
    queue: :scraping,
    max_attempts: 1,
    priority: 0

  alias Cinegraph.Festivals
  alias Cinegraph.Workers.AwardImportWorker
  require Logger

  # Spacing between organization sync jobs in seconds (10 minutes)
  # This prevents multiple organizations from processing simultaneously
  @org_sync_spacing_seconds 600

  @doc """
  Queue a sync operation for all organizations.
  """
  def queue_sync_all_missing do
    %{"action" => "sync_all_missing"}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Queue a gap discovery operation.
  """
  def queue_discover_gaps do
    %{"action" => "discover_gaps"}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "sync_all_missing"}}) do
    Logger.info("AwardImportOrchestratorWorker: Starting sync_all_missing")

    # Get all organizations
    orgs = Festivals.list_organizations()

    if length(orgs) == 0 do
      Logger.warning("AwardImportOrchestratorWorker: No organizations found")
      {:ok, %{organizations_queued: 0}}
    else
      Logger.info("AwardImportOrchestratorWorker: Found #{length(orgs)} organizations to sync")

      # Queue sync_missing for each organization with spacing
      # Each org's sync job is scheduled 10 minutes apart to prevent overwhelming the system
      jobs =
        orgs
        |> Enum.with_index()
        |> Enum.map(fn {org, index} ->
          schedule_delay = index * @org_sync_spacing_seconds

          AwardImportWorker.new(
            %{
              "organization_id" => org.id,
              "action" => "sync_missing"
            },
            schedule_in: schedule_delay
          )
        end)

      results = Oban.insert_all(jobs)
      queued_count = if is_list(results), do: length(results), else: 0

      total_duration_minutes = div((queued_count - 1) * @org_sync_spacing_seconds, 60)

      Logger.info(
        "AwardImportOrchestratorWorker: Queued sync_missing for #{queued_count} organizations " <>
          "(spaced #{div(@org_sync_spacing_seconds, 60)} min apart, ~#{total_duration_minutes} min total)"
      )

      # Broadcast progress
      broadcast_progress(:sync_all_started, %{
        organizations_queued: queued_count,
        organizations: Enum.map(orgs, fn org -> %{id: org.id, name: org.name} end),
        spacing_seconds: @org_sync_spacing_seconds,
        estimated_duration_minutes: total_duration_minutes
      })

      {:ok, %{organizations_queued: queued_count, spacing_seconds: @org_sync_spacing_seconds}}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "discover_gaps"}}) do
    Logger.info("AwardImportOrchestratorWorker: Starting discover_gaps")

    # Get all import statuses with gaps (not_started, failed, etc.)
    gaps =
      Festivals.list_award_import_statuses()
      |> Enum.filter(fn status ->
        status.status in ["not_started", "failed", "no_matches", "low_match", "empty"]
      end)

    # Group by organization for better reporting
    gaps_by_org =
      gaps
      |> Enum.group_by(& &1.abbreviation)
      |> Enum.map(fn {abbrev, statuses} ->
        %{
          abbreviation: abbrev,
          organization_name: List.first(statuses).organization_name,
          gap_count: length(statuses),
          years: Enum.map(statuses, & &1.year) |> Enum.sort(),
          statuses: Enum.frequencies_by(statuses, & &1.status)
        }
      end)
      |> Enum.sort_by(& &1.gap_count, :desc)

    summary = %{
      total_gaps: length(gaps),
      organizations_with_gaps: length(gaps_by_org),
      by_organization: gaps_by_org,
      by_status: Enum.frequencies_by(gaps, & &1.status),
      timestamp: DateTime.utc_now()
    }

    Logger.info(
      "AwardImportOrchestratorWorker: Found #{length(gaps)} gaps across #{length(gaps_by_org)} organizations"
    )

    # Broadcast the gaps discovered
    broadcast_progress(:gaps_discovered, summary)

    {:ok, summary}
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "get_import_summary"}}) do
    Logger.info("AwardImportOrchestratorWorker: Getting import summary")

    # Get comprehensive summary using the Festivals context
    summary = Festivals.get_award_import_summary()

    # Add organization-level details
    org_summaries =
      Festivals.list_organizations()
      |> Enum.map(fn org ->
        org_statuses = Festivals.list_award_import_statuses(organization_id: org.id)

        %{
          organization_id: org.id,
          name: org.name,
          abbreviation: org.abbreviation,
          total_years: length(org_statuses),
          completed: Enum.count(org_statuses, &(&1.status == "completed")),
          partial: Enum.count(org_statuses, &(&1.status == "partial")),
          not_started: Enum.count(org_statuses, &(&1.status == "not_started")),
          failed: Enum.count(org_statuses, &(&1.status in ["failed", "no_matches", "low_match"])),
          year_range: Festivals.get_organization_year_range(org.id)
        }
      end)

    full_summary =
      Map.merge(summary, %{
        organizations: org_summaries,
        timestamp: DateTime.utc_now()
      })

    # Broadcast the summary
    broadcast_progress(:import_summary, full_summary)

    {:ok, full_summary}
  end

  # Handle retry of failed imports for a specific organization
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "retry_failed", "organization_id" => org_id}}) do
    Logger.info(
      "AwardImportOrchestratorWorker: Retrying failed imports for organization #{org_id}"
    )

    # Find years with any failure status (failed, no_matches, low_match, empty)
    failed_statuses =
      Festivals.list_award_import_statuses(organization_id: org_id)
      |> Enum.filter(fn status ->
        status.status in ["failed", "no_matches", "low_match", "empty"]
      end)

    # Use same spacing as AwardImportWorker (5 minutes)
    year_spacing_seconds = 300

    if length(failed_statuses) == 0 do
      Logger.info(
        "AwardImportOrchestratorWorker: No failed imports found for organization #{org_id}"
      )

      {:ok, %{retried: 0}}
    else
      # Queue import jobs for each failed year with spacing
      jobs =
        failed_statuses
        |> Enum.sort_by(& &1.year, :desc)
        |> Enum.with_index()
        |> Enum.map(fn {status, index} ->
          schedule_delay = index * year_spacing_seconds

          AwardImportWorker.new(
            %{"organization_id" => org_id, "year" => status.year},
            schedule_in: schedule_delay
          )
        end)

      results = Oban.insert_all(jobs)
      queued_count = if is_list(results), do: length(results), else: 0

      total_duration_minutes = div((queued_count - 1) * year_spacing_seconds, 60)

      Logger.info(
        "AwardImportOrchestratorWorker: Queued #{queued_count} retry jobs for organization #{org_id} " <>
          "(spaced #{div(year_spacing_seconds, 60)} min apart, ~#{total_duration_minutes} min total)"
      )

      broadcast_progress(:retry_queued, %{
        organization_id: org_id,
        years_retried: queued_count,
        years: Enum.map(failed_statuses, & &1.year),
        spacing_seconds: year_spacing_seconds,
        estimated_duration_minutes: total_duration_minutes
      })

      {:ok, %{retried: queued_count, spacing_seconds: year_spacing_seconds}}
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
