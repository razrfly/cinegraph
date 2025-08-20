defmodule Cinegraph.Workers.ComprehensivePredictionsCalculator do
  @moduledoc """
  Oban worker that calculates and caches ALL predictions page data:
  - 2020s predictions
  - Historical validation for all decades
  - Profile comparison data
  
  This replicates all the expensive calculations the predictions page does,
  but runs them in the background via Oban.
  """
  
  use Oban.Worker, queue: :predictions, max_attempts: 3
  
  require Logger
  
  alias Cinegraph.Repo
  alias Cinegraph.Predictions.{MoviePredictor, PredictionCache, HistoricalValidator}
  alias Cinegraph.Metrics.{MetricWeightProfile, ScoringService}
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id}}) do
    Logger.info("Starting comprehensive predictions calculation for profile #{profile_id}")
    
    profile = Repo.get!(MetricWeightProfile, profile_id)
    
    # Step 1: Calculate 2020s predictions
    Logger.info("Calculating 2020s predictions...")
    predictions_result = MoviePredictor.predict_2020s_movies(1000, profile)
    
    # Transform predictions to cache format
    movie_scores = 
      Enum.reduce(predictions_result.predictions, %{}, fn pred, acc ->
        Map.put(acc, to_string(pred.id), %{
          "title" => pred.title,
          "score" => convert_to_float(pred.prediction.likelihood_percentage), # Convert in case it's Decimal
          "release_date" => Date.to_iso8601(pred.release_date),
          "year" => pred.year,
          "status" => Atom.to_string(pred.status),
          "canonical_sources" => deep_convert_decimals(pred.movie.canonical_sources || %{}),
          "total_score" => convert_to_float(pred.prediction.total_score),
          "breakdown" => format_breakdown(pred.prediction.breakdown)
        })
      end)
    
    # Step 2: Calculate historical validation for ALL decades
    Logger.info("Calculating historical validation for all decades...")
    validation_result = try do
      result = HistoricalValidator.validate_all_decades(profile)
      # Convert any Decimals in the validation result
      if result, do: deep_convert_decimals(result), else: nil
    rescue
      error ->
        Logger.error("Failed to calculate validation: #{inspect(error)}")
        nil
    end
    
    # Step 3: Calculate profile comparison
    Logger.info("Calculating profile comparison...")
    profile_comparison = try do
      # Convert to plain maps to avoid JSON encoding issues
      result = HistoricalValidator.get_comprehensive_comparison()
      
      # Convert profiles to simple maps to avoid JSON encoding issues with structs
      if result do
        %{
          profiles: Enum.map(result.profiles, fn data ->
            # Convert the MetricWeightProfile struct to a plain map
            profile_map = if is_struct(data.profile, MetricWeightProfile) do
              %{
                id: data.profile.id,
                name: data.profile.name,
                description: data.profile.description
              }
            else
              data.profile
            end
            
            %{
              profile_name: profile_map.name,
              profile_id: profile_map.id,
              profile_description: profile_map[:description],
              overall_accuracy: convert_to_float(data.overall_accuracy),
              decade_accuracies: convert_decade_accuracies(data.decade_accuracies),
              strengths: data.strengths
            }
          end),
          # Convert best_overall accuracy if it's a Decimal
          best_overall: convert_best_overall(result.best_overall),
          # Convert tuples in best_per_decade to lists
          best_per_decade: convert_tuples_to_lists(result.best_per_decade),
          # Also convert tuples in insights
          insights: convert_insights_tuples(result.insights)
        }
      end
    rescue
      error ->
        Logger.error("Failed to calculate profile comparison: #{inspect(error)}")
        nil
    end
    
    # Calculate statistics
    statistics = calculate_statistics(predictions_result.predictions)
    
    # Build comprehensive metadata
    metadata = %{
      "algorithm_info" => deep_convert_decimals(predictions_result.algorithm_info),
      "total_candidates" => predictions_result.total_candidates,
      "calculation_timestamp" => DateTime.utc_now(),
      "validation_data" => validation_result,
      "profile_comparison" => profile_comparison
    }
    
    # Store everything in database cache with all Decimals converted
    {:ok, _cache} = PredictionCache.upsert_cache(%{
      decade: 2020,
      profile_id: profile_id,
      movie_scores: deep_convert_decimals(movie_scores),
      statistics: deep_convert_decimals(statistics),
      calculated_at: DateTime.utc_now(),
      metadata: deep_convert_decimals(metadata)
    })
    
    Logger.info("Successfully cached comprehensive predictions data")
    
    # Also cache in Cachex for fast access
    cache_validation_result(profile, validation_result)
    cache_profile_comparison(profile_comparison)
    
    :ok
  end
  
  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(300) # 5 minutes for comprehensive calculation
  
  # Helper to queue calculation for all profiles
  def queue_all_profiles do
    profiles = ScoringService.get_all_profiles()
    
    Enum.each(profiles, fn profile ->
      %{profile_id: profile.id}
      |> new()
      |> Oban.insert()
    end)
    
    Logger.info("Queued comprehensive predictions calculation for #{length(profiles)} profiles")
  end
  
  # Queue calculation for the default profile
  def queue_default_profile do
    profile = ScoringService.get_default_profile()
    
    %{profile_id: profile.id}
    |> new()
    |> Oban.insert()
    
    Logger.info("Queued comprehensive predictions calculation for default profile")
  end
  
  # Private helpers
  
  defp cache_validation_result(profile, validation_result) when not is_nil(validation_result) do
    validation_cache_key = "validation:#{profile.name}:#{profile_hash(profile)}"
    Cachex.put(:predictions_cache, validation_cache_key, validation_result, ttl: :timer.hours(24))
    Logger.info("Cached validation data in memory for profile #{profile.name}")
  end
  defp cache_validation_result(_, _), do: :ok
  
  defp cache_profile_comparison(profile_comparison) when not is_nil(profile_comparison) do
    cache_key = "profile_comparison:#{Date.utc_today()}"
    Cachex.put(:predictions_cache, cache_key, profile_comparison, ttl: :timer.hours(24))
    Logger.info("Cached profile comparison data in memory")
  end
  defp cache_profile_comparison(_), do: :ok
  
  defp profile_hash(profile) do
    profile.category_weights
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:md5, &1))
    |> Base.encode16(case: :lower)
  end
  
  defp calculate_statistics(predictions) do
    scores = Enum.map(predictions, fn pred ->
      score = pred.prediction.likelihood_percentage
      if is_struct(score, Decimal), do: Decimal.to_float(score), else: score
    end)
    
    %{
      "total_predictions" => length(predictions),
      "average_score" => calculate_average(scores),
      "median_score" => calculate_median(scores),
      "high_confidence_count" => Enum.count(scores, & &1 >= 80),
      "medium_confidence_count" => Enum.count(scores, & &1 >= 50 and &1 < 80),
      "low_confidence_count" => Enum.count(scores, & &1 < 50),
      "already_added_count" => Enum.count(predictions, & &1.status == :already_added),
      "future_prediction_count" => Enum.count(predictions, & &1.status == :future_prediction)
    }
  end
  
  defp calculate_average([]), do: 0
  defp calculate_average(scores) do
    Float.round(Enum.sum(scores) / length(scores), 2)
  end
  
  defp calculate_median([]), do: 0
  defp calculate_median(scores) do
    sorted = Enum.sort(scores)
    mid = div(length(sorted), 2)
    
    if rem(length(sorted), 2) == 0 do
      Float.round((Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2, 2)
    else
      Float.round(Enum.at(sorted, mid), 2)
    end
  end
  
  defp format_breakdown(breakdown) when is_list(breakdown) do
    Enum.map(breakdown, fn item ->
      %{
        "criterion" => Atom.to_string(item.criterion),
        "raw_score" => convert_to_float(item.raw_score),
        "weight" => convert_to_float(item.weight),
        "weighted_points" => convert_to_float(item.weighted_points)
      }
    end)
  end
  defp format_breakdown(_), do: []
  
  # Convert tuples to lists for JSON encoding
  defp convert_tuples_to_lists(map) when is_map(map) do
    Enum.map(map, fn 
      {k, {name, %Decimal{} = value}} -> {k, [name, Decimal.to_float(value)]}
      {k, {name, value}} -> {k, [name, value]}
      {k, %{"accuracy" => %Decimal{} = acc} = v} -> 
        {k, Map.put(v, "accuracy", Decimal.to_float(acc))}
      {k, %{accuracy: %Decimal{} = acc} = v} -> 
        {k, Map.put(v, :accuracy, Decimal.to_float(acc))}
      {k, v} -> {k, v}
    end)
    |> Map.new()
  end
  defp convert_tuples_to_lists(other), do: other
  
  # Convert tuples in insights to JSON-encodable format
  defp convert_insights_tuples(insights) when is_map(insights) do
    Enum.map(insights, fn
      {:highest_variance, {name, value}} -> {:highest_variance, [name, value]}
      {:most_consistent, {name, value}} -> {:most_consistent, [name, value]}
      {k, v} when is_map(v) -> {k, convert_tuples_to_lists(v)}
      {k, v} -> {k, v}
    end)
    |> Map.new()
  end
  defp convert_insights_tuples(other), do: other
  
  # Convert Decimal to float for JSON encoding
  defp convert_to_float(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp convert_to_float(value) when is_float(value), do: value
  defp convert_to_float(value) when is_integer(value), do: value / 1.0
  defp convert_to_float(_), do: 0.0
  
  # Convert best_overall map with possible Decimal values
  defp convert_best_overall(nil), do: nil
  defp convert_best_overall(best) when is_map(best) do
    Map.new(best, fn
      {"accuracy", %Decimal{} = value} -> {"accuracy", Decimal.to_float(value)}
      {:accuracy, %Decimal{} = value} -> {:accuracy, Decimal.to_float(value)}
      {k, v} -> {k, v}
    end)
  end
  defp convert_best_overall(other), do: other
  
  # Convert decade accuracies map with Decimal values
  defp convert_decade_accuracies(nil), do: %{}
  defp convert_decade_accuracies(accuracies) when is_map(accuracies) do
    Map.new(accuracies, fn 
      {decade, %Decimal{} = value} -> {decade, Decimal.to_float(value)}
      {decade, value} when is_float(value) -> {decade, value}
      {decade, value} when is_integer(value) -> {decade, value / 1.0}
      {decade, _} -> {decade, 0.0}
    end)
  end
  defp convert_decade_accuracies(_), do: %{}
  
  # Deep convert all Decimals in any nested structure
  defp deep_convert_decimals(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp deep_convert_decimals(%DateTime{} = dt), do: dt
  defp deep_convert_decimals(%Date{} = date), do: date
  defp deep_convert_decimals(%Time{} = time), do: time
  defp deep_convert_decimals(%NaiveDateTime{} = ndt), do: ndt
  defp deep_convert_decimals(map) when is_map(map) and not is_struct(map) do
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
end