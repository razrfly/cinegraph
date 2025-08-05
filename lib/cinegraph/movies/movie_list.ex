defmodule Cinegraph.Movies.MovieList do
  @moduledoc """
  Schema for managing dynamic movie lists from various sources (IMDB, TMDb, etc).
  Replaces the hardcoded canonical_lists.ex with a database-driven approach.
  """
  use Ecto.Schema
  import Ecto.Changeset
  
  @source_types ["imdb", "tmdb", "letterboxd", "custom"]
  @categories ["awards", "critics", "curated", "festivals", "personal", "registry"]
  @import_statuses ["success", "failed", "partial", "pending"]
  
  schema "movie_lists" do
    # Basic Info
    field :source_key, :string
    field :name, :string
    field :description, :string
    
    # Source Details
    field :source_type, :string
    field :source_url, :string
    field :source_id, :string
    
    # Configuration
    field :category, :string
    field :active, :boolean, default: true
    
    # Award Tracking
    field :tracks_awards, :boolean, default: false
    
    # Import Tracking
    field :last_import_at, :utc_datetime
    field :last_import_status, :string
    field :total_imports, :integer, default: 0
    
    # Metadata
    field :metadata, :map, default: %{}
    
    timestamps()
  end
  
  @doc false
  def changeset(movie_list, attrs) do
    movie_list
    |> cast(attrs, [
      :source_key, :name, :description, :source_type, :source_url, :source_id,
      :category, :active, :tracks_awards, :last_import_at,
      :last_import_status, :total_imports, :metadata
    ])
    |> validate_required([:source_key, :name, :source_type, :source_url])
    |> validate_inclusion(:source_type, @source_types)
    |> validate_inclusion(:category, @categories, message: "must be one of: #{Enum.join(@categories, ", ")}")
    |> validate_inclusion(:last_import_status, @import_statuses, allow_nil: true)
    |> validate_length(:source_key, max: 255)
    |> validate_length(:name, max: 500)
    |> validate_url(:source_url)
    |> extract_source_id()
    |> unique_constraint(:source_key)
  end
  
  @doc """
  Changeset for updating import statistics after an import run.
  """
  def import_stats_changeset(movie_list, attrs) do
    movie_list
    |> cast(attrs, [:last_import_at, :last_import_status, :total_imports, :metadata])
    |> validate_inclusion(:last_import_status, @import_statuses)
  end
  
  # Private functions
  
  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn _, url ->
      case URI.parse(url) do
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and not is_nil(host) ->
          []
        _ ->
          [{field, "must be a valid HTTP(S) URL"}]
      end
    end)
  end
  
  defp extract_source_id(changeset) do
    case {get_field(changeset, :source_type), get_field(changeset, :source_url)} do
      {"imdb", url} when is_binary(url) ->
        # Extract IMDB list ID from URL (e.g., ls024863935)
        case Regex.run(~r/list\/(ls\d+)/, url) do
          [_, list_id] -> put_change(changeset, :source_id, list_id)
          _ -> changeset
        end
        
      {"tmdb", url} when is_binary(url) ->
        # Extract TMDb list ID from URL
        case Regex.run(~r/list\/(\d+)/, url) do
          [_, list_id] -> put_change(changeset, :source_id, list_id)
          _ -> changeset
        end
        
      _ ->
        changeset
    end
  end
  
  @doc """
  Convert MovieList to the format expected by existing import system.
  This ensures backward compatibility with the current canonical_lists.ex structure.
  """
  def to_config(%__MODULE__{} = list) do
    base_config = %{
      list_id: list.source_id,
      source_key: list.source_key,
      name: list.name,
      category: list.category,
      metadata: list.metadata || %{}
    }
    
    # Add award-specific metadata if applicable
    if list.tracks_awards do
      Map.put(base_config, :metadata, Map.merge(base_config.metadata, %{
        "tracks_awards" => true
      }))
    else
      base_config
    end
  end
  
  @doc """
  Returns valid source types for the dropdown.
  """
  def source_types, do: @source_types
  
  @doc """
  Returns valid categories for the dropdown.
  """
  def categories, do: @categories
end