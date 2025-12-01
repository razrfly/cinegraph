defmodule CinegraphWeb.YearImportsLive do
  @moduledoc """
  Dedicated LiveView for managing year-by-year TMDb imports.
  Provides detailed controls, analytics, and monitoring for the incremental import system.
  """

  use CinegraphWeb, :live_view

  alias Cinegraph.Imports.ImportStateV2
  alias Cinegraph.Workers.DailyYearImportWorker
  alias Cinegraph.Workers.YearImportCompletionWorker
  alias Cinegraph.Repo
  import Ecto.Query
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to import progress updates
      Phoenix.PubSub.subscribe(Cinegraph.PubSub, "import_progress")
      # Refresh data every 5 seconds
      :timer.send_interval(5000, self(), :refresh_data)
    end

    socket =
      socket
      |> assign(:page_title, "Year-by-Year TMDb Import")
      |> assign(:import_paused, ImportStateV2.get("year_import_paused") == "true")
      |> assign(:selected_year, nil)
      |> assign(:show_year_details, false)
      |> load_data()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("start_next_year", _params, socket) do
    if socket.assigns.import_paused do
      {:noreply, put_flash(socket, :error, "Imports are paused. Resume imports first.")}
    else
      case DailyYearImportWorker.new(%{}) |> Oban.insert() do
        {:ok, _job} ->
          socket =
            socket
            |> put_flash(:info, "Started import for next pending year")
            |> assign(:is_running, true)
            |> load_data()

          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to start import: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("import_year", %{"year" => year_str}, socket) do
    if socket.assigns.import_paused do
      {:noreply, put_flash(socket, :error, "Imports are paused. Resume imports first.")}
    else
      current_year = Date.utc_today().year

      case Integer.parse(year_str) do
        {year, _} when year >= 1888 ->
          if year <= current_year + 1 do
            case DailyYearImportWorker.import_year(year) do
              {:ok, _job} ->
                socket =
                  socket
                  |> put_flash(:info, "Started import for year #{year}")
                  |> assign(:is_running, true)
                  |> load_data()

                {:noreply, socket}

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
            end
          else
            {:noreply, put_flash(socket, :error, "Year cannot be in the future")}
          end

        _ ->
          {:noreply, put_flash(socket, :error, "Invalid year")}
      end
    end
  end

  @impl true
  def handle_event("toggle_pause", _params, socket) do
    new_paused = !socket.assigns.import_paused
    ImportStateV2.set("year_import_paused", to_string(new_paused))

    message =
      if new_paused,
        do: "Year imports paused. No new imports will start automatically.",
        else: "Year imports resumed. Automatic imports will continue."

    socket =
      socket
      |> put_flash(:info, message)
      |> assign(:import_paused, new_paused)

    {:noreply, socket}
  end

  @impl true
  def handle_event("show_year_details", %{"year" => year_str}, socket) do
    case Integer.parse(year_str) do
      {year, _} ->
        details = load_year_details(year)

        socket =
          socket
          |> assign(:selected_year, year)
          |> assign(:year_details, details)
          |> assign(:show_year_details, true)

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_year_details", _params, socket) do
    socket =
      socket
      |> assign(:selected_year, nil)
      |> assign(:show_year_details, false)

    {:noreply, socket}
  end

  @impl true
  def handle_event("reset_year", %{"year" => year_str}, socket) do
    case Integer.parse(year_str) do
      {year, _} ->
        # Clear the year's completion state so it can be re-imported
        ImportStateV2.delete("year_#{year}_completed_at")
        ImportStateV2.delete("year_#{year}_progress")

        # Update last_completed_year if needed
        current_last = ImportStateV2.get_integer("last_completed_year", Date.utc_today().year + 1)

        if year < current_last do
          ImportStateV2.set("last_completed_year", year + 1)
        end

        socket =
          socket
          |> put_flash(:info, "Year #{year} reset. It will be re-imported on next run.")
          |> load_data()

        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid year")}
    end
  end

  @impl true
  def handle_event("cancel_year_jobs", %{"year" => year_str}, socket) do
    case Integer.parse(year_str) do
      {year, _} ->
        cancelled = cancel_jobs_for_year(year)

        socket =
          socket
          |> put_flash(:info, "Cancelled #{cancelled} pending jobs for year #{year}")
          |> load_data()

        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid year")}
    end
  end

  @impl true
  def handle_info(:refresh_data, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:year_import_complete, progress}, socket) do
    message =
      "Year #{progress.year} import complete! #{progress.completed} jobs, #{progress.movie_count} movies."

    socket =
      socket
      |> put_flash(:info, message)
      |> load_data()

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Data loading functions

  defp load_data(socket) do
    current_year = Date.utc_today().year
    years = load_all_years(current_year)
    stats = calculate_overall_stats(years)
    queue_stats = load_queue_stats()
    is_running = check_import_running()
    recent_activity = load_recent_activity()

    socket
    |> assign(:years, years)
    |> assign(:stats, stats)
    |> assign(:queue_stats, queue_stats)
    |> assign(:is_running, is_running)
    |> assign(:recent_activity, recent_activity)
    |> assign(:current_year, current_year)
  end

  defp load_all_years(current_year) do
    # Show years from current year back to 1900 (or earliest with data)
    last_completed_year = ImportStateV2.get_integer("last_completed_year", current_year + 1)
    bulk_complete = ImportStateV2.get("bulk_import_complete") == "true"

    # Determine range to show
    # Show 10 years ahead of where we're importing, plus all completed years
    end_year = max(1900, last_completed_year - 20)

    current_year..end_year
    |> Enum.map(fn year ->
      our_count = DailyYearImportWorker.count_movies_for_year(year)
      tmdb_count = ImportStateV2.get_integer("year_#{year}_total_movies", 0)
      progress_pct = ImportStateV2.get("year_#{year}_progress")

      # Get job counts for this year
      {pending, executing, completed, failed} = YearImportCompletionWorker.count_jobs_for_year(year)

      status =
        cond do
          bulk_complete -> :bulk_complete
          year > last_completed_year -> :pending
          year == last_completed_year and (pending + executing) > 0 -> :in_progress
          year < last_completed_year -> :completed
          our_count > 0 and tmdb_count > 0 and our_count >= tmdb_count * 0.95 -> :completed
          true -> :pending
        end

      completion_pct =
        if tmdb_count > 0 do
          Float.round(our_count / tmdb_count * 100, 1)
        else
          0.0
        end

      %{
        year: year,
        our_count: our_count,
        tmdb_count: tmdb_count,
        progress: progress_pct,
        completion_pct: completion_pct,
        status: status,
        pending_jobs: pending,
        executing_jobs: executing,
        completed_jobs: completed,
        failed_jobs: failed,
        started_at: ImportStateV2.get("year_#{year}_started_at"),
        completed_at: ImportStateV2.get("year_#{year}_completed_at")
      }
    end)
  end

  defp calculate_overall_stats(years) do
    total_our_movies = Enum.sum(Enum.map(years, & &1.our_count))
    total_tmdb_movies = Enum.sum(Enum.map(years, & &1.tmdb_count))
    completed_years = Enum.count(years, &(&1.status == :completed))
    in_progress_years = Enum.count(years, &(&1.status == :in_progress))
    pending_years = Enum.count(years, &(&1.status == :pending))

    overall_pct =
      if total_tmdb_movies > 0 do
        Float.round(total_our_movies / total_tmdb_movies * 100, 2)
      else
        0.0
      end

    # Estimate time to complete based on recent import rate
    import_rate = ImportStateV2.get("import_rate") || "0"
    rate = parse_float(import_rate)

    remaining = max(0, total_tmdb_movies - total_our_movies)

    eta =
      if rate > 0 do
        minutes = remaining / rate
        format_duration(minutes)
      else
        "Unknown"
      end

    %{
      total_our_movies: total_our_movies,
      total_tmdb_movies: total_tmdb_movies,
      overall_pct: overall_pct,
      completed_years: completed_years,
      in_progress_years: in_progress_years,
      pending_years: pending_years,
      remaining_movies: remaining,
      import_rate: rate,
      eta: eta
    }
  end

  defp load_queue_stats do
    queues = [:tmdb_orchestration, :tmdb_discovery, :tmdb_details]

    Enum.map(queues, fn queue ->
      queue_name = Atom.to_string(queue)

      available =
        Repo.one(
          from(j in Oban.Job,
            where: j.queue == ^queue_name and j.state == "available",
            select: count(j.id)
          )
        ) || 0

      executing =
        Repo.one(
          from(j in Oban.Job,
            where: j.queue == ^queue_name and j.state == "executing",
            select: count(j.id)
          )
        ) || 0

      completed =
        Repo.one(
          from(j in Oban.Job,
            where: j.queue == ^queue_name and j.state == "completed",
            select: count(j.id)
          )
        ) || 0

      %{
        queue: queue,
        name: format_queue_name(queue),
        available: available,
        executing: executing,
        completed: completed
      }
    end)
  end

  defp check_import_running do
    count =
      Repo.one(
        from(j in Oban.Job,
          where:
            j.worker == "Cinegraph.Workers.DailyYearImportWorker" and
              j.state in ["available", "executing", "scheduled"],
          select: count(j.id)
        )
      ) || 0

    count > 0
  end

  defp load_recent_activity do
    # Get recent import state changes
    query =
      from(a in Cinegraph.Metrics.ApiLookupMetric,
        where:
          a.source == "tmdb" and
            a.operation == "import_state" and
            a.inserted_at > ago(24, "hour"),
        order_by: [desc: a.inserted_at],
        limit: 20,
        select: %{
          key: a.target_identifier,
          metadata: a.metadata,
          timestamp: a.inserted_at
        }
      )

    Repo.all(query)
    |> Enum.map(fn row ->
      %{
        key: row.key,
        value: get_in(row.metadata, ["value"]) || "—",
        timestamp: row.timestamp
      }
    end)
  end

  defp load_year_details(year) do
    # Get detailed stats for a specific year
    our_count = DailyYearImportWorker.count_movies_for_year(year)
    tmdb_count = ImportStateV2.get_integer("year_#{year}_total_movies", 0)
    {pending, executing, completed, failed} = YearImportCompletionWorker.count_jobs_for_year(year)

    # Get sample of recent movies imported for this year
    recent_movies =
      Repo.all(
        from(m in Cinegraph.Movies.Movie,
          where: fragment("EXTRACT(YEAR FROM ?::date) = ?", m.release_date, ^year),
          order_by: [desc: m.inserted_at],
          limit: 10,
          select: %{
            id: m.id,
            title: m.title,
            release_date: m.release_date,
            tmdb_id: m.tmdb_id,
            inserted_at: m.inserted_at
          }
        )
      )

    %{
      year: year,
      our_count: our_count,
      tmdb_count: tmdb_count,
      completion_pct:
        if(tmdb_count > 0, do: Float.round(our_count / tmdb_count * 100, 1), else: 0.0),
      pending_jobs: pending,
      executing_jobs: executing,
      completed_jobs: completed,
      failed_jobs: failed,
      total_jobs: pending + executing + completed + failed,
      started_at: ImportStateV2.get("year_#{year}_started_at"),
      completed_at: ImportStateV2.get("year_#{year}_completed_at"),
      recent_movies: recent_movies
    }
  end

  defp cancel_jobs_for_year(year) do
    # Find job IDs first, then cancel via Oban's API to properly trigger lifecycle callbacks
    job_ids =
      Repo.all(
        from(j in Oban.Job,
          where:
            j.worker == "Cinegraph.Workers.TMDbDiscoveryWorker" and
              j.state in ["available", "scheduled"] and
              fragment("?->>'import_type' = 'year_import'", j.args) and
              fragment("(?->>'year')::int = ?", j.args, ^year),
          select: j.id
        )
      )

    Enum.each(job_ids, &Oban.cancel_job/1)
    length(job_ids)
  end

  # Helper functions

  defp format_queue_name(:tmdb_orchestration), do: "Orchestration"
  defp format_queue_name(:tmdb_discovery), do: "Discovery"
  defp format_queue_name(:tmdb_details), do: "Details"
  defp format_queue_name(queue), do: queue |> Atom.to_string() |> String.replace("_", " ")

  defp parse_float(str) when is_binary(str) do
    case Float.parse(str) do
      {val, _} -> val
      :error -> 0.0
    end
  end

  defp parse_float(_), do: 0.0

  defp format_duration(minutes) when minutes < 60, do: "#{round(minutes)} min"
  defp format_duration(minutes) when minutes < 1440, do: "#{Float.round(minutes / 60, 1)} hours"
  defp format_duration(minutes), do: "#{Float.round(minutes / 1440, 1)} days"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 py-8">
      <!-- Header -->
      <div class="mb-8">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-3xl font-bold text-gray-900">Year-by-Year TMDb Import</h1>
            <p class="mt-1 text-gray-600">
              Incrementally importing the full TMDb catalog, one year at a time
            </p>
          </div>
          <.link
            navigate="/admin/imports"
            class="text-indigo-600 hover:text-indigo-800 flex items-center gap-1"
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M10 19l-7-7m0 0l7-7m-7 7h18"
              />
            </svg>
            Back to Import Dashboard
          </.link>
        </div>
      </div>

    <!-- Overall Stats -->
      <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
        <div class="bg-white rounded-lg shadow p-6">
          <div class="text-sm text-gray-500">Overall Progress</div>
          <div class="text-2xl font-bold text-indigo-600">{@stats.overall_pct}%</div>
          <div class="mt-2 h-2 bg-gray-200 rounded-full">
            <div
              class="h-2 bg-indigo-600 rounded-full transition-all duration-500"
              style={"width: #{min(@stats.overall_pct, 100)}%"}
            >
            </div>
          </div>
        </div>
        <div class="bg-white rounded-lg shadow p-6">
          <div class="text-sm text-gray-500">Movies Imported</div>
          <div class="text-2xl font-bold">
            {Number.Delimit.number_to_delimited(@stats.total_our_movies, precision: 0)}
          </div>
          <div class="text-sm text-gray-400">
            of {Number.Delimit.number_to_delimited(@stats.total_tmdb_movies, precision: 0)} total
          </div>
        </div>
        <div class="bg-white rounded-lg shadow p-6">
          <div class="text-sm text-gray-500">Years Status</div>
          <div class="flex items-baseline gap-2">
            <span class="text-2xl font-bold text-green-600">{@stats.completed_years}</span>
            <span class="text-gray-400">complete</span>
          </div>
          <div class="text-sm">
            <span class="text-yellow-600">{@stats.in_progress_years}</span>
            in progress, <span class="text-gray-400">{@stats.pending_years}</span>
            pending
          </div>
        </div>
        <div class="bg-white rounded-lg shadow p-6">
          <div class="text-sm text-gray-500">Estimated Time</div>
          <div class="text-2xl font-bold">{@stats.eta}</div>
          <div class="text-sm text-gray-400">
            at {Float.round(@stats.import_rate, 1)} movies/min
          </div>
        </div>
      </div>

    <!-- Controls -->
      <div class="bg-white rounded-lg shadow p-6 mb-8">
        <h2 class="text-lg font-semibold mb-4">Import Controls</h2>
        <div class="flex flex-wrap items-center gap-4">
          <!-- Start Next Year Button -->
          <button
            phx-click="start_next_year"
            disabled={@is_running || @import_paused}
            class={"px-4 py-2 rounded-md text-white font-medium transition-colors " <>
              if(@is_running || @import_paused, do: "bg-gray-400 cursor-not-allowed", else: "bg-indigo-600 hover:bg-indigo-700")}
          >
            <%= if @is_running do %>
              <span class="flex items-center gap-2">
                <svg class="animate-spin h-4 w-4" fill="none" viewBox="0 0 24 24">
                  <circle
                    class="opacity-25"
                    cx="12"
                    cy="12"
                    r="10"
                    stroke="currentColor"
                    stroke-width="4"
                  >
                  </circle>
                  <path
                    class="opacity-75"
                    fill="currentColor"
                    d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                  >
                  </path>
                </svg>
                Import Running...
              </span>
            <% else %>
              Start Next Year Import
            <% end %>
          </button>

    <!-- Import Specific Year -->
          <form phx-submit="import_year" class="flex items-center gap-2">
            <input
              type="number"
              name="year"
              placeholder="Year"
              min="1888"
              max={@current_year + 1}
              class="w-24 px-3 py-2 border border-gray-300 rounded-md"
            />
            <button
              type="submit"
              disabled={@is_running || @import_paused}
              class={"px-4 py-2 rounded-md text-white font-medium transition-colors " <>
                if(@is_running || @import_paused, do: "bg-gray-400 cursor-not-allowed", else: "bg-green-600 hover:bg-green-700")}
            >
              Import Year
            </button>
          </form>

    <!-- Pause/Resume Toggle -->
          <button
            phx-click="toggle_pause"
            class={"px-4 py-2 rounded-md font-medium transition-colors " <>
              if(@import_paused,
                do: "bg-green-100 text-green-700 hover:bg-green-200",
                else: "bg-yellow-100 text-yellow-700 hover:bg-yellow-200")}
          >
            <%= if @import_paused do %>
              <span class="flex items-center gap-2">
                <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 20 20">
                  <path
                    fill-rule="evenodd"
                    d="M10 18a8 8 0 100-16 8 8 0 000 16zM9.555 7.168A1 1 0 008 8v4a1 1 0 001.555.832l3-2a1 1 0 000-1.664l-3-2z"
                    clip-rule="evenodd"
                  />
                </svg>
                Resume Imports
              </span>
            <% else %>
              <span class="flex items-center gap-2">
                <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 20 20">
                  <path
                    fill-rule="evenodd"
                    d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zM7 8a1 1 0 012 0v4a1 1 0 11-2 0V8zm5-1a1 1 0 00-1 1v4a1 1 0 102 0V8a1 1 0 00-1-1z"
                    clip-rule="evenodd"
                  />
                </svg>
                Pause Imports
              </span>
            <% end %>
          </button>

    <!-- Status Indicator -->
          <div class="ml-auto flex items-center gap-2">
            <%= if @import_paused do %>
              <span class="px-3 py-1 bg-yellow-100 text-yellow-800 rounded-full text-sm font-medium">
                Paused
              </span>
            <% else %>
              <%= if @is_running do %>
                <span class="px-3 py-1 bg-green-100 text-green-800 rounded-full text-sm font-medium flex items-center gap-1">
                  <span class="w-2 h-2 bg-green-500 rounded-full animate-pulse"></span>
                  Running
                </span>
              <% else %>
                <span class="px-3 py-1 bg-gray-100 text-gray-600 rounded-full text-sm font-medium">
                  Idle
                </span>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>

    <!-- Queue Status -->
      <div class="bg-white rounded-lg shadow p-6 mb-8">
        <h2 class="text-lg font-semibold mb-4">Queue Status</h2>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <%= for queue <- @queue_stats do %>
            <div class="border rounded-lg p-4">
              <div class="font-medium text-gray-700">{queue.name}</div>
              <div class="mt-2 grid grid-cols-3 gap-2 text-center text-sm">
                <div>
                  <div class="text-lg font-bold text-yellow-600">{queue.available}</div>
                  <div class="text-gray-500">Pending</div>
                </div>
                <div>
                  <div class="text-lg font-bold text-blue-600">{queue.executing}</div>
                  <div class="text-gray-500">Running</div>
                </div>
                <div>
                  <div class="text-lg font-bold text-green-600">{queue.completed}</div>
                  <div class="text-gray-500">Done</div>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>

    <!-- Year-by-Year Grid -->
      <div class="bg-white rounded-lg shadow p-6 mb-8">
        <h2 class="text-lg font-semibold mb-4">Year Progress</h2>
        <div class="overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Year
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Our Movies
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  TMDb Total
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Completion
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Jobs
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Status
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <%= for year_data <- @years do %>
                <tr class={"hover:bg-gray-50 " <> if(year_data.status == :in_progress, do: "bg-blue-50", else: "")}>
                  <td class="px-4 py-3 whitespace-nowrap font-medium">{year_data.year}</td>
                  <td class="px-4 py-3 whitespace-nowrap">
                    {Number.Delimit.number_to_delimited(year_data.our_count, precision: 0)}
                  </td>
                  <td class="px-4 py-3 whitespace-nowrap">
                    <%= if year_data.tmdb_count > 0 do %>
                      {Number.Delimit.number_to_delimited(year_data.tmdb_count, precision: 0)}
                    <% else %>
                      <span class="text-gray-400">—</span>
                    <% end %>
                  </td>
                  <td class="px-4 py-3 whitespace-nowrap">
                    <%= if year_data.tmdb_count > 0 do %>
                      <div class="flex items-center gap-2">
                        <div class="w-24 h-2 bg-gray-200 rounded-full">
                          <div
                            class={"h-2 rounded-full " <> completion_color(year_data.completion_pct)}
                            style={"width: #{min(year_data.completion_pct, 100)}%"}
                          >
                          </div>
                        </div>
                        <span class="text-sm text-gray-600">{year_data.completion_pct}%</span>
                      </div>
                    <% else %>
                      <span class="text-gray-400">—</span>
                    <% end %>
                  </td>
                  <td class="px-4 py-3 whitespace-nowrap text-sm">
                    <%= if year_data.pending_jobs + year_data.executing_jobs + year_data.completed_jobs > 0 do %>
                      <span class="text-yellow-600">{year_data.pending_jobs}</span>
                      /
                      <span class="text-blue-600">{year_data.executing_jobs}</span>
                      /
                      <span class="text-green-600">{year_data.completed_jobs}</span>
                      <%= if year_data.failed_jobs > 0 do %>
                        / <span class="text-red-600">{year_data.failed_jobs}</span>
                      <% end %>
                    <% else %>
                      <span class="text-gray-400">—</span>
                    <% end %>
                  </td>
                  <td class="px-4 py-3 whitespace-nowrap">
                    <span class={status_badge_class(year_data.status)}>
                      {status_label(year_data.status)}
                    </span>
                  </td>
                  <td class="px-4 py-3 whitespace-nowrap">
                    <div class="flex items-center gap-2">
                      <button
                        phx-click="show_year_details"
                        phx-value-year={year_data.year}
                        class="text-indigo-600 hover:text-indigo-800 text-sm"
                      >
                        Details
                      </button>
                      <%= if year_data.status == :completed do %>
                        <button
                          phx-click="reset_year"
                          phx-value-year={year_data.year}
                          class="text-yellow-600 hover:text-yellow-800 text-sm"
                          data-confirm="Reset year #{year_data.year}? It will be re-imported."
                        >
                          Reset
                        </button>
                      <% end %>
                      <%= if year_data.pending_jobs > 0 do %>
                        <button
                          phx-click="cancel_year_jobs"
                          phx-value-year={year_data.year}
                          class="text-red-600 hover:text-red-800 text-sm"
                          data-confirm="Cancel #{year_data.pending_jobs} pending jobs for #{year_data.year}?"
                        >
                          Cancel
                        </button>
                      <% end %>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>

    <!-- Recent Activity -->
      <div class="bg-white rounded-lg shadow p-6">
        <h2 class="text-lg font-semibold mb-4">Recent Activity (Last 24 Hours)</h2>
        <%= if Enum.empty?(@recent_activity) do %>
          <p class="text-gray-500">No recent activity</p>
        <% else %>
          <div class="space-y-2 max-h-64 overflow-y-auto">
            <%= for activity <- @recent_activity do %>
              <div class="flex items-center justify-between text-sm py-1 border-b border-gray-100">
                <span class="text-gray-600">{activity.key}</span>
                <span class="font-mono text-gray-800">{activity.value}</span>
                <span class="text-gray-400">
                  {Calendar.strftime(activity.timestamp, "%H:%M:%S")}
                </span>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

    <!-- Year Details Modal -->
      <%= if @show_year_details && @year_details do %>
        <div
          class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50"
          phx-click="close_year_details"
        >
          <div
            class="bg-white rounded-lg shadow-xl max-w-2xl w-full mx-4 max-h-[80vh] overflow-y-auto"
            phx-click-away="close_year_details"
          >
            <div class="p-6">
              <div class="flex items-center justify-between mb-4">
                <h3 class="text-xl font-bold">Year {@year_details.year} Details</h3>
                <button
                  phx-click="close_year_details"
                  class="text-gray-400 hover:text-gray-600"
                >
                  <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M6 18L18 6M6 6l12 12"
                    />
                  </svg>
                </button>
              </div>

    <!-- Year Stats -->
              <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
                <div class="bg-gray-50 rounded p-3">
                  <div class="text-sm text-gray-500">Our Movies</div>
                  <div class="text-xl font-bold">
                    {Number.Delimit.number_to_delimited(@year_details.our_count, precision: 0)}
                  </div>
                </div>
                <div class="bg-gray-50 rounded p-3">
                  <div class="text-sm text-gray-500">TMDb Total</div>
                  <div class="text-xl font-bold">
                    {Number.Delimit.number_to_delimited(@year_details.tmdb_count, precision: 0)}
                  </div>
                </div>
                <div class="bg-gray-50 rounded p-3">
                  <div class="text-sm text-gray-500">Completion</div>
                  <div class="text-xl font-bold text-indigo-600">
                    {@year_details.completion_pct}%
                  </div>
                </div>
                <div class="bg-gray-50 rounded p-3">
                  <div class="text-sm text-gray-500">Total Jobs</div>
                  <div class="text-xl font-bold">{@year_details.total_jobs}</div>
                </div>
              </div>

    <!-- Job Breakdown -->
              <div class="mb-6">
                <h4 class="font-medium mb-2">Job Status</h4>
                <div class="flex items-center gap-4 text-sm">
                  <span class="text-yellow-600">
                    Pending: {@year_details.pending_jobs}
                  </span>
                  <span class="text-blue-600">
                    Executing: {@year_details.executing_jobs}
                  </span>
                  <span class="text-green-600">
                    Completed: {@year_details.completed_jobs}
                  </span>
                  <span class="text-red-600">Failed: {@year_details.failed_jobs}</span>
                </div>
              </div>

    <!-- Timestamps -->
              <div class="mb-6">
                <h4 class="font-medium mb-2">Timeline</h4>
                <div class="text-sm text-gray-600">
                  <div>
                    Started: {@year_details.started_at || "Not started"}
                  </div>
                  <div>
                    Completed: {@year_details.completed_at || "In progress"}
                  </div>
                </div>
              </div>

    <!-- Recent Movies -->
              <%= if @year_details.recent_movies != [] do %>
                <div>
                  <h4 class="font-medium mb-2">Recently Imported Movies</h4>
                  <div class="space-y-2">
                    <%= for movie <- @year_details.recent_movies do %>
                      <div class="flex items-center justify-between text-sm py-1 border-b border-gray-100">
                        <.link
                          navigate={"/movies/#{movie.id}"}
                          class="text-indigo-600 hover:text-indigo-800"
                        >
                          {movie.title}
                        </.link>
                        <span class="text-gray-400">{movie.release_date}</span>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

    <!-- Actions -->
              <div class="mt-6 pt-4 border-t flex justify-end gap-2">
                <button
                  phx-click="import_year"
                  phx-value-year={@year_details.year}
                  class="px-4 py-2 bg-indigo-600 text-white rounded hover:bg-indigo-700"
                >
                  Import This Year
                </button>
                <button
                  phx-click="close_year_details"
                  class="px-4 py-2 bg-gray-200 text-gray-700 rounded hover:bg-gray-300"
                >
                  Close
                </button>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Helper functions for rendering

  defp status_badge_class(:completed),
    do: "px-2 py-1 text-xs font-medium rounded-full bg-green-100 text-green-800"

  defp status_badge_class(:in_progress),
    do: "px-2 py-1 text-xs font-medium rounded-full bg-blue-100 text-blue-800"

  defp status_badge_class(:pending),
    do: "px-2 py-1 text-xs font-medium rounded-full bg-gray-100 text-gray-600"

  defp status_badge_class(:bulk_complete),
    do: "px-2 py-1 text-xs font-medium rounded-full bg-purple-100 text-purple-800"

  defp status_badge_class(_),
    do: "px-2 py-1 text-xs font-medium rounded-full bg-gray-100 text-gray-600"

  defp status_label(:completed), do: "Complete"
  defp status_label(:in_progress), do: "In Progress"
  defp status_label(:pending), do: "Pending"
  defp status_label(:bulk_complete), do: "Bulk Complete"
  defp status_label(_), do: "Unknown"

  defp completion_color(pct) when pct >= 95, do: "bg-green-500"
  defp completion_color(pct) when pct >= 50, do: "bg-blue-500"
  defp completion_color(pct) when pct >= 10, do: "bg-yellow-500"
  defp completion_color(_), do: "bg-gray-400"
end
