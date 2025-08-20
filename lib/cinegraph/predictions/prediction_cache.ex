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
    |> validate_inclusion(:decade, [1920, 1930, 1940, 1950, 1960, 1970, 1980, 1990, 2000, 2010, 2020])
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
    # Convert any Decimal values to floats before saving
    safe_attrs = deep_convert_decimals(attrs)
    
    %__MODULE__{}
    |> changeset(safe_attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:decade, :profile_id]
    )
  end
  
  # Deep convert all Decimals in any nested structure with more comprehensive coverage
  defp deep_convert_decimals(%Decimal{} = decimal) do
    # Add logging to see what we're converting
    require Logger
    Logger.debug("Converting Decimal to float: #{inspect(decimal)} -> #{Decimal.to_float(decimal)}")
    Decimal.to_float(decimal)
  end
  
  # Handle other struct types that might contain Decimals
  defp deep_convert_decimals(%{__struct__: struct_name} = struct_data) when struct_name not in [DateTime, Date, Time, NaiveDateTime] do
    # Convert struct to map, process, but keep as map (don't reconstruct struct)
    require Logger
    Logger.warning("Found unexpected struct type: #{inspect(struct_name)}, converting to map")
    
    struct_data
    |> Map.from_struct()
    |> deep_convert_decimals()
  end
  
  defp deep_convert_decimals(%DateTime{} = dt), do: dt
  defp deep_convert_decimals(%Date{} = date), do: date
  defp deep_convert_decimals(%Time{} = time), do: time
  defp deep_convert_decimals(%NaiveDateTime{} = ndt), do: ndt
  
  defp deep_convert_decimals(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, deep_convert_decimals(v)} end)
  end
  
  defp deep_convert_decimals(list) when is_list(list) do
    Enum.map(list, &deep_convert_decimals/1)
  end
  
  defp deep_convert_decimals(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&deep_convert_decimals/1)
    |> List.to_tuple()
  end
  
  defp deep_convert_decimals(value), do: value
  
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