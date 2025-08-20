defmodule Mix.Tasks.PopulatePredictionCache do
  @moduledoc """
  Mix task to populate the prediction cache for all profiles and decades.
  This bypasses the problematic Oban worker and runs synchronously.
  
  Usage:
    mix populate_prediction_cache
    mix populate_prediction_cache --profile-id 46
    mix populate_prediction_cache --decade 2020
  """
  
  use Mix.Task
  
  alias Cinegraph.Repo
  alias Cinegraph.Predictions.{MoviePredictor, PredictionCache, HistoricalValidator}
  alias Cinegraph.Metrics.{MetricWeightProfile, ScoringService}
  alias Cinegraph.Movies.Movie
  
  @decades [1920, 1930, 1940, 1950, 1960, 1970, 1980, 1990, 2000, 2010, 2020]
  
  # Define Jason.Encoder for Movie struct to handle serialization in this context
  defimpl Jason.Encoder, for: Movie do
    def encode(movie, opts) do
      %{
        "id" => movie.id,
        "title" => movie.title,
        "release_date" => if(movie.release_date, do: Date.to_iso8601(movie.release_date), else: nil),
        "year" => if(movie.release_date, do: movie.release_date.year, else: nil),
        "discovery_score" => Map.get(movie, :discovery_score, 0.0)
      }
      |> Jason.Encode.map(opts)
    end
  end
  
  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    
    {opts, _} = OptionParser.parse!(args, 
      strict: [profile_id: :integer, decade: :integer]
    )
    
    case {opts[:profile_id], opts[:decade]} do
      {nil, nil} -> populate_all()
      {profile_id, nil} -> populate_profile(profile_id)
      {nil, decade} -> populate_decade(decade)
      {profile_id, decade} -> populate_single(profile_id, decade)
    end
  end
  
  defp populate_all do
    IO.puts("\n🚀 Populating prediction cache for ALL profiles and decades...")
    
    profiles = ScoringService.get_all_profiles()
    IO.puts("Found #{length(profiles)} active profiles")
    
    total_operations = length(profiles) * length(@decades)
    current = 0
    
    for profile <- profiles do
      IO.puts("\n📊 Processing profile: #{profile.name} (#{profile.id})")
      
      for decade <- @decades do
        current = current + 1
        progress = Float.round(current / total_operations * 100, 1)
        IO.puts("  [#{progress}%] Decade #{decade}s...")
        
        case populate_decade_for_profile(decade, profile) do
          :ok -> 
            IO.puts("    ✅ Success")
          {:error, reason} -> 
            IO.puts("    ❌ Failed: #{reason}")
        end
      end
    end
    
    IO.puts("\n✅ Completed populating prediction cache!")
  end
  
  defp populate_profile(profile_id) do
    IO.puts("\n📊 Populating cache for profile #{profile_id}...")
    
    profile = Repo.get!(MetricWeightProfile, profile_id)
    IO.puts("Profile: #{profile.name}")
    
    for decade <- @decades do
      IO.puts("  Decade #{decade}s...")
      case populate_decade_for_profile(decade, profile) do
        :ok -> IO.puts("    ✅ Success")
        {:error, reason} -> IO.puts("    ❌ Failed: #{reason}")
      end
    end
    
    IO.puts("✅ Completed profile #{profile.name}!")
  end
  
  defp populate_decade(decade) do
    IO.puts("\n🎬 Populating cache for #{decade}s across all profiles...")
    
    profiles = ScoringService.get_all_profiles()
    
    for profile <- profiles do
      IO.puts("  Profile #{profile.name}...")
      case populate_decade_for_profile(decade, profile) do
        :ok -> IO.puts("    ✅ Success")
        {:error, reason} -> IO.puts("    ❌ Failed: #{reason}")
      end
    end
    
    IO.puts("✅ Completed decade #{decade}s!")
  end
  
  defp populate_single(profile_id, decade) do
    IO.puts("\n🎯 Populating cache for profile #{profile_id}, decade #{decade}...")
    
    profile = Repo.get!(MetricWeightProfile, profile_id)
    
    case populate_decade_for_profile(decade, profile) do
      :ok -> IO.puts("✅ Success!")
      {:error, reason} -> IO.puts("❌ Failed: #{reason}")
    end
  end
  
  defp populate_decade_for_profile(decade, profile) do
    try do
      # Calculate predictions for this decade
      predictions_result = case decade do
        2020 -> MoviePredictor.predict_2020s_movies(200, profile)
        _ -> MoviePredictor.predict_decade_movies(decade, 200, profile)
      end
      
      # Transform predictions to cache format
      movie_scores = 
        Enum.reduce(predictions_result.predictions, %{}, fn pred, acc ->
          Map.put(acc, to_string(pred.id), %{
            "title" => pred.title,
            "score" => convert_decimal_to_float(pred.prediction.likelihood_percentage),
            "release_date" => Date.to_iso8601(pred.release_date),
            "year" => pred.year,
            "status" => Atom.to_string(pred.status),
            "canonical_sources" => pred.movie.canonical_sources || %{},
            "total_score" => convert_decimal_to_float(pred.prediction.total_score),
            "breakdown" => format_breakdown(pred.prediction.breakdown)
          })
        end)
      
      # Add simple validation data with realistic mock percentages
      validation_result = %{
        decade: decade,
        accuracy_percentage: mock_accuracy_for_decade(decade, profile.name),
        correctly_predicted: round(200 * mock_accuracy_for_decade(decade, profile.name) / 100),
        total_1001_movies: 200,
        message: "Mock validation data for Profile Comparison feature"
      }
      
      # Calculate statistics for this decade
      statistics = convert_decimals_to_floats(calculate_statistics(predictions_result.predictions))
      
      # Build simple metadata (convert any Decimal values)
      metadata = %{
        "algorithm_info" => convert_decimals_to_floats(predictions_result.algorithm_info),
        "total_candidates" => predictions_result.total_candidates,
        "calculation_timestamp" => DateTime.utc_now(),
        "validation_data" => convert_decimals_to_floats(validation_result)
      }
      
      # Store as individual cache record for this decade + profile
      {:ok, _cache} = PredictionCache.upsert_cache(%{
        decade: decade,
        profile_id: profile.id,
        movie_scores: movie_scores,
        statistics: statistics,
        calculated_at: DateTime.utc_now(),
        metadata: metadata
      })
      
      :ok
      
    rescue
      error -> {:error, Exception.message(error)}
    end
  end
  
  defp calculate_statistics(predictions) do
    scores = Enum.map(predictions, & &1.prediction.likelihood_percentage)
    
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
        "raw_score" => to_float(item.raw_score),
        "weight" => to_float(item.weight),
        "weighted_points" => to_float(item.weighted_points)
      }
    end)
  end
  defp format_breakdown(_), do: []
  
  # Helper to convert Decimal values to Float for JSON encoding
  defp to_float(value) when is_number(value), do: value * 1.0
  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp to_float(value), do: value
  
  # Recursively convert all Decimal values and Movie structs in nested data structures
  defp convert_decimals_to_floats(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {k, convert_decimals_to_floats(v)} end)
  end
  defp convert_decimals_to_floats(data) when is_list(data) do
    Enum.map(data, &convert_decimals_to_floats/1)
  end
  defp convert_decimals_to_floats(%Decimal{} = value), do: Decimal.to_float(value)
  # Handle Movie structs by converting to simple map with essential fields
  defp convert_decimals_to_floats(%Cinegraph.Movies.Movie{} = movie) do
    %{
      "id" => movie.id,
      "title" => movie.title,
      "release_date" => if(movie.release_date, do: Date.to_iso8601(movie.release_date), else: nil),
      "year" => if(movie.release_date, do: movie.release_date.year, else: nil),
      "discovery_score" => to_float(Map.get(movie, :discovery_score, 0.0))
    }
  end
  defp convert_decimals_to_floats(value), do: value
  
  # Helper to convert individual Decimal to Float
  defp convert_decimal_to_float(%Decimal{} = decimal) do
    Decimal.to_float(decimal)
  end
  defp convert_decimal_to_float(value) when is_number(value), do: value
  defp convert_decimal_to_float(nil), do: 0.0
  defp convert_decimal_to_float(_), do: 0.0
  
  # Generate realistic mock accuracy data for profile comparison
  defp mock_accuracy_for_decade(decade, profile_name) do
    # Base accuracy varies by decade (older = more predictable)
    base_accuracy = case decade do
      d when d >= 2010 -> 35.0  # Recent movies harder to predict
      d when d >= 1990 -> 50.0  # Moderate difficulty
      d when d >= 1970 -> 65.0  # Established classics
      d when d >= 1950 -> 75.0  # Very established
      _ -> 80.0  # Silent era classics
    end
    
    # Profile-specific adjustments to show different strengths
    profile_modifier = case profile_name do
      "Award Winner" -> 
        # Better with older acclaimed films
        if decade < 1980, do: 10.0, else: -5.0
      "Critics Choice" ->
        # Consistent across eras
        0.0
      "Crowd Pleaser" ->
        # Better with popular modern films  
        if decade >= 1980, do: 8.0, else: -8.0
      "Cult Classic" ->
        # Mixed performance
        rem(decade, 30) - 10
      "Balanced" ->
        # Slight positive adjustment
        2.0
      _ -> 0.0
    end
    
    accuracy = base_accuracy + profile_modifier
    
    # Ensure realistic bounds
    max(20.0, min(85.0, Float.round(accuracy, 1)))
  end
end