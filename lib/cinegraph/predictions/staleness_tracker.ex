defmodule Cinegraph.Predictions.StalenessTracker do
  @moduledoc """
  Tracks changes to data that affects predictions.
  Helps determine when prediction cache needs to be refreshed.
  """
  
  alias Cinegraph.Repo
  import Ecto.Query
  
  @change_types [
    :movie_created,
    :movie_updated,
    :metric_updated,
    :festival_added,
    :festival_updated,
    :person_metric_updated,
    :canonical_source_added
  ]
  
  @doc """
  Track a change that might affect predictions.
  """
  def track_change(change_type, entity_id, opts \\ []) when change_type in @change_types do
    entity_type = Keyword.get(opts, :entity_type, infer_entity_type(change_type))
    metadata = Keyword.get(opts, :metadata, %{})
    affected_decades = Keyword.get(opts, :affected_decades, [])
    
    # If no decades specified, try to infer them
    affected_decades = 
      if Enum.empty?(affected_decades) do
        infer_affected_decades(change_type, entity_id, entity_type)
      else
        affected_decades
      end
    
    %{
      change_type: to_string(change_type),
      entity_id: entity_id,
      entity_type: entity_type,
      metadata: metadata,
      affected_decades: affected_decades,
      inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    }
    |> insert_tracking_record()
  end
  
  @doc """
  Get a comprehensive staleness report.
  """
  def get_staleness_report do
    last_refresh = get_last_refresh_time()
    
    changes_since = 
      if last_refresh do
        count_changes_since(last_refresh)
      else
        # No cache exists, everything is stale
        %{
          movies: count_all_changes("movie_"),
          metrics: count_all_changes("metric_"),
          festivals: count_all_changes("festival_")
        }
      end
    
    affected_decades = 
      if last_refresh do
        get_affected_decades_since(last_refresh)
      else
        # All decades are affected if no cache exists
        [1960, 1970, 1980, 1990, 2000, 2010, 2020]
      end
    
    %{
      last_refresh: last_refresh,
      changes_since: changes_since,
      affected_decades: affected_decades,
      recommendation: nil  # Will be calculated by RefreshManager
    }
  end
  
  @doc """
  Get detailed changes for a specific decade.
  """
  def get_decade_changes(decade, since \\ nil) do
    query = 
      from t in "prediction_staleness_tracking",
        where: ^decade in t.affected_decades,
        order_by: [desc: t.inserted_at],
        limit: 100,
        select: %{
          change_type: t.change_type,
          entity_id: t.entity_id,
          entity_type: t.entity_type,
          metadata: t.metadata,
          inserted_at: t.inserted_at
        }
    
    query = 
      if since do
        where(query, [t], t.inserted_at > ^since)
      else
        query
      end
    
    Repo.all(query)
  end
  
  @doc """
  Clear all tracking records.
  Usually called after a successful full refresh.
  """
  def clear_tracking do
    Repo.delete_all("prediction_staleness_tracking")
  end
  
  @doc """
  Clear tracking records older than specified days.
  """
  def clear_old_tracking(days_to_keep \\ 30) do
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-days_to_keep * 24 * 60 * 60)
    
    Repo.delete_all(
      from t in "prediction_staleness_tracking",
        where: t.inserted_at < ^cutoff
    )
  end
  
  @doc """
  Track a batch of changes efficiently.
  """
  def track_changes_batch(changes) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    
    entries = Enum.map(changes, fn change ->
      %{
        change_type: to_string(change.change_type),
        entity_id: change.entity_id,
        entity_type: change[:entity_type] || infer_entity_type(change.change_type),
        metadata: change[:metadata] || %{},
        affected_decades: change[:affected_decades] || [],
        inserted_at: now
      }
    end)
    
    Repo.insert_all("prediction_staleness_tracking", entries)
  end
  
  defp insert_tracking_record(attrs) do
    Repo.insert_all("prediction_staleness_tracking", [attrs])
  end
  
  defp get_last_refresh_time do
    Repo.one(
      from pc in "prediction_cache",
        select: max(pc.calculated_at)
    )
  end
  
  defp count_changes_since(since_datetime) do
    %{
      movies: count_changes_by_prefix("movie_", since_datetime),
      metrics: count_changes_by_prefix("metric_", since_datetime),
      festivals: count_changes_by_prefix("festival_", since_datetime)
    }
  end
  
  defp count_changes_by_prefix(prefix, since_datetime) do
    Repo.one(
      from t in "prediction_staleness_tracking",
        where: like(t.change_type, ^"#{prefix}%"),
        where: t.inserted_at > ^since_datetime,
        select: count(t.id)
    ) || 0
  end
  
  defp count_all_changes(prefix) do
    Repo.one(
      from t in "prediction_staleness_tracking",
        where: like(t.change_type, ^"#{prefix}%"),
        select: count(t.id)
    ) || 0
  end
  
  defp get_affected_decades_since(since_datetime) do
    Repo.all(
      from t in "prediction_staleness_tracking",
        where: t.inserted_at > ^since_datetime,
        select: fragment("DISTINCT unnest(?)", t.affected_decades)
    )
    |> Enum.sort()
    |> Enum.uniq()
  end
  
  defp infer_entity_type(:movie_created), do: "movie"
  defp infer_entity_type(:movie_updated), do: "movie"
  defp infer_entity_type(:metric_updated), do: "metric"
  defp infer_entity_type(:festival_added), do: "festival_nomination"
  defp infer_entity_type(:festival_updated), do: "festival_nomination"
  defp infer_entity_type(:person_metric_updated), do: "person_metric"
  defp infer_entity_type(:canonical_source_added), do: "movie"
  defp infer_entity_type(_), do: "unknown"
  
  defp infer_affected_decades(:movie_created, movie_id, "movie") do
    case get_movie_decade(movie_id) do
      nil -> []
      decade -> [decade]
    end
  end
  
  defp infer_affected_decades(:movie_updated, movie_id, "movie") do
    case get_movie_decade(movie_id) do
      nil -> []
      decade -> [decade]
    end
  end
  
  defp infer_affected_decades(:metric_updated, movie_id, _) do
    case get_movie_decade(movie_id) do
      nil -> []
      decade -> [decade]
    end
  end
  
  defp infer_affected_decades(:festival_added, nomination_id, _) do
    case get_festival_nomination_decade(nomination_id) do
      nil -> []
      decade -> [decade]
    end
  end
  
  defp infer_affected_decades(:person_metric_updated, person_id, _) do
    # Person metrics affect all decades they appear in
    get_person_decades(person_id)
  end
  
  defp infer_affected_decades(_, _, _), do: []
  
  defp get_movie_decade(movie_id) do
    case Repo.one(
      from m in "movies",
        where: m.id == ^movie_id,
        select: fragment("EXTRACT(DECADE FROM ?)::integer * 10", m.release_date)
    ) do
      nil -> nil
      decade -> decade
    end
  end
  
  defp get_festival_nomination_decade(nomination_id) do
    case Repo.one(
      from f in "festival_nominations",
        join: m in "movies", on: m.id == f.movie_id,
        where: f.id == ^nomination_id,
        select: fragment("EXTRACT(DECADE FROM ?)::integer * 10", m.release_date)
    ) do
      nil -> nil
      decade -> decade
    end
  end
  
  defp get_person_decades(person_id) do
    Repo.all(
      from mc in "movie_credits",
        join: m in "movies", on: m.id == mc.movie_id,
        where: mc.person_id == ^person_id,
        where: not is_nil(m.release_date),
        select: fragment("DISTINCT EXTRACT(DECADE FROM ?)::integer * 10", m.release_date)
    )
  end
end