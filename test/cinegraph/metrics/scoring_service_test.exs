defmodule Cinegraph.Metrics.ScoringServiceTest do
  use Cinegraph.DataCase, async: true
  alias Cinegraph.Metrics.{ScoringService, MetricWeightProfile}

  describe "profile_to_discovery_weights/1" do
    test "correctly converts mob and critics categories to discovery weights" do
      profile = %MetricWeightProfile{
        name: "Test Profile",
        category_weights: %{
          "mob" => 0.10,
          "critics" => 0.10,
          "festival_recognition" => 0.20,
          "time_machine" => 0.20,
          "auteurs" => 0.20,
          "box_office" => 0.20
        }
      }

      result = ScoringService.profile_to_discovery_weights(profile)

      assert result.mob == 0.10
      assert result.critics == 0.10
      assert result.festival_recognition == 0.20
      assert result.time_machine == 0.20
      assert result.auteurs == 0.20
      assert result.box_office == 0.20
    end

    test "uses default weights when categories are missing" do
      profile = %MetricWeightProfile{
        name: "Empty Profile",
        category_weights: %{}
      }

      result = ScoringService.profile_to_discovery_weights(profile)

      assert result.mob == 0.10
      assert result.critics == 0.10
      assert result.festival_recognition == 0.20
      assert result.time_machine == 0.20
      assert result.auteurs == 0.20
      assert result.box_office == 0.20
    end

    test "handles nil category_weights gracefully" do
      profile = %MetricWeightProfile{
        name: "Nil Profile",
        category_weights: nil
      }

      result = ScoringService.profile_to_discovery_weights(profile)

      assert result.mob == 0.10
      assert result.critics == 0.10
      assert result.festival_recognition == 0.20
      assert result.time_machine == 0.20
      assert result.auteurs == 0.20
      assert result.box_office == 0.20
    end

    test "handles zero mob/critics weights" do
      profile = %MetricWeightProfile{
        name: "No Ratings Profile",
        category_weights: %{
          "mob" => 0.00,
          "critics" => 0.00,
          "festival_recognition" => 0.50,
          "time_machine" => 0.30,
          "auteurs" => 0.10,
          "box_office" => 0.10
        }
      }

      result = ScoringService.profile_to_discovery_weights(profile)

      assert result.mob == 0.00
      assert result.critics == 0.00
      assert result.festival_recognition == 0.50
      assert result.time_machine == 0.30
      assert result.auteurs == 0.10
      assert result.box_office == 0.10
    end

    test "handles full mob weight" do
      profile = %MetricWeightProfile{
        name: "All Mob Profile",
        category_weights: %{
          "mob" => 1.00,
          "critics" => 0.00,
          "festival_recognition" => 0.00,
          "time_machine" => 0.00,
          "auteurs" => 0.00,
          "box_office" => 0.00
        }
      }

      result = ScoringService.profile_to_discovery_weights(profile)

      assert result.mob == 1.00
      assert result.critics == 0.00
      assert result.festival_recognition == 0.00
      assert result.time_machine == 0.00
      assert result.auteurs == 0.00
      assert result.box_office == 0.00
    end
  end

  describe "discovery_weights_to_profile/2" do
    test "converts discovery weights back to profile format" do
      weights = %{
        mob: 0.15,
        critics: 0.15,
        festival_recognition: 0.25,
        time_machine: 0.20,
        auteurs: 0.15,
        box_office: 0.10
      }

      result = ScoringService.discovery_weights_to_profile(weights, "Custom Test")

      assert result.name == "Custom Test"
      assert result.category_weights["mob"] == 0.15
      assert result.category_weights["critics"] == 0.15
      assert result.category_weights["festival_recognition"] == 0.25
      assert result.category_weights["time_machine"] == 0.20
      assert result.category_weights["auteurs"] == 0.15
      assert result.category_weights["box_office"] == 0.10
    end

    test "handles missing weights with defaults" do
      weights = %{
        mob: 0.30,
        critics: 0.20,
        festival_recognition: 0.50
      }

      result = ScoringService.discovery_weights_to_profile(weights, "Partial Weights")

      assert result.name == "Partial Weights"
      assert result.category_weights["mob"] == 0.30
      assert result.category_weights["critics"] == 0.20
      assert result.category_weights["festival_recognition"] == 0.50
      assert result.category_weights["time_machine"] == 0.20
      assert result.category_weights["auteurs"] == 0.20
      assert result.category_weights["box_office"] == 0.20
    end
  end
end
