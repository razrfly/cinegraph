defmodule CinegraphWeb.ImportDashboardLive do
  use CinegraphWeb, :live_view
  
  alias Cinegraph.Imports.{TMDbImporter, ImportProgress}
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  import Ecto.Query
  
  @refresh_interval 2000  # 2 seconds
  
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end
    
    socket =
      socket
      |> assign(:page_title, "Import Dashboard")
      |> load_stats()
      |> load_imports()
      |> load_oban_stats()
    
    {:ok, socket}
  end
  
  @impl true
  def handle_info(:refresh, socket) do
    socket =
      socket
      |> load_stats()
      |> load_imports()
      |> load_oban_stats()
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_event("start_popular_import", _params, socket) do
    case TMDbImporter.start_popular_import() do
      {:ok, _progress} ->
        socket =
          socket
          |> put_flash(:info, "Started popular movies import")
          |> load_imports()
        
        {:noreply, socket}
      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to start import: #{inspect(reason)}")
        {:noreply, socket}
    end
  end
  
  @impl true
  def handle_event("start_daily_update", _params, socket) do
    case TMDbImporter.start_daily_update() do
      {:ok, _progress} ->
        socket =
          socket
          |> put_flash(:info, "Started daily update")
          |> load_imports()
        
        {:noreply, socket}
      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to start daily update: #{inspect(reason)}")
        {:noreply, socket}
    end
  end
  
  @impl true
  def handle_event("start_decade_import", %{"decade" => decade_str}, socket) do
    case Integer.parse(decade_str) do
      {decade, ""} when decade > 0 ->
        case TMDbImporter.start_decade_import(decade) do
          {:ok, _progress} ->
            socket =
              socket
              |> put_flash(:info, "Started import for #{decade}s")
              |> load_imports()
            
            {:noreply, socket}
          {:error, reason} ->
            socket = put_flash(socket, :error, "Failed to start decade import: #{inspect(reason)}")
            {:noreply, socket}
        end
      _ ->
        socket = put_flash(socket, :error, "Invalid decade value")
        {:noreply, socket}
    end
  end
  
  @impl true
  def handle_event("pause_import", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {parsed_id, ""} when parsed_id > 0 ->
        case TMDbImporter.pause_import(parsed_id) do
      {:ok, _} ->
        socket =
          socket
          |> put_flash(:info, "Import paused")
          |> load_imports()
        
        {:noreply, socket}
          {:error, reason} ->
            socket = put_flash(socket, :error, "Failed to pause import: #{inspect(reason)}")
            {:noreply, socket}
        end
      _ ->
        socket = put_flash(socket, :error, "Invalid import ID")
        {:noreply, socket}
    end
  end
  
  @impl true
  def handle_event("resume_import", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {parsed_id, ""} when parsed_id > 0 ->
        case TMDbImporter.resume_import(parsed_id) do
      {:ok, _} ->
        socket =
          socket
          |> put_flash(:info, "Import resumed")
          |> load_imports()
        
        {:noreply, socket}
          {:error, reason} ->
            socket = put_flash(socket, :error, "Failed to resume import: #{inspect(reason)}")
            {:noreply, socket}
        end
      _ ->
        socket = put_flash(socket, :error, "Invalid import ID")
        {:noreply, socket}
    end
  end
  
  defp load_stats(socket) do
    stats = %{
      total_movies: Repo.aggregate(Movie, :count),
      movies_with_tmdb: Repo.aggregate(from(m in Movie, where: not is_nil(m.tmdb_data)), :count),
      movies_with_omdb: Repo.aggregate(from(m in Movie, where: not is_nil(m.omdb_data)), :count),
      total_people: Repo.aggregate(Cinegraph.Movies.Person, :count),
      total_credits: Repo.aggregate(Cinegraph.Movies.Credit, :count)
    }
    
    assign(socket, :stats, stats)
  end
  
  defp load_imports(socket) do
    imports = TMDbImporter.get_import_status()
    recent_imports = ImportProgress.get_latest("full") |> List.wrap()
    
    socket
    |> assign(:active_imports, imports)
    |> assign(:recent_imports, recent_imports)
  end
  
  defp load_oban_stats(socket) do
    queue_stats = 
      Oban.config()
      |> Map.get(:queues)
      |> Enum.map(fn {queue, _limit} ->
        jobs = Repo.aggregate(
          from(j in Oban.Job, where: j.queue == ^to_string(queue) and j.state == "available"),
          :count
        )
        
        executing = Repo.aggregate(
          from(j in Oban.Job, where: j.queue == ^to_string(queue) and j.state == "executing"),
          :count
        )
        
        %{
          name: queue,
          available: jobs,
          executing: executing
        }
      end)
    
    assign(socket, :queue_stats, queue_stats)
  end
  
  @doc """
  Formats duration in seconds to a human-readable string.
  """
  def format_duration(seconds) when is_number(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)
    
    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m #{secs}s"
      true -> "#{secs}s"
    end
  end
  def format_duration(_), do: "0s"
end