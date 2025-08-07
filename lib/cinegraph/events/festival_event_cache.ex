defmodule Cinegraph.Events.FestivalEventCache do
  @moduledoc """
  Cache for festival events to avoid repeated database queries during parsing.
  Stores active festival events in memory for fast lookups.
  """

  use Agent
  require Logger

  alias Cinegraph.Events

  @cache_ttl :timer.minutes(5)

  def start_link(_opts) do
    Agent.start_link(fn -> %{events: nil, last_updated: nil} end, name: __MODULE__)
  end

  @doc """
  Get all active festival events from cache or database.
  Cache is automatically refreshed if expired.
  """
  def get_active_events do
    Agent.get_and_update(__MODULE__, fn state ->
      if cache_valid?(state) do
        {state.events, state}
      else
        events = Events.list_active_events()
        Logger.debug("FestivalEventCache: Loaded #{length(events)} active events from database")
        new_state = %{events: events, last_updated: System.monotonic_time(:millisecond)}
        {events, new_state}
      end
    end)
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
  Call this after creating, updating, or deleting festival events.
  """
  def invalidate do
    Agent.update(__MODULE__, fn _state ->
      Logger.debug("FestivalEventCache: Cache invalidated")
      %{events: nil, last_updated: nil}
    end)
  end

  @doc """
  Preload the cache with fresh data from the database.
  Useful after startup or after bulk updates.
  """
  def refresh do
    Agent.update(__MODULE__, fn _state ->
      events = Events.list_active_events()
      Logger.debug("FestivalEventCache: Refreshed with #{length(events)} active events")
      %{events: events, last_updated: System.monotonic_time(:millisecond)}
    end)
  end

  defp cache_valid?(%{events: nil}), do: false
  defp cache_valid?(%{last_updated: nil}), do: false
  
  defp cache_valid?(%{last_updated: last_updated}) do
    current_time = System.monotonic_time(:millisecond)
    age = current_time - last_updated
    age < @cache_ttl
  end
end