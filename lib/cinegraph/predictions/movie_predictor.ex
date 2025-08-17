defmodule Cinegraph.Predictions.MoviePredictor do
  @moduledoc """
  Predicts which 2020s movies are most likely to be added to future 1001 Movies lists.
  Uses database-driven weight profiles from metric_weight_profiles table.
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Metrics.ScoringService
  alias Cinegraph.Metrics.MetricWeightProfile

  @doc """
  Get top 2020s movies ranked by likelihood of being added to future 1001 Movies lists.
  Uses database weight profiles or custom weights.
  """
  def predict_2020s_movies(limit \\ 100, profile_or_weights \\ nil) do
    # Get the weight profile to use
    profile = get_weight_profile(profile_or_weights)
    
    # Build base query for 2020s movies not on 1001 list
    base_query = 
      from m in Movie,
        where: m.release_date >= ^~D[2020-01-01],
        where: m.release_date < ^~D[2030-01-01],
        where: m.import_status == "full",
        where: is_nil(fragment("? -> ?", m.canonical_sources, "1001_movies")),
        limit: 500  # Get more candidates for better selection
    
    # Apply database-driven scoring
    scored_query = ScoringService.apply_scoring(base_query, profile)
    
    # Execute query and format results
    movies_with_scores = Repo.all(scored_query)
    
    scored_movies = 
      movies_with_scores
      |> Enum.map(&format_prediction_result_from_scored/1)
      |> Enum.take(limit)
    
    weights = ScoringService.profile_to_discovery_weights(profile)
    scored_movies =
      scored_movies
      |> Enum.map(&put_in(&1, [:prediction, :weights_used], weights))

    %{
      predictions: scored_movies,
      total_candidates: length(movies_with_scores),
      algorithm_info: %{
        profile_used: profile.name,
        weights_used: weights,
        criteria_count: 5,
        decade: "2020s"
      }
    }
  end

  @doc """
  Calculate prediction score for a specific movie using database profiles.
  """
  def calculate_movie_prediction(movie, profile_or_weights \\ nil) do
    profile = get_weight_profile(profile_or_weights)
    weights = ScoringService.profile_to_discovery_weights(profile)
    
    # Build single movie query
    query = from m in Movie, where: m.id == ^movie.id
    
    # Apply scoring
    scored_query = ScoringService.apply_scoring(query, profile, %{})
    
    # Get scored result
    case Repo.one(scored_query) do
      nil -> format_prediction_result_from_movie(movie, 0.0) |> put_in([:prediction, :weights_used], weights)
      scored_movie -> format_prediction_result_from_scored(scored_movie) |> put_in([:prediction, :weights_used], weights)
    end
  end

  @doc """
  Get detailed scoring breakdown for a specific movie.
  """
  def get_movie_scoring_details(movie_id, profile_or_weights \\ nil) do
    movie = Repo.get!(Movie, movie_id)
    prediction = calculate_movie_prediction(movie, profile_or_weights)
    
    %{
      movie: movie,
      prediction: prediction.prediction,
      status: determine_movie_status(movie),
      similar_patterns: find_similar_historical_patterns(prediction.prediction),
      estimated_timeline: estimate_addition_timeline(prediction.prediction)
    }
  end

  @doc """
  Get 2020s movies that are already on the 1001 Movies list for validation.
  """
  def get_confirmed_2020s_additions(profile_or_weights \\ nil) do
    profile = get_weight_profile(profile_or_weights)
    
    query =
      from m in Movie,
        where: fragment("EXTRACT(YEAR FROM ?) >= 2020", m.release_date),
        where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
        order_by: [desc: m.release_date],
        limit: 100
    
    # Apply scoring to see how well we predict actual additions
    scored_query = ScoringService.apply_scoring(query, profile)
    
    Repo.all(scored_query)
    |> Enum.map(&format_prediction_result_from_scored/1)
  end

  @doc """
  Get movies that our algorithm predicts with high confidence.
  """
  def get_high_confidence_predictions(min_score \\ 0.8, profile_or_weights \\ nil) do
    profile = get_weight_profile(profile_or_weights)
    normalized_min =
      cond do
        is_integer(min_score) and min_score > 1 -> min_score / 100.0
        is_float(min_score) and min_score > 1.0 -> min_score / 100.0
        true -> min_score * 1.0
      end
    
    # Build query with minimum score filter
    query = 
      from m in Movie,
        where: m.release_date >= ^~D[2020-01-01],
        where: m.release_date < ^~D[2030-01-01],
        where: m.import_status == "full",
        where: is_nil(fragment("? -> ?", m.canonical_sources, "1001_movies"))
    
    # Apply scoring with min score filter
    scored_query = ScoringService.apply_scoring(query, profile, %{min_score: normalized_min})
    
    Repo.all(scored_query)
    |> Enum.map(&format_prediction_result_from_scored/1)
  end

  # Private functions

  defp get_weight_profile(nil), do: ScoringService.get_default_profile()
  
  defp get_weight_profile(%MetricWeightProfile{} = profile), do: profile
  
  defp get_weight_profile(profile_name) when is_binary(profile_name) do
    ScoringService.get_profile(profile_name) || ScoringService.get_default_profile()
  end
  
  defp get_weight_profile(weights) when is_map(weights) do
    # Convert discovery-style weights to a profile
    # This allows backward compatibility with the UI
    %MetricWeightProfile{
      name: "Custom",
      description: "Custom weights from UI",
      category_weights: convert_ui_weights_to_categories(weights),
      active: true
    }
  end

  defp convert_ui_weights_to_categories(weights) do
    # Coerce non-numeric values to 0.0 and delegate to ScoringService for consistent mapping
    sanitized = %{
      popular_opinion: to_float(Map.get(weights, :popular_opinion, 0.0)),
      critical_acclaim: to_float(Map.get(weights, :critical_acclaim, 0.0)),
      industry_recognition:
        to_float(Map.get(weights, :industry_recognition, Map.get(weights, :festival_recognition, 0.0))),
      cultural_impact: to_float(Map.get(weights, :cultural_impact, 0.0)),
      people_quality:
        to_float(Map.get(weights, :people_quality, Map.get(weights, :auteur_recognition, 0.0)))
    }
    ScoringService.discovery_weights_to_profile(sanitized).category_weights
  end

  defp to_float(value) when is_number(value), do: value * 1.0
  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float_val, _} -> float_val
      :error -> 0.0
    end
  end
  defp to_float(_), do: 0.0

  defp format_prediction_result_from_scored(movie) do
    # Convert discovery_score (0-1) to likelihood percentage (0-100)
    discovery_score = to_float(movie.discovery_score)
    likelihood = convert_score_to_likelihood(discovery_score)
    
    %{
      id: movie.id,
      title: movie.title,
      release_date: movie.release_date,
      year: extract_year(movie.release_date),
      prediction: %{
        total_score: Float.round(discovery_score * 100, 1),
        likelihood_percentage: Float.round(likelihood, 1),
        criteria_scores: Map.get(movie, :score_components, %{}),
        weights_used: nil,  # Will be set by caller if needed
        breakdown: format_score_breakdown(movie)
      },
      status: determine_movie_status(movie),
      movie: movie
    }
  end

  defp format_prediction_result_from_movie(movie, score) do
    likelihood = convert_score_to_likelihood(score)
    
    %{
      id: movie.id,
      title: movie.title,
      release_date: movie.release_date,
      year: extract_year(movie.release_date),
      prediction: %{
        total_score: Float.round(score * 100, 1),
        likelihood_percentage: Float.round(likelihood, 1),
        criteria_scores: %{},
        weights_used: nil,
        breakdown: []
      },
      status: determine_movie_status(movie),
      movie: movie
    }
  end

  defp format_score_breakdown(movie) do
    components = Map.get(movie, :score_components, %{})
    
    [
      %{
        criterion: :popular_opinion,
        raw_score: Float.round(to_float(components[:popular_opinion]) * 100, 1),
        weight: 0.2,
        weighted_points: Float.round(to_float(components[:popular_opinion]) * 20, 1)
      },
      %{
        criterion: :critical_acclaim,
        raw_score: Float.round(to_float(components[:critical_acclaim]) * 100, 1),
        weight: 0.2,
        weighted_points: Float.round(to_float(components[:critical_acclaim]) * 20, 1)
      },
      %{
        criterion: :industry_recognition,
        raw_score: Float.round(to_float(components[:industry_recognition]) * 100, 1),
        weight: 0.2,
        weighted_points: Float.round(to_float(components[:industry_recognition]) * 20, 1)
      },
      %{
        criterion: :cultural_impact,
        raw_score: Float.round(to_float(components[:cultural_impact]) * 100, 1),
        weight: 0.2,
        weighted_points: Float.round(to_float(components[:cultural_impact]) * 20, 1)
      },
      %{
        criterion: :people_quality,
        raw_score: Float.round(to_float(components[:people_quality]) * 100, 1),
        weight: 0.2,
        weighted_points: Float.round(to_float(components[:people_quality]) * 20, 1)
      }
    ]
  end

  defp convert_score_to_likelihood(score) when is_nil(score), do: 0.0
  defp convert_score_to_likelihood(score) do
    # Convert 0-1 score to 0-100 likelihood with a sigmoid-like curve
    # This gives more realistic percentages
    normalized = score * 100
    
    cond do
      normalized >= 90 -> 95 + (normalized - 90) * 0.5
      normalized >= 80 -> 85 + (normalized - 80) * 1.0
      normalized >= 70 -> 70 + (normalized - 70) * 1.5
      normalized >= 60 -> 55 + (normalized - 60) * 1.5
      normalized >= 50 -> 40 + (normalized - 50) * 1.5
      normalized >= 40 -> 30 + (normalized - 40) * 1.0
      normalized >= 30 -> 20 + (normalized - 30) * 1.0
      true -> normalized * 0.67
    end
  end

  defp determine_movie_status(movie) do
    if movie.canonical_sources && Map.has_key?(movie.canonical_sources, "1001_movies") do
      :already_added
    else
      :future_prediction
    end
  end

  defp extract_year(release_date) when is_nil(release_date), do: nil
  defp extract_year(release_date) do
    case Date.from_iso8601(to_string(release_date)) do
      {:ok, date} -> date.year
      _ -> 
        if is_struct(release_date, Date) do
          release_date.year
        else
          nil
        end
    end
  end

  defp find_similar_historical_patterns(prediction) do
    # Find movies with similar scores that made it onto the 1001 list
    # This would be enhanced with actual pattern matching
    score = prediction[:total_score] || 0.0
    
    [
      %{
        title: "Parasite",
        year: 2019,
        added_year: 2021,
        years_later: 2,
        similar_score: score
      },
      %{
        title: "Moonlight", 
        year: 2016,
        added_year: 2018,
        years_later: 2,
        similar_score: score
      }
    ]
  end

  defp estimate_addition_timeline(prediction) do
    likelihood = prediction[:likelihood_percentage] || 0.0
    
    cond do
      likelihood >= 95 -> "2025-2026 editions"
      likelihood >= 85 -> "2025-2027 editions"  
      likelihood >= 75 -> "2026-2028 editions"
      likelihood >= 65 -> "2027-2030 editions"
      likelihood >= 55 -> "2028-2032 editions"
      likelihood >= 45 -> "Future editions (likely)"
      true -> "Future editions (uncertain)"
    end
  end
end