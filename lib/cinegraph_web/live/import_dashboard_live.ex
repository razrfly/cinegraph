defmodule CinegraphWeb.ImportDashboardLive do
  @moduledoc """
  Simplified import dashboard using state tracking.
  Shows real progress: TMDB Total - Our Total = Remaining
  """
  use CinegraphWeb, :live_view
  
  alias Cinegraph.Imports.TMDbImporter
  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Movie, MovieLists}
  alias Cinegraph.Workers.{CanonicalImportOrchestrator, OscarImportWorker}
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
      |> assign(:canonical_lists, CanonicalImportOrchestrator.available_lists())
      |> assign(:oscar_decades, generate_oscar_decades())
      |> assign(:all_movie_lists, MovieLists.list_all_movie_lists())
      |> assign(:show_modal, false)
      |> assign(:editing_list, nil)
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
  def handle_event("import_canonical_list", %{"list_key" => "all"}, socket) do
    # Queue imports for all canonical lists
    alias Cinegraph.CanonicalLists
    
    jobs = CanonicalLists.all()
    |> Enum.map(fn {list_key, _config} ->
      %{
        "action" => "orchestrate_import",
        "list_key" => list_key
      }
      |> Cinegraph.Workers.CanonicalImportOrchestrator.new()
    end)
    
    # Insert all jobs
    case Oban.insert_all(jobs) do
      jobs_list when is_list(jobs_list) and length(jobs_list) > 0 ->
        socket =
          socket
          |> put_flash(:info, "Queued import for all #{length(jobs_list)} canonical lists")
          |> assign(:canonical_import_running, true)
          |> assign(:canonical_import_progress, "Starting import of all lists...")
        
        {:noreply, socket}
        
      _ ->
        socket = put_flash(socket, :error, "Failed to queue canonical imports")
        {:noreply, socket}
    end
  end
  
  def handle_event("import_canonical_list", %{"list_key" => list_key}, socket) do
    # Queue the canonical import orchestrator job
    %{
      "action" => "orchestrate_import",
      "list_key" => list_key
    }
    |> Cinegraph.Workers.CanonicalImportOrchestrator.new()
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
        [start_year_str, end_year_str] = String.split(year_range, "-")
        case {Integer.parse(start_year_str), Integer.parse(end_year_str)} do
          {{start_year, ""}, {end_year, ""}} ->
            %{"action" => "import_range", "start_year" => start_year, "end_year" => end_year}
          _ ->
            {:error, :invalid_year_range}
        end
      
      true ->
        case Integer.parse(year_range) do
          {year, ""} -> %{"action" => "import_single", "year" => year}
          _ -> 
            {:error, :invalid_year}
        end
    end
    
    # Queue the Oscar import job
    case job_args do
      {:error, :invalid_year} ->
        socket = put_flash(socket, :error, "Invalid year format")
        {:noreply, socket}
        
      {:error, :invalid_year_range} ->
        socket = put_flash(socket, :error, "Invalid year range format")
        {:noreply, socket}
        
      _ ->
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
  end
  
  @impl true
  def handle_event("show_add_modal", _params, socket) do
    socket = 
      socket
      |> assign(:show_modal, true)
      |> assign(:editing_list, nil)
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_event("show_edit_modal", %{"id" => id}, socket) do
    list = MovieLists.get_movie_list!(String.to_integer(id))
    
    socket = 
      socket
      |> assign(:show_modal, true)
      |> assign(:editing_list, list)
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_event("hide_modal", _params, socket) do
    socket = 
      socket
      |> assign(:show_modal, false)
      |> assign(:editing_list, nil)
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_event("add_movie_list", params, socket) do
    # Auto-detect source type from URL
    source_type = detect_source_type(params["source_url"])
    
    attrs = %{
      source_url: params["source_url"],
      name: params["name"],
      source_key: params["source_key"],
      category: params["category"],
      description: params["description"],
      source_type: source_type,
      tracks_awards: params["tracks_awards"] == "on",
      active: true
    }
    
    case MovieLists.create_movie_list(attrs) do
      {:ok, list} ->
        socket = 
          socket
          |> put_flash(:info, "List '#{list.name}' added successfully!")
          |> assign(:all_movie_lists, get_movie_list_with_real_counts())
          |> assign(:canonical_lists, CanonicalImportOrchestrator.available_lists())
          |> assign(:show_modal, false)
        
        {:noreply, socket}
        
      {:error, changeset} ->
        errors = format_changeset_errors(changeset)
        socket = put_flash(socket, :error, "Failed to add list: #{errors}")
        {:noreply, socket}
    end
  end
  
  @impl true
  def handle_event("update_movie_list", params, socket) do
    list = MovieLists.get_movie_list!(String.to_integer(params["list_id"]))
    
    # Auto-detect source type from URL
    source_type = detect_source_type(params["source_url"])
    
    attrs = %{
      source_url: params["source_url"],
      name: params["name"],
      category: params["category"],
      description: params["description"],
      source_type: source_type,
      tracks_awards: params["tracks_awards"] == "on"
    }
    
    case MovieLists.update_movie_list(list, attrs) do
      {:ok, updated_list} ->
        socket = 
          socket
          |> put_flash(:info, "List '#{updated_list.name}' updated successfully!")
          |> assign(:all_movie_lists, get_movie_list_with_real_counts())
          |> assign(:canonical_lists, CanonicalImportOrchestrator.available_lists())
          |> assign(:show_modal, false)
          |> assign(:editing_list, nil)
        
        {:noreply, socket}
        
      {:error, changeset} ->
        errors = format_changeset_errors(changeset)
        socket = put_flash(socket, :error, "Failed to update list: #{errors}")
        {:noreply, socket}
    end
  end
  
  @impl true
  def handle_event("delete_list", %{"id" => id}, socket) do
    list = MovieLists.get_movie_list!(String.to_integer(id))
    
    case MovieLists.delete_movie_list(list) do
      {:ok, _deleted_list} ->
        socket = 
          socket
          |> put_flash(:info, "List '#{list.name}' deleted successfully!")
          |> assign(:all_movie_lists, get_movie_list_with_real_counts())
          |> assign(:canonical_lists, CanonicalImportOrchestrator.available_lists())
        
        {:noreply, socket}
        
      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to delete list")
        {:noreply, socket}
    end
  end
  
  @impl true
  def handle_event("toggle_list_active", %{"id" => id}, socket) do
    list = MovieLists.get_movie_list!(String.to_integer(id))
    
    case MovieLists.update_movie_list(list, %{active: !list.active}) do
      {:ok, _updated_list} ->
        socket = 
          socket
          |> put_flash(:info, "List #{if list.active, do: "disabled", else: "enabled"} successfully")
          |> assign(:all_movie_lists, get_movie_list_with_real_counts())
          |> assign(:canonical_lists, CanonicalImportOrchestrator.available_lists())
        
        {:noreply, socket}
        
      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update list")
        {:noreply, socket}
    end
  end
  
  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
    |> Enum.join("; ")
  end

  defp detect_source_type(url) do
    cond do
      String.contains?(url, "imdb.com") -> "imdb"
      String.contains?(url, "themoviedb.org") || String.contains?(url, "tmdb.org") -> "tmdb"
      String.contains?(url, "letterboxd.com") -> "letterboxd"
      true -> "custom"
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
      canonical_movies: Repo.aggregate(from(m in Movie, where: fragment("? \\?| array[?]", m.canonical_sources, ["1001_movies", "criterion", "sight_sound_critics_2022", "national_film_registry"])), :count),
      oscar_movies: get_oscar_movies_count(),
      total_people: Repo.aggregate(Cinegraph.Movies.Person, :count),
      total_credits: Repo.aggregate(Cinegraph.Movies.Credit, :count),
      total_genres: Repo.aggregate(Cinegraph.Movies.Genre, :count),
      total_keywords: Repo.aggregate(Cinegraph.Movies.Keyword, :count),
      unique_collaborations: Repo.aggregate(Cinegraph.Collaborations.Collaboration, :count),
      multi_collaborations: Repo.aggregate(from(c in Cinegraph.Collaborations.Collaboration, where: c.collaboration_count > 1), :count)
    }
    
    # Get canonical list stats
    canonical_stats = get_canonical_list_stats()
    
    # Get Oscar statistics
    oscar_stats = get_oscar_stats()
    
    # Get Oban queue stats
    queue_stats = get_oban_stats()
    
    # Get runtime stats from ImportStats
    runtime_stats = Cinegraph.Imports.ImportStats.get_stats()
    
    socket
    |> assign(:progress, progress)
    |> assign(:stats, stats)
    |> assign(:canonical_stats, canonical_stats)
    |> assign(:oscar_stats, oscar_stats)
    |> assign(:queue_stats, queue_stats)
    |> assign(:import_rate, runtime_stats.movies_per_minute)
    |> assign(:all_movie_lists, get_movie_list_with_real_counts())
    |> assign(:canonical_lists, CanonicalImportOrchestrator.available_lists())
  end
  
  defp get_oscar_movies_count do
    # Count movies that have IMDb IDs matching those in Oscar ceremony data
    # Since nominations haven't been processed into oscar_nominations table yet,
    # we'll count from the JSON data in oscar_ceremonies
    
    # First try the oscar_nominations table (proper way)
    nominations_count = Repo.aggregate(
      from(n in Cinegraph.Cultural.OscarNomination, select: count(n.movie_id, :distinct)), 
      :count
    )
    
    if nominations_count > 0 do
      nominations_count
    else
      # Fallback: count movies that exist in our database and match Oscar ceremony IMDb IDs
      ceremony_imdb_ids = get_oscar_ceremony_imdb_ids()
      
      if length(ceremony_imdb_ids) > 0 do
        Repo.aggregate(
          from(m in Movie, where: m.imdb_id in ^ceremony_imdb_ids),
          :count
        )
      else
        0
      end
    end
  end
  
  defp get_oscar_ceremony_imdb_ids do
    # Extract all IMDb IDs from Oscar ceremony JSON data
    case Repo.all(from(c in Cinegraph.Cultural.OscarCeremony, select: c.data, where: not is_nil(c.data))) do
      [] -> []
      ceremony_data_list ->
        ceremony_data_list
        |> Enum.flat_map(fn data ->
          case data["categories"] do
            nil -> []
            categories when is_list(categories) ->
              categories
              |> Enum.flat_map(fn category ->
                case category["nominees"] do
                  nil -> []
                  nominees when is_list(nominees) ->
                    nominees
                    |> Enum.filter(fn nominee -> is_binary(nominee["film_imdb_id"]) end)
                    |> Enum.map(fn nominee -> nominee["film_imdb_id"] end)
                  _ -> []
                end
              end)
            _ -> []
          end
        end)
        |> Enum.uniq()
    end
  end

  defp get_canonical_list_stats do
    alias Cinegraph.CanonicalLists
    
    # Get all canonical lists and their counts
    CanonicalLists.all()
    |> Enum.map(fn {list_key, config} ->
      # Use raw SQL to avoid Ecto escaping issues with the ? operator
      {:ok, %{rows: [[count]]}} = Repo.query(
        "SELECT COUNT(*) FROM movies WHERE canonical_sources ? $1",
        [list_key]
      )
      
      # Get expected count from database metadata if available
      expected_count = case MovieLists.get_active_by_source_key(list_key) do
        nil -> nil
        list -> list.metadata["expected_movie_count"]
      end
      
      %{
        key: list_key,
        name: config.name,
        count: count,
        expected_count: expected_count
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)  # Sort by count descending
  end
  
  defp get_movie_list_with_real_counts do
    # Get all movie lists with real database counts instead of last_movie_count
    MovieLists.list_all_movie_lists()
    |> Enum.map(fn list ->
      # Get real count from database
      real_count = case Repo.query("SELECT COUNT(*) FROM movies WHERE canonical_sources ? $1", [list.source_key]) do
        {:ok, %{rows: [[count]]}} -> count
        _ -> 0
      end
      
      # Add real count to the list struct
      Map.put(list, :real_movie_count, real_count)
    end)
  end

  defp get_oscar_stats do
    # Get ceremony years and their nomination/win counts
    ceremony_stats = Repo.all(
      from oc in Cinegraph.Cultural.OscarCeremony,
      left_join: on_table in Cinegraph.Cultural.OscarNomination, on: on_table.ceremony_id == oc.id,
      group_by: [oc.year, oc.id],
      select: {oc.year, count(on_table.id), sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", on_table.won))},
      order_by: [desc: oc.year]
    )
    
    # Calculate totals (ceremony_stats now returns tuples: {year, nominations, wins})
    total_nominations = Enum.sum(Enum.map(ceremony_stats, fn {_year, nominations, _wins} -> nominations end))
    total_wins = Enum.sum(Enum.map(ceremony_stats, fn {_year, _nominations, wins} -> wins || 0 end))
    total_ceremonies = length(ceremony_stats)
    total_categories = Repo.aggregate(Cinegraph.Cultural.OscarCategory, :count)
    
    # Build stats list
    base_stats = [
      %{label: "Ceremonies Imported", value: "#{total_ceremonies} (2016-2024)"},
      %{label: "Total Nominations", value: format_number(total_nominations)},
      %{label: "Total Wins", value: format_number(total_wins)},
      %{label: "Categories", value: format_number(total_categories)}
    ]
    
    # Add year-by-year breakdown
    year_stats = ceremony_stats
    |> Enum.filter(fn {_year, nominations, _wins} -> nominations > 0 end)  # Only show years with data
    |> Enum.map(fn {year, nominations, wins} ->
      %{
        label: "#{year} Wins", 
        value: "#{wins || 0}/#{nominations}"
      }
    end)
    
    base_stats ++ year_stats
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
      %{progress_percent: percent} -> "Processing pages... #{percent}% complete"
      %{pages_queued: pages} -> "Queued #{pages} page jobs"
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

  defp generate_oscar_decades do
    current_year = Date.utc_today().year
    current_decade_start = div(current_year, 10) * 10
    start_decade = 1930  # First practical Oscar ceremony data available
    
    # Generate decades from start_decade to current_decade in reverse order (newest first)
    current_decade_start
    |> then(fn decade -> decade..start_decade//-10 end)
    |> Enum.map(fn decade_start ->
      decade_end = min(decade_start + 9, current_year)
      decade_name = "#{decade_start}s"
      
      %{
        value: "#{decade_start}-#{decade_end}",
        label: "#{decade_name} (#{decade_start}-#{decade_end})"
      }
    end)
  end
end