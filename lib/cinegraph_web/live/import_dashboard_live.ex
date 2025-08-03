defmodule CinegraphWeb.ImportDashboardLive do
  @moduledoc """
  Simplified import dashboard using state tracking.
  Shows real progress: TMDB Total - Our Total = Remaining
  """
  use CinegraphWeb, :live_view
  
  alias Cinegraph.Imports.TMDbImporter
  alias Cinegraph.Import.{ImportStats, ImportCoordinator}
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  import Ecto.Query
  
  @refresh_interval 5000  # 5 seconds
  
  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Import Dashboard")
      |> assign(:refresh_timer, nil)
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
  def handle_event("start_concurrent_import", %{"type" => type, "pages" => pages}, socket) do
    pages = String.to_integer(pages)
    
    case ImportCoordinator.start_import(type, pages) do
      {:ok, import_id} ->
        socket =
          socket
          |> put_flash(:info, "Started concurrent #{type} import (ID: #{import_id}) for #{pages} pages")
          |> load_data()
        
        {:noreply, socket}
      {:error, reason} ->
        socket = Phoenix.LiveView.put_flash(socket, :error, "Failed to start concurrent import: #{inspect(reason)}")
        {:noreply, socket}
    end
  end
  
  @impl true
  def handle_event("start_full_import", _params, socket) do
    case TMDbImporter.start_full_import() do
      {:ok, info} ->
        socket =
          socket
          |> put_flash(:info, "Started full import from page #{info.starting_page}")
          |> load_data()
        
        {:noreply, socket}
      {:error, reason} ->
        socket = Phoenix.LiveView.put_flash(socket, :error, "Failed to start import: #{inspect(reason)}")
        {:noreply, socket}
    end
  end
  
  @impl true
  def handle_event("start_daily_update", _params, socket) do
    case TMDbImporter.start_daily_update() do
      {:ok, _job} ->
        socket =
          socket
          |> put_flash(:info, "Started daily update for recent movies")
          |> load_data()
        
        {:noreply, socket}
      {:error, reason} ->
        socket = Phoenix.LiveView.put_flash(socket, :error, "Failed to start daily update: #{inspect(reason)}")
        {:noreply, socket}
    end
  end
  
  @impl true
  def handle_event("update_tmdb_total", _params, socket) do
    case TMDbImporter.update_tmdb_total() do
      {:ok, total} ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:info, "Updated TMDB total: #{format_number(total)} movies")
          |> load_data()
        
        {:noreply, socket}
      {:error, reason} ->
        socket = Phoenix.LiveView.put_flash(socket, :error, "Failed to update TMDB total: #{inspect(reason)}")
        {:noreply, socket}
    end
  end
  
  defp load_data(socket) do
    # Get progress
    progress = TMDbImporter.get_progress()
    
    # Get runtime import stats from ETS
    runtime_stats = ImportStats.get_dashboard_stats()
    
    # Get database stats
    stats = %{
      total_movies: Repo.aggregate(Movie, :count),
      movies_with_tmdb: Repo.aggregate(from(m in Movie, where: not is_nil(m.tmdb_data)), :count),
      movies_with_omdb: Repo.aggregate(from(m in Movie, where: not is_nil(m.omdb_data)), :count),
      total_people: Repo.aggregate(Cinegraph.Movies.Person, :count),
      total_credits: Repo.aggregate(Cinegraph.Movies.Credit, :count),
      total_genres: Repo.aggregate(Cinegraph.Movies.Genre, :count),
      total_keywords: Repo.aggregate(Cinegraph.Movies.Keyword, :count)
    }
    
    # Get Oban queue stats
    queue_stats = get_oban_stats()
    
    # Use runtime import rate if available, otherwise calculate from DB
    import_rate = if runtime_stats.total_movies_per_minute > 0 do
      runtime_stats.total_movies_per_minute
    else
      calculate_import_rate(socket.assigns[:stats], stats)
    end
    
    socket
    |> assign(:progress, progress)
    |> assign(:stats, stats)
    |> assign(:queue_stats, queue_stats)
    |> assign(:import_rate, import_rate)
    |> assign(:runtime_stats, runtime_stats)
    |> assign(:active_imports, ImportStats.get_all_active_imports())
  end
  
  defp get_oban_stats do
    queues = [:tmdb_discovery, :tmdb_details, :omdb_enrichment]
    
    Enum.map(queues, fn queue ->
      available = Repo.aggregate(
        from(j in Oban.Job, where: j.queue == ^to_string(queue) and j.state == "available"),
        :count
      )
      
      executing = Repo.aggregate(
        from(j in Oban.Job, where: j.queue == ^to_string(queue) and j.state == "executing"),
        :count
      )
      
      completed = Repo.aggregate(
        from(j in Oban.Job, where: j.queue == ^to_string(queue) and j.state == "completed"),
        :count
      )
      
      %{
        name: queue,
        available: available,
        executing: executing,
        completed: completed
      }
    end)
  end
  
  defp calculate_import_rate(nil, _), do: 0.0
  defp calculate_import_rate(old_stats, new_stats) do
    # Calculate movies imported per minute
    time_diff = @refresh_interval / 1000 / 60  # Convert to minutes
    movies_diff = new_stats.total_movies - old_stats.total_movies
    
    if time_diff > 0 do
      Float.round(movies_diff / time_diff, 2)
    else
      0.0
    end
  end
  
  defp schedule_refresh(socket) do
    if connected?(socket) do
      timer = Process.send_after(self(), :refresh, @refresh_interval)
      assign(socket, :refresh_timer, timer)
    else
      socket
    end
  end
  
  @doc """
  Formats a number with thousand separators.
  """
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
  
  @doc """
  Estimates time to completion based on current rate.
  """
  def estimate_completion_time(remaining, rate) when rate > 0 do
    minutes = remaining / rate
    hours = minutes / 60
    days = hours / 24
    
    cond do
      days >= 1 -> "~#{Float.round(days, 1)} days"
      hours >= 1 -> "~#{Float.round(hours, 1)} hours"
      true -> "~#{Float.round(minutes, 0)} minutes"
    end
  end
  def estimate_completion_time(_, _), do: "Unknown"
end