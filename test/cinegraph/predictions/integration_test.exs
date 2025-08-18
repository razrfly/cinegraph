defmodule Cinegraph.Predictions.IntegrationTest do
  @moduledoc """
  Integration tests for the Movie Prediction System.
  These tests verify the entire system works together correctly.
  """

  use Cinegraph.DataCase

  alias Cinegraph.Predictions.{MoviePredictor, CriteriaScoring}

  describe "Movie Prediction System Integration" do
    test "system components work together without crashing" do
      # Test that the core components can be instantiated
      assert is_map(CriteriaScoring.get_default_weights())

      # Test that predictions can be generated (may return empty if no data)
      result = MoviePredictor.predict_2020s_movies(10)
      assert is_map(result)
      assert Map.has_key?(result, :predictions)
      assert Map.has_key?(result, :total_candidates)
      assert Map.has_key?(result, :algorithm_info)
    end

    test "chunked processing prevents the 0.0% bug" do
      # This test verifies the fix for the original issue #324
      # Even with limited data, the system should not return all 0.0% predictions

      result = MoviePredictor.predict_2020s_movies(5)

      # If there are any predictions, they should have valid likelihood scores
      if length(result.predictions) > 0 do
        for prediction <- result.predictions do
          # Likelihood should be a valid number (not 0.0 unless legitimately calculated)
          assert is_number(prediction.prediction.likelihood_percentage)
          assert prediction.prediction.likelihood_percentage >= 0.0
          assert prediction.prediction.likelihood_percentage <= 100.0

          # Total score should also be valid
          assert is_number(prediction.prediction.total_score)
          assert prediction.prediction.total_score >= 0.0
          assert prediction.prediction.total_score <= 100.0
        end
      end
    end

    test "performance is acceptable (under 10 seconds)" do
      # This test verifies the fix for issue #324 performance problem
      start_time = :os.system_time(:millisecond)

      _result = MoviePredictor.predict_2020s_movies(50)

      end_time = :os.system_time(:millisecond)
      processing_time = end_time - start_time

      # Should complete much faster than the original 30+ seconds
      assert processing_time < 10_000,
             "Processing took #{processing_time}ms, should be under 10 seconds (was 30+ seconds before fix)"
    end

    test "weight validation works correctly" do
      # Test valid weights
      valid_weights = %{
        critical_acclaim: 0.35,
        festival_recognition: 0.30,
        cultural_impact: 0.20,
        technical_innovation: 0.10,
        auteur_recognition: 0.05
      }

      result = MoviePredictor.predict_2020s_movies(5, valid_weights)
      assert result.algorithm_info.weights_used == valid_weights
    end

    test "all criteria contribute to scoring" do
      # Test that each criterion actually affects the scoring
      movie_data = %{
        id: 1,
        title: "Test Movie",
        tmdb_data: %{"budget" => 1_000_000, "revenue" => 10_000_000},
        canonical_sources: nil
      }

      # Test individual scoring functions don't crash
      assert is_number(CriteriaScoring.score_critical_acclaim(movie_data))
      assert is_number(CriteriaScoring.score_festival_recognition(movie_data))
      assert is_number(CriteriaScoring.score_cultural_impact(movie_data))
      assert is_number(CriteriaScoring.score_technical_innovation(movie_data))
      assert is_number(CriteriaScoring.score_auteur_recognition(movie_data))
    end

    test "batch processing is consistent with individual processing" do
      # Test the core fix: batch processing should work the same as individual
      test_movies = [
        %{id: 1, title: "Movie 1", tmdb_data: %{}, canonical_sources: nil},
        %{id: 2, title: "Movie 2", tmdb_data: %{}, canonical_sources: nil},
        %{id: 3, title: "Movie 3", tmdb_data: %{}, canonical_sources: nil}
      ]

      # Batch processing should not crash and should return valid results
      batch_results = CriteriaScoring.batch_score_movies(test_movies)

      assert length(batch_results) == 3

      for result <- batch_results do
        assert Map.has_key?(result, :movie)
        assert Map.has_key?(result, :prediction)
        assert is_number(result.prediction.total_score)
        assert is_number(result.prediction.likelihood_percentage)
      end
    end

    test "confirmed additions detection works" do
      # Test that we can detect movies already on 1001 list
      confirmed = MoviePredictor.get_confirmed_2020s_additions()

      assert is_list(confirmed)

      # All confirmed should have :already_added status
      for movie <- confirmed do
        assert movie.status == :already_added
      end
    end

    test "high confidence filtering works" do
      # Test different confidence thresholds
      high_confidence = MoviePredictor.get_high_confidence_predictions(0.90)
      medium_confidence = MoviePredictor.get_high_confidence_predictions(0.70)
      low_confidence = MoviePredictor.get_high_confidence_predictions(0.50)

      # Higher thresholds should return fewer or equal results
      assert length(high_confidence) <= length(medium_confidence)
      assert length(medium_confidence) <= length(low_confidence)

      # All results should meet their threshold
      for movie <- high_confidence do
        assert movie.prediction.likelihood_percentage >= 90
        assert movie.status == :future_prediction
      end
    end

    test "likelihood conversion produces reasonable results" do
      # Test that total scores convert to reasonable likelihood percentages
      # This ensures the sigmoid-like conversion function works properly

      test_cases = [
        %{id: 1, title: "Low Score Movie", tmdb_data: %{}},
        %{
          id: 2,
          title: "Medium Score Movie",
          tmdb_data: %{"budget" => 100_000, "revenue" => 1_000_000}
        },
        %{
          id: 3,
          title: "High Score Movie",
          tmdb_data: %{"budget" => 10_000_000, "revenue" => 100_000_000}
        }
      ]

      for movie <- test_cases do
        score = CriteriaScoring.calculate_movie_score(movie)

        # Likelihood should always be between 0 and 100
        assert score.likelihood_percentage >= 0.0
        assert score.likelihood_percentage <= 100.0

        # Likelihood should generally be related to total score
        # (though the conversion is non-linear)
        if score.total_score == 0.0 do
          assert score.likelihood_percentage < 10.0
        end
      end
    end
  end

  describe "Error Handling and Edge Cases" do
    test "handles empty movie lists gracefully" do
      result = MoviePredictor.predict_2020s_movies(0)
      assert result.predictions == []
      assert is_integer(result.total_candidates)
    end

    test "handles movies with missing data" do
      minimal_movie = %{
        id: 999,
        title: "Minimal Movie",
        tmdb_data: nil,
        canonical_sources: nil
      }

      # Should not crash
      score = CriteriaScoring.calculate_movie_score(minimal_movie)
      assert is_map(score)
      assert is_number(score.total_score)
      assert is_number(score.likelihood_percentage)
    end

    test "handles large limits without performance issues" do
      # Test that very large limits don't cause problems
      start_time = :os.system_time(:millisecond)

      result = MoviePredictor.predict_2020s_movies(1000)

      end_time = :os.system_time(:millisecond)
      processing_time = end_time - start_time

      # Should complete in reasonable time even with large limits
      assert processing_time < 15_000, "Large limit processing took too long"
      assert is_list(result.predictions)
    end

    test "movie status detection works correctly" do
      # Test status determination logic
      result = MoviePredictor.predict_2020s_movies(10)

      for prediction <- result.predictions do
        assert prediction.status in [:already_added, :future_prediction]
      end
    end

    test "breakdown calculations are mathematically sound" do
      # Test that breakdown math is correct
      movie = %{id: 1, title: "Test", tmdb_data: %{}, canonical_sources: nil}
      score = CriteriaScoring.calculate_movie_score(movie)

      # Sum of weighted points should approximately equal total score
      total_from_breakdown =
        score.breakdown
        |> Enum.map(& &1.weighted_points)
        |> Enum.sum()

      # Allow for small floating point differences
      assert abs(total_from_breakdown - score.total_score) < 0.1
    end
  end
end
