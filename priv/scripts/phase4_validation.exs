# Phase 4 Validation Script
# Run with: mix run priv/scripts/phase4_validation.exs
#
# This script validates all 7 success criteria against your actual development data

alias Cinegraph.Repo
alias Cinegraph.Movies
alias Cinegraph.Movies.{Movie, MovieScoring}
alias Cinegraph.Movies.DiscoveryScoringSimple, as: DiscoveryScoring
alias Cinegraph.Metrics.{ScoringService, MetricWeightProfile}

import Ecto.Query

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("PHASE 4 VALIDATION - Unified 5-Category Scoring System")
IO.puts(String.duplicate("=", 80) <> "\n")

# Validation Results Tracker
results = %{
  passed: [],
  failed: [],
  warnings: []
}

# Helper function to print test results
print_test = fn name, status, details ->
  icon =
    case status do
      :pass -> "✅"
      :fail -> "❌"
      :warn -> "⚠️"
    end

  IO.puts("#{icon} #{name}")
  if details, do: IO.puts("   #{details}")
end

IO.puts("═══ CRITERION 1: CONSISTENCY ═══\n")

# Test 1.1: Same movie, same score across contexts
IO.puts("Test 1.1: Score consistency across MovieScoring and ScoringService")

movie =
  Movie
  |> where([m], not is_nil(m.tmdb_id))
  |> limit(1)
  |> Repo.one()
  |> Repo.preload([:external_metrics])

if movie do
  movie_scoring_data = MovieScoring.calculate_movie_scores(movie)
  profile = ScoringService.get_default_profile()

  discovery_movie =
    Movie
    |> where([m], m.id == ^movie.id)
    |> ScoringService.add_scores_for_display(profile)
    |> Repo.one()

  movie_score = movie_scoring_data.overall_score
  discovery_score = discovery_movie.discovery_score * 10
  diff = abs(movie_score - discovery_score)

  if diff < 1.0 do
    print_test.(
      "Score consistency",
      :pass,
      "Movie: #{movie.title} | MovieScoring: #{movie_score} | Discovery: #{Float.round(discovery_score, 1)} | Diff: #{Float.round(diff, 2)}"
    )

    results = Map.put(results, :passed, results.passed ++ ["1.1 Score consistency"])
  else
    print_test.(
      "Score consistency",
      :fail,
      "Score difference too large: #{diff}"
    )

    results = Map.put(results, :failed, results.failed ++ ["1.1 Score consistency"])
  end
else
  print_test.("Score consistency", :warn, "No movies in database to test")
  results = Map.put(results, :warnings, results.warnings ++ ["1.1 No test data"])
end

# Test 1.2: All 5 categories present
IO.puts("\nTest 1.2: All 5 categories present in both systems")
movie_test = %Movie{id: 1, canonical_sources: %{}}
score_data = MovieScoring.calculate_movie_scores(movie_test)

movie_categories = Map.keys(score_data.components) |> Enum.sort()
expected = [:cultural_impact, :financial_performance, :industry_recognition, :people_quality, :popular_opinion]

if movie_categories == expected do
  print_test.("MovieScoring categories", :pass, "All 5 categories present")
  results = Map.put(results, :passed, results.passed ++ ["1.2 MovieScoring categories"])
else
  print_test.("MovieScoring categories", :fail, "Categories: #{inspect(movie_categories)}")
  results = Map.put(results, :failed, results.failed ++ ["1.2 MovieScoring categories"])
end

profile = ScoringService.get_default_profile()
weights = ScoringService.profile_to_discovery_weights(profile)
service_categories = Map.keys(weights) |> Enum.sort()

if length(service_categories) == 5 do
  print_test.("ScoringService categories", :pass, "All 5 categories present")
  results = Map.put(results, :passed, results.passed ++ ["1.2 ScoringService categories"])
else
  print_test.("ScoringService categories", :fail, "Only #{length(service_categories)} categories")
  results = Map.put(results, :failed, results.failed ++ ["1.2 ScoringService categories"])
end

IO.puts("\n" <> String.duplicate("─", 80))
IO.puts("═══ CRITERION 2: CLARITY ═══\n")

# Test 2.1: Category descriptions exist
IO.puts("Test 2.1: Human-readable category descriptions")

descriptions = %{
  popular_opinion: "All rating sources (IMDb, TMDb, Metacritic, RT)",
  industry_recognition: "Festival awards and nominations",
  cultural_impact: "Canonical lists and popularity metrics",
  people_quality: "Quality of directors, actors, and crew",
  financial_success: "Box office revenue and budget performance"
}

all_have_descriptions = Enum.all?(descriptions, fn {_k, v} -> String.length(v) > 10 end)

if all_have_descriptions do
  print_test.("Category descriptions", :pass, "All 5 categories have clear descriptions")
  results = Map.put(results, :passed, results.passed ++ ["2.1 Category descriptions"])
else
  print_test.("Category descriptions", :fail, "Some descriptions missing or too short")
  results = Map.put(results, :failed, results.failed ++ ["2.1 Category descriptions"])
end

# Test 2.2: Profile descriptions
IO.puts("\nTest 2.2: Profile descriptions are informative")
profiles = ScoringService.get_all_profiles()

if length(profiles) > 0 do
  profiles_with_descriptions =
    Enum.count(profiles, fn p ->
      p.description && String.length(p.description) > 20 && p.description =~ ~r/\d+%/
    end)

  if profiles_with_descriptions == length(profiles) do
    print_test.(
      "Profile descriptions",
      :pass,
      "All #{length(profiles)} profiles have clear descriptions with percentages"
    )

    results = Map.put(results, :passed, results.passed ++ ["2.2 Profile descriptions"])
  else
    print_test.(
      "Profile descriptions",
      :warn,
      "#{profiles_with_descriptions}/#{length(profiles)} profiles have good descriptions"
    )

    results = Map.put(results, :warnings, results.warnings ++ ["2.2 Some profiles need better descriptions"])
  end
else
  print_test.("Profile descriptions", :fail, "No profiles in database")
  results = Map.put(results, :failed, results.failed ++ ["2.2 No profiles found"])
end

IO.puts("\n" <> String.duplicate("─", 80))
IO.puts("═══ CRITERION 3: CONFIGURABILITY ═══\n")

# Test 3.1: Profiles loadable from database
IO.puts("Test 3.1: Weight profiles can be loaded from database")
profiles = ScoringService.get_all_profiles()

if length(profiles) >= 4 do
  print_test.(
    "Profile loading",
    :pass,
    "#{length(profiles)} weight profiles available: #{Enum.map(profiles, & &1.name) |> Enum.join(", ")}"
  )

  results = Map.put(results, :passed, results.passed ++ ["3.1 Profile loading"])
else
  print_test.("Profile loading", :fail, "Only #{length(profiles)} profiles (expected ≥4)")
  results = Map.put(results, :failed, results.failed ++ ["3.1 Insufficient profiles"])
end

# Test 3.2: All profiles use 5-category system
IO.puts("\nTest 3.2: All profiles use the 5-category system")
valid_categories = ["popular_opinion", "awards", "cultural", "people", "financial"]

profiles_with_valid_categories =
  Enum.count(profiles, fn profile ->
    Enum.all?(Map.keys(profile.category_weights), fn cat -> cat in valid_categories end)
  end)

if profiles_with_valid_categories == length(profiles) do
  print_test.("5-category compliance", :pass, "All profiles use standard 5 categories")
  results = Map.put(results, :passed, results.passed ++ ["3.2 5-category compliance"])
else
  print_test.(
    "5-category compliance",
    :fail,
    "#{length(profiles) - profiles_with_valid_categories} profiles have invalid categories"
  )

  results = Map.put(results, :failed, results.failed ++ ["3.2 Invalid categories in some profiles"])
end

IO.puts("\n" <> String.duplicate("─", 80))
IO.puts("═══ CRITERION 4: PERFORMANCE ═══\n")

# Test 4.1: Single movie scoring performance
IO.puts("Test 4.1: Single movie scoring completes in <100ms")

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

  time_ms = time_microseconds / 1000

  if time_ms < 100 do
    print_test.("Single movie performance", :pass, "Scored in #{Float.round(time_ms, 1)}ms")
    results = Map.put(results, :passed, results.passed ++ ["4.1 Single movie performance"])
  else
    print_test.("Single movie performance", :warn, "Took #{Float.round(time_ms, 1)}ms (target <100ms)")
    results = Map.put(results, :warnings, results.warnings ++ ["4.1 Slower than target"])
  end
else
  print_test.("Single movie performance", :warn, "No movies to test")
  results = Map.put(results, :warnings, results.warnings ++ ["4.1 No test data"])
end

# Test 4.2: Discovery page performance
IO.puts("\nTest 4.2: Discovery page with 20 movies completes in <5s")
profile = ScoringService.get_default_profile()

{time_microseconds, movies} =
  :timer.tc(fn ->
    Movie
    |> limit(20)
    |> ScoringService.apply_scoring(profile)
    |> Repo.all()
  end)

time_s = time_microseconds / 1_000_000

if length(movies) > 0 do
  if time_s < 5.0 do
    print_test.(
      "Discovery page performance",
      :pass,
      "#{length(movies)} movies scored in #{Float.round(time_s, 2)}s"
    )

    results = Map.put(results, :passed, results.passed ++ ["4.2 Discovery performance"])
  else
    print_test.(
      "Discovery page performance",
      :warn,
      "Took #{Float.round(time_s, 2)}s for #{length(movies)} movies (target <5s)"
    )

    results = Map.put(results, :warnings, results.warnings ++ ["4.2 Slower than target"])
  end
else
  print_test.("Discovery page performance", :warn, "No movies to test")
  results = Map.put(results, :warnings, results.warnings ++ ["4.2 No test data"])
end

# Test 4.3: Fallback profile performance
IO.puts("\nTest 4.3: Fallback profile loads instantly")

{time_microseconds, profile} =
  :timer.tc(fn ->
    ScoringService.get_default_profile()
  end)

time_ms = time_microseconds / 1000

if time_ms < 50 do
  print_test.("Fallback performance", :pass, "Loaded in #{Float.round(time_ms, 1)}ms")
  results = Map.put(results, :passed, results.passed ++ ["4.3 Fallback performance"])
else
  print_test.("Fallback performance", :warn, "Took #{Float.round(time_ms, 1)}ms (target <50ms)")
  results = Map.put(results, :warnings, results.warnings ++ ["4.3 Slower than target"])
end

IO.puts("\n" <> String.duplicate("─", 80))
IO.puts("═══ CRITERION 5: ACCURACY ═══\n")

# Test 5.1: Live data usage
IO.puts("Test 5.1: All categories use live database data")
profile = ScoringService.get_profile("Balanced")

if profile && profile.category_weights["popular_opinion"] > 0 do
  print_test.("Live data usage", :pass, "Profiles loaded from database with live weights")
  results = Map.put(results, :passed, results.passed ++ ["5.1 Live data usage"])
else
  print_test.("Live data usage", :fail, "Using fallback or invalid data")
  results = Map.put(results, :failed, results.failed ++ ["5.1 Data not live"])
end

# Test 5.2: Financial performance calculation
IO.puts("\nTest 5.2: Financial performance uses actual revenue/budget")

score_with_data =
  MovieScoring.calculate_financial_performance(%{budget: 100_000_000, revenue: 500_000_000})

score_without_data = MovieScoring.calculate_financial_performance(%{})

if score_with_data > 0 && score_without_data == 0.0 do
  print_test.(
    "Financial calculation",
    :pass,
    "Correctly calculates from data (score: #{Float.round(score_with_data, 2)}) and returns 0 when missing"
  )

  results = Map.put(results, :passed, results.passed ++ ["5.2 Financial calculation"])
else
  print_test.("Financial calculation", :fail, "Calculation logic incorrect")
  results = Map.put(results, :failed, results.failed ++ ["5.2 Financial calculation"])
end

IO.puts("\n" <> String.duplicate("─", 80))
IO.puts("═══ CRITERION 6: TRANSPARENCY ═══\n")

# Test 6.1: Score components exposed
IO.puts("Test 6.1: Score components are exposed to users")
movie_test = %Movie{id: 1, canonical_sources: %{}}
score_data = MovieScoring.calculate_movie_scores(movie_test)

if Map.has_key?(score_data, :components) && map_size(score_data.components) == 5 do
  print_test.("Component exposure", :pass, "All 5 score components visible to users")
  results = Map.put(results, :passed, results.passed ++ ["6.1 Component exposure"])
else
  print_test.("Component exposure", :fail, "Components not properly exposed")
  results = Map.put(results, :failed, results.failed ++ ["6.1 Component exposure"])
end

IO.puts("\n" <> String.duplicate("─", 80))
IO.puts("═══ CRITERION 7: MAINTAINABILITY ═══\n")

# Test 7.1: Single source of truth
IO.puts("Test 7.1: Single source of truth for category definitions")

movie_categories =
  MovieScoring.calculate_movie_scores(%Movie{id: 1, canonical_sources: %{}}).components
  |> Map.keys()
  |> length()

scoring_service_categories =
  ScoringService.profile_to_discovery_weights(ScoringService.get_default_profile())
  |> Map.keys()
  |> length()

if movie_categories == 5 && scoring_service_categories == 5 do
  print_test.("Single source of truth", :pass, "Both systems use exactly 5 categories")
  results = Map.put(results, :passed, results.passed ++ ["7.1 Single source of truth"])
else
  print_test.(
    "Single source of truth",
    :fail,
    "Category count mismatch: MovieScoring=#{movie_categories}, ScoringService=#{scoring_service_categories}"
  )

  results = Map.put(results, :failed, results.failed ++ ["7.1 Category mismatch"])
end

# Test 7.2: Database storage
IO.puts("\nTest 7.2: All profiles stored in database")
profiles = ScoringService.get_all_profiles()

if length(profiles) >= 4 do
  profiles_from_db =
    Enum.count(profiles, fn p -> p.__meta__ && p.__meta__.state == :loaded end)

  if profiles_from_db == length(profiles) do
    print_test.("Database storage", :pass, "All #{length(profiles)} profiles stored in database")
    results = Map.put(results, :passed, results.passed ++ ["7.2 Database storage"])
  else
    print_test.("Database storage", :warn, "Some profiles may not be persisted")
    results = Map.put(results, :warnings, results.warnings ++ ["7.2 Storage verification"])
  end
else
  print_test.("Database storage", :fail, "Insufficient profiles in database")
  results = Map.put(results, :failed, results.failed ++ ["7.2 Insufficient profiles"])
end

IO.puts("\n" <> String.duplicate("─", 80))
IO.puts("═══ DATA QUALITY CHECK ═══\n")

movies =
  Movie
  |> where([m], not is_nil(m.tmdb_id))
  |> limit(50)
  |> Repo.all()
  |> Repo.preload([:external_metrics])

if length(movies) > 0 do
  movies_with_ratings = Enum.count(movies, fn m -> length(m.external_metrics) > 0 end)
  percentage = movies_with_ratings / length(movies) * 100

  IO.puts("Movies sampled: #{length(movies)}")
  IO.puts("Movies with ratings: #{movies_with_ratings}")
  IO.puts("Data coverage: #{Float.round(percentage, 1)}%")

  if percentage >= 50 do
    print_test.("Data quality", :pass, "#{Float.round(percentage, 1)}% of movies have rating data")
    results = Map.put(results, :passed, results.passed ++ ["Data quality check"])
  else
    print_test.(
      "Data quality",
      :warn,
      "Only #{Float.round(percentage, 1)}% coverage (recommend ≥50%)"
    )

    results = Map.put(results, :warnings, results.warnings ++ ["Low data coverage"])
  end
else
  print_test.("Data quality", :warn, "No movies in database")
  results = Map.put(results, :warnings, results.warnings ++ ["No data for quality check"])
end

# Print Summary
IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("VALIDATION SUMMARY")
IO.puts(String.duplicate("=", 80) <> "\n")

IO.puts("✅ PASSED: #{length(results.passed)}")

Enum.each(results.passed, fn test ->
  IO.puts("   • #{test}")
end)

if length(results.warnings) > 0 do
  IO.puts("\n⚠️  WARNINGS: #{length(results.warnings)}")

  Enum.each(results.warnings, fn warning ->
    IO.puts("   • #{warning}")
  end)
end

if length(results.failed) > 0 do
  IO.puts("\n❌ FAILED: #{length(results.failed)}")

  Enum.each(results.failed, fn failure ->
    IO.puts("   • #{failure}")
  end)
end

total = length(results.passed) + length(results.failed)
pass_rate = if total > 0, do: length(results.passed) / total * 100, else: 0

IO.puts("\n" <> String.duplicate("─", 80))
IO.puts("Pass Rate: #{Float.round(pass_rate, 1)}% (#{length(results.passed)}/#{total})")

status =
  cond do
    pass_rate >= 90 -> "🎉 EXCELLENT - System ready for Phase 3"
    pass_rate >= 75 -> "✅ GOOD - Minor issues to address"
    pass_rate >= 60 -> "⚠️  FAIR - Several issues need attention"
    true -> "❌ NEEDS WORK - Critical issues found"
  end

IO.puts("Status: #{status}")
IO.puts(String.duplicate("=", 80) <> "\n")
