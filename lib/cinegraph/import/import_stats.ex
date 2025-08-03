defmodule Cinegraph.Import.ImportStats do
  @moduledoc """
  Runtime statistics for movie imports using ETS.
  No database persistence - stats only live for the duration of the import process.
  """
  use GenServer
  require Logger

  @table_name :import_stats
  @update_interval 1000 # Update calculations every second

  # Client API

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def start_import(import_id, total_pages) do
    GenServer.call(__MODULE__, {:start_import, import_id, total_pages})
  end

  def record_page_complete(import_id, movies_count) do
    GenServer.cast(__MODULE__, {:page_complete, import_id, movies_count})
  end

  def record_movie_imported(import_id) do
    GenServer.cast(__MODULE__, {:movie_imported, import_id})
  end

  def complete_import(import_id) do
    GenServer.call(__MODULE__, {:complete_import, import_id})
  end

  def get_stats(import_id) do
    case :ets.lookup(@table_name, {:import, import_id}) do
      [{_, stats}] -> {:ok, stats}
      [] -> {:error, :not_found}
    end
  end

  def get_all_active_imports do
    :ets.match_object(@table_name, {{:import, :_}, :_})
    |> Enum.map(fn {{:import, _id}, stats} -> stats end)
    |> Enum.filter(& &1.status == :running)
  end

  def get_dashboard_stats do
    active_imports = get_all_active_imports()
    
    total_stats = Enum.reduce(active_imports, %{
      total_movies: 0,
      total_pages: 0,
      total_movies_per_minute: 0.0,
      estimated_completion_time: nil
    }, fn import, acc ->
      %{
        total_movies: acc.total_movies + import.movies_imported,
        total_pages: acc.total_pages + import.pages_processed,
        total_movies_per_minute: acc.total_movies_per_minute + import.current_rate,
        estimated_completion_time: calculate_overall_eta(active_imports)
      }
    end)
    
    total_stats
  end

  # Server Callbacks

  @impl true
  def init(_) do
    # Create ETS table - public so LiveView can read directly if needed
    :ets.new(@table_name, [:set, :public, :named_table])
    
    # Schedule periodic rate updates
    Process.send_after(self(), :update_rates, @update_interval)
    
    {:ok, %{}}
  end

  @impl true
  def handle_call({:start_import, import_id, total_pages}, _from, state) do
    now = DateTime.utc_now()
    
    stats = %{
      import_id: import_id,
      status: :running,
      started_at: now,
      last_updated: now,
      total_pages: total_pages,
      pages_processed: 0,
      movies_imported: 0,
      current_rate: 0.0,
      average_movies_per_page: 0.0,
      estimated_completion: nil
    }
    
    :ets.insert(@table_name, {{:import, import_id}, stats})
    
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:complete_import, import_id}, _from, state) do
    case :ets.lookup(@table_name, {:import, import_id}) do
      [{key, stats}] ->
        updated_stats = %{stats | 
          status: :completed,
          last_updated: DateTime.utc_now()
        }
        :ets.insert(@table_name, {key, updated_stats})
        
        # Clean up after 5 minutes
        Process.send_after(self(), {:cleanup_import, import_id}, 300_000)
        
        {:reply, :ok, state}
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_cast({:page_complete, import_id, movies_count}, state) do
    update_import_stats(import_id, fn stats ->
      %{stats | 
        pages_processed: stats.pages_processed + 1,
        movies_imported: stats.movies_imported + movies_count,
        last_updated: DateTime.utc_now()
      }
    end)
    
    {:noreply, state}
  end

  @impl true
  def handle_cast({:movie_imported, import_id}, state) do
    update_import_stats(import_id, fn stats ->
      %{stats | 
        movies_imported: stats.movies_imported + 1,
        last_updated: DateTime.utc_now()
      }
    end)
    
    {:noreply, state}
  end

  @impl true
  def handle_info(:update_rates, state) do
    # Update rates for all active imports
    active_imports = :ets.match_object(@table_name, {{:import, :_}, :_})
    
    Enum.each(active_imports, fn {{:import, import_id}, stats} ->
      if stats.status == :running do
        update_import_rate(import_id, stats)
      end
    end)
    
    # Schedule next update
    Process.send_after(self(), :update_rates, @update_interval)
    
    {:noreply, state}
  end

  @impl true
  def handle_info({:cleanup_import, import_id}, state) do
    :ets.delete(@table_name, {:import, import_id})
    {:noreply, state}
  end

  # Private Functions

  defp update_import_stats(import_id, update_fn) do
    case :ets.lookup(@table_name, {:import, import_id}) do
      [{key, stats}] ->
        updated_stats = update_fn.(stats)
        :ets.insert(@table_name, {key, updated_stats})
      [] ->
        Logger.warning("Import stats not found for #{import_id}")
    end
  end

  defp update_import_rate(import_id, stats) do
    now = DateTime.utc_now()
    elapsed_seconds = DateTime.diff(now, stats.started_at, :second)
    
    if elapsed_seconds > 0 do
      current_rate = stats.movies_imported / elapsed_seconds * 60.0
      avg_movies_per_page = if stats.pages_processed > 0,
        do: stats.movies_imported / stats.pages_processed,
        else: 20.0 # TMDb default
      
      remaining_pages = stats.total_pages - stats.pages_processed
      remaining_movies = remaining_pages * avg_movies_per_page
      
      eta = if current_rate > 0 do
        seconds_remaining = remaining_movies / current_rate * 60
        DateTime.add(now, trunc(seconds_remaining), :second)
      else
        nil
      end
      
      updated_stats = %{stats |
        current_rate: Float.round(current_rate, 1),
        average_movies_per_page: Float.round(avg_movies_per_page, 1),
        estimated_completion: eta
      }
      
      :ets.insert(@table_name, {{:import, import_id}, updated_stats})
    end
  end

  defp calculate_overall_eta(active_imports) do
    case active_imports do
      [] -> nil
      imports ->
        # Find the import that will finish last
        imports
        |> Enum.map(& &1.estimated_completion)
        |> Enum.reject(&is_nil/1)
        |> Enum.max(DateTime, fn -> nil end)
    end
  end
end