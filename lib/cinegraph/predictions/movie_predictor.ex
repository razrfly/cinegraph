defmodule Cinegraph.Predictions.MoviePredictor do
  @moduledoc """
  Predicts which 2020s movies are most likely to be added to future 1001 Movies lists.
  Uses database-driven weight profiles from metric_weight_profiles table.
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Predictions.LensScoring
  alias Cinegraph.Metrics.{MetricWeightProfile, ScoringService}

  @default_source_key "1001_movies"

  @doc """
  Get top 2020s movies ranked by likelihood of being added to future 1001 Movies lists.
  Uses database weight profiles or custom weights.
  Combines predictions with confirmed additions in proper ranking order.
  """
  def predict_2020s_movies(
        limit \\ 100,
        profile_or_weights \\ nil,
        source_key \\ @default_source_key
      ) do
    predict_decade_movies(2020, limit, profile_or_weights, source_key)
  end

  @doc """
  Get top movies from ANY decade ranked by likelihood of being added to the target list.
  This is the generic version that works for all decades and any `source_key`.
  """
  def predict_decade_movies(
        decade,
        limit \\ 100,
        profile_or_weights \\ nil,
        source_key \\ @default_source_key
      ) do
    weights = get_criteria_weights(profile_or_weights)

    # Calculate date range for the decade
    start_date = Date.new!(decade, 1, 1)
    end_date = Date.new!(decade + 9, 12, 31)

    # Get the most engagement-signaled movies from the decade.
    # order_by ensures notable films are fetched first; limit keeps worker time bounded.
    # (HistoricalValidator runs unbounded for backtest accuracy — this function is UI-only.)
    # #913 / #923: Movie schema marks tmdb_data as load_in_query: false to
    # keep multi-MB JSONB out of every default SELECT. The Target-mode box_office
    # lens reads movie.tmdb_data for budget / revenue, so opt back in here.
    # (Long-term: migrate those reads to external_metrics so this can come out.)
    all_movies_query =
      from m in Movie,
        where: m.release_date >= ^start_date,
        where: m.release_date <= ^end_date,
        where: m.import_status == "full",
        order_by: [desc: fragment("COALESCE((? ->> 'vote_count')::numeric, 0)", m.tmdb_data)],
        limit: 5000,
        select_merge: %{tmdb_data: m.tmdb_data}

    all_decade_movies = Repo.all(all_movies_query, timeout: :timer.seconds(120))
    scored = LensScoring.batch_score_movies(all_decade_movies, weights, source_key)

    # Format and sort all movies by score
    all_scored_movies =
      scored
      |> Enum.sort_by(& &1.prediction.total_score, :desc)
      |> Enum.take(limit)
      |> Enum.map(&format_prediction_result(&1, source_key))

    # Count candidates (movies not already on the target list)
    total_candidates =
      Enum.count(scored, fn %{movie: movie} ->
        is_nil(Map.get(movie.canonical_sources || %{}, source_key))
      end)

    %{
      predictions: all_scored_movies,
      total_candidates: total_candidates,
      algorithm_info: %{
        profile_used: "LensScoring",
        weights_used: weights,
        criteria_count: length(LensScoring.scoring_criteria()),
        decade: "#{decade}s"
      }
    }
  end

  @doc """
  Calculate prediction score for a specific movie using database profiles.
  """
  def calculate_movie_prediction(
        movie,
        profile_or_weights \\ nil,
        source_key \\ @default_source_key
      ) do
    weights = get_criteria_weights(profile_or_weights)
    prediction = LensScoring.calculate_movie_score(movie, weights, source_key)
    format_prediction_result(%{movie: movie, prediction: prediction}, source_key)
  end

  @doc """
  Get detailed scoring breakdown for a specific movie.
  """
  def get_movie_scoring_details(
        movie_id,
        profile_or_weights \\ nil,
        source_key \\ @default_source_key
      ) do
    # #923: Movie schema marks tmdb_data load_in_query: false. The box_office lens
    # reads movie.tmdb_data for budget/revenue in Target mode, so the single-row
    # fetch here must opt back in. Without this, ROI score is silently 0.
    movie =
      from(m in Movie,
        where: m.id == ^movie_id,
        select_merge: %{tmdb_data: m.tmdb_data}
      )
      |> Repo.one!()

    prediction = calculate_movie_prediction(movie, profile_or_weights, source_key)

    %{
      movie: movie,
      prediction: prediction.prediction,
      status: determine_movie_status(movie, source_key),
      similar_patterns: find_similar_historical_patterns(prediction.prediction),
      estimated_timeline: estimate_addition_timeline(prediction.prediction)
    }
  end

  @doc """
  Get 2020s movies that are already on the 1001 Movies list for validation.
  """
  def get_confirmed_2020s_additions(profile_or_weights \\ nil, source_key \\ @default_source_key) do
    weights = get_criteria_weights(profile_or_weights)

    # #923: opt back in to tmdb_data — the box_office lens needs it for budget/revenue.
    query =
      from m in Movie,
        where: fragment("EXTRACT(YEAR FROM ?) >= 2020", m.release_date),
        where: fragment("? \\? ?", m.canonical_sources, ^source_key),
        order_by: [desc: m.release_date],
        limit: 100,
        select_merge: %{tmdb_data: m.tmdb_data}

    Repo.all(query, timeout: :timer.seconds(120))
    |> LensScoring.batch_score_movies(weights, source_key)
    |> Enum.map(&format_prediction_result(&1, source_key))
  end

  @doc """
  Get movies that our algorithm predicts with high confidence.
  """
  def get_high_confidence_predictions(
        min_score \\ 0.8,
        profile_or_weights \\ nil,
        source_key \\ @default_source_key
      ) do
    weights = get_criteria_weights(profile_or_weights)

    # Normalize min_score to 0-100 scale (Target-mode scores are 0-100)
    min_score_100 =
      if is_float(min_score) and min_score <= 1.0,
        do: min_score * 100.0,
        else: min_score * 1.0

    # #923: opt back in to tmdb_data for the box_office budget/revenue read.
    query =
      from m in Movie,
        where: m.release_date >= ^~D[2020-01-01],
        where: m.release_date < ^~D[2030-01-01],
        where: m.import_status == "full",
        where: is_nil(fragment("? -> ?", m.canonical_sources, ^source_key)),
        select_merge: %{tmdb_data: m.tmdb_data}

    Repo.all(query, timeout: :timer.seconds(120))
    |> LensScoring.batch_score_movies(weights, source_key)
    |> Enum.filter(&(&1.prediction.total_score >= min_score_100))
    |> Enum.map(&format_prediction_result(&1, source_key))
  end

  # Private functions

  defp get_criteria_weights(nil), do: LensScoring.get_default_weights()

  # A DB weight profile (passed by the prediction workers and admin) — convert its
  # category_weights into the six-lens atom map so the selected profile actually
  # drives prediction scoring.
  defp get_criteria_weights(%MetricWeightProfile{} = profile),
    do: ScoringService.profile_to_discovery_weights(profile)

  defp get_criteria_weights(name) when is_binary(name),
    do: LensScoring.get_profile_weights(name)

  defp get_criteria_weights(weights) when is_map(weights) do
    if Map.has_key?(weights, :festival_recognition),
      do: weights,
      else: LensScoring.get_default_weights()
  end

  defp get_criteria_weights(_), do: LensScoring.get_default_weights()

  defp format_prediction_result(%{movie: movie, prediction: prediction}, source_key) do
    %{
      id: movie.id,
      title: movie.title,
      release_date: movie.release_date,
      year: extract_year(movie.release_date),
      prediction: prediction,
      status: determine_movie_status(movie, source_key),
      movie: movie
    }
  end

  defp determine_movie_status(movie, source_key) do
    if movie.canonical_sources && Map.has_key?(movie.canonical_sources, source_key) do
      :already_added
    else
      :future_prediction
    end
  end

  defp extract_year(release_date) when is_nil(release_date), do: nil

  defp extract_year(release_date) do
    case Date.from_iso8601(to_string(release_date)) do
      {:ok, date} ->
        date.year

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
