defmodule Cinegraph.Predictions.PredictionCache do
  @moduledoc """
  Schema and context for the prediction cache table.
  Stores pre-calculated prediction scores to avoid expensive queries.
  """
  
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Cinegraph.{Repo, Metrics}
  
  schema "prediction_cache" do
    field :decade, :integer
    belongs_to :profile, Metrics.MetricWeightProfile
    field :movie_scores, :map
    field :statistics, :map
    field :calculated_at, :utc_datetime
    field :metadata, :map
    
    timestamps()
  end
  
  @doc false
  def changeset(cache, attrs) do
    cache
    |> cast(attrs, [:decade, :profile_id, :movie_scores, :statistics, :calculated_at, :metadata])
    |> validate_required([:decade, :profile_id, :movie_scores, :statistics, :calculated_at])
    |> validate_inclusion(:decade, [1960, 1970, 1980, 1990, 2000, 2010, 2020])
    |> unique_constraint([:decade, :profile_id])
  end
  
  @doc """
  Get cached predictions for a decade and profile.
  Returns nil if no cache exists.
  """
  def get_cached_predictions(decade, profile_id) do
    Repo.one(
      from pc in __MODULE__,
        where: pc.decade == ^decade and pc.profile_id == ^profile_id,
        preload: :profile
    )
  end
  
  @doc """
  Check if cache exists for a decade and profile.
  """
  def cache_exists?(decade, profile_id) do
    Repo.exists?(
      from pc in __MODULE__,
        where: pc.decade == ^decade and pc.profile_id == ^profile_id
    )
  end
  
  @doc """
  Check if cache is stale (older than specified hours).
  """
  def cache_stale?(decade, profile_id, max_age_hours \\ 168) do
    cutoff = DateTime.utc_now() |> DateTime.add(-max_age_hours * 3600, :second)
    
    case get_cached_predictions(decade, profile_id) do
      nil -> true
      cache -> DateTime.compare(cache.calculated_at, cutoff) == :lt
    end
  end
  
  @doc """
  Get age of cache in hours.
  """
  def get_cache_age(decade, profile_id) do
    case get_cached_predictions(decade, profile_id) do
      nil -> nil
      cache -> 
        DateTime.diff(DateTime.utc_now(), cache.calculated_at, :hour)
    end
  end
  
  @doc """
  Upsert cache entry for a decade and profile.
  """
  def upsert_cache(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:decade, :profile_id]
    )
  end
  
  @doc """
  Delete cache for a specific decade and profile.
  """
  def delete_cache(decade, profile_id) do
    Repo.delete_all(
      from pc in __MODULE__,
        where: pc.decade == ^decade and pc.profile_id == ^profile_id
    )
  end
  
  @doc """
  Delete all caches for a profile.
  """
  def delete_profile_caches(profile_id) do
    Repo.delete_all(
      from pc in __MODULE__,
        where: pc.profile_id == ^profile_id
    )
  end
  
  @doc """
  Get all cached profiles and their status.
  """
  def get_cache_status do
    Repo.all(
      from pc in __MODULE__,
        join: p in assoc(pc, :profile),
        select: %{
          decade: pc.decade,
          profile_name: p.name,
          profile_id: pc.profile_id,
          calculated_at: pc.calculated_at,
          movie_count: fragment("jsonb_object_length(?)", pc.movie_scores)
        },
        order_by: [desc: pc.calculated_at]
    )
  end
end