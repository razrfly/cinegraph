defmodule CinegraphWeb.YearImportsLive do
  @moduledoc """
  Dedicated LiveView for managing year-by-year TMDb imports.
  Provides detailed controls, analytics, and monitoring for the incremental import system.

  Uses cached stats from DashboardStats to prevent timeout issues with large datasets.
  """

  use CinegraphWeb, :live_view

  alias Cinegraph.Imports.ImportStateV2
  alias Cinegraph.Workers.DailyYearImportWorker
  alias Cinegraph.Workers.YearImportCompletionWorker
  alias Cinegraph.Workers.ScheduledBackfillWorker
  alias Cinegraph.Cache.DashboardStats
  alias Cinegraph.Repo
  import Ecto.Query
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to import progress updates
      Phoenix.PubSub.subscribe(Cinegraph.PubSub, "import_progress")
      # Subscribe to cached stats updates
      Phoenix.PubSub.subscribe(Cinegraph.PubSub, "year_imports_stats")
      # Refresh data every 30 seconds (increased from 5s since we use cache)
      :timer.send_interval(30_000, self(), :refresh_data)
    end

    socket =
      socket
      |> assign(:page_title, "Year-by-Year TMDb Import")
      |> assign(:selected_year, nil)
      |> assign(:show_year_details, false)
      |> assign(:loading, true)
      |> load_data()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
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
  def handle_info(:stats_updated, socket) do
    # Cache has been updated, reload data
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:year_import_complete, progress}, socket) do
    message =
      "Year #{progress.year} import complete! #{progress.completed} jobs, #{progress.movie_count} movies."

    # Invalidate cache when import completes
    DashboardStats.invalidate()

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

    # Use cached stats to prevent timeout issues
    cached = DashboardStats.get_year_imports_stats()

    # Provide defaults for all required fields to prevent template errors
    # Data-driven status counts (Issue #425)
    default_stats = %{
      total_our_movies: 0,
      total_tmdb_movies: 0,
      overall_pct: 0.0,
      completed_years: 0,
      partial_years: 0,
      in_progress_years: 0,
      started_years: 0,
      pending_years: 0,
      unknown_years: 0,
      remaining_movies: 0,
      import_rate: 0.0,
      eta: "Unknown"
    }

    # Get backfill queue health status
    backfill_health = ScheduledBackfillWorker.health_check()

    socket
    |> assign(:years, Map.get(cached, :years, []))
    |> assign(:stats, Map.merge(default_stats, Map.get(cached, :stats, %{})))
    |> assign(:queue_stats, Map.get(cached, :queue_stats, []))
    |> assign(:is_running, Map.get(cached, :is_running, false))
    |> assign(:backfill_health, backfill_health)
    |> assign(:current_year, current_year)
    |> assign(:loading, Map.get(cached, :loading, false))
  end

  # Note: load_all_years, calculate_overall_stats, load_queue_stats,
  # check_import_running, and load_recent_activity have been moved to
  # Cinegraph.Cache.DashboardStats for efficient batched querying and caching.

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

  # Helper functions moved to DashboardStats module

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
          <div class="flex items-center gap-4">
            <%= if @loading do %>
              <span class="text-sm text-gray-500 flex items-center gap-2">
                <svg class="animate-spin h-4 w-4 text-indigo-600" fill="none" viewBox="0 0 24 24">
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
                Loading stats...
              </span>
            <% end %>
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
          <div class="text-sm text-gray-500 mb-2">Years Status</div>
          <div class="flex items-baseline gap-2">
            <span class="text-2xl font-bold text-green-600">{@stats.completed_years}</span>
            <span class="text-gray-400">complete (95%+)</span>
          </div>
          <div class="text-sm space-y-1">
            <%= if @stats.partial_years > 0 do %>
              <div>
                <span class="text-yellow-600 font-medium">{@stats.partial_years}</span>
                <span class="text-gray-500">partial (50-95%)</span>
              </div>
            <% end %>
            <%= if @stats.in_progress_years > 0 do %>
              <div>
                <span class="text-blue-600 font-medium">{@stats.in_progress_years}</span>
                <span class="text-gray-500">in progress</span>
              </div>
            <% end %>
            <%= if @stats.started_years > 0 do %>
              <div>
                <span class="text-cyan-600 font-medium">{@stats.started_years}</span>
                <span class="text-gray-500">started</span>
              </div>
            <% end %>
            <%= if @stats.pending_years > 0 do %>
              <div>
                <span class="text-gray-400">{@stats.pending_years}</span>
                <span class="text-gray-500">pending</span>
              </div>
            <% end %>
            <%= if @stats.unknown_years > 0 do %>
              <div>
                <span class="text-orange-600 font-medium">{@stats.unknown_years}</span>
                <span class="text-gray-500">no baseline</span>
              </div>
            <% end %>
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
      
    <!-- Backfill Queue Health -->
      <div class="bg-white rounded-lg shadow p-6 mb-8">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-semibold">Backfill Queue Health</h2>
          <span class={backfill_status_class(@backfill_health.status)}>
            {backfill_status_label(@backfill_health.status)}
          </span>
        </div>
        <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
          <div class="border rounded-lg p-4">
            <div class="text-sm text-gray-500">Pending Jobs</div>
            <div class="text-2xl font-bold text-indigo-600">
              {Number.Delimit.number_to_delimited(@backfill_health.pending_jobs, precision: 0)}
            </div>
            <div class="text-xs text-gray-400">
              threshold: {Number.Delimit.number_to_delimited(@backfill_health.threshold, precision: 0)}
            </div>
          </div>
          <div class="border rounded-lg p-4">
            <div class="text-sm text-gray-500">Available</div>
            <div class="text-2xl font-bold text-yellow-600">
              {Number.Delimit.number_to_delimited(@backfill_health.breakdown.available, precision: 0)}
            </div>
            <div class="text-xs text-gray-400">ready to process</div>
          </div>
          <div class="border rounded-lg p-4">
            <div class="text-sm text-gray-500">Executing</div>
            <div class="text-2xl font-bold text-blue-600">
              {Number.Delimit.number_to_delimited(@backfill_health.breakdown.executing, precision: 0)}
            </div>
            <div class="text-xs text-gray-400">currently running</div>
          </div>
          <div class="border rounded-lg p-4">
            <div class="text-sm text-gray-500">Retryable</div>
            <div class="text-2xl font-bold text-orange-600">
              {Number.Delimit.number_to_delimited(@backfill_health.breakdown.retryable, precision: 0)}
            </div>
            <div class="text-xs text-gray-400">will retry</div>
          </div>
        </div>
        <div class="mt-4 text-sm text-gray-500">
          Cron job runs every 15 minutes. Will queue more movies when pending drops below threshold.
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
                      / <span class="text-blue-600">{year_data.executing_jobs}</span>
                      / <span class="text-green-600">{year_data.completed_jobs}</span>
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
                <button phx-click="close_year_details" class="text-gray-400 hover:text-gray-600">
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
              <div class="mt-6 pt-4 border-t flex justify-end">
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
  # Data-driven status badges (Issue #425)

  defp status_badge_class(:completed),
    do: "px-2 py-1 text-xs font-medium rounded-full bg-green-100 text-green-800"

  defp status_badge_class(:partial),
    do: "px-2 py-1 text-xs font-medium rounded-full bg-yellow-100 text-yellow-800"

  defp status_badge_class(:in_progress),
    do: "px-2 py-1 text-xs font-medium rounded-full bg-blue-100 text-blue-800"

  defp status_badge_class(:started),
    do: "px-2 py-1 text-xs font-medium rounded-full bg-cyan-100 text-cyan-800"

  defp status_badge_class(:pending),
    do: "px-2 py-1 text-xs font-medium rounded-full bg-gray-100 text-gray-600"

  defp status_badge_class(:unknown),
    do: "px-2 py-1 text-xs font-medium rounded-full bg-orange-100 text-orange-800"

  defp status_badge_class(:bulk_complete),
    do: "px-2 py-1 text-xs font-medium rounded-full bg-purple-100 text-purple-800"

  defp status_badge_class(_),
    do: "px-2 py-1 text-xs font-medium rounded-full bg-gray-100 text-gray-600"

  defp status_label(:completed), do: "Complete (95%+)"
  defp status_label(:partial), do: "Partial (50-95%)"
  defp status_label(:in_progress), do: "In Progress"
  defp status_label(:started), do: "Started"
  defp status_label(:pending), do: "Pending"
  defp status_label(:unknown), do: "No Baseline"
  defp status_label(:bulk_complete), do: "Bulk Complete"
  defp status_label(_), do: "Unknown"

  defp completion_color(pct) when pct >= 95, do: "bg-green-500"
  defp completion_color(pct) when pct >= 50, do: "bg-blue-500"
  defp completion_color(pct) when pct >= 10, do: "bg-yellow-500"
  defp completion_color(_), do: "bg-gray-400"

  # Backfill queue health helpers
  defp backfill_status_class(:healthy),
    do: "px-3 py-1 bg-green-100 text-green-800 rounded-full text-sm font-medium"

  defp backfill_status_class(:below_threshold),
    do: "px-3 py-1 bg-yellow-100 text-yellow-800 rounded-full text-sm font-medium"

  defp backfill_status_class(_),
    do: "px-3 py-1 bg-gray-100 text-gray-600 rounded-full text-sm font-medium"

  defp backfill_status_label(:healthy), do: "Queue Healthy"
  defp backfill_status_label(:below_threshold), do: "Will Queue More"
  defp backfill_status_label(_), do: "Unknown"
end
