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
    query = from ml in MovieList, 
            where: ml.active == true, 
            select: ml.source_key

    query = case Keyword.get(opts, :category) do
      nil -> query
      category -> from ml in query, where: ml.category == ^category
    end

    query = case Keyword.get(opts, :tracks_awards) do
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
  
  defp determine_category(_source_key, config) do
    # Try to determine category from metadata first
    case get_in(config, [:metadata, "category"]) do
      category when is_binary(category) -> category
      _ ->
        # Intelligent fallback based on content analysis
        cond do
          String.contains?(config.name, ["Award", "Winners", "Festival"]) -> "awards"
          String.contains?(config.name, ["Critics", "Poll", "Sight"]) -> "critics"
          String.contains?(config.name, ["Registry", "Archive", "Library"]) -> "registry"
          String.contains?(config.name, ["Collection", "Must See"]) -> "curated"
          true -> "curated"
        end
    end
  end
  
  defp tracks_awards?(_source_key, config) do
    # Check if explicitly set in metadata
    case get_in(config, [:metadata, "tracks_awards"]) do
      true -> true
      false -> false
      _ ->
        # Intelligent fallback - detect award-related lists by name/content
        has_award_keywords = String.contains?(config.name, [
          "Award", "Winners", "Festival", "Golden", "Bear", "Lion", 
          "Palme", "Academy", "Oscar", "Cannes", "Berlin", "Venice"
        ])
        
        has_award_metadata = get_in(config, [:metadata, "awards_included"]) != nil ||
                            get_in(config, [:metadata, "festival"]) != nil
        
        has_award_keywords || has_award_metadata
    end
  end
  
end