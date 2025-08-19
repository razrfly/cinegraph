defmodule Cinegraph.Workers.PredictionCalculator do
  @moduledoc """
  Oban worker for calculating and caching movie predictions.
  Runs manually on-demand to avoid database overload.
  """
  use Oban.Worker,
    queue: :predictions,
    max_attempts: 3,
    priority: 2

  require Logger
  import Ecto.Query
  
  alias Cinegraph.{Repo, Movies, Metrics}
  alias Cinegraph.Predictions.PredictionCache
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => "full_refresh"} = args}) do
    Logger.info("Starting full prediction refresh")
    
    profiles = args["profile_ids"] || get_all_profile_ids()
    decades = args["decades"] || [1960, 1970, 1980, 1990, 2000, 2010, 2020]
    
    total = length(profiles) * length(decades)
    
    # Create a list of all combinations with their index
    combinations = for profile_id <- profiles, decade <- decades, do: {profile_id, decade}
    
    combinations
    |> Enum.with_index(1)
    |> Enum.each(fn {{profile_id, decade}, current} ->
      progress = round(current / total * 100)
      
      # Update job progress metadata
      update_job_progress(args["job_id"], progress, "Processing decade #{decade} for profile #{profile_id}")
      
      calculate_and_cache_predictions(profile_id, decade)
    end)
    
    Logger.info("Completed full prediction refresh")
    :ok
  end
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => "decade", "decade" => decade, "profile_id" => profile_id}}) do
    Logger.info("Refreshing predictions for decade #{decade}, profile #{profile_id}")
    
    calculate_and_cache_predictions(profile_id, decade)
    
    :ok
  end
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => "selective", "decades" => decades}}) do
    Logger.info("Starting selective prediction refresh for decades: #{inspect(decades)}")
    
    profiles = get_all_profile_ids()
    
    for profile_id <- profiles, decade <- decades do
      calculate_and_cache_predictions(profile_id, decade)
    end
    
    :ok
  end
  
  defp calculate_and_cache_predictions(profile_id, decade) do
    # Get the weight profile
    profile = Repo.get!(Metrics.MetricWeightProfile, profile_id)
    
    # Calculate predictions for this decade/profile combination
    predictions = calculate_predictions_for_decade(profile, decade)
    statistics = calculate_statistics(predictions)
    
    # Cache the results
    PredictionCache.upsert_cache(%{
      decade: decade,
      profile_id: profile_id,
      movie_scores: predictions,
      statistics: statistics,
      calculated_at: DateTime.utc_now()
    })
  end
  
  defp calculate_predictions_for_decade(profile, decade) do
    # Use the ORIGINAL MoviePredictor logic that actually works
    start_date = Date.new!(decade, 1, 1)
    end_date = Date.new!(decade + 9, 12, 31)
    
    # Build the query with the decade filter
    query = 
      from m in Movies.Movie,
        where: m.release_date >= ^start_date and m.release_date <= ^end_date,
        where: m.import_status == "full",
        limit: 2000
    
    # Use the REAL scoring service that was working before
    scored_query = Metrics.ScoringService.apply_scoring(query, profile)
    movies_with_scores = Repo.all(scored_query)
    
    # Convert to the cache format, keeping the ACTUAL scores from the database
    Enum.reduce(movies_with_scores, %{}, fn movie, acc ->
      # The score is in the discovery_score field from the query
      score = Map.get(movie, :discovery_score, 0.0)
      
      Map.put(acc, movie.id, %{
        title: movie.title,
        score: score,  # This is already in the correct 0-100 range
        release_date: movie.release_date,
        canonical_sources: movie.canonical_sources
      })
    end)
  end
  
  defp calculate_movie_score_with_metrics(movie, profile, metrics) do
    # This implements the scoring logic from the complex query
    # but in application code rather than SQL
    
    weights = profile.category_weights
    
    score = 0.0
    
    # Critical acclaim (metacritic + rotten tomatoes)
    score = 
      if metrics.metacritic || metrics.rotten_tomatoes do
        critical_score = 
          ((metrics.metacritic || 0) / 100.0 * 0.5) +
          ((metrics.rotten_tomatoes || 0) / 100.0 * 0.5)
        score + (weights["critical_acclaim"] || 0.2) * critical_score
      else
        score
      end
    
    # Audience reception (IMDb rating)
    score = 
      if metrics.imdb_rating do
        score + (weights["audience_reception"] || 0.2) * (metrics.imdb_rating / 10.0)
      else
        score
      end
    
    # Festival recognition
    score = 
      if metrics.festival_wins && metrics.festival_wins > 0 do
        festival_score = min(metrics.festival_wins / 5.0, 1.0)
        score + (weights["festival_recognition"] || 0.15) * festival_score
      else
        score
      end
    
    # Cast quality
    score = 
      if metrics.cast_quality_score do
        score + (weights["cast_quality"] || 0.15) * (metrics.cast_quality_score / 100.0)
      else
        score
      end
    
    # Director quality
    score = 
      if metrics.director_quality_score do
        score + (weights["director_quality"] || 0.15) * (metrics.director_quality_score / 100.0)
      else
        score
      end
    
    # Cultural impact (canonical sources)
    score = 
      if movie.canonical_sources && map_size(movie.canonical_sources) > 0 do
        cultural_score = min(map_size(movie.canonical_sources) / 3.0, 1.0)
        score + (weights["cultural_impact"] || 0.15) * cultural_score
      else
        score
      end
    
    score
  end
  
  defp get_movie_metrics(movie_id) do
    # Simplified query to get metrics for a movie
    # Using direct table queries to avoid complex joins
    
    # Get external metrics
    external_metrics = Repo.all(
      from em in "external_metrics",
        where: em.movie_id == ^movie_id,
        select: {em.source, em.metric_type, em.value}
    )
    
    metacritic = Enum.find_value(external_metrics, fn 
      {"metacritic", _, value} -> value
      _ -> nil
    end)
    
    rotten_tomatoes = Enum.find_value(external_metrics, fn 
      {"rotten_tomatoes", _, value} -> value
      _ -> nil
    end)
    
    imdb_rating = Enum.find_value(external_metrics, fn 
      {"imdb", "rating_average", value} -> value
      _ -> nil
    end)
    
    # Get festival wins
    festival_wins = Repo.one(
      from f in "festival_nominations",
        where: f.movie_id == ^movie_id and f.won == true,
        select: count(f.id)
    ) || 0
    
    # Get cast quality score
    cast_quality_score = Repo.one(
      from mc in "movie_credits",
        join: pm in "person_metrics",
          on: pm.person_id == mc.person_id,
        where: mc.movie_id == ^movie_id and 
               mc.credit_type == "cast" and 
               pm.metric_type == "quality_score",
        select: avg(pm.score)
    )
    
    # Get director quality score  
    director_quality_score = Repo.one(
      from mc in "movie_credits",
        join: pm in "person_metrics",
          on: pm.person_id == mc.person_id,
        where: mc.movie_id == ^movie_id and 
               mc.job == "Director" and 
               pm.metric_type == "quality_score",
        select: avg(pm.score)
    )
    
    %{
      metacritic: metacritic,
      rotten_tomatoes: rotten_tomatoes,
      imdb_rating: imdb_rating,
      festival_wins: festival_wins,
      cast_quality_score: cast_quality_score,
      director_quality_score: director_quality_score
    }
  end
  
  defp calculate_statistics(predictions) do
    scores = predictions |> Map.values() |> Enum.map(& &1.score)
    
    %{
      count: length(scores),
      average: calculate_average(scores),
      median: calculate_median(scores),
      min: Enum.min(scores, fn -> 0 end),
      max: Enum.max(scores, fn -> 0 end),
      std_dev: calculate_std_dev(scores)
    }
  end
  
  defp calculate_average([]), do: 0
  defp calculate_average(scores), do: Enum.sum(scores) / length(scores)
  
  defp calculate_median([]), do: 0
  defp calculate_median(scores) do
    sorted = Enum.sort(scores)
    mid = div(length(sorted), 2)
    
    if rem(length(sorted), 2) == 0 do
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    else
      Enum.at(sorted, mid)
    end
  end
  
  defp calculate_std_dev([]), do: 0
  defp calculate_std_dev(scores) do
    avg = calculate_average(scores)
    variance = Enum.sum(Enum.map(scores, fn x -> :math.pow(x - avg, 2) end)) / length(scores)
    :math.sqrt(variance)
  end
  
  defp get_all_profile_ids do
    Repo.all(
      from p in Metrics.MetricWeightProfile,
        where: p.active == true,
        select: p.id
    )
  end
  
  defp update_job_progress(nil, _progress, _message), do: :ok
  defp update_job_progress(_job_id, _progress, _message) do
    # For now, skip job progress updates as they're not critical
    # This would need a more complex implementation with Oban's API
    :ok
  end
  
  defp batch_get_movie_metrics([]) do
    %{}
  end
  
  defp batch_get_movie_metrics(movie_ids) do
    # Batch fetch all metrics for multiple movies at once to avoid N+1 queries
    
    # Get all external metrics in one query
    external_metrics = Repo.all(
      from em in "external_metrics",
        where: em.movie_id in ^movie_ids,
        select: {em.movie_id, em.source, em.metric_type, em.value}
    )
    
    # Get all festival wins in one query
    festival_wins = Repo.all(
      from f in "festival_nominations",
        where: f.movie_id in ^movie_ids and f.won == true,
        group_by: f.movie_id,
        select: {f.movie_id, count(f.id)}
    ) |> Map.new()
    
    # Get all cast quality scores in one query
    cast_scores = Repo.all(
      from mc in "movie_credits",
        join: pm in "person_metrics",
          on: pm.person_id == mc.person_id,
        where: mc.movie_id in ^movie_ids and 
               mc.credit_type == "cast" and 
               pm.metric_type == "quality_score",
        group_by: mc.movie_id,
        select: {mc.movie_id, avg(pm.score)}
    ) |> Map.new()
    
    # Get all director quality scores in one query
    director_scores = Repo.all(
      from mc in "movie_credits",
        join: pm in "person_metrics",
          on: pm.person_id == mc.person_id,
        where: mc.movie_id in ^movie_ids and 
               mc.department == "Directing" and 
               pm.metric_type == "quality_score",
        group_by: mc.movie_id,
        select: {mc.movie_id, avg(pm.score)}
    ) |> Map.new()
    
    # Build metrics map for each movie
    Enum.reduce(movie_ids, %{}, fn movie_id, acc ->
      movie_external_metrics = 
        Enum.filter(external_metrics, fn {id, _, _, _} -> id == movie_id end)
      
      metacritic = Enum.find_value(movie_external_metrics, fn 
        {_, "metacritic", _, value} -> value
        _ -> nil
      end)
      
      rotten_tomatoes = Enum.find_value(movie_external_metrics, fn 
        {_, "rotten_tomatoes", _, value} -> value
        _ -> nil
      end)
      
      imdb_rating = Enum.find_value(movie_external_metrics, fn 
        {_, "imdb", "rating_average", value} -> value
        _ -> nil
      end)
      
      Map.put(acc, movie_id, %{
        metacritic: metacritic,
        rotten_tomatoes: rotten_tomatoes,
        imdb_rating: imdb_rating,
        festival_wins: Map.get(festival_wins, movie_id, 0),
        cast_quality_score: Map.get(cast_scores, movie_id),
        director_quality_score: Map.get(director_scores, movie_id)
      })
    end)
  end
end