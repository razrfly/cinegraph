defmodule Cinegraph.Lists.ListSlugs do
  @moduledoc """
  Mapping between URL-friendly slugs and internal list keys.
  Provides bidirectional lookup for clean URL routing.

  Now delegates to the movie_lists database table (single source of truth)
  while maintaining the same public API for all callers.
  """

  alias Cinegraph.Movies.MovieLists

  @doc """
  Convert a URL slug to an internal list key.
  Returns {:ok, key} or {:error, :not_found}
  """
  def slug_to_key(slug) when is_binary(slug) do
    case MovieLists.get_by_slug(slug) do
      nil -> {:error, :not_found}
      list -> {:ok, list.source_key}
    end
  end

  @doc """
  Convert an internal list key to a URL slug.
  Returns {:ok, slug} or {:error, :not_found}
  """
  def key_to_slug(key) when is_binary(key) do
    case MovieLists.get_by_source_key(key) do
      nil -> {:error, :not_found}
      %{slug: nil} -> {:error, :not_found}
      list -> {:ok, list.slug}
    end
  end

  @doc """
  Get metadata for a list by its internal key.
  Returns {:ok, metadata} or {:error, :not_found}
  """
  def get_metadata(key) when is_binary(key) do
    case MovieLists.get_by_source_key(key) do
      nil ->
        {:error, :not_found}

      list ->
        {:ok,
         %{
           name: list.name,
           short_name: list.short_name,
           description: list.description,
           icon: list.icon
         }}
    end
  end

  @doc """
  Get all lists with their slugs and metadata.
  Returns a list of maps with :key, :slug, and metadata fields.
  """
  def all do
    MovieLists.all_displayable()
    |> Enum.map(&to_display_map/1)
    |> Enum.sort_by(&Map.get(&1, :name, ""))
  end

  @doc """
  Get list info by slug including metadata.
  Returns {:ok, map} or {:error, :not_found}
  """
  def get_by_slug(slug) when is_binary(slug) do
    case MovieLists.get_by_slug(slug) do
      nil -> {:error, :not_found}
      list -> {:ok, to_display_map(list)}
    end
  end

  @doc """
  Check if a slug is valid.
  """
  def valid_slug?(slug) when is_binary(slug) do
    MovieLists.get_by_slug(slug) != nil
  end

  @doc """
  Get all valid slugs.
  """
  def all_slugs do
    MovieLists.all_slugs()
  end

  @doc """
  Get all valid internal keys.
  """
  def all_keys do
    MovieLists.all_displayable()
    |> Enum.map(& &1.source_key)
  end

  # Convert a MovieList struct to the display map format callers expect
  defp to_display_map(list) do
    %{
      key: list.source_key,
      slug: list.slug,
      name: list.name,
      short_name: list.short_name,
      description: list.description,
      icon: list.icon
    }
  end
end
