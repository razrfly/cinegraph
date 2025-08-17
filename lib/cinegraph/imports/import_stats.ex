defmodule Cinegraph.Imports.ImportStats do
  @moduledoc """
  Simple ETS-based runtime statistics for imports.
  Tracks current import progress without database persistence.
  """
  use GenServer
  require Logger

  @table_name :import_stats
  # Update stats every 5 seconds
  @update_interval 5_000

  # Client API

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Get current import statistics"
  def get_stats do
    case :ets.lookup(@table_name, :current_stats) do
      [{:current_stats, stats}] ->
        stats

      [] ->
        %{
          movies_per_minute: 0.0,
          active_jobs: %{},
          last_update: nil
        }
    end
  end

  @doc "Get Oban queue statistics"
  def get_queue_stats do
    GenServer.call(__MODULE__, :get_queue_stats)
  end

  # Server Callbacks

  @impl true
  def init(_) do
    # Create ETS table
    :ets.new(@table_name, [:set, :public, :named_table])

    # Initialize stats
    :ets.insert(
      @table_name,
      {:current_stats,
       %{
         movies_per_minute: 0.0,
         active_jobs: %{},
         last_update: nil,
         last_movie_count: 0,
         last_check_time: DateTime.utc_now()
       }}
    )

    # Schedule periodic updates
    Process.send_after(self(), :update_stats, @update_interval)

    {:ok, %{}}
  end

  @impl true
  def handle_info(:update_stats, state) do
    update_import_stats()
    Process.send_after(self(), :update_stats, @update_interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_queue_stats, _from, state) do
    stats = calculate_queue_stats()
    {:reply, stats, state}
  end

  # Private functions

  defp update_import_stats do
    current_time = DateTime.utc_now()
    current_movie_count = Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count, :id)

    prev_stats =
      case :ets.lookup(@table_name, :current_stats) do
        [{:current_stats, stats}] -> stats
        [] -> %{movies_per_minute: 0.0, last_movie_count: 0, last_check_time: current_time}
      end

    # Calculate rate
    time_diff = DateTime.diff(current_time, prev_stats.last_check_time, :second)
    movies_diff = current_movie_count - prev_stats.last_movie_count

    movies_per_minute =
      if time_diff > 0 do
        Float.round(movies_diff / time_diff * 60, 1)
      else
        prev_stats.movies_per_minute
      end

    # Update stats
    new_stats = %{
      movies_per_minute: movies_per_minute,
      active_jobs: calculate_active_jobs(),
      last_update: current_time,
      last_movie_count: current_movie_count,
      last_check_time: current_time
    }

    :ets.insert(@table_name, {:current_stats, new_stats})
  end

  defp calculate_active_jobs do
    import Ecto.Query

    %{
      discovery: count_jobs_in_queue("tmdb_discovery"),
      details: count_jobs_in_queue("tmdb_details"),
      omdb: count_jobs_in_queue("omdb_enrichment"),
      collaboration: count_jobs_in_queue("collaboration")
    }
  end

  defp count_jobs_in_queue(queue_name) do
    import Ecto.Query

    Cinegraph.Repo.aggregate(
      from(j in Oban.Job,
        where: j.queue == ^queue_name and j.state in ["available", "executing"]
      ),
      :count,
      :id
    )
  end

  defp calculate_queue_stats do
    import Ecto.Query

    queues = ["tmdb_discovery", "tmdb_details", "omdb_enrichment", "collaboration"]

    Enum.map(queues, fn queue ->
      available =
        Cinegraph.Repo.aggregate(
          from(j in Oban.Job, where: j.queue == ^queue and j.state == "available"),
          :count,
          :id
        )

      executing =
        Cinegraph.Repo.aggregate(
          from(j in Oban.Job, where: j.queue == ^queue and j.state == "executing"),
          :count,
          :id
        )

      completed =
        Cinegraph.Repo.aggregate(
          from(j in Oban.Job, where: j.queue == ^queue and j.state == "completed"),
          :count,
          :id
        )

      %{
        queue: queue,
        available: available,
        executing: executing,
        completed: completed,
        total: available + executing
      }
    end)
  end
end
