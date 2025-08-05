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
  """
  def get_movie_list!(id), do: Repo.get!(MovieList, id)
  
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
  def update_import_stats(%MovieList{} = movie_list, status, movie_count) do
    attrs = %{
      last_import_at: DateTime.utc_now(),
      last_import_status: status,
      last_movie_count: movie_count,
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
  Get a specific list configuration by source_key.
  Falls back to hardcoded canonical lists if not found in database.
  """
  def get_config(source_key) do
    case get_active_by_source_key(source_key) do
      %MovieList{} = list -> 
        {:ok, MovieList.to_config(list)}
      nil ->
        # Fallback to hardcoded lists during transition
        Cinegraph.CanonicalLists.get(source_key)
    end
  end
  
  @doc """
  Migrate existing hardcoded lists to the database.
  This is idempotent - it won't create duplicates.
  """
  def migrate_hardcoded_lists do
    hardcoded_lists = Cinegraph.CanonicalLists.all()
    
    results = Enum.map(hardcoded_lists, fn {source_key, config} ->
      # Check if already exists
      case get_by_source_key(source_key) do
        nil ->
          # Create new list from hardcoded config
          attrs = %{
            source_key: source_key,
            name: config.name,
            source_type: "imdb",
            source_url: "https://www.imdb.com/list/#{config.list_id}/",
            source_id: config.list_id,
            category: determine_category(source_key, config),
            active: true,
            tracks_awards: tracks_awards?(source_key, config),
            award_types: extract_award_types(config),
            metadata: config.metadata || %{}
          }
          
          case create_movie_list(attrs) do
            {:ok, list} -> {:ok, list}
            {:error, changeset} -> {:error, source_key, changeset}
          end
          
        existing ->
          {:exists, existing}
      end
    end)
    
    # Summary
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
  
  # Private helper functions
  
  defp determine_category(source_key, _config) do
    cond do
      source_key == "cannes_winners" -> "awards"
      source_key == "sight_sound_critics_2022" -> "critics"
      source_key == "national_film_registry" -> "registry"
      source_key == "criterion" -> "curated"
      true -> "curated"
    end
  end
  
  defp tracks_awards?(source_key, config) do
    source_key == "cannes_winners" || 
    get_in(config, [:metadata, "awards_included"]) != nil
  end
  
  defp extract_award_types(config) do
    case get_in(config, [:metadata, "awards_included"]) do
      nil -> []
      awards_string -> 
        awards_string
        |> String.split(",")
        |> Enum.map(&String.trim/1)
    end
  end
end