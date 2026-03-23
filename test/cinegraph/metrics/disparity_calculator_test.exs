defmodule Cinegraph.Metrics.DisparityCalculatorTest do
  use ExUnit.Case, async: true

  alias Cinegraph.Metrics.DisparityCalculator

  describe "calculate_disparity/2" do
    test "returns absolute difference" do
      assert DisparityCalculator.calculate_disparity(8.5, 4.0) == 4.5
      assert DisparityCalculator.calculate_disparity(4.0, 8.5) == 4.5
      assert DisparityCalculator.calculate_disparity(5.0, 5.0) == 0.0
    end
  end

  describe "classify_disparity/3" do
    test "critics_darling when ivory_tower high and mob low" do
      # ivory > 7.5, mob < 5.5, disparity > 2.0
      assert DisparityCalculator.classify_disparity(4.0, 8.5, 4.5) == "critics_darling"
    end

    test "peoples_champion when mob high and ivory_tower low" do
      # mob > 7.5, ivory < 5.5, disparity > 2.0
      assert DisparityCalculator.classify_disparity(8.5, 4.0, 4.5) == "peoples_champion"
    end

    test "perfect_harmony when both high and disparity tiny" do
      # mob > 7.5, ivory > 7.5, disparity < 0.5
      assert DisparityCalculator.classify_disparity(8.0, 8.2, 0.2) == "perfect_harmony"
    end

    test "polarizer when disparity large but doesn't fit other categories" do
      # e.g. mid-range scores but large gap
      assert DisparityCalculator.classify_disparity(6.0, 3.0, 3.0) == "polarizer"
    end

    test "nil when disparity is not significant" do
      assert DisparityCalculator.classify_disparity(6.0, 5.5, 0.5) == nil
    end
  end

  describe "calculate_unpredictability/1" do
    test "all equal scores returns 0.0" do
      components = %{
        mob: 5.0,
        ivory_tower: 5.0,
        industry_recognition: 5.0,
        cultural_impact: 5.0,
        people_quality: 5.0,
        financial_performance: 5.0
      }

      assert DisparityCalculator.calculate_unpredictability(components) == 0.0
    end

    test "alternating 0/10 returns ~5.0 stddev" do
      components = %{
        mob: 0.0,
        ivory_tower: 10.0,
        industry_recognition: 0.0,
        cultural_impact: 10.0,
        people_quality: 0.0,
        financial_performance: 10.0
      }

      result = DisparityCalculator.calculate_unpredictability(components)
      assert_in_delta result, 5.0, 0.01
    end
  end

  describe "calculate_all/1" do
    test "both-zero case returns nil disparity and category" do
      scores = %{
        components: %{
          mob: 0.0,
          ivory_tower: 0.0,
          industry_recognition: 0.0,
          cultural_impact: 0.0,
          people_quality: 0.0,
          financial_performance: 0.0
        }
      }

      result = DisparityCalculator.calculate_all(scores)
      assert result.disparity_score == nil
      assert result.disparity_category == nil
      assert result.unpredictability_score == 0.0
    end

    test "normal case returns expected map structure" do
      scores = %{
        components: %{
          mob: 4.0,
          ivory_tower: 8.5,
          industry_recognition: 7.0,
          cultural_impact: 6.0,
          people_quality: 5.0,
          financial_performance: 3.0
        }
      }

      result = DisparityCalculator.calculate_all(scores)
      assert result.disparity_score == 4.5
      assert result.disparity_category == "critics_darling"
      assert is_float(result.unpredictability_score)
      assert result.unpredictability_score > 0.0
    end
  end
end
