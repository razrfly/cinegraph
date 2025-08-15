defmodule Cinegraph.Metrics.ScoringServiceTest do
  use Cinegraph.DataCase, async: true
  alias Cinegraph.Metrics.{ScoringService, MetricWeightProfile}

  describe "profile_to_discovery_weights/1" do
    test "correctly splits ratings weight 50/50 between popular and critical" do
      profile = %MetricWeightProfile{
        name: "Test Profile",
        category_weights: %{
          "ratings" => 0.60,
          "awards" => 0.20,
          "cultural" => 0.20,
          "financial" => 0.00
        }
      }

      result = ScoringService.profile_to_discovery_weights(profile)

      # Ratings weight should be split evenly
      assert result.popular_opinion == 0.30
      assert result.critical_acclaim == 0.30

      # Other weights should pass through
      assert result.industry_recognition == 0.20
      assert result.cultural_impact == 0.20
    end

    test "folds financial weight into cultural impact" do
      profile = %MetricWeightProfile{
        name: "Test Profile",
        category_weights: %{
          "ratings" => 0.40,
          "awards" => 0.20,
          "cultural" => 0.30,
          "financial" => 0.10
        }
      }

      result = ScoringService.profile_to_discovery_weights(profile)

      # Ratings weight should be split evenly
      assert result.popular_opinion == 0.20
      assert result.critical_acclaim == 0.20

      # Awards weight should pass through
      assert result.industry_recognition == 0.20

      # Cultural impact should include half of financial weight
      # cultural (0.30) + financial (0.10) * 0.5 = 0.35
      assert result.cultural_impact == 0.35
    end

    test "uses default weights when categories are missing" do
      profile = %MetricWeightProfile{
        name: "Empty Profile",
        category_weights: %{}
      }

      result = ScoringService.profile_to_discovery_weights(profile)

      # Should use defaults: ratings=0.4, awards=0.2, cultural=0.2
      # 0.4 * 0.5 = 0.2
      assert result.popular_opinion == 0.20
      # 0.4 * 0.5 = 0.2
      assert result.critical_acclaim == 0.20
      assert result.industry_recognition == 0.20
      assert result.cultural_impact == 0.20
    end

    test "handles nil category_weights gracefully" do
      profile = %MetricWeightProfile{
        name: "Nil Profile",
        category_weights: nil
      }

      result = ScoringService.profile_to_discovery_weights(profile)

      # Should use defaults: ratings=0.4, awards=0.2, cultural=0.2
      assert result.popular_opinion == 0.20
      assert result.critical_acclaim == 0.20
      assert result.industry_recognition == 0.20
      assert result.cultural_impact == 0.20
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

      result = ScoringService.profile_to_discovery_weights(profile)

      assert result.popular_opinion == 0.00
      assert result.critical_acclaim == 0.00
      assert result.industry_recognition == 0.50
      assert result.cultural_impact == 0.50
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

      result = ScoringService.profile_to_discovery_weights(profile)

      # 1.00 * 0.5
      assert result.popular_opinion == 0.50
      # 1.00 * 0.5
      assert result.critical_acclaim == 0.50
      assert result.industry_recognition == 0.00
      assert result.cultural_impact == 0.00
    end
  end

  describe "discovery_weights_to_profile/2" do
    test "converts discovery weights back to profile format" do
      weights = %{
        popular_opinion: 0.30,
        critical_acclaim: 0.20,
        industry_recognition: 0.25,
        cultural_impact: 0.25
      }

      result = ScoringService.discovery_weights_to_profile(weights, "Custom Test")

      assert result.name == "Custom Test"
      # Ratings are derived from both popular_opinion and critical_acclaim
      assert result.category_weights["ratings"] == 0.50
      assert result.category_weights["awards"] == 0.25
      assert result.category_weights["cultural"] == 0.25
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
