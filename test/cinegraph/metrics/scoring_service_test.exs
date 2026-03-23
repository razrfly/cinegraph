defmodule Cinegraph.Metrics.ScoringServiceTest do
  use Cinegraph.DataCase, async: true
  alias Cinegraph.Metrics.{ScoringService, MetricWeightProfile}

  describe "profile_to_discovery_weights/1" do
    test "correctly converts mob and ivory_tower categories to discovery weights" do
      profile = %MetricWeightProfile{
        name: "Test Profile",
        category_weights: %{
          "mob" => 0.10,
          "ivory_tower" => 0.10,
          "awards" => 0.20,
          "cultural" => 0.20,
          "people" => 0.20,
          "financial" => 0.20
        }
      }

      result = ScoringService.profile_to_discovery_weights(profile)

      assert result.mob == 0.10
      assert result.ivory_tower == 0.10
      assert result.industry_recognition == 0.20
      assert result.cultural_impact == 0.20
      assert result.people_quality == 0.20
      assert result.financial_success == 0.20
    end

    test "splits legacy popular_opinion 50/50 into mob and ivory_tower" do
      profile = %MetricWeightProfile{
        name: "Legacy Profile",
        category_weights: %{
          "popular_opinion" => 0.40,
          "awards" => 0.20,
          "cultural" => 0.20,
          "people" => 0.10,
          "financial" => 0.10
        }
      }

      result = ScoringService.profile_to_discovery_weights(profile)

      assert result.mob == 0.20
      assert result.ivory_tower == 0.20
      assert result.industry_recognition == 0.20
      assert result.cultural_impact == 0.20
      assert result.people_quality == 0.10
      assert result.financial_success == 0.10
    end

    test "uses default weights when categories are missing" do
      profile = %MetricWeightProfile{
        name: "Empty Profile",
        category_weights: %{}
      }

      result = ScoringService.profile_to_discovery_weights(profile)

      # mob and ivory_tower each get half of ratings default (0.20)
      assert result.mob == 0.10
      assert result.ivory_tower == 0.10
      assert result.industry_recognition == 0.20
      assert result.cultural_impact == 0.20
      assert result.people_quality == 0.20
      assert result.financial_success == 0.00
    end

    test "handles nil category_weights gracefully" do
      profile = %MetricWeightProfile{
        name: "Nil Profile",
        category_weights: nil
      }

      result = ScoringService.profile_to_discovery_weights(profile)

      assert result.mob == 0.10
      assert result.ivory_tower == 0.10
      assert result.industry_recognition == 0.20
      assert result.cultural_impact == 0.20
      assert result.people_quality == 0.20
      assert result.financial_success == 0.00
    end

    test "handles zero mob/ivory_tower weights" do
      profile = %MetricWeightProfile{
        name: "No Ratings Profile",
        category_weights: %{
          "mob" => 0.00,
          "ivory_tower" => 0.00,
          "awards" => 0.50,
          "cultural" => 0.30,
          "people" => 0.10,
          "financial" => 0.10
        }
      }

      result = ScoringService.profile_to_discovery_weights(profile)

      assert result.mob == 0.00
      assert result.ivory_tower == 0.00
      assert result.industry_recognition == 0.50
      assert result.cultural_impact == 0.30
      assert result.people_quality == 0.10
      assert result.financial_success == 0.10
    end

    test "handles full mob weight" do
      profile = %MetricWeightProfile{
        name: "All Mob Profile",
        category_weights: %{
          "mob" => 1.00,
          "ivory_tower" => 0.00,
          "awards" => 0.00,
          "cultural" => 0.00,
          "people" => 0.00,
          "financial" => 0.00
        }
      }

      result = ScoringService.profile_to_discovery_weights(profile)

      assert result.mob == 1.00
      assert result.ivory_tower == 0.00
      assert result.industry_recognition == 0.00
      assert result.cultural_impact == 0.00
      assert result.people_quality == 0.00
      assert result.financial_success == 0.00
    end

    test "handles backward compatibility with old 'ratings' category" do
      profile = %MetricWeightProfile{
        name: "Old Format Profile",
        category_weights: %{
          "ratings" => 0.40,
          "awards" => 0.20,
          "cultural" => 0.20,
          "people" => 0.20
        }
      }

      result = ScoringService.profile_to_discovery_weights(profile)

      # Old "ratings" splits 50/50 into mob + ivory_tower
      assert result.mob == 0.20
      assert result.ivory_tower == 0.20
      assert result.industry_recognition == 0.20
      assert result.cultural_impact == 0.20
      assert result.people_quality == 0.20
    end
  end

  describe "discovery_weights_to_profile/2" do
    test "converts discovery weights back to profile format" do
      weights = %{
        mob: 0.15,
        ivory_tower: 0.15,
        industry_recognition: 0.25,
        cultural_impact: 0.20,
        people_quality: 0.15,
        financial_success: 0.10
      }

      result = ScoringService.discovery_weights_to_profile(weights, "Custom Test")

      assert result.name == "Custom Test"
      assert result.category_weights["mob"] == 0.15
      assert result.category_weights["ivory_tower"] == 0.15
      assert result.category_weights["awards"] == 0.25
      assert result.category_weights["cultural"] == 0.20
      assert result.category_weights["people"] == 0.15
      assert result.category_weights["financial"] == 0.10
    end

    test "handles missing weights with defaults" do
      weights = %{
        mob: 0.30,
        ivory_tower: 0.20,
        industry_recognition: 0.50
      }

      result = ScoringService.discovery_weights_to_profile(weights, "Partial Weights")

      assert result.name == "Partial Weights"
      assert result.category_weights["mob"] == 0.30
      assert result.category_weights["ivory_tower"] == 0.20
      assert result.category_weights["awards"] == 0.50
      # Missing weights should default to 0.2
      assert result.category_weights["cultural"] == 0.20
      assert result.category_weights["people"] == 0.20
      assert result.category_weights["financial"] == 0.20
    end
  end
end
