defmodule Cinegraph.Imports.ImportState do
  @moduledoc """
  Simple key-value store for tracking import state.
  Used for tracking pagination, total counts, and sync timestamps.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Cinegraph.Repo
  
  @primary_key {:key, :string, []}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: :updated_at]
  
  schema "import_state" do
    field :value, :string
    field :updated_at, :utc_datetime_usec
  end
  
  @doc """
  Gets a value by key, returns nil if not found.
  """
  def get(key) do
    case Repo.get(__MODULE__, key) do
      nil -> nil
      state -> state.value
    end
  end
  
  @doc """
  Gets a value by key, returns default if not found.
  """
  def get(key, default) do
    get(key) || default
  end
  
  @doc """
  Gets a value as an integer.
  """
  def get_integer(key, default \\ 0) do
    case get(key) do
      nil -> default
      value -> 
        case Integer.parse(value) do
          {int, _} -> int
          :error -> default
        end
    end
  end
  
  @doc """
  Gets a value as a date.
  """
  def get_date(key) do
    case get(key) do
      nil -> nil
      value -> Date.from_iso8601!(value)
    end
  end
  
  @doc """
  Sets a value for a key.
  """
  def set(key, value) when is_binary(key) do
    value_string = to_string(value)
    
    case Repo.get(__MODULE__, key) do
      nil ->
        %__MODULE__{key: key}
        |> changeset(%{value: value_string})
        |> Repo.insert()
      
      existing ->
        existing
        |> changeset(%{value: value_string})
        |> Repo.update()
    end
  end
  
  @doc """
  Sets multiple key-value pairs.
  """
  def set_many(pairs) when is_list(pairs) do
    Enum.each(pairs, fn {key, value} -> set(key, value) end)
  end
  
  @doc """
  Deletes a key.
  """
  def delete(key) do
    case Repo.get(__MODULE__, key) do
      nil -> {:ok, nil}
      state -> Repo.delete(state)
    end
  end
  
  @doc """
  Gets all state as a map.
  """
  def all do
    __MODULE__
    |> Repo.all()
    |> Enum.map(fn state -> {state.key, state.value} end)
    |> Enum.into(%{})
  end
  
  # Changeset
  defp changeset(state, attrs) do
    state
    |> cast(attrs, [:value])
    |> validate_required([:value])
    |> put_change(:updated_at, DateTime.utc_now())
  end
  
  # Convenience functions for common keys
  
  @doc """
  Get/set the total number of movies in TMDB.
  """
  def tmdb_total_movies, do: get_integer("tmdb_total_movies", 0)
  def set_tmdb_total_movies(count), do: set("tmdb_total_movies", count)
  
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
end