defmodule Cinegraph.Metrics.ScoringServiceTest do
  use Cinegraph.DataCase, async: true
  alias Cinegraph.Metrics.{ScoringService, MetricWeightProfile}
  alias Cinegraph.Movies.{Movie, MovieScoreCache}
  alias Cinegraph.Repo

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

  describe "apply_scoring_from_cache/3" do
    test "orders movies by weighted sum of cached lens scores" do
      high_critics = insert_movie!("High Critics")
      high_mob = insert_movie!("High Mob")

      insert_score_cache!(high_critics, 7.0, mob: 2.0, critics: 9.0)
      insert_score_cache!(high_mob, 7.0, mob: 9.0, critics: 2.0)

      critics_heavy = %MetricWeightProfile{
        name: "Critics Heavy",
        category_weights: %{
          "mob" => 0.0,
          "critics" => 1.0,
          "festival_recognition" => 0.0,
          "time_machine" => 0.0,
          "auteurs" => 0.0,
          "box_office" => 0.0
        },
        weights: %{},
        active: true,
        is_default: false
      }

      results = ScoringService.apply_scoring_from_cache(Movie, critics_heavy, %{}) |> Repo.all()
      ids = Enum.map(results, & &1.id)

      assert Enum.find_index(ids, &(&1 == high_critics.id)) <
               Enum.find_index(ids, &(&1 == high_mob.id))
    end

    test "filters out movies below min_score" do
      low = insert_movie!("Low Score")
      high = insert_movie!("High Score")

      insert_score_cache!(low, 1.0, overall: 1.0)
      insert_score_cache!(high, 8.0, overall: 8.0)

      profile = %MetricWeightProfile{
        name: "Balanced",
        category_weights: %{
          "mob" => 0.2,
          "critics" => 0.2,
          "festival_recognition" => 0.2,
          "time_machine" => 0.2,
          "auteurs" => 0.1,
          "box_office" => 0.1
        },
        weights: %{},
        active: true,
        is_default: false
      }

      results =
        ScoringService.apply_scoring_from_cache(Movie, profile, %{min_score: 5.0}) |> Repo.all()

      ids = Enum.map(results, & &1.id)
      assert high.id in ids
      refute low.id in ids
    end

    test "excludes movies with no cache row" do
      cached = insert_movie!("Cached")
      uncached = insert_movie!("Uncached")

      insert_score_cache!(cached, 7.0, mob: 7.0, critics: 7.0)

      profile = %MetricWeightProfile{
        name: "Test",
        category_weights: %{
          "mob" => 0.5,
          "critics" => 0.5,
          "festival_recognition" => 0.0,
          "time_machine" => 0.0,
          "auteurs" => 0.0,
          "box_office" => 0.0
        },
        weights: %{},
        active: true,
        is_default: false
      }

      results = ScoringService.apply_scoring_from_cache(Movie, profile, %{}) |> Repo.all()
      ids = Enum.map(results, & &1.id)
      assert cached.id in ids
      refute uncached.id in ids
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

  defp insert_movie!(title) do
    Repo.insert!(%Movie{
      tmdb_id: System.unique_integer([:positive]),
      title: title,
      original_title: title
    })
  end

  defp insert_score_cache!(movie, overall_score, scores) do
    mob = Keyword.get(scores, :mob, overall_score)
    critics = Keyword.get(scores, :critics, overall_score)
    festival = Keyword.get(scores, :festival_recognition, overall_score)
    time_m = Keyword.get(scores, :time_machine, overall_score)
    auteurs = Keyword.get(scores, :auteurs, overall_score)
    box_office = Keyword.get(scores, :box_office, overall_score)

    Repo.insert!(%MovieScoreCache{
      movie_id: movie.id,
      mob_score: mob,
      critics_score: critics,
      festival_recognition_score: festival,
      time_machine_score: time_m,
      auteurs_score: auteurs,
      box_office_score: box_office,
      overall_score: overall_score,
      score_confidence: 1.0,
      disparity_score: abs(mob - critics),
      disparity_category: nil,
      unpredictability_score: 0.0,
      calculated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      calculation_version: "test"
    })
  end
end
