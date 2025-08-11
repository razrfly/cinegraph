#!/usr/bin/env elixir
# Test script for the database reorganization (issue #208)

Mix.start()
Mix.shell(Mix.Shell.Process)

# Start the application
{:ok, _} = Application.ensure_all_started(:cinegraph)

import Ecto.Query
alias Cinegraph.{Repo, Movies, Metrics}
alias Cinegraph.Movies.{Movie, ExternalMetric, MovieRecommendation}
alias Cinegraph.Services.TMDb
require Logger

defmodule ReorganizationTest do
  def run do
    Logger.info("Starting database reorganization test...")
    
    # Clean up any test data from previous runs
    cleanup_test_data()
    
    # Test 1: Create a movie with TMDb data
    Logger.info("\n=== Test 1: Creating movie from TMDb ===")
    test_tmdb_import()
    
    # Test 2: Store metrics separately
    Logger.info("\n=== Test 2: Storing metrics ===")
    test_metrics_storage()
    
    # Test 3: Store OMDb metrics
    Logger.info("\n=== Test 3: Storing OMDb metrics ===")
    test_omdb_metrics()
    
    # Test 4: Store recommendations
    Logger.info("\n=== Test 4: Storing recommendations ===")
    test_recommendations()
    
    # Test 5: Test backward-compatible view
    Logger.info("\n=== Test 5: Testing backward-compatible view ===")
    test_backward_compatible_view()
    
    # Test 6: Test metric retrieval
    Logger.info("\n=== Test 6: Testing metric retrieval ===")
    test_metric_retrieval()
    
    Logger.info("\n=== All tests completed successfully! ===")
  rescue
    e ->
      Logger.error("Test failed: #{inspect(e)}")
      Logger.error(Exception.format_stacktrace(__STACKTRACE__))
  end
  
  defp cleanup_test_data do
    # Clean up test movie if it exists
    test_tmdb_id = 550  # Fight Club
    
    if movie = Movies.get_movie_by_tmdb_id(test_tmdb_id) do
      # Delete metrics
      Repo.delete_all(from m in ExternalMetric, where: m.movie_id == ^movie.id)
      
      # Delete recommendations
      Repo.delete_all(from r in MovieRecommendation, 
        where: r.source_movie_id == ^movie.id or r.recommended_movie_id == ^movie.id)
      
      # Delete the movie
      {:ok, _} = Movies.delete_movie(movie)
      Logger.info("Cleaned up existing test data")
    end
  end
  
  defp test_tmdb_import do
    # Use Fight Club as test movie
    tmdb_id = 550
    
    # Simulate TMDb data
    tmdb_data = %{
      "id" => tmdb_id,
      "title" => "Fight Club",
      "original_title" => "Fight Club",
      "overview" => "A ticking-time-bomb insomniac and a slippery soap salesman...",
      "release_date" => "1999-10-15",
      "runtime" => 139,
      "status" => "Released",
      "tagline" => "Mischief. Mayhem. Soap.",
      "imdb_id" => "tt0137523",
      "tmdb_data" => %{"test" => true},
      "vote_average" => 8.4,
      "vote_count" => 25000,
      "popularity" => 60.5,
      "budget" => 63000000,
      "revenue" => 100853753
    }
    
    # Create movie (without volatile fields)
    {:ok, movie} = Movies.create_or_update_movie_from_tmdb(tmdb_data)
    
    # Verify core fields are stored
    assert movie.title == "Fight Club"
    assert movie.tmdb_id == tmdb_id
    assert movie.imdb_id == "tt0137523"
    assert movie.runtime == 139
    
    # Verify volatile fields are NOT in the movie table
    refute Map.has_key?(movie, :vote_average)
    refute Map.has_key?(movie, :vote_count)
    refute Map.has_key?(movie, :popularity)
    refute Map.has_key?(movie, :budget)
    refute Map.has_key?(movie, :revenue)
    
    Logger.info("✓ Movie created successfully without volatile fields")
  end
  
  defp test_metrics_storage do
    movie = Movies.get_movie_by_tmdb_id(550)
    
    tmdb_data = %{
      "vote_average" => 8.4,
      "vote_count" => 25000,
      "popularity" => 60.5,
      "budget" => 63000000,
      "revenue" => 100853753
    }
    
    # Store metrics using the new Metrics module
    :ok = Metrics.store_tmdb_metrics(movie, tmdb_data)
    
    # Verify metrics were stored
    metrics = Metrics.get_movie_metrics(movie.id)
    
    assert length(metrics) > 0
    
    # Check specific metrics
    rating_metric = Enum.find(metrics, &(&1.metric_type == "rating_average"))
    assert rating_metric != nil
    assert rating_metric.value == 8.4
    assert rating_metric.source == "tmdb"
    
    budget_metric = Enum.find(metrics, &(&1.metric_type == "budget"))
    assert budget_metric != nil
    assert budget_metric.value == 63000000
    
    Logger.info("✓ TMDb metrics stored successfully")
  end
  
  defp test_omdb_metrics do
    movie = Movies.get_movie_by_tmdb_id(550)
    
    omdb_data = %{
      "imdbRating" => "8.8",
      "imdbVotes" => "1,900,000",
      "Metascore" => "66",
      "BoxOffice" => "$37,030,102",
      "Awards" => "Won 1 Oscar. 10 wins & 37 nominations total",
      "Ratings" => [
        %{"Source" => "Rotten Tomatoes", "Value" => "79%"}
      ]
    }
    
    # Store OMDb metrics
    :ok = Metrics.store_omdb_metrics(movie, omdb_data)
    
    # Verify OMDb metrics
    omdb_metrics = Metrics.get_movie_metrics(movie.id, source: "omdb")
    imdb_metrics = Metrics.get_movie_metrics(movie.id, source: "imdb")
    
    assert length(omdb_metrics) > 0
    assert length(imdb_metrics) > 0
    
    # Check IMDb rating
    imdb_rating = Enum.find(imdb_metrics, &(&1.metric_type == "rating_average"))
    assert imdb_rating != nil
    assert imdb_rating.value == 8.8
    
    # Check awards
    awards_metric = Enum.find(omdb_metrics, &(&1.metric_type == "awards_summary"))
    assert awards_metric != nil
    assert awards_metric.text_value =~ "Oscar"
    
    Logger.info("✓ OMDb metrics stored successfully")
  end
  
  defp test_recommendations do
    source_movie = Movies.get_movie_by_tmdb_id(550)
    
    # Create a recommended movie first
    rec_tmdb_data = %{
      "id" => 551,
      "title" => "The Machinist",
      "original_title" => "The Machinist",
      "overview" => "Trevor Reznik is a machinist...",
      "release_date" => "2004-01-18",
      "runtime" => 101,
      "status" => "Released",
      "imdb_id" => "tt0361862",
      "tmdb_data" => %{"test" => true}
    }
    
    {:ok, rec_movie} = Movies.create_or_update_movie_from_tmdb(rec_tmdb_data)
    
    # Store recommendation
    recommendations_data = [
      %{
        "id" => 551,
        "vote_average" => 7.5,
        "popularity" => 30.2,
        "vote_count" => 2000,
        "release_date" => "2004-01-18"
      }
    ]
    
    :ok = Metrics.store_tmdb_recommendations(source_movie, recommendations_data, "similar")
    
    # Verify recommendation was stored
    recs = Repo.all(from r in MovieRecommendation, 
      where: r.source_movie_id == ^source_movie.id)
    
    assert length(recs) == 1
    rec = hd(recs)
    assert rec.recommended_movie_id == rec_movie.id
    assert rec.type == "similar"
    assert rec.rank == 1
    
    Logger.info("✓ Recommendations stored successfully")
  end
  
  defp test_backward_compatible_view do
    # Query the backward-compatible view
    result = Repo.query!("""
      SELECT title, vote_average, vote_count, popularity, budget, revenue
      FROM movies_with_metrics
      WHERE tmdb_id = 550
    """)
    
    assert result.num_rows == 1
    [row] = result.rows
    [title, vote_avg, vote_count, popularity, budget, revenue] = row
    
    assert title == "Fight Club"
    assert vote_avg == 8.4
    assert vote_count == 25000
    assert popularity == 60.5
    assert budget == 63000000
    assert revenue == 100853753
    
    Logger.info("✓ Backward-compatible view working correctly")
  end
  
  defp test_metric_retrieval do
    movie = Movies.get_movie_by_tmdb_id(550)
    
    # Test get_metric_value
    rating = Metrics.get_metric_value(movie.id, "tmdb", "rating_average")
    assert rating == 8.4
    
    # Test get_movie_aggregates (backward compatibility)
    aggregates = Metrics.get_movie_aggregates(movie.id)
    
    assert aggregates.vote_average == 8.4
    assert aggregates.vote_count == 25000
    assert aggregates.popularity == 60.5
    assert aggregates.budget == 63000000
    assert aggregates.revenue == 100853753
    assert aggregates.awards_text =~ "Oscar"
    
    Logger.info("✓ Metric retrieval functions working correctly")
  end
  
  defp assert(true), do: :ok
  defp assert(false), do: raise "Assertion failed"
  defp assert(condition), do: if(condition, do: :ok, else: raise("Assertion failed"))
  
  defp refute(false), do: :ok
  defp refute(true), do: raise "Refutation failed"
  defp refute(condition), do: if(!condition, do: :ok, else: raise("Refutation failed"))
end

# Run the tests
ReorganizationTest.run()