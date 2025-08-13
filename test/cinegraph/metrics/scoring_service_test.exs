defmodule Cinegraph.Metrics.ScoringServiceTest do
  use Cinegraph.DataCase
  alias Cinegraph.Metrics.{ScoringService, MetricWeightProfile}

  describe "profile_to_discovery_weights/1" do
    test "splits ratings weight 50/50 between popular_opinion and critical_acclaim" do
      profile = %MetricWeightProfile{
        name: "Test Profile",
        category_weights: %{
          "ratings" => 0.60,
          "awards" => 0.20,
          "cultural" => 0.20,
          "financial" => 0.00
        }
      }

      weights = ScoringService.profile_to_discovery_weights(profile)

      # Ratings weight should be split equally
      assert weights.popular_opinion == 0.30  # 0.60 * 0.5
      assert weights.critical_acclaim == 0.30  # 0.60 * 0.5
      assert weights.industry_recognition == 0.20
      assert weights.cultural_impact == 0.20
    end

    test "handles zero ratings weight" do
      profile = %MetricWeightProfile{
        name: "No Ratings Profile",
        category_weights: %{
          "ratings" => 0.00,
          "awards" => 0.50,
          "cultural" => 0.50,
          "financial" => 0.00
        }
      }

      weights = ScoringService.profile_to_discovery_weights(profile)

      assert weights.popular_opinion == 0.00
      assert weights.critical_acclaim == 0.00
      assert weights.industry_recognition == 0.50
      assert weights.cultural_impact == 0.50
    end

    test "handles full ratings weight" do
      profile = %MetricWeightProfile{
        name: "All Ratings Profile",
        category_weights: %{
          "ratings" => 1.00,
          "awards" => 0.00,
          "cultural" => 0.00,
          "financial" => 0.00
        }
      }

      weights = ScoringService.profile_to_discovery_weights(profile)

      assert weights.popular_opinion == 0.50  # 1.00 * 0.5
      assert weights.critical_acclaim == 0.50  # 1.00 * 0.5
      assert weights.industry_recognition == 0.00
      assert weights.cultural_impact == 0.00
    end

    test "includes financial weight in cultural_impact when present" do
      profile = %MetricWeightProfile{
        name: "Financial Profile",
        category_weights: %{
          "ratings" => 0.40,
          "awards" => 0.20,
          "cultural" => 0.20,
          "financial" => 0.20
        }
      }

      weights = ScoringService.profile_to_discovery_weights(profile)

      assert weights.popular_opinion == 0.20  # 0.40 * 0.5
      assert weights.critical_acclaim == 0.20  # 0.40 * 0.5
      assert weights.industry_recognition == 0.20
      # Cultural impact should include financial weight
      assert weights.cultural_impact == 0.40  # 0.20 (cultural) + 0.20 (financial)
    end
  end

  describe "get_category_weight/3" do
    setup do
      profile = %MetricWeightProfile{
        name: "Test Profile",
        category_weights: %{
          "ratings" => 0.50,
          "awards" => 0.25,
          "cultural" => 0.25
        }
      }
      {:ok, profile: profile}
    end

    test "returns weight for existing category", %{profile: profile} do
      assert ScoringService.get_category_weight(profile, "ratings", 0.0) == 0.50
      assert ScoringService.get_category_weight(profile, "awards", 0.0) == 0.25
      assert ScoringService.get_category_weight(profile, "cultural", 0.0) == 0.25
    end

    test "returns default for missing category", %{profile: profile} do
      assert ScoringService.get_category_weight(profile, "financial", 0.0) == 0.0
      assert ScoringService.get_category_weight(profile, "nonexistent", 0.5) == 0.5
    end

    test "handles nil category_weights gracefully", %{profile: profile} do
      profile_with_nil = %{profile | category_weights: nil}
      assert ScoringService.get_category_weight(profile_with_nil, "ratings", 0.5) == 0.5
    end
  end
end