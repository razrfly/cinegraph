defmodule CinegraphWeb.ImportDashboardLive do
  @moduledoc """
  Simplified import dashboard using state tracking.
  Shows real progress: TMDB Total - Our Total = Remaining
  """
  use CinegraphWeb, :live_view
  
  alias Cinegraph.Imports.TMDbImporter
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Workers.{CanonicalImportWorker, OscarImportWorker}
  import Ecto.Query
  
  @refresh_interval 5000  # 5 seconds
  
  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to import progress updates
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Cinegraph.PubSub, "import_progress")
    end
    
    socket =
      socket
      |> assign(:page_title, "Import Dashboard")
      |> assign(:refresh_timer, nil)
      |> assign(:canonical_import_running, false)
      |> assign(:canonical_import_progress, nil)
      |> assign(:oscar_import_running, false)
      |> assign(:oscar_import_progress, nil)
      |> assign(:canonical_lists, CanonicalImportWorker.available_lists())
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
  def handle_info({:canonical_progress, progress}, socket) do
    socket = case progress.status do
      :started ->
        assign(socket, :canonical_import_progress, progress.status)
        
      :completed ->
        socket
        |> put_flash(:info, "Canonical import completed: #{progress.total_movies} movies processed")
        |> assign(:canonical_import_running, false)
        |> assign(:canonical_import_progress, nil)
        |> load_data()
        
      _ ->
        assign(socket, :canonical_import_progress, format_canonical_progress(progress))
    end
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_info({:oscar_progress, progress}, socket) do
    socket = case progress.status do
      :started ->
        assign(socket, :oscar_import_progress, progress.status)
        
      :completed ->
        message = case progress.type do
          :single -> "Oscar import completed for #{progress.year}: #{progress.total_nominees} nominees"
          :range -> "Oscar import completed for years #{progress.start_year}-#{progress.end_year}"
          :all -> "Oscar import completed for all years"
        end
        
        socket
        |> put_flash(:info, message)
        |> assign(:oscar_import_running, false)
        |> assign(:oscar_import_progress, nil)
        |> load_data()
        
      :queued ->
        assign(socket, :oscar_import_progress, "Queued #{progress.jobs_queued} Oscar import jobs")
        
      _ ->
        assign(socket, :oscar_import_progress, format_oscar_progress(progress))
    end
    
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
  
  @impl true
  def handle_event("import_canonical_list", %{"list_key" => list_key}, socket) do
    # Queue the canonical import job
    %{
      "action" => "import_canonical_list",
      "list_key" => list_key
    }
    |> CanonicalImportWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        socket =
          socket
          |> put_flash(:info, "Queued canonical list import")
          |> assign(:canonical_import_running, true)
          |> assign(:canonical_import_progress, "Starting import...")
        
        {:noreply, socket}
        
      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to queue canonical import: #{inspect(reason)}")
        {:noreply, socket}
    end
  end
  
  @impl true
  def handle_event("import_oscars", %{"year_range" => year_range}, socket) do
    # Determine job args based on selection
    job_args = cond do
      year_range == "all" -> 
        %{"action" => "import_all_years"}
      
      String.contains?(year_range, "-") ->
        [start_year, end_year] = String.split(year_range, "-")
        %{"action" => "import_range", "start_year" => start_year, "end_year" => end_year}
      
      true ->
        %{"action" => "import_single", "year" => String.to_integer(year_range)}
    end
    
    # Queue the Oscar import job
    job_args
    |> OscarImportWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        socket =
          socket
          |> put_flash(:info, "Queued Oscar import")
          |> assign(:oscar_import_running, true)
          |> assign(:oscar_import_progress, "Starting import...")
        
        {:noreply, socket}
        
      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to queue Oscar import: #{inspect(reason)}")
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
      canonical_movies: Repo.aggregate(from(m in Movie, where: fragment("? \\? ?", m.canonical_sources, "1001_movies")), :count),
      oscar_movies: Repo.aggregate(from(n in Cinegraph.Cultural.OscarNomination, select: count(n.movie_id, :distinct)), :count),
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
    queues = [:tmdb_discovery, :tmdb_details, :omdb_enrichment, :collaboration, :imdb_scraping, :oscar_imports]
    
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
  def format_queue_name(:imdb_scraping), do: "IMDb Scraping"
  def format_queue_name(:oscar_imports), do: "Oscar Imports"
  def format_queue_name(queue) when is_atom(queue), do: queue |> to_string() |> String.capitalize()
  def format_queue_name(queue), do: String.capitalize(queue)
  
  defp format_canonical_progress(progress) do
    case progress do
      %{status: status} when is_binary(status) -> status
      %{list_name: name} -> "Importing #{name}..."
      _ -> "Processing canonical list..."
    end
  end
  
  defp format_oscar_progress(progress) do
    case progress do
      %{status: status} when is_binary(status) -> status
      %{year: year} -> "Importing Oscar data for #{year}..."
      _ -> "Processing Oscar import..."
    end
  end
end