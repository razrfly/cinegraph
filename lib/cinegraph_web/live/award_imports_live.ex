defmodule CinegraphWeb.AwardImportsLive do
  @moduledoc """
  LiveView dashboard for managing awards/festival import operations.
  Uses AwardImportStats cache for efficient data loading.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Cache.AwardImportStats
  alias Cinegraph.Workers.{AwardImportWorker, AwardImportOrchestratorWorker}
  require Logger

  @refresh_interval 5000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Cinegraph.PubSub, "award_imports")
    end

    socket =
      socket
      |> assign(:page_title, "Awards Import Dashboard")
      |> assign(:selected_organization, nil)
      |> assign(:show_detail_modal, false)
      |> assign(:import_running, false)
      |> assign(:import_progress, nil)
      |> load_data()
      |> schedule_refresh()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket =
      socket
      |> load_data()
      |> schedule_refresh()

    {:noreply, socket}
  end

  @impl true
  def handle_info(:stats_updated, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info(:cache_invalidated, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:org_years_updated, org_id}, socket) do
    if socket.assigns.selected_organization &&
         socket.assigns.selected_organization.organization_id == org_id do
      years = AwardImportStats.get_organization_years(org_id)
      {:noreply, assign(socket, :organization_years, years)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:import_started, data}, socket) do
    socket =
      socket
      |> assign(:import_running, true)
      |> assign(:import_progress, format_import_progress(data))

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_missing, data}, socket) do
    socket =
      socket
      |> put_flash(:info, "Queued #{data.years_queued} imports for organization")
      |> assign(:import_running, true)
      |> load_data()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_all_started, data}, socket) do
    socket =
      socket
      |> put_flash(:info, "Queued sync for #{data.organizations_queued} organizations")
      |> assign(:import_running, true)
      |> load_data()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:gaps_discovered, data}, socket) do
    socket =
      socket
      |> put_flash(
        :info,
        "Found #{data.total_gaps} import gaps across #{data.organizations_with_gaps} organizations"
      )
      |> load_data()

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Event Handlers

  @impl true
  def handle_event("show_organization_detail", %{"org-id" => org_id_str}, socket) do
    case Integer.parse(org_id_str) do
      {org_id, ""} ->
        stats = AwardImportStats.get_stats()

        org =
          Enum.find(stats.organizations, fn o ->
            o.organization_id == org_id
          end)

        years = AwardImportStats.get_organization_years(org_id)

        socket =
          socket
          |> assign(:selected_organization, org)
          |> assign(:organization_years, years)
          |> assign(:show_detail_modal, true)

        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid organization ID")}
    end
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_detail_modal, false)
      |> assign(:selected_organization, nil)
      |> assign(:organization_years, [])

    {:noreply, socket}
  end

  @impl true
  def handle_event("import_year", %{"org-id" => org_id_str, "year" => year_str}, socket) do
    with {org_id, ""} <- Integer.parse(org_id_str),
         {year, ""} <- Integer.parse(year_str) do
      case AwardImportWorker.queue_import(org_id, year) do
        {:ok, _job} ->
          socket =
            socket
            |> put_flash(:info, "Queued import for year #{year}")
            |> assign(:import_running, true)

          {:noreply, socket}

        {:error, reason} ->
          socket = put_flash(socket, :error, "Failed to queue import: #{inspect(reason)}")
          {:noreply, socket}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Invalid organization ID or year")}
    end
  end

  @impl true
  def handle_event("sync_organization", %{"org-id" => org_id_str}, socket) do
    case Integer.parse(org_id_str) do
      {org_id, ""} ->
        case AwardImportWorker.queue_sync_missing(org_id) do
          {:ok, _job} ->
            socket =
              socket
              |> put_flash(:info, "Queued sync for missing years")
              |> assign(:import_running, true)

            {:noreply, socket}

          {:error, reason} ->
            socket = put_flash(socket, :error, "Failed to queue sync: #{inspect(reason)}")
            {:noreply, socket}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid organization ID")}
    end
  end

  @impl true
  def handle_event("sync_all_organizations", _params, socket) do
    case AwardImportOrchestratorWorker.queue_sync_all_missing() do
      {:ok, _job} ->
        socket =
          socket
          |> put_flash(:info, "Queued sync for all organizations")
          |> assign(:import_running, true)

        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to queue sync: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("discover_gaps", _params, socket) do
    case AwardImportOrchestratorWorker.queue_discover_gaps() do
      {:ok, _job} ->
        socket = put_flash(socket, :info, "Discovering import gaps...")
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to discover gaps: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh_cache", _params, socket) do
    AwardImportStats.refresh()
    socket = put_flash(socket, :info, "Cache refresh triggered")
    {:noreply, socket}
  end

  # Private Functions

  defp load_data(socket) do
    stats = AwardImportStats.get_stats()

    socket
    |> assign(:overall_stats, stats.overall)
    |> assign(:organizations, stats.organizations)
    |> assign(:queue_status, stats.queue_status)
    |> assign(:recent_activity, stats.recent_activity)
    |> assign(:stats_loading, Map.get(stats, :loading, false))
  end

  defp schedule_refresh(socket) do
    if connected?(socket) do
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    socket
  end

  defp format_import_progress(data) do
    org = Map.get(data, :organization, "Unknown")
    year = Map.get(data, :year, "")
    "Importing #{org} #{year}..."
  end

  # Template Helper Functions

  def format_number(nil), do: "0"

  def format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_number(num) when is_float(num) do
    format_number(round(num))
  end

  def status_color("completed"), do: "bg-green-100 text-green-800"
  def status_color("partial"), do: "bg-yellow-100 text-yellow-800"
  def status_color("pending"), do: "bg-gray-100 text-gray-800"
  def status_color("not_started"), do: "bg-gray-100 text-gray-600"
  def status_color("failed"), do: "bg-red-100 text-red-800"
  def status_color("no_matches"), do: "bg-orange-100 text-orange-800"
  def status_color("low_match"), do: "bg-orange-100 text-orange-800"
  def status_color("empty"), do: "bg-gray-100 text-gray-500"
  def status_color(_), do: "bg-gray-100 text-gray-800"

  def status_icon("completed"), do: "check-circle"
  def status_icon("partial"), do: "exclamation-circle"
  def status_icon("pending"), do: "clock"
  def status_icon("not_started"), do: "minus-circle"
  def status_icon("failed"), do: "x-circle"
  def status_icon("no_matches"), do: "question-mark-circle"
  def status_icon("low_match"), do: "exclamation-triangle"
  def status_icon("empty"), do: "document"
  def status_icon(_), do: "question-mark-circle"

  def format_datetime(nil), do: "Never"

  def format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  def format_datetime(_), do: "Unknown"

  def format_rate(nil), do: "0%"
  def format_rate(rate) when is_float(rate), do: "#{Float.round(rate, 1)}%"
  def format_rate(rate) when is_number(rate), do: "#{rate}%"
  def format_rate(_), do: "0%"
end
