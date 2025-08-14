defmodule Cinegraph.Metrics.ScoringServiceTest do
  use Cinegraph.DataCase, async: true
  
  alias Cinegraph.Metrics.{ScoringService, MetricWeightProfile}
  
  describe "profile_to_discovery_weights/1" do
    test "splits ratings weight 50/50 between popular_opinion and critical_acclaim" do
      profile = %MetricWeightProfile{
        category_weights: %{
          "ratings" => 0.60,
          "awards" => 0.20,
          "cultural" => 0.20,
          "financial" => 0.00
        }
      }
      
      weights = ScoringService.profile_to_discovery_weights(profile)
      
      # Ratings weight of 0.60 should be split evenly
      assert_in_delta weights.popular_opinion, 0.30, 1.0e-8  # 0.60 * 0.5
      assert_in_delta weights.critical_acclaim, 0.30, 1.0e-8  # 0.60 * 0.5
      assert_in_delta weights.industry_recognition, 0.20, 1.0e-8
      assert_in_delta weights.cultural_impact, 0.20, 1.0e-8
    end
    
    test "includes financial weight in cultural_impact" do
      profile = %MetricWeightProfile{
        category_weights: %{
          "ratings" => 0.40,
          "awards" => 0.20,
          "cultural" => 0.20,
          "financial" => 0.20  # This should be added to cultural
        }
      }
      
      weights = ScoringService.profile_to_discovery_weights(profile)
      
      assert_in_delta weights.popular_opinion, 0.20, 1.0e-8  # 0.40 * 0.5
      assert_in_delta weights.critical_acclaim, 0.20, 1.0e-8  # 0.40 * 0.5
      assert_in_delta weights.industry_recognition, 0.20, 1.0e-8
      # Cultural (0.20) + Financial (0.20) = 0.40
      assert_in_delta weights.cultural_impact, 0.40, 1.0e-8
    end
    
    test "handles missing category weights with defaults" do
      profile = %MetricWeightProfile{
        category_weights: %{
          "ratings" => 0.80,
          "awards" => 0.20
          # Missing cultural and financial
        }
      }
      
      weights = ScoringService.profile_to_discovery_weights(profile)
      
      assert_in_delta weights.popular_opinion, 0.40, 1.0e-8  # 0.80 * 0.5
      assert_in_delta weights.critical_acclaim, 0.40, 1.0e-8  # 0.80 * 0.5
      assert_in_delta weights.industry_recognition, 0.20, 1.0e-8
      assert_in_delta weights.cultural_impact, 0.25, 1.0e-8  # Default 0.25 for cultural + 0.0 for financial
    end
  end
  
  describe "discovery_weights_to_profile/2" do
    test "combines popular_opinion and critical_acclaim into ratings category" do
      weights = %{
        popular_opinion: 0.30,
        critical_acclaim: 0.30,
        industry_recognition: 0.20,
        cultural_impact: 0.20
      }
      
      profile_data = ScoringService.discovery_weights_to_profile(weights, "Test Profile")
      
      # Should sum popular (0.30) + critical (0.30) = 0.60 for ratings
      assert_in_delta profile_data.category_weights["ratings"], 0.60, 1.0e-8
      assert_in_delta profile_data.category_weights["awards"], 0.20, 1.0e-8
      assert_in_delta profile_data.category_weights["cultural"], 0.20, 1.0e-8
      assert_in_delta profile_data.category_weights["financial"], 0.0, 1.0e-8
    end
    
    test "handles missing weight keys with defaults" do
      weights = %{
        popular_opinion: 0.50
        # Missing other keys
      }
      
      profile_data = ScoringService.discovery_weights_to_profile(weights, "Partial")
      
      # popular_opinion (0.50) + critical_acclaim default (0.25) = 0.75
      assert_in_delta profile_data.category_weights["ratings"], 0.75, 1.0e-8
      assert_in_delta profile_data.category_weights["awards"], 0.25, 1.0e-8  # Default
      assert_in_delta profile_data.category_weights["cultural"], 0.25, 1.0e-8  # Default
      assert_in_delta profile_data.category_weights["financial"], 0.0, 1.0e-8  # Default
    end
  end
  
  describe "normalize_profile_name/1" do
    test "converts atom to title case string" do
      assert ScoringService.normalize_profile_name(:balanced) == "Balanced"
      assert ScoringService.normalize_profile_name(:crowd_pleaser) == "Crowd Pleaser"
      assert ScoringService.normalize_profile_name(:critics_choice) == "Critics Choice"
    end
    
    test "normalizes binary strings to title case" do
      assert ScoringService.normalize_profile_name("balanced") == "Balanced"
      assert ScoringService.normalize_profile_name("crowd_pleaser") == "Crowd Pleaser"
      assert ScoringService.normalize_profile_name("CRITICS_CHOICE") == "Critics Choice"
      assert ScoringService.normalize_profile_name("award winner") == "Award Winner"
    end
    
    test "handles already normalized strings" do
      assert ScoringService.normalize_profile_name("Balanced") == "Balanced"
      assert ScoringService.normalize_profile_name("Crowd Pleaser") == "Crowd Pleaser"
    end
  end
  
  describe "apply_scoring/3" do
    setup do
      # Create a test profile
      {:ok, profile} = 
        %MetricWeightProfile{}
        |> MetricWeightProfile.changeset(%{
          name: "Test Profile",
          description: "Test profile for scoring",
          weights: %{},
          category_weights: %{
            "ratings" => 0.50,
            "awards" => 0.25,
            "financial" => 0.00,
            "cultural" => 0.25
          },
          active: true,
          is_default: false,
          is_system: false
        })
        |> Repo.insert()
      
      {:ok, profile: profile}
    end
    
    test "accepts atom profile names", %{profile: profile} do
      # This should not raise an error
      query = from(m in Cinegraph.Movies.Movie, limit: 1)
      
      # Test with atom - should convert to "Test Profile" and find the profile
      result = ScoringService.apply_scoring(query, :test_profile, %{})
      assert result != nil
    end
    
    test "accepts binary profile names", %{profile: profile} do
      query = from(m in Cinegraph.Movies.Movie, limit: 1)
      
      # Test with exact name
      result = ScoringService.apply_scoring(query, "Test Profile", %{})
      assert result != nil
      
      # Test with unnormalized name
      result = ScoringService.apply_scoring(query, "test_profile", %{})
      assert result != nil
    end
    
    test "accepts MetricWeightProfile struct directly", %{profile: profile} do
      query = from(m in Cinegraph.Movies.Movie, limit: 1)
      
      result = ScoringService.apply_scoring(query, profile, %{})
      assert result != nil
    end
    
    test "falls back to default profile when profile not found" do
      # Create a default profile
      {:ok, default} = 
        %MetricWeightProfile{}
        |> MetricWeightProfile.changeset(%{
          name: "Balanced",
          description: "Default balanced profile",
          weights: %{},
          category_weights: %{
            "ratings" => 0.50,
            "awards" => 0.25,
            "financial" => 0.00,
            "cultural" => 0.25
          },
          active: true,
          is_default: true,
          is_system: true
        })
        |> Repo.insert()
      
      query = from(m in Cinegraph.Movies.Movie, limit: 1)
      
      # Non-existent profile should fall back to default
      result = ScoringService.apply_scoring(query, "NonExistent", %{})
      assert result != nil
    end
  end
  
  describe "get_profile/1" do
    setup do
      {:ok, profile} = 
        %MetricWeightProfile{}
        |> MetricWeightProfile.changeset(%{
          name: "Crowd Pleaser",
          description: "Test profile",
          weights: %{},
          category_weights: %{
            "ratings" => 0.50,
            "awards" => 0.15,
            "financial" => 0.00,
            "cultural" => 0.35
          },
          active: true
        })
        |> Repo.insert()
      
      {:ok, profile: profile}
    end
    
    test "finds profile by normalized binary name", %{profile: profile} do
      assert ScoringService.get_profile("Crowd Pleaser") != nil
      assert ScoringService.get_profile("crowd_pleaser") != nil
      assert ScoringService.get_profile("CROWD_PLEASER") != nil
    end
    
    test "finds profile by atom name", %{profile: profile} do
      assert ScoringService.get_profile(:crowd_pleaser) != nil
    end
    
    test "returns nil for non-existent profile" do
      assert ScoringService.get_profile("NonExistent") == nil
      assert ScoringService.get_profile(:non_existent) == nil
    end
    
    test "only returns active profiles" do
      {:ok, inactive} = 
        %MetricWeightProfile{}
        |> MetricWeightProfile.changeset(%{
          name: "Inactive Profile",
          description: "Inactive test profile",
          weights: %{},
          category_weights: %{"ratings" => 1.0},
          active: false
        })
        |> Repo.insert()
      
      assert ScoringService.get_profile("Inactive Profile") == nil
    end
  end
end