defmodule Cinegraph.Imports.ImportStateV2 do
  @moduledoc """
  New import state tracking using the unified api_lookup_metrics system.
  Provides the same API as ImportState but with better observability and performance tracking.
  """

  alias Cinegraph.Metrics.ApiTracker

  @default_source "tmdb"

  @doc """
  Gets a value by key, returns nil if not found.
  """
  def get(key), do: ApiTracker.get_import_state(@default_source, key)

  @doc """
  Gets a value by key, returns default if not found.
  """
  def get(key, default), do: ApiTracker.get_import_state(@default_source, key, default)

  @doc """
  Gets a value as an integer.
  """
  def get_integer(key, default \\ 0) do
    ApiTracker.get_import_state_integer(@default_source, key, default)
  end

  @doc """
  Gets a value as a float.
  """
  def get_float(key, default \\ 0.0) do
    case get(key) do
      nil ->
        default

      value when is_float(value) ->
        value

      value when is_integer(value) ->
        value * 1.0

      value when is_binary(value) ->
        case Float.parse(value) do
          {float, _} -> float
          :error -> default
        end

      _ ->
        default
    end
  end

  @doc """
  Gets a value as a date.
  """
  def get_date(key) do
    ApiTracker.get_import_state_date(@default_source, key)
  end

  @doc """
  Sets a value for a key.
  """
  def set(key, value) when is_binary(key) do
    case ApiTracker.set_import_state(@default_source, key, value) do
      {:ok, _} ->
        # Return format compatible with old system
        {:ok, %{key: key, value: value}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sets multiple key-value pairs.
  """
  def set_many(pairs) when is_list(pairs) do
    Enum.each(pairs, fn {key, value} -> set(key, value) end)
  end

  @doc """
  Gets all state as a map.
  """
  def all do
    ApiTracker.get_all_import_state(@default_source)
  end

  # Convenience functions for common keys (maintaining backward compatibility)

  @doc """
  Get/set the total number of movies in TMDB.
  """
  def tmdb_total_movies, do: get_integer("total_movies", 0)
  def set_tmdb_total_movies(count), do: set("total_movies", count)

  @doc """
  Get/set the last page processed during import.
  """
  def last_page_processed, do: get_integer("last_page_processed", 0)
  def set_last_page_processed(page), do: set("last_page_processed", page)

  @doc """
  Get/set the timestamp of the last full sync.
  """
  def last_full_sync, do: get_date("last_full_sync")
  def set_last_full_sync(date \\ Date.utc_today()), do: set("last_full_sync", date)

  @doc """
  Get/set the timestamp of the last update check.
  """
  def last_update_check, do: get_date("last_update_check")
  def set_last_update_check(date \\ Date.utc_today()), do: set("last_update_check", date)

  @doc """
  Delete functionality (not supported in new system - returns success for compatibility)
  """
  def delete(_key), do: {:ok, nil}

  @doc """
  Gets import progress with enhanced metrics.
  """
  def get_progress_with_metrics do
    # Get individual values using the correct key names
    our_total = count_our_movies()
    tmdb_total = get_integer("total_movies", 0)
    last_page = get_integer("last_page_processed", 0)
    last_sync = get_date("last_full_sync")
    last_check = get_date("last_update_check")

    %{
      tmdb_total_movies: tmdb_total,
      our_total_movies: our_total,
      movies_remaining: max(0, tmdb_total - our_total),
      completion_percentage:
        if(tmdb_total > 0, do: Float.round(our_total / tmdb_total * 100, 2), else: 0.0),
      last_page_processed: last_page,
      last_full_sync: last_sync,
      last_update_check: last_check
    }
  end

  # Helper function to count our movies (copied from TMDbImporter)
  defp count_our_movies do
    import Ecto.Query
    alias Cinegraph.{Repo, Movies.Movie}

    Repo.one(from m in Movie, select: count(m.id))
  end
end
