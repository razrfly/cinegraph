defmodule Cinegraph.Metrics do
  @moduledoc """
  The Metrics context handles all volatile/subjective data from external sources.
  Replaces the old ExternalSources module for storing ratings, popularity, and financial data.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Movie, ExternalMetric, MovieRecommendation}
  require Logger

  @doc """
  Stores metrics from TMDb data.
  """
  def store_tmdb_metrics(movie, tmdb_data) do
    metrics = ExternalMetric.from_tmdb(movie.id, tmdb_data)
    
    Enum.each(metrics, fn metric_attrs ->
      upsert_metric(metric_attrs)
    end)
    
    :ok
  end

  @doc """
  Stores metrics from OMDb data.
  """
  def store_omdb_metrics(movie, omdb_data) do
    metrics = ExternalMetric.from_omdb(movie.id, omdb_data)
    
    Enum.each(metrics, fn metric_attrs ->
      upsert_metric(metric_attrs)
    end)
    
    :ok
  end

  @doc """
  Creates or updates a metric.
  """
  def upsert_metric(attrs) do
    %ExternalMetric{}
    |> ExternalMetric.changeset(attrs)
    |> Repo.insert(
      on_conflict: :replace_all,
      conflict_target: [:movie_id, :source, :metric_type, :fetched_at]
    )
  end

  @doc """
  Stores TMDb recommendations.
  """
  def store_tmdb_recommendations(source_movie, recommendations_data, type) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    
    recommendations_data
    |> Enum.with_index(1)
    |> Enum.each(fn {rec_data, rank} ->
      # First ensure the recommended movie exists
      case Repo.get_by(Movie, tmdb_id: rec_data["id"]) do
        nil ->
          # Skip if movie doesn't exist yet
          :ok

        recommended_movie ->
          attrs = %{
            source_movie_id: source_movie.id,
            recommended_movie_id: recommended_movie.id,
            source: "tmdb",
            type: type,
            rank: rank,
            score: rec_data["vote_average"] || 0.0,
            metadata: %{
              "popularity" => rec_data["popularity"],
              "vote_count" => rec_data["vote_count"],
              "release_date" => rec_data["release_date"]
            },
            fetched_at: now
          }
          
          %MovieRecommendation{}
          |> MovieRecommendation.changeset(attrs)
          |> Repo.insert(
            on_conflict: :replace_all,
            conflict_target: [:source_movie_id, :recommended_movie_id, :source, :type]
          )
      end
    end)
    
    :ok
  end

  @doc """
  Gets all metrics for a movie, optionally filtered by source or type.
  """
  def get_movie_metrics(movie_id, opts \\ []) do
    query = from m in ExternalMetric, where: m.movie_id == ^movie_id
    
    query = case Keyword.get(opts, :source) do
      nil -> query
      source -> from m in query, where: m.source == ^source
    end
    
    query = case Keyword.get(opts, :metric_type) do
      nil -> query
      type -> from m in query, where: m.metric_type == ^type
    end
    
    Repo.all(query)
  end

  @doc """
  Gets the latest value for a specific metric.
  """
  def get_metric_value(movie_id, source, metric_type) do
    from(m in ExternalMetric,
      where: m.movie_id == ^movie_id and 
             m.source == ^source and 
             m.metric_type == ^metric_type,
      order_by: [desc: m.fetched_at],
      limit: 1,
      select: m.value
    )
    |> Repo.one()
  end

  @doc """
  Stores review and list appearance metrics from TMDb.
  """
  def store_tmdb_engagement_metrics(movie, reviews_data, lists_data) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    
    # Store review count as engagement metric
    if reviews_data && reviews_data["results"] do
      review_count = length(reviews_data["results"])
      
      # Calculate average rating if reviews have ratings
      avg_rating = if review_count > 0 do
        ratings = reviews_data["results"]
          |> Enum.filter(& &1["author_details"]["rating"])
          |> Enum.map(& &1["author_details"]["rating"])
        
        if length(ratings) > 0 do
          Enum.sum(ratings) / length(ratings)
        end
      end
      
      upsert_metric(%{
        movie_id: movie.id,
        source: "tmdb",
        metric_type: "rating_votes",
        value: review_count,
        metadata: %{
          "type" => "user_reviews",
          "average_rating" => avg_rating
        },
        fetched_at: now
      })
    end
    
    # Store list appearances as popularity metric
    if lists_data && lists_data["results"] do
      list_count = length(lists_data["results"])
      
      # Count lists that might be culturally relevant
      cultural_lists = lists_data["results"]
        |> Enum.filter(fn list ->
          name = String.downcase(list["name"] || "")
          String.contains?(name, [
            "award", "oscar", "academy", "cannes", "criterion",
            "afi", "best", "greatest", "top", "essential", "classic"
          ])
        end)
      
      upsert_metric(%{
        movie_id: movie.id,
        source: "tmdb",
        metric_type: "popularity_score",
        value: list_count,
        metadata: %{
          "type" => "list_appearances",
          "cultural_list_count" => length(cultural_lists),
          "cultural_list_names" => Enum.take(Enum.map(cultural_lists, & &1["name"]), 10)
        },
        fetched_at: now
      })
    end
    
    :ok
  end

  @doc """
  Gets aggregated metrics for a movie (for backward compatibility).
  Returns a map similar to what the movies table used to contain.
  """
  def get_movie_aggregates(movie_id) do
    metrics = get_movie_metrics(movie_id)
    
    Enum.reduce(metrics, %{}, fn metric, acc ->
      case metric.metric_type do
        "rating_average" when metric.source == "tmdb" ->
          Map.put(acc, :vote_average, metric.value)
        "rating_votes" when metric.source == "tmdb" ->
          Map.put(acc, :vote_count, metric.value)
        "popularity_score" when metric.source == "tmdb" ->
          Map.put(acc, :popularity, metric.value)
        "budget" ->
          Map.put(acc, :budget, metric.value)
        "revenue_worldwide" ->
          Map.put(acc, :revenue, metric.value)
        "revenue_domestic" ->
          Map.put(acc, :box_office_domestic, metric.value)
        "awards_summary" ->
          Map.merge(acc, %{
            awards_text: metric.text_value,
            awards: metric.metadata
          })
        _ ->
          acc
      end
    end)
  end
end