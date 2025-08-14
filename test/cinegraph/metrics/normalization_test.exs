defmodule Cinegraph.Metrics.NormalizationTest do
  use ExUnit.Case, async: true
  
  alias Cinegraph.Metrics.Normalization
  
  describe "normalize_popularity/1" do
    test "returns 0 for nil input" do
      assert Normalization.normalize_popularity(nil) == 0.0
    end
    
    test "returns 0 for 0 input" do
      assert_in_delta Normalization.normalize_popularity(0), 0.0, 0.001
    end
    
    test "normalizes using logarithmic scale" do
      # Test some known values
      # LN(1 + 1) / LN(1000 + 1) ≈ 0.1
      assert_in_delta Normalization.normalize_popularity(1), 0.1, 0.01
      
      # LN(10 + 1) / LN(1000 + 1) ≈ 0.346
      assert_in_delta Normalization.normalize_popularity(10), 0.346, 0.01
      
      # LN(100 + 1) / LN(1000 + 1) ≈ 0.663
      assert_in_delta Normalization.normalize_popularity(100), 0.663, 0.01
      
      # LN(1000 + 1) / LN(1000 + 1) = 1.0
      assert_in_delta Normalization.normalize_popularity(1000), 1.0, 0.001
    end
    
    test "values above max still normalize correctly" do
      # Values above 1000 will produce values > 1.0
      result = Normalization.normalize_popularity(5000)
      assert result > 1.0
      assert_in_delta result, 1.222, 0.01
    end
  end
  
  describe "calculate_cultural_impact/2" do
    test "returns 0 when both inputs are nil" do
      assert Normalization.calculate_cultural_impact(nil, nil) == 0.0
    end
    
    test "calculates canonical sources contribution" do
      # 5 canonical sources * 0.1 = 0.5
      result = Normalization.calculate_cultural_impact(5, 0)
      assert_in_delta result, 0.5, 0.001
    end
    
    test "calculates popularity contribution" do
      # No canonical sources, popularity 100
      # LN(100 + 1) / LN(1000 + 1) ≈ 0.663
      result = Normalization.calculate_cultural_impact(0, 100)
      assert_in_delta result, 0.663, 0.01
    end
    
    test "combines both contributions" do
      # 3 canonical sources * 0.1 = 0.3
      # LN(50 + 1) / LN(1000 + 1) ≈ 0.557
      # Total = 0.3 + 0.557 = 0.857
      result = Normalization.calculate_cultural_impact(3, 50)
      assert_in_delta result, 0.857, 0.01
    end
    
    test "caps result at 1.0" do
      # 10 canonical sources * 0.1 = 1.0
      # Plus any popularity would exceed 1.0
      result = Normalization.calculate_cultural_impact(10, 500)
      assert result == 1.0
    end
  end
  
  describe "configuration values" do
    test "canonical_sources_weight returns expected value" do
      assert Normalization.canonical_sources_weight() == 0.1
    end
    
    test "popularity_max_value returns expected value" do
      assert Normalization.popularity_max_value() == 1000.0
    end
  end
  
  describe "SQL fragments" do
    test "popularity_normalization_sql returns correct SQL" do
      sql = Normalization.popularity_normalization_sql()
      assert sql == "LN(COALESCE(?, 0) + 1) / LN(1000.0 + 1)"
    end
    
    test "cultural_impact_sql returns correct SQL" do
      sql = Normalization.cultural_impact_sql()
      assert sql =~ "COALESCE(LEAST(1.0,"
      assert sql =~ "jsonb_each"
      assert sql =~ "0.1"
      assert sql =~ "LN(COALESCE(?, 0) + 1) / LN(1000.0 + 1)"
    end
  end
  
  describe "logarithmic vs linear normalization" do
    test "logarithmic provides better distribution for small values" do
      # Linear normalization would give:
      # 1/1000 = 0.001
      # 10/1000 = 0.01
      # 100/1000 = 0.1
      
      # Logarithmic gives better spread:
      log_1 = Normalization.normalize_popularity(1)
      log_10 = Normalization.normalize_popularity(10)
      log_100 = Normalization.normalize_popularity(100)
      
      # Check that logarithmic gives better differentiation for small values
      assert log_1 > 0.001  # Much better than linear
      assert log_10 > 0.01   # Much better than linear
      assert log_100 > 0.1   # Better than linear
      
      # Verify the progression is more gradual
      ratio_log = log_10 / log_1
      assert ratio_log < 10  # Log scale compresses the ratio
    end
  end
end