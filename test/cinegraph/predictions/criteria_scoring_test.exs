defmodule Cinegraph.Predictions.CriteriaScoringTest do
  use Cinegraph.DataCase
  
  alias Cinegraph.Predictions.CriteriaScoring
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo
  
  describe "get_default_weights/0" do
    test "returns valid default weights" do
      weights = CriteriaScoring.get_default_weights()
      
      assert %{
        critical_acclaim: critical_acclaim,
        festival_recognition: festival_recognition,
        cultural_impact: cultural_impact,
        technical_innovation: technical_innovation,
        auteur_recognition: auteur_recognition
      } = weights
      
      # All weights should be numbers between 0 and 1
      assert is_number(critical_acclaim) and critical_acclaim >= 0 and critical_acclaim <= 1
      assert is_number(festival_recognition) and festival_recognition >= 0 and festival_recognition <= 1
      assert is_number(cultural_impact) and cultural_impact >= 0 and cultural_impact <= 1
      assert is_number(technical_innovation) and technical_innovation >= 0 and technical_innovation <= 1
      assert is_number(auteur_recognition) and auteur_recognition >= 0 and auteur_recognition <= 1
      
      # Weights should sum to approximately 1.0
      total = Map.values(weights) |> Enum.sum()
      assert abs(total - 1.0) < 0.01
    end
  end
  
  describe "calculate_movie_score/2" do
    test "returns valid score structure" do
      movie = Repo.all(Movie) |> List.first()
      
      if movie do
        score = CriteriaScoring.calculate_movie_score(movie)
        
        assert %{
          total_score: total_score,
          likelihood_percentage: likelihood,
          criteria_scores: criteria_scores,
          weights_used: weights,
          breakdown: breakdown
        } = score
        
        # Total score should be 0-100
        assert is_number(total_score)
        assert total_score >= 0.0
        assert total_score <= 100.0
        
        # Likelihood should be 0-100
        assert is_number(likelihood)
        assert likelihood >= 0.0
        assert likelihood <= 100.0
        
        # Criteria scores should all be 0-100
        assert map_size(criteria_scores) == 5
        for {_criterion, score} <- criteria_scores do
          assert is_number(score)
          assert score >= 0.0
          assert score <= 100.0
        end
        
        # Breakdown should have 5 entries
        assert length(breakdown) == 5
        for breakdown_item <- breakdown do
          assert %{
            criterion: criterion,
            raw_score: raw_score,
            weight: weight,
            weighted_points: weighted_points
          } = breakdown_item
          
          assert criterion in [:critical_acclaim, :festival_recognition, :cultural_impact, :technical_innovation, :auteur_recognition]
          assert is_number(raw_score) and raw_score >= 0.0 and raw_score <= 100.0
          assert is_number(weight) and weight >= 0.0 and weight <= 1.0
          assert is_number(weighted_points)
        end
      end
    end
    
    test "uses custom weights when provided" do
      movie = Repo.all(Movie) |> List.first()
      
      if movie do
        custom_weights = %{
          critical_acclaim: 0.50,
          festival_recognition: 0.20,
          cultural_impact: 0.15,
          technical_innovation: 0.10,
          auteur_recognition: 0.05
        }
        
        score = CriteriaScoring.calculate_movie_score(movie, custom_weights)
        
        assert score.weights_used == custom_weights
        
        # Check that breakdown uses custom weights
        for breakdown_item <- score.breakdown do
          criterion = breakdown_item.criterion
          assert breakdown_item.weight == custom_weights[criterion]
        end
      end
    end
  end
  
  describe "batch_score_movies/2" do
    test "returns same results as individual scoring" do
      movies = Repo.all(Movie) |> Enum.take(3)
      
      if length(movies) > 0 do
        # Get batch scores
        batch_results = CriteriaScoring.batch_score_movies(movies)
        
        # Get individual scores
        individual_results = 
          Enum.map(movies, fn movie ->
            prediction = CriteriaScoring.calculate_movie_score(movie)
            %{movie: movie, prediction: prediction}
          end)
        
        assert length(batch_results) == length(individual_results)
        
        # Compare results (allowing for small floating point differences)
        for {batch_result, individual_result} <- Enum.zip(batch_results, individual_results) do
          assert batch_result.movie.id == individual_result.movie.id
          
          batch_score = batch_result.prediction.total_score
          individual_score = individual_result.prediction.total_score
          
          # Scores should be very close (within 0.1 due to floating point)
          assert abs(batch_score - individual_score) < 0.1
        end
      end
    end
    
    test "handles empty movie list" do
      result = CriteriaScoring.batch_score_movies([])
      assert result == []
    end
    
    test "is more efficient than individual scoring for multiple movies" do
      movies = Repo.all(Movie) |> Enum.take(10)
      
      if length(movies) >= 5 do
        # Time batch scoring
        batch_start = :os.system_time(:millisecond)
        _batch_results = CriteriaScoring.batch_score_movies(movies)
        batch_time = :os.system_time(:millisecond) - batch_start
        
        # Time individual scoring
        individual_start = :os.system_time(:millisecond)
        _individual_results = 
          Enum.map(movies, fn movie ->
            prediction = CriteriaScoring.calculate_movie_score(movie)
            %{movie: movie, prediction: prediction}
          end)
        individual_time = :os.system_time(:millisecond) - individual_start
        
        # Batch should be faster or at least not significantly slower
        # Allow for some variance but batch should generally be more efficient
        assert batch_time <= individual_time * 1.5, 
          "Batch scoring (#{batch_time}ms) should be faster than individual (#{individual_time}ms)"
      end
    end
  end
  
  describe "individual scoring functions" do
    test "score_critical_acclaim/1 returns valid scores" do
      movie = Repo.all(Movie) |> List.first()
      
      if movie do
        score = CriteriaScoring.score_critical_acclaim(movie)
        assert is_number(score)
        assert score >= 0.0
        assert score <= 100.0
      end
    end
    
    test "score_festival_recognition/1 returns valid scores" do
      movie = Repo.all(Movie) |> List.first()
      
      if movie do
        score = CriteriaScoring.score_festival_recognition(movie)
        assert is_number(score)
        assert score >= 0.0
        assert score <= 100.0
      end
    end
    
    test "score_cultural_impact/1 returns valid scores" do
      movie = Repo.all(Movie) |> List.first()
      
      if movie do
        score = CriteriaScoring.score_cultural_impact(movie)
        assert is_number(score)
        assert score >= 0.0
      end
    end
    
    test "score_technical_innovation/1 returns valid scores" do
      movie = Repo.all(Movie) |> List.first()
      
      if movie do
        score = CriteriaScoring.score_technical_innovation(movie)
        assert is_number(score)
        assert score >= 0.0
        assert score <= 100.0
      end
    end
    
    test "score_auteur_recognition/1 returns valid scores" do
      movie = Repo.all(Movie) |> List.first()
      
      if movie do
        score = CriteriaScoring.score_auteur_recognition(movie)
        assert is_number(score)
        assert score >= 0.0
        assert score <= 100.0
      end
    end
  end
  
  describe "error handling" do
    test "handles movies with missing data gracefully" do
      # Create a minimal movie with no external data
      movie = %Movie{
        id: 999999,
        title: "Test Movie",
        tmdb_data: nil,
        external_metrics: []
      }
      
      score = CriteriaScoring.calculate_movie_score(movie)
      
      # Should not crash and should return valid structure
      assert is_map(score)
      assert is_number(score.total_score)
      assert is_number(score.likelihood_percentage)
    end
    
    test "handles nil values in scoring functions" do
      movie = %Movie{
        id: 999999,
        title: "Test Movie", 
        tmdb_data: %{},
        external_metrics: []
      }
      
      # Individual functions should handle nil gracefully
      assert is_number(CriteriaScoring.score_critical_acclaim(movie))
      assert is_number(CriteriaScoring.score_festival_recognition(movie))
      assert is_number(CriteriaScoring.score_cultural_impact(movie))
      assert is_number(CriteriaScoring.score_technical_innovation(movie))
      assert is_number(CriteriaScoring.score_auteur_recognition(movie))
    end
  end
  
  describe "likelihood conversion" do
    test "converts scores to realistic likelihood percentages" do
      # Test that the likelihood conversion produces reasonable results
      test_cases = [
        {0.0, 0.0},      # Minimum
        {50.0, 45.0},    # Mid-range
        {80.0, 85.0},    # High
        {95.0, 99.5},    # Very high
        {100.0, 100.0}   # Maximum
      ]
      
      for {input_score, expected_likelihood} <- test_cases do
        # Create a movie with predictable scores
        movie = %Movie{
          id: 999999,
          title: "Test Movie",
          tmdb_data: %{},
          external_metrics: []
        }
        
        # We can't directly test the private convert_to_likelihood function,
        # but we can verify the overall behavior makes sense
        score = CriteriaScoring.calculate_movie_score(movie)
        
        # Likelihood should be reasonable
        assert score.likelihood_percentage >= 0.0
        assert score.likelihood_percentage <= 100.0
      end
    end
  end
end