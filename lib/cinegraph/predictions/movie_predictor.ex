defmodule Cinegraph.Predictions.MoviePredictor do
  @moduledoc """
  Predicts which 2020s movies are most likely to be added to future 1001 Movies lists.
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Predictions.CriteriaScoring

  @doc """
  Get top 100 2020s movies ranked by likelihood of being added to future 1001 Movies lists.
  """
  def predict_2020s_movies(limit \\ 100, weights \\ nil) do
    # Get all 2020s movies not already on the list
    movies_2020s = get_2020s_movies()
    
    # Process movies in smaller chunks for better performance
    scored_movies = 
      movies_2020s
      |> Enum.chunk_every(25)  # Smaller chunks for faster processing
      |> Enum.flat_map(fn chunk ->
        chunk
        |> CriteriaScoring.batch_score_movies(weights)
        |> Enum.map(&format_prediction_result/1)
      end)
      # No need to filter - all percentages should be valid now
      |> Enum.sort_by(& &1.prediction.likelihood_percentage, :desc)
      |> Enum.take(limit)
    
    %{
      predictions: scored_movies,
      total_candidates: length(movies_2020s),
      algorithm_info: %{
        weights_used: weights || CriteriaScoring.get_default_weights(),
        criteria_count: 5,
        decade: "2020s"
      }
    }
  end

  @doc """
  Calculate prediction score for a specific movie.
  """
  def calculate_movie_prediction(movie, weights \\ nil) do
    add_prediction_score(movie, weights)
  end

  @doc """
  Get detailed scoring breakdown for a specific movie.
  """
  def get_movie_scoring_details(movie_id, weights \\ nil) do
    movie = Repo.get!(Movie, movie_id)
    prediction = CriteriaScoring.calculate_movie_score(movie, weights)
    
    %{
      movie: movie,
      prediction: prediction,
      status: determine_movie_status(movie),
      similar_patterns: find_similar_historical_patterns(prediction),
      estimated_timeline: estimate_addition_timeline(prediction)
    }
  end

  @doc """
  Get 2020s movies that are already on the 1001 Movies list for validation.
  """
  def get_confirmed_2020s_additions do
    query =
      from m in Movie,
        where: fragment("EXTRACT(YEAR FROM ?) >= 2020", m.release_date),
        where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
        order_by: [desc: m.release_date],
        preload: [:external_metrics]

    Repo.all(query)
    |> Enum.map(&add_prediction_score/1)
    |> Enum.sort_by(& &1.prediction.likelihood_percentage, :desc)
  end

  @doc """
  Get movies that our algorithm would have predicted but aren't on the list yet.
  """
  def get_high_confidence_predictions(min_likelihood \\ 80) do
    predict_2020s_movies(200)
    |> Map.get(:predictions)
    |> Enum.filter(fn movie ->
      movie.prediction.likelihood_percentage >= min_likelihood and
      movie.status == :future_prediction
    end)
  end

  # Private functions

  defp get_2020s_movies do
    # More efficient query with proper date filtering
    query =
      from m in Movie,
        where: m.release_date >= ^~D[2020-01-01],
        where: m.release_date < ^~D[2030-01-01],
        where: m.import_status == "full",
        where: is_nil(fragment("? -> ?", m.canonical_sources, "1001_movies")),
        order_by: [desc: m.release_date],
        limit: 300

    Repo.all(query)
  end

  defp add_prediction_score(movie, weights \\ nil) do
    prediction = CriteriaScoring.calculate_movie_score(movie, weights)
    format_prediction_result(%{movie: movie, prediction: prediction})
  end

  defp format_prediction_result(%{movie: movie, prediction: prediction}) do
    %{
      id: movie.id,
      title: movie.title,
      release_date: movie.release_date,
      year: extract_year(movie.release_date),
      prediction: prediction,
      status: determine_movie_status(movie),
      movie: movie
    }
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
        # Try to extract year from release_date if it's already a Date
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
    [
      %{
        title: "Eternal Sunshine of the Spotless Mind",
        year: 2004,
        added_year: 2008,
        years_later: 4,
        similar_score: prediction.total_score
      },
      %{
        title: "There Will Be Blood", 
        year: 2007,
        added_year: 2011,
        years_later: 4,
        similar_score: prediction.total_score
      }
    ]
  end

  defp estimate_addition_timeline(prediction) do
    likelihood = prediction.likelihood_percentage
    
    cond do
      likelihood >= 95 -> "2025-2026 editions"
      likelihood >= 85 -> "2025-2027 editions"  
      likelihood >= 75 -> "2026-2028 editions"
      likelihood >= 65 -> "2027-2030 editions"
      true -> "Future editions (uncertain)"
    end
  end
end