defmodule Cinegraph.Movies.MovieLists do
  @moduledoc """
  Context for managing dynamic movie lists.
  Provides functions to create, read, update, and manage movie lists from various sources.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo
  alias Cinegraph.Movies.MovieList

  @doc """
  Returns all active movie lists.
  """
  def list_active_movie_lists do
    MovieList
    |> where([ml], ml.active == true)
    |> order_by([ml], asc: ml.name)
    |> Repo.all()
  end

  @doc """
  Returns all movie lists (active and inactive).
  """
  def list_all_movie_lists do
    MovieList
    |> order_by([ml], asc: ml.name)
    |> Repo.all()
  end

  @doc """
  Gets a single movie list by ID.
  Raises if not found.
  """
  def get_movie_list!(id), do: Repo.get!(MovieList, id)

  @doc """
  Gets a single movie list by ID.
  Returns nil if not found.
  """
  def get_movie_list(id), do: Repo.get(MovieList, id)

  @doc """
  Gets a movie list by source_key.
  Returns nil if not found.
  """
  def get_by_source_key(source_key) do
    Repo.get_by(MovieList, source_key: source_key)
  end

  @doc """
  Gets a movie list by source_key, only if active.
  This is the main function used by the import system.
  """
  def get_active_by_source_key(source_key) do
    MovieList
    |> where([ml], ml.source_key == ^source_key and ml.active == true)
    |> Repo.one()
  end

  @doc """
  Creates a movie list.
  """
  def create_movie_list(attrs \\ %{}) do
    %MovieList{}
    |> MovieList.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a movie list.
  """
  def update_movie_list(%MovieList{} = movie_list, attrs) do
    movie_list
    |> MovieList.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates import statistics for a movie list.
  """
  def update_import_stats(%MovieList{} = movie_list, status, _movie_count) do
    attrs = %{
      last_import_at: DateTime.utc_now(),
      last_import_status: status,
      total_imports: movie_list.total_imports + 1
    }

    movie_list
    |> MovieList.import_stats_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a movie list.
  """
  def delete_movie_list(%MovieList{} = movie_list) do
    Repo.delete(movie_list)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking movie list changes.
  """
  def change_movie_list(%MovieList{} = movie_list, attrs \\ %{}) do
    MovieList.changeset(movie_list, attrs)
  end

  @doc """
  Gets a movie list by its URL slug.
  Returns nil if not found.
  """
  def get_by_slug(slug) do
    MovieList
    |> where([ml], ml.slug == ^slug and ml.active == true)
    |> Repo.one()
  end

  @doc """
  Returns all active lists that have slugs, ordered by display_order.
  Used for the public-facing list index page.
  """
  def all_displayable do
    MovieList
    |> where([ml], ml.active == true and not is_nil(ml.slug))
    |> order_by([ml], asc: ml.display_order, asc: ml.name)
    |> Repo.all()
  end

  @doc """
  Returns all slug strings for active lists.
  Used by the sitemap generator.
  """
  def all_slugs do
    MovieList
    |> where([ml], ml.active == true and not is_nil(ml.slug))
    |> select([ml], ml.slug)
    |> order_by([ml], asc: ml.display_order)
    |> Repo.all()
  end

  @doc """
  Get all movie lists in the format expected by the import system.
  This provides backward compatibility with canonical_lists.ex
  """
  def all_as_config do
    list_active_movie_lists()
    |> Enum.map(fn list ->
      {list.source_key, MovieList.to_config(list)}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Get a specific list configuration by source_key from database only.
  No longer falls back to hardcoded canonical lists.
  """
  def get_config(source_key) do
    case get_active_by_source_key(source_key) do
      %MovieList{} = list ->
        {:ok, MovieList.to_config(list)}

      nil ->
        {:error, "List not found in database: #{source_key}"}
    end
  end

  @doc """
  Get all active source keys, optionally filtered by category.
  This replaces hardcoded arrays throughout the codebase.
  """
  def get_active_source_keys(opts \\ []) do
    query =
      from ml in MovieList,
        where: ml.active == true,
        select: ml.source_key

    query =
      case Keyword.get(opts, :category) do
        nil -> query
        category -> from ml in query, where: ml.category == ^category
      end

    query =
      case Keyword.get(opts, :tracks_awards) do
        nil -> query
        tracks_awards -> from ml in query, where: ml.tracks_awards == ^tracks_awards
      end

    Repo.all(query)
  end

  @doc """
  Get category for a specific source key from database.
  Returns nil if not found.
  """
  def get_category_for_source_key(source_key) do
    case get_active_by_source_key(source_key) do
      %MovieList{category: category} -> category
      nil -> nil
    end
  end

  @doc """
  Check if a source key tracks awards from database.
  Returns false if not found.
  """
  def tracks_awards_for_source_key?(source_key) do
    case get_active_by_source_key(source_key) do
      %MovieList{tracks_awards: tracks_awards} -> tracks_awards
      nil -> false
    end
  end

  @doc """
  Seed default canonical lists into the database.
  This is idempotent - it won't create duplicates.
  Data is inlined here to avoid circular dependencies with CanonicalLists.
  """
  def seed_default_lists do
    default_lists = [
      %{
        source_key: "1001_movies",
        name: "1001 Movies You Must See Before You Die",
        description:
          "The essential guide to cinema's greatest films, updated annually with new selections.",
        source_type: "imdb",
        source_url: "https://www.imdb.com/list/ls024863935/",
        source_id: "ls024863935",
        category: "curated",
        active: true,
        tracks_awards: false,
        metadata: %{"edition" => "2024"},
        slug: "1001-movies",
        short_name: "1001 Movies",
        icon: "film",
        display_order: 1
      },
      %{
        source_key: "criterion",
        name: "The Criterion Collection",
        description:
          "A continuing series of important classic and contemporary films from around the world.",
        source_type: "imdb",
        source_url: "https://www.imdb.com/list/ls087831830/",
        source_id: "ls087831830",
        category: "curated",
        active: true,
        tracks_awards: false,
        metadata: %{"source" => "criterion.com"},
        slug: "criterion",
        short_name: "Criterion",
        icon: "sparkles",
        display_order: 2
      },
      %{
        source_key: "sight_sound_critics_2022",
        name: "BFI's Sight & Sound | Critics' Top 100 Movies (2022 Edition)",
        description:
          "BFI's once-a-decade poll of the world's greatest films as voted by critics (2022 edition).",
        source_type: "imdb",
        source_url: "https://www.imdb.com/list/ls566134733/",
        source_id: "ls566134733",
        category: "critics",
        active: true,
        tracks_awards: false,
        metadata: %{
          "edition" => "2022",
          "poll_type" => "critics",
          "source" => "BFI Sight & Sound"
        },
        slug: "sight-sound-2022",
        short_name: "Sight & Sound 2022",
        icon: "eye",
        display_order: 3
      },
      %{
        source_key: "national_film_registry",
        name: "National Film Registry - The Full List of Films",
        description:
          "Films preserved by the Library of Congress for their cultural, historical, or aesthetic significance.",
        source_type: "imdb",
        source_url: "https://www.imdb.com/list/ls595303232/",
        source_id: "ls595303232",
        category: "registry",
        active: true,
        tracks_awards: false,
        metadata: %{
          "source" => "Library of Congress",
          "reliability" => "95%",
          "note" => "Updated annually after official announcements"
        },
        slug: "national-film-registry",
        short_name: "Film Registry",
        icon: "building-library",
        display_order: 4
      }
    ]

    results =
      Enum.map(default_lists, fn attrs ->
        case get_by_source_key(attrs.source_key) do
          nil ->
            case create_movie_list(attrs) do
              {:ok, list} -> {:ok, list}
              {:error, changeset} -> {:error, attrs.source_key, changeset}
            end

          existing ->
            # Update existing lists with display fields if missing
            if is_nil(existing.slug) and not is_nil(attrs[:slug]) do
              update_movie_list(
                existing,
                Map.take(attrs, [:slug, :short_name, :icon, :display_order, :description])
              )
            end

            {:exists, existing}
        end
      end)

    created = Enum.count(results, fn r -> match?({:ok, _}, r) end)
    existed = Enum.count(results, fn r -> match?({:exists, _}, r) end)
    errors = Enum.filter(results, fn r -> match?({:error, _, _}, r) end)

    %{
      created: created,
      existed: existed,
      errors: errors,
      total: length(results)
    }
  end

  @doc false
  @deprecated "Use seed_default_lists/0 instead"
  def migrate_hardcoded_lists, do: seed_default_lists()
end
