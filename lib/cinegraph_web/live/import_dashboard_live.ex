defmodule CinegraphWeb.ImportDashboardLive do
  @moduledoc """
  Simplified import dashboard using state tracking.
  Shows real progress: TMDB Total - Our Total = Remaining
  """
  use CinegraphWeb, :live_view
  
  alias Cinegraph.Imports.TMDbImporter
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
  def handle_event("start_full_import", _params, socket) do
    case TMDbImporter.start_full_import(pages: 100) do
      {:ok, info} ->
        socket =
          socket
          |> put_flash(:info, "Queued #{info.pages_queued} pages starting from page #{info.starting_page}")
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
  
  @impl true
  def handle_event("import_pages", %{"pages" => pages_str}, socket) do
    case Integer.parse(pages_str) do
      {pages, _} when pages > 0 ->
        case TMDbImporter.import_pages(pages) do
          {:ok, count} ->
            socket =
              socket
              |> put_flash(:info, "Queued #{count} pages for import")
              |> load_data()
            
            {:noreply, socket}
          {:error, reason} ->
            socket = Phoenix.LiveView.put_flash(socket, :error, "Failed to queue pages: #{inspect(reason)}")
            {:noreply, socket}
        end
      _ ->
        socket = Phoenix.LiveView.put_flash(socket, :error, "Invalid number of pages")
        {:noreply, socket}
    end
  end
  
  defp load_data(socket) do
    # Get progress
    progress = TMDbImporter.get_progress()
    
    # Get database stats
    stats = %{
      total_movies: Repo.aggregate(Movie, :count),
      movies_with_tmdb: Repo.aggregate(from(m in Movie, where: not is_nil(m.tmdb_data)), :count),
      movies_with_omdb: Repo.aggregate(from(m in Movie, where: not is_nil(m.omdb_data)), :count),
      total_people: Repo.aggregate(Cinegraph.Movies.Person, :count),
      total_credits: Repo.aggregate(Cinegraph.Movies.Credit, :count),
      total_genres: Repo.aggregate(Cinegraph.Movies.Genre, :count),
      total_keywords: Repo.aggregate(Cinegraph.Movies.Keyword, :count),
      unique_collaborations: Repo.aggregate(Cinegraph.Collaborations.Collaboration, :count),
      multi_collaborations: Repo.aggregate(from(c in Cinegraph.Collaborations.Collaboration, where: c.collaboration_count > 1), :count)
    }
    
    # Get Oban queue stats
    queue_stats = get_oban_stats()
    
    # Get runtime stats from ImportStats
    runtime_stats = Cinegraph.Imports.ImportStats.get_stats()
    
    socket
    |> assign(:progress, progress)
    |> assign(:stats, stats)
    |> assign(:queue_stats, queue_stats)
    |> assign(:import_rate, runtime_stats.movies_per_minute)
  end
  
  defp get_oban_stats do
    queues = [:tmdb_discovery, :tmdb_details, :omdb_enrichment, :collaboration]
    
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
  
  @doc """
  Formats queue names for display.
  """
  def format_queue_name(:tmdb_discovery), do: "TMDb Discovery"
  def format_queue_name(:tmdb_details), do: "TMDb Details"
  def format_queue_name(:omdb_enrichment), do: "OMDb Enrichment"
  def format_queue_name(:collaboration), do: "Collaboration"
  def format_queue_name(queue) when is_atom(queue), do: queue |> to_string() |> String.capitalize()
  def format_queue_name(queue), do: String.capitalize(queue)
end