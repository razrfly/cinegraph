defmodule Cinegraph.Movies.DecadeAnalyzerTest do
  use Cinegraph.DataCase
  alias Cinegraph.Movies.DecadeAnalyzer

  describe "get_decade_distribution/0" do
    test "returns decade distribution data with correct structure" do
      distribution = DecadeAnalyzer.get_decade_distribution()
      
      assert is_list(distribution)
      assert length(distribution) > 0
      
      # Check the first decade has the right structure
      first_decade = hd(distribution)
      assert Map.has_key?(first_decade, :decade)
      assert Map.has_key?(first_decade, :count)
      assert Map.has_key?(first_decade, :percentage)
      assert Map.has_key?(first_decade, :average_per_year)
      
      assert is_integer(first_decade.decade)
      assert is_integer(first_decade.count)
      assert is_float(first_decade.percentage)
      assert is_float(first_decade.average_per_year)
    end
  end

  describe "get_decade_stats/1" do
    test "returns detailed stats for a specific decade" do
      stats = DecadeAnalyzer.get_decade_stats(1980)
      
      assert stats.decade == 1980
      assert Map.has_key?(stats, :total_count)
      assert Map.has_key?(stats, :movies)
      assert Map.has_key?(stats, :year_distribution)
      assert Map.has_key?(stats, :average_per_year)
      assert Map.has_key?(stats, :peak_year)
      assert Map.has_key?(stats, :historical_context)
      
      assert is_list(stats.movies)
      assert is_map(stats.year_distribution)
      assert is_float(stats.average_per_year)
      assert stats.historical_context == "Blockbuster era and independent film rise"
    end
  end

  describe "predict_future_additions/2" do
    test "generates reasonable predictions" do
      predictions = DecadeAnalyzer.predict_future_additions(2025, 2027)
      
      assert length(predictions) == 3
      
      Enum.each(predictions, fn prediction ->
        assert Map.has_key?(prediction, :year)
        assert Map.has_key?(prediction, :predicted_count)
        assert Map.has_key?(prediction, :confidence_range)
        assert Map.has_key?(prediction, :factors)
        
        assert prediction.year >= 2025 and prediction.year <= 2027
        assert is_integer(prediction.predicted_count)
        assert is_tuple(prediction.confidence_range)
        assert is_map(prediction.factors)
        
        # Predictions should be reasonable (1-20 films per year)
        assert prediction.predicted_count >= 1 and prediction.predicted_count <= 20
      end)
    end
  end

  describe "get_available_editions/0" do
    test "returns available editions list" do
      editions = DecadeAnalyzer.get_available_editions()
      
      assert is_list(editions)
      # Should have at least one edition
      assert length(editions) > 0
      
      # All editions should be strings/years
      Enum.each(editions, fn edition ->
        assert is_binary(edition)
      end)
    end
  end

  describe "get_recent_year_trends/1" do
    test "returns year-by-year data for recent years" do
      trends = DecadeAnalyzer.get_recent_year_trends(2015)
      
      assert is_list(trends)
      assert length(trends) > 0
      
      # Check structure
      first_trend = hd(trends)
      assert Map.has_key?(first_trend, :year)
      assert Map.has_key?(first_trend, :count)
      assert is_integer(first_trend.year)
      assert is_integer(first_trend.count)
    end
  end
end