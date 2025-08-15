defmodule Cinegraph.Metrics.NormalizationHelperTest do
  use ExUnit.Case, async: true
  alias Cinegraph.Metrics.NormalizationHelper

  describe "logarithmic_normalize/2" do
    test "returns 0 for zero input" do
      assert NormalizationHelper.logarithmic_normalize(0, 1000) == 0.0
    end

    test "returns 0 for negative input" do
      assert NormalizationHelper.logarithmic_normalize(-10, 1000) == 0.0
    end

    test "returns 1.0 for input equal to threshold" do
      result = NormalizationHelper.logarithmic_normalize(1000, 1000)
      assert_in_delta(result, 1.0, 0.001)
    end

    test "returns value between 0 and 1 for input less than threshold" do
      result = NormalizationHelper.logarithmic_normalize(100, 1000)
      assert result > 0.0
      assert result < 1.0
      # Expected value: ln(101)/ln(1001) ≈ 0.6655
      assert_in_delta(result, 0.6655, 0.001)
    end

    test "returns value greater than 1 for input greater than threshold" do
      result = NormalizationHelper.logarithmic_normalize(5000, 1000)
      assert result > 1.0
    end

    test "normalizes TMDb popularity values correctly" do
      # Common TMDb popularity values
      assert_in_delta(NormalizationHelper.logarithmic_normalize(10, 1000), 0.3320, 0.001)
      assert_in_delta(NormalizationHelper.logarithmic_normalize(50, 1000), 0.5639, 0.001)
      assert_in_delta(NormalizationHelper.logarithmic_normalize(100, 1000), 0.6655, 0.001)
      assert_in_delta(NormalizationHelper.logarithmic_normalize(500, 1000), 0.8988, 0.001)
    end
  end

  describe "linear_normalize/2" do
    test "returns 0 for zero input" do
      assert NormalizationHelper.linear_normalize(0, 100) == 0.0
    end

    test "returns 0.5 for input half of max" do
      assert NormalizationHelper.linear_normalize(50, 100) == 0.5
    end

    test "returns 1.0 for input equal to max" do
      assert NormalizationHelper.linear_normalize(100, 100) == 1.0
    end

    test "caps at 1.0 for input greater than max" do
      assert NormalizationHelper.linear_normalize(200, 100) == 1.0
    end
  end

  describe "tmdb_popularity_sql/1" do
    test "generates SQL with default threshold" do
      sql = NormalizationHelper.tmdb_popularity_sql()
      assert String.contains?(sql, "LN(value + 1) / LN(? + 1)")
      assert String.contains?(sql, "tmdb")
      assert String.contains?(sql, "popularity_score")
    end

    test "generates SQL with custom threshold" do
      sql = NormalizationHelper.tmdb_popularity_sql(5000)
      assert String.contains?(sql, "LN(value + 1) / LN(? + 1)")
    end
  end

  describe "canonical_sources_sql/1" do
    test "generates SQL with default weight" do
      sql = NormalizationHelper.canonical_sources_sql()
      assert String.contains?(sql, "COUNT(*) * ?")
      assert String.contains?(sql, "jsonb_each")
    end

    test "generates SQL with custom weight" do
      sql = NormalizationHelper.canonical_sources_sql(0.2)
      assert String.contains?(sql, "COUNT(*) * ?")
    end
  end

  describe "cultural_impact_sql/1" do
    test "generates complete cultural impact SQL with defaults" do
      sql = NormalizationHelper.cultural_impact_sql()
      assert String.contains?(sql, "LN(value + 1) / LN(1000 + 1)")
      assert String.contains?(sql, "COUNT(*) * 0.1")
      assert String.contains?(sql, "LEAST(1.0")
    end

    test "generates SQL with custom parameters" do
      sql =
        NormalizationHelper.cultural_impact_sql(
          canonical_weight: 0.2,
          popularity_threshold: 5000,
          max_value: 2.0
        )

      assert String.contains?(sql, "LN(value + 1) / LN(5000 + 1)")
      assert String.contains?(sql, "COUNT(*) * 0.2")
      assert String.contains?(sql, "LEAST(2.0")
    end
  end

  describe "cultural_impact_config/0" do
    test "returns default configuration" do
      config = NormalizationHelper.cultural_impact_config()
      assert config.canonical_weight == 0.1
      assert config.popularity_threshold == 1000
      assert config.max_value == 1.0
    end
  end

  describe "comparison with linear normalization" do
    test "logarithmic normalization produces more gradual scaling than linear" do
      # For TMDb popularity, logarithmic scaling should compress high values
      # and expand low-to-mid values compared to linear scaling

      values = [1, 10, 50, 100, 500, 1000]
      threshold = 1000

      for value <- values do
        log_result = NormalizationHelper.logarithmic_normalize(value, threshold)
        linear_result = NormalizationHelper.linear_normalize(value, threshold)

        if value < 100 do
          # For small values, log normalization should give higher results
          assert log_result > linear_result,
                 "Expected log(#{value}) > linear(#{value}), got #{log_result} <= #{linear_result}"
        end
      end
    end
  end
end
