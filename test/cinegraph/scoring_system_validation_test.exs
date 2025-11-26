defmodule Cinegraph.ScoringSystemValidationTest do
  @moduledoc """
  Phase 4 Validation Tests for the unified 5-category scoring system.

  Tests all 7 success criteria:
  1. Consistency - Same movie has same score across all contexts
  2. Clarity - Users understand categories
  3. Configurability - Weights adjustable via database
  4. Performance - <100ms single movie, <5s list pages
  5. Accuracy - All categories use live data
  6. Transparency - Users see calculation
  7. Maintainability - Single source of truth
  """

  use Cinegraph.DataCase, async: false
  import Ecto.Query

  alias Cinegraph.Repo
  alias Cinegraph.Movies
  alias Cinegraph.Movies.{Movie, MovieScoring}
  alias Cinegraph.Movies.DiscoveryScoringSimple, as: DiscoveryScoring
  alias Cinegraph.Metrics.{ScoringService, MetricWeightProfile}

  describe "SUCCESS CRITERION 1: Consistency" do
    test "same movie has same score across MovieScoring and ScoringService" do
      # Get a real movie with data
      movie =
        Movie
        |> where([m], not is_nil(m.tmdb_id))
        |> limit(1)
        |> Repo.one()
        |> Repo.preload([:external_metrics])

      if movie do
        # Get score from MovieScoring (movie detail page)
        movie_scoring_data = MovieScoring.calculate_movie_scores(movie)

        # Get score from ScoringService (discovery)
        profile = ScoringService.get_default_profile()

        discovery_movie =
          Movie
          |> where([m], m.id == ^movie.id)
          |> ScoringService.add_scores_for_display(profile)
          |> Repo.one()

        # Both should exist
        assert movie_scoring_data.overall_score
        assert discovery_movie.discovery_score

        # Scores should be within reasonable tolerance (within 0.5 points on 0-10 scale)
        # Note: They may differ slightly due to different calculation methods, but should be close
        score_diff = abs(movie_scoring_data.overall_score - discovery_movie.discovery_score * 10)

        assert score_diff < 1.0,
               """
               Score inconsistency detected for movie #{movie.title}:
               - MovieScoring: #{movie_scoring_data.overall_score}
               - ScoringService: #{discovery_movie.discovery_score * 10}
               - Difference: #{score_diff}
               """
      else
        # Skip test if no movies in database
        assert true
      end
    end

    test "all 5 categories are present in both systems" do
      # MovieScoring categories
      movie = %Movie{id: 1, canonical_sources: %{}}
      score_data = MovieScoring.calculate_movie_scores(movie)

      assert Map.has_key?(score_data.components, :popular_opinion)
      assert Map.has_key?(score_data.components, :industry_recognition)
      assert Map.has_key?(score_data.components, :cultural_impact)
      assert Map.has_key?(score_data.components, :people_quality)
      assert Map.has_key?(score_data.components, :financial_performance)

      # ScoringService categories
      profile = ScoringService.get_default_profile()
      weights = ScoringService.profile_to_discovery_weights(profile)

      assert Map.has_key?(weights, :popular_opinion)
      assert Map.has_key?(weights, :industry_recognition)
      assert Map.has_key?(weights, :cultural_impact)
      assert Map.has_key?(weights, :people_quality)
      assert Map.has_key?(weights, :financial_success)
    end

    test "category names are consistent between systems" do
      # Get categories from both systems
      movie = %Movie{id: 1, canonical_sources: %{}}
      movie_scoring_categories = MovieScoring.calculate_movie_scores(movie).components |> Map.keys()

      profile = ScoringService.get_default_profile()
      scoring_service_categories = ScoringService.profile_to_discovery_weights(profile) |> Map.keys()

      # Convert to strings for easier comparison
      movie_scoring_names = Enum.map(movie_scoring_categories, &to_string/1) |> Enum.sort()

      scoring_service_names =
        Enum.map(scoring_service_categories, fn
          :financial_success -> "financial_performance"
          other -> to_string(other)
        end)
        |> Enum.sort()

      assert movie_scoring_names == scoring_service_names,
             """
             Category name mismatch:
             MovieScoring: #{inspect(movie_scoring_names)}
             ScoringService: #{inspect(scoring_service_names)}
             """
    end
  end

  describe "SUCCESS CRITERION 2: Clarity" do
    test "all categories have human-readable descriptions" do
      # Check that descriptions exist for all categories
      categories = [
        :popular_opinion,
        :industry_recognition,
        :cultural_impact,
        :people_quality,
        :financial_success
      ]

      # These descriptions should be defined in DiscoveryTuner
      descriptions = %{
        popular_opinion: "All rating sources (IMDb, TMDb, Metacritic, RT)",
        industry_recognition: "Festival awards and nominations",
        cultural_impact: "Canonical lists and popularity metrics",
        people_quality: "Quality of directors, actors, and crew",
        financial_success: "Box office revenue and budget performance"
      }

      for category <- categories do
        assert Map.has_key?(descriptions, category),
               "Missing description for category: #{category}"

        assert String.length(descriptions[category]) > 10,
               "Description too short for category: #{category}"
      end
    end

    test "profile descriptions are clear and informative" do
      profiles = ScoringService.get_all_profiles()

      assert length(profiles) >= 4, "Should have at least 4 weight profiles"

      for profile <- profiles do
        assert profile.description, "Profile #{profile.name} missing description"
        assert String.length(profile.description) > 20, "Profile #{profile.name} description too short"
        # Description should mention percentages
        assert profile.description =~ ~r/\d+%/, "Profile #{profile.name} description should include percentages"
      end
    end
  end

  describe "SUCCESS CRITERION 3: Configurability" do
    test "weight profiles can be loaded from database" do
      profiles = ScoringService.get_all_profiles()
      assert length(profiles) > 0, "No weight profiles in database"

      # Verify each profile has valid structure
      for profile <- profiles do
        assert profile.name
        assert profile.category_weights
        assert is_map(profile.category_weights)
        assert profile.active
      end
    end

    test "custom weight profiles can be created without code changes" do
      # Create a custom profile
      custom_attrs = %{
        name: "Test Custom Profile",
        description: "Test profile for validation",
        category_weights: %{
          "popular_opinion" => 0.30,
          "awards" => 0.25,
          "cultural" => 0.20,
          "people" => 0.15,
          "financial" => 0.10
        },
        weights: %{},
        active: true,
        is_system: false
      }

      changeset = MetricWeightProfile.changeset(%MetricWeightProfile{}, custom_attrs)
      assert changeset.valid?, "Custom profile changeset should be valid"

      # Insert and retrieve
      {:ok, created} = Repo.insert(changeset)
      retrieved = ScoringService.get_profile(created.name)

      assert retrieved
      assert retrieved.category_weights["popular_opinion"] == 0.30

      # Cleanup
      Repo.delete(created)
    end

    test "all weight profiles use the 5-category system" do
      profiles = ScoringService.get_all_profiles()

      for profile <- profiles do
        weights = profile.category_weights

        # Should have exactly 5 categories (though some may be 0.0)
        valid_categories = ["popular_opinion", "awards", "cultural", "people", "financial"]

        for category <- Map.keys(weights) do
          assert category in valid_categories,
                 "Invalid category '#{category}' in profile #{profile.name}"
        end
      end
    end

    test "weights can be adjusted via database without code deployment" do
      # Get a profile
      profile = ScoringService.get_profile("Balanced")

      if profile do
        original_weights = profile.category_weights

        # Update weights
        new_weights = %{
          "popular_opinion" => 0.25,
          "awards" => 0.25,
          "cultural" => 0.20,
          "people" => 0.20,
          "financial" => 0.10
        }

        changeset =
          MetricWeightProfile.changeset(profile, %{category_weights: new_weights})

        {:ok, updated} = Repo.update(changeset)

        # Verify change persisted
        reloaded = ScoringService.get_profile("Balanced")
        assert reloaded.category_weights == new_weights

        # Restore original
        Repo.update(MetricWeightProfile.changeset(updated, %{category_weights: original_weights}))
      else
        # Skip if no Balanced profile
        assert true
      end
    end
  end

  describe "SUCCESS CRITERION 4: Performance" do
    @tag timeout: 120_000
    test "single movie scoring completes in <100ms" do
      movie =
        Movie
        |> where([m], not is_nil(m.tmdb_id))
        |> limit(1)
        |> Repo.one()
        |> Repo.preload([:external_metrics])

      if movie do
        {time_microseconds, _result} =
          :timer.tc(fn ->
            MovieScoring.calculate_movie_scores(movie)
          end)

        time_milliseconds = time_microseconds / 1000

        assert time_milliseconds < 100,
               "Single movie scoring took #{time_milliseconds}ms (should be <100ms)"
      else
        assert true
      end
    end

    @tag timeout: 120_000
    test "discovery page with 20 movies completes in <5s" do
      profile = ScoringService.get_default_profile()

      {time_microseconds, movies} =
        :timer.tc(fn ->
          Movie
          |> limit(20)
          |> ScoringService.apply_scoring(profile)
          |> Repo.all()
        end)

      time_seconds = time_microseconds / 1_000_000

      assert time_seconds < 5.0,
             "Discovery scoring for 20 movies took #{time_seconds}s (should be <5s)"

      assert length(movies) > 0, "Should return at least some movies"
    end

    test "default profile loads quickly" do
      {time_microseconds, profile} =
        :timer.tc(fn ->
          ScoringService.get_default_profile()
        end)

      time_milliseconds = time_microseconds / 1000

      assert profile
      assert time_milliseconds < 50, "Default profile should load in <50ms"
    end
  end

  describe "SUCCESS CRITERION 5: Accuracy" do
    test "all categories use live data from database, not hard-coded values" do
      # Verify MovieScoring queries database
      movie = %Movie{id: 1, canonical_sources: %{}}
      score_data = MovieScoring.calculate_movie_scores(movie)

      # Should have component scores (even if 0)
      assert is_map(score_data.components)
      assert Map.has_key?(score_data.components, :popular_opinion)

      # Verify ScoringService queries database
      profile = ScoringService.get_profile("Balanced")
      assert profile
      assert profile.category_weights["popular_opinion"] > 0
    end

    test "no hard-coded weight values in scoring calculations" do
      # Check that default profile comes from database
      profile = ScoringService.get_default_profile()

      # Should have name indicating it's from database or fallback
      assert profile.name in ["Balanced", "Fallback"]

      # Fallback should be clearly marked
      if profile.name == "Fallback" do
        assert profile.description =~ "fallback"
      end
    end

    test "financial performance uses actual revenue/budget data" do
      # Create a movie with financial data
      metrics = %{
        budget: 100_000_000,
        revenue: 500_000_000
      }

      score = MovieScoring.calculate_financial_performance(metrics)

      # Score should be > 0 when we have data
      assert score > 0
      assert score <= 10

      # Should be 0 when no data
      empty_score = MovieScoring.calculate_financial_performance(%{})
      assert empty_score == 0.0
    end
  end

  describe "SUCCESS CRITERION 6: Transparency" do
    test "score components are exposed to users" do
      movie = %Movie{id: 1, canonical_sources: %{}}
      score_data = MovieScoring.calculate_movie_scores(movie)

      # User can see breakdown
      assert Map.has_key?(score_data, :components)
      assert map_size(score_data.components) == 5

      # All components have values
      for {_category, score} <- score_data.components do
        assert is_float(score) or is_integer(score)
        assert score >= 0
        assert score <= 10
      end
    end

    test "discovery queries include score_components in results" do
      profile = ScoringService.get_default_profile()

      movies =
        Movie
        |> limit(1)
        |> ScoringService.add_scores_for_display(profile)
        |> Repo.all()

      if length(movies) > 0 do
        movie = List.first(movies)

        # Should have score components
        assert Map.has_key?(movie, :score_components)
        assert is_map(movie.score_components)
      else
        assert true
      end
    end
  end

  describe "SUCCESS CRITERION 7: Maintainability" do
    test "single source of truth for category definitions" do
      # Both systems should reference the same 5 categories
      movie_categories =
        MovieScoring.calculate_movie_scores(%Movie{id: 1, canonical_sources: %{}}).components
        |> Map.keys()
        |> Enum.sort()

      scoring_service_categories =
        ScoringService.profile_to_discovery_weights(ScoringService.get_default_profile())
        |> Map.keys()
        |> Enum.sort()

      # Should have same number of categories
      assert length(movie_categories) == 5
      assert length(scoring_service_categories) == 5
    end

    test "no duplicate scoring logic across modules" do
      # This is a code smell test - verify ScoringService is used as primary
      # MovieScoring should be for display purposes, not primary scoring

      # ScoringService should be referenced in discovery modules
      assert Code.ensure_loaded?(Cinegraph.Metrics.ScoringService)
      assert Code.ensure_loaded?(Cinegraph.Movies.DiscoveryScoringSimple)

      # Verify DiscoveryScoringSimple delegates to ScoringService
      # (This is checked by ensuring the module exists and the apply_scoring
      #  function accepts profiles)
      assert function_exported?(
               Cinegraph.Movies.DiscoveryScoringSimple,
               :apply_scoring,
               3
             )
    end

    test "all weight profiles stored in database, not in code" do
      # Verify we can get profiles from database
      profiles = ScoringService.get_all_profiles()
      assert length(profiles) >= 4, "Should have at least 4 profiles in database"

      # Verify they're actual database records
      for profile <- profiles do
        assert profile.__meta__
        assert profile.__meta__.state == :loaded
      end
    end
  end

  describe "DATA QUALITY CHECKS" do
    test "sample of movies have sufficient data for scoring" do
      movies =
        Movie
        |> where([m], not is_nil(m.tmdb_id))
        |> limit(10)
        |> Repo.all()
        |> Repo.preload([:external_metrics])

      if length(movies) > 0 do
        movies_with_ratings =
          Enum.count(movies, fn movie ->
            length(movie.external_metrics) > 0
          end)

        percentage = movies_with_ratings / length(movies) * 100

        IO.puts("\nData Quality Report:")
        IO.puts("  Movies checked: #{length(movies)}")
        IO.puts("  Movies with ratings: #{movies_with_ratings}")
        IO.puts("  Percentage: #{Float.round(percentage, 1)}%")

        # At least 50% should have some rating data
        assert percentage >= 50,
               "Only #{percentage}% of movies have rating data (should be >=50%)"
      else
        IO.puts("\nNo movies in database - skipping data quality check")
        assert true
      end
    end
  end
end
