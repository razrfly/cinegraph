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
  Get cached predictions for multiple decades.
  """
  def get_cached_predictions_multi(decades, profile_id) when is_list(decades) do
    Repo.all(
      from pc in __MODULE__,
        where: pc.decade in ^decades and pc.profile_id == ^profile_id,
        preload: :profile
    )
  end
  
  @doc """
  Get cached movie scores for a specific decade and profile.
  Returns the movie_scores map or nil if no cache exists.
  """
  def get_movie_scores(decade, profile_id) do
    case get_cached_predictions(decade, profile_id) do
      nil -> nil
      cache -> cache.movie_scores
    end
  end
  
  @doc """
  Get cached statistics for a decade and profile.
  """
  def get_statistics(decade, profile_id) do
    case get_cached_predictions(decade, profile_id) do
      nil -> nil
      cache -> cache.statistics
    end
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
  Get cache coverage statistics.
  """
  def get_cache_coverage do
    all_combinations = 
      for decade <- [1960, 1970, 1980, 1990, 2000, 2010, 2020],
          profile <- Repo.all(from p in Metrics.MetricWeightProfile, where: p.active == true),
          do: {decade, profile.id}
    
    cached_count = 
      Repo.one(
        from pc in __MODULE__,
          select: count(pc.id)
      ) || 0
    
    total_possible = length(all_combinations)
    
    %{
      cached: cached_count,
      total: total_possible,
      coverage_percentage: if(total_possible > 0, do: cached_count / total_possible * 100, else: 0),
      missing_combinations: find_missing_combinations(all_combinations)
    }
  end
  
  @doc """
  Get age statistics for all caches.
  """
  def get_cache_age_stats do
    caches = Repo.all(
      from pc in __MODULE__,
        select: %{
          decade: pc.decade,
          profile_id: pc.profile_id,
          calculated_at: pc.calculated_at
        }
    )
    
    now = DateTime.utc_now()
    
    ages = Enum.map(caches, fn cache ->
      DateTime.diff(now, cache.calculated_at, :hour)
    end)
    
    if Enum.empty?(ages) do
      %{
        oldest_hours: nil,
        newest_hours: nil,
        average_hours: nil,
        median_hours: nil
      }
    else
      sorted_ages = Enum.sort(ages)
      
      %{
        oldest_hours: Enum.max(ages),
        newest_hours: Enum.min(ages),
        average_hours: Enum.sum(ages) / length(ages),
        median_hours: Enum.at(sorted_ages, div(length(sorted_ages), 2))
      }
    end
  end
  
  @doc """
  Get sorted predictions for display.
  Returns a list of movies with scores, sorted by score descending.
  """
  def get_sorted_predictions(decade, profile_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    min_score = Keyword.get(opts, :min_score, 0)
    canonical_filter = Keyword.get(opts, :canonical_source)
    
    case get_cached_predictions(decade, profile_id) do
      nil -> 
        []
        
      cache ->
        cache.movie_scores
        |> Map.to_list()
        |> Enum.map(fn {movie_id, data} ->
          Map.put(data, :id, movie_id)
        end)
        |> maybe_filter_canonical(canonical_filter)
        |> Enum.filter(fn movie -> movie.score >= min_score end)
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(limit)
    end
  end
  
  defp find_missing_combinations(all_combinations) do
    cached = 
      Repo.all(
        from pc in __MODULE__,
          select: {pc.decade, pc.profile_id}
      )
    
    all_combinations -- cached
  end
  
  defp maybe_filter_canonical(movies, nil), do: movies
  defp maybe_filter_canonical(movies, source) do
    Enum.filter(movies, fn movie ->
      movie[:canonical_sources] && Map.has_key?(movie.canonical_sources, source)
    end)
  end
end