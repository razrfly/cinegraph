defmodule Cinegraph.Events.FestivalEventCacheETS do
  @moduledoc """
  ETS-based cache for festival events to avoid repeated database queries during parsing.
  More robust than Agent-based caching with better concurrency and crash recovery.
  """

  use GenServer
  require Logger

  alias Cinegraph.Events

  @table_name :festival_event_cache
  @cache_ttl :timer.minutes(5)
  @cache_key :events
  @timestamp_key :last_updated

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get all active festival events from cache or database.
  Falls back to direct database query if cache is not available.
  """
  def get_active_events do
    case :ets.whereis(@table_name) do
      :undefined ->
        # Cache not initialized, fall back to direct query
        Logger.debug("FestivalEventCache: ETS table not found, falling back to database")
        Events.list_active_events()
      
      _tid ->
        case :ets.lookup(@table_name, @cache_key) do
          [{@cache_key, events, timestamp}] ->
            if cache_valid?(timestamp) do
              events
            else
              refresh_cache()
            end
          
          [] ->
            refresh_cache()
        end
    end
  rescue
    # If ETS crashes, fall back to database
    _error ->
      Logger.warning("FestivalEventCache: ETS error, falling back to database")
      Events.list_active_events()
  end

  @doc """
  Find a festival event by abbreviation using cached data.
  """
  def find_by_abbreviation(abbreviation) do
    get_active_events()
    |> Enum.find(fn event -> event.abbreviation == abbreviation end)
  end

  @doc """
  Find a festival event by source key using cached data.
  """
  def find_by_source_key(source_key) do
    get_active_events()
    |> Enum.find(fn event -> event.source_key == source_key end)
  end

  @doc """
  Invalidate the cache, forcing a reload on next access.
  """
  def invalidate do
    case :ets.whereis(@table_name) do
      :undefined -> :ok
      _tid ->
        :ets.delete(@table_name, @cache_key)
        Logger.debug("FestivalEventCache: Cache invalidated")
    end
    :ok
  rescue
    _error -> :ok
  end

  @doc """
  Preload the cache with fresh data from the database.
  """
  def refresh do
    refresh_cache()
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table with public read access for better performance
    :ets.new(@table_name, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])
    
    # Preload cache on startup
    refresh_cache()
    
    Logger.info("FestivalEventCache: ETS cache initialized")
    {:ok, %{}}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    events = refresh_cache()
    {:reply, events, state}
  end

  @impl true
  def handle_cast(:invalidate, state) do
    invalidate()
    {:noreply, state}
  end

  # Private functions

  defp refresh_cache do
    events = Events.list_active_events()
    timestamp = System.monotonic_time(:millisecond)
    
    :ets.insert(@table_name, {@cache_key, events, timestamp})
    
    Logger.debug("FestivalEventCache: Loaded #{length(events)} active events from database")
    events
  rescue
    error ->
      Logger.error("FestivalEventCache: Error refreshing cache: #{inspect(error)}")
      # Return direct database query on error
      Events.list_active_events()
  end

  defp cache_valid?(timestamp) do
    current_time = System.monotonic_time(:millisecond)
    age = current_time - timestamp
    age < @cache_ttl
  end
end