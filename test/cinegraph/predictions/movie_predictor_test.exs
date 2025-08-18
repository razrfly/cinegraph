defmodule Cinegraph.Predictions.MoviePredictorTest do
  use Cinegraph.DataCase

  alias Cinegraph.Predictions.{MoviePredictor, CriteriaScoring}
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  describe "predict_2020s_movies/2" do
    test "returns predictions with valid structure" do
      result = MoviePredictor.predict_2020s_movies(10)

      assert %{
               predictions: predictions,
               total_candidates: total_candidates,
               algorithm_info: algorithm_info
             } = result

      assert is_list(predictions)
      assert is_integer(total_candidates)
      assert total_candidates >= 0

      # Check algorithm info structure
      assert %{
               weights_used: weights,
               criteria_count: 5,
               decade: "2020s"
             } = algorithm_info

      assert is_map(weights)
      assert map_size(weights) == 5
    end

    test "predictions are properly sorted by likelihood descending" do
      result = MoviePredictor.predict_2020s_movies(20)
      predictions = result.predictions

      # Skip if no predictions
      if length(predictions) > 1 do
        likelihood_percentages =
          predictions
          |> Enum.map(& &1.prediction.likelihood_percentage)

        sorted_percentages = Enum.sort(likelihood_percentages, :desc)
        assert likelihood_percentages == sorted_percentages
      end
    end

    test "respects limit parameter" do
      small_result = MoviePredictor.predict_2020s_movies(5)
      large_result = MoviePredictor.predict_2020s_movies(50)

      assert length(small_result.predictions) <= 5
      assert length(large_result.predictions) <= 50
    end

    test "handles custom weights correctly" do
      custom_weights = %{
        popular_opinion: 0.30,
        critical_acclaim: 0.30,
        industry_recognition: 0.20,
        cultural_impact: 0.10,
        people_quality: 0.10
      }

      result = MoviePredictor.predict_2020s_movies(10, custom_weights)

      assert result.algorithm_info.weights_used == custom_weights
    end

    test "predictions have valid likelihood percentages" do
      result = MoviePredictor.predict_2020s_movies(10)

      for prediction <- result.predictions do
        likelihood = prediction.prediction.likelihood_percentage
        assert is_number(likelihood)
        assert likelihood >= 0.0
        assert likelihood <= 100.0
      end
    end

    test "handles edge case with zero movies" do
      # This tests the chunked processing doesn't break with empty results
      result = MoviePredictor.predict_2020s_movies(0)

      assert result.predictions == []
      assert result.total_candidates >= 0
    end
  end

  describe "calculate_movie_prediction/2" do
    test "returns valid prediction structure for a movie" do
      # Get a movie from the database if available
      movie = Repo.all(Movie) |> List.first()

      if movie do
        prediction = MoviePredictor.calculate_movie_prediction(movie)

        assert %{
                 id: id,
                 title: title,
                 prediction: pred,
                 status: status
               } = prediction

        assert id == movie.id
        assert title == movie.title
        assert status in [:already_added, :future_prediction]

        # Check prediction structure
        assert %{
                 total_score: total_score,
                 likelihood_percentage: likelihood,
                 criteria_scores: criteria_scores,
                 weights_used: weights,
                 breakdown: breakdown
               } = pred

        assert is_number(total_score)
        assert is_number(likelihood)
        assert is_map(criteria_scores)
        assert is_map(weights)
        assert is_list(breakdown)
      end
    end
  end

  describe "get_confirmed_2020s_additions/0" do
    test "returns movies that are on 1001 list" do
      confirmed = MoviePredictor.get_confirmed_2020s_additions()

      assert is_list(confirmed)

      # All confirmed movies should have :already_added status
      for movie <- confirmed do
        assert movie.status == :already_added
      end
    end
  end

  describe "get_high_confidence_predictions/1" do
    test "filters predictions by minimum likelihood" do
      high_confidence = MoviePredictor.get_high_confidence_predictions(90)
      medium_confidence = MoviePredictor.get_high_confidence_predictions(70)

      # All high confidence movies should have likelihood >= 90
      for movie <- high_confidence do
        assert movie.prediction.likelihood_percentage >= 90
        assert movie.status == :future_prediction
      end

      # Medium confidence should have more results
      assert length(medium_confidence) >= length(high_confidence)
    end
  end

  describe "error handling" do
    test "handles invalid weights gracefully" do
      invalid_weights = %{
        critical_acclaim: "invalid",
        festival_recognition: 0.30,
        cultural_impact: 0.20,
        technical_innovation: 0.10,
        auteur_recognition: 0.05
      }

      # Should not crash, may return empty results or use defaults
      result = MoviePredictor.predict_2020s_movies(10, invalid_weights)
      assert is_map(result)
    end

    test "handles extremely large limits" do
      # Should not crash with very large limits
      result = MoviePredictor.predict_2020s_movies(10_000)
      assert is_map(result)
      assert is_list(result.predictions)
    end
  end

  describe "performance" do
    test "chunked processing completes in reasonable time" do
      start_time = :os.system_time(:millisecond)

      _result = MoviePredictor.predict_2020s_movies(100)

      end_time = :os.system_time(:millisecond)
      processing_time = end_time - start_time

      # Should complete within 10 seconds (vs. the 30+ seconds before fix)
      assert processing_time < 10_000,
             "Processing took #{processing_time}ms, should be under 10 seconds"
    end
  end
end
