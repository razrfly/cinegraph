defmodule Cinegraph.CanonicalLists do
  @moduledoc """
  Thin compatibility wrapper over the movie_lists database table.

  Previously held hardcoded list configurations. Now delegates to
  `Cinegraph.Movies.MovieLists` so the database is the single source of truth.
  Existing callers (CanonicalImportWorker, CanonicalImporter, import_canonical mix task)
  continue working with zero changes.
  """

  alias Cinegraph.Movies.MovieLists

  @doc """
  Get all available canonical lists.
  Returns a map of %{source_key => config}.
  """
  def all do
    MovieLists.all_as_config()
  end

  @doc """
  Get a specific list configuration by key.
  Returns {:ok, config} or {:error, message}.
  """
  def get(list_key) when is_binary(list_key) do
    MovieLists.get_config(list_key)
  end

  @doc """
  Get just the list IDs (source_ids) for all active lists.
  """
  def list_ids do
    MovieLists.list_active_movie_lists()
    |> Enum.map(& &1.source_id)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Build the IMDb URL for a list.
  """
  def list_url(list_key) when is_binary(list_key) do
    case get(list_key) do
      {:ok, config} -> {:ok, "https://www.imdb.com/list/#{config.list_id}/"}
      error -> error
    end
  end
end
