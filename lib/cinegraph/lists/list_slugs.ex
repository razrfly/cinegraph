defmodule Cinegraph.Lists.ListSlugs do
  @moduledoc """
  Mapping between URL-friendly slugs and internal list keys.
  Provides bidirectional lookup for clean URL routing.
  """

  # URL slug -> internal key
  @slug_to_key %{
    "1001-movies" => "1001_movies",
    "criterion" => "criterion",
    "sight-sound-2022" => "sight_sound_critics_2022",
    "national-film-registry" => "national_film_registry"
  }

  # Internal key -> URL slug
  @key_to_slug %{
    "1001_movies" => "1001-movies",
    "criterion" => "criterion",
    "sight_sound_critics_2022" => "sight-sound-2022",
    "national_film_registry" => "national-film-registry"
  }

  # Display metadata for each list
  @list_metadata %{
    "1001_movies" => %{
      name: "1001 Movies You Must See Before You Die",
      short_name: "1001 Movies",
      description:
        "The essential guide to cinema's greatest films, updated annually with new selections.",
      icon: "film"
    },
    "criterion" => %{
      name: "The Criterion Collection",
      short_name: "Criterion",
      description:
        "A continuing series of important classic and contemporary films from around the world.",
      icon: "sparkles"
    },
    "sight_sound_critics_2022" => %{
      name: "Sight & Sound Critics' Top 100",
      short_name: "Sight & Sound 2022",
      description:
        "BFI's once-a-decade poll of the world's greatest films as voted by critics (2022 edition).",
      icon: "eye"
    },
    "national_film_registry" => %{
      name: "National Film Registry",
      short_name: "Film Registry",
      description:
        "Films preserved by the Library of Congress for their cultural, historical, or aesthetic significance.",
      icon: "building-library"
    }
  }

  @doc """
  Convert a URL slug to an internal list key.
  Returns {:ok, key} or {:error, :not_found}
  """
  def slug_to_key(slug) when is_binary(slug) do
    case Map.get(@slug_to_key, slug) do
      nil -> {:error, :not_found}
      key -> {:ok, key}
    end
  end

  @doc """
  Convert an internal list key to a URL slug.
  Returns {:ok, slug} or {:error, :not_found}
  """
  def key_to_slug(key) when is_binary(key) do
    case Map.get(@key_to_slug, key) do
      nil -> {:error, :not_found}
      slug -> {:ok, slug}
    end
  end

  @doc """
  Get metadata for a list by its internal key.
  Returns {:ok, metadata} or {:error, :not_found}
  """
  def get_metadata(key) when is_binary(key) do
    case Map.get(@list_metadata, key) do
      nil -> {:error, :not_found}
      metadata -> {:ok, metadata}
    end
  end

  @doc """
  Get all lists with their slugs and metadata.
  Returns a list of maps with :key, :slug, and metadata fields.
  """
  def all do
    @key_to_slug
    |> Enum.map(fn {key, slug} ->
      metadata = Map.get(@list_metadata, key, %{})
      Map.merge(metadata, %{key: key, slug: slug})
    end)
    |> Enum.sort_by(&Map.get(&1, :name, ""))
  end

  @doc """
  Get list info by slug including metadata.
  Returns {:ok, map} or {:error, :not_found}
  """
  def get_by_slug(slug) when is_binary(slug) do
    with {:ok, key} <- slug_to_key(slug),
         {:ok, metadata} <- get_metadata(key) do
      {:ok, Map.merge(metadata, %{key: key, slug: slug})}
    end
  end

  @doc """
  Check if a slug is valid.
  """
  def valid_slug?(slug) when is_binary(slug) do
    Map.has_key?(@slug_to_key, slug)
  end

  @doc """
  Get all valid slugs.
  """
  def all_slugs do
    Map.keys(@slug_to_key)
  end

  @doc """
  Get all valid internal keys.
  """
  def all_keys do
    Map.keys(@key_to_slug)
  end
end
