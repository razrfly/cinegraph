#!/usr/bin/env elixir

# Test the Movie Prediction System
IO.puts("🎬 Testing Movie Prediction System...")
IO.puts("=====================================\n")

import Ecto.Query
alias Cinegraph.Predictions.{MoviePredictor, CriteriaScoring}
alias Cinegraph.Movies.Movie
alias Cinegraph.Repo

# Test 1: Get 2020s movies
IO.puts("1. Testing movie retrieval...")

movies =
  Repo.all(
    from m in Movie,
      where: m.release_date >= ^~D[2020-01-01],
      where: m.release_date < ^~D[2030-01-01],
      where: m.import_status == "full",
      where: is_nil(fragment("? -> ?", m.canonical_sources, "1001_movies")),
      limit: 5
  )

if length(movies) > 0 do
  IO.puts("   ✅ Found #{length(movies)} 2020s movies")

  # Test 2: Score a single movie
  IO.puts("\n2. Testing individual movie scoring...")
  movie = hd(movies)
  score = CriteriaScoring.calculate_movie_score(movie)

  IO.puts("   Movie: #{movie.title}")
  IO.puts("   Total Score: #{score.total_score}")
  IO.puts("   Likelihood: #{score.likelihood_percentage}%")

  if score.likelihood_percentage > 0 and score.likelihood_percentage <= 100 do
    IO.puts("   ✅ Individual scoring works correctly")
  else
    IO.puts("   ❌ Individual scoring returned invalid value: #{score.likelihood_percentage}%")
  end

  # Test 3: Batch score movies
  IO.puts("\n3. Testing batch scoring...")
  batch_results = CriteriaScoring.batch_score_movies(Enum.take(movies, 3))

  Enum.each(batch_results, fn result ->
    likelihood = result.prediction.likelihood_percentage
    IO.puts("   #{result.movie.title}: #{likelihood}%")

    if likelihood <= 0 or likelihood > 100 do
      IO.puts("   ⚠️ WARNING: Invalid likelihood value!")
    end
  end)

  valid_results =
    Enum.filter(batch_results, fn r ->
      r.prediction.likelihood_percentage > 0 and
        r.prediction.likelihood_percentage <= 100
    end)

  if length(valid_results) == length(batch_results) do
    IO.puts("   ✅ Batch scoring works correctly")
  else
    IO.puts(
      "   ❌ Batch scoring has issues: #{length(valid_results)}/#{length(batch_results)} valid"
    )
  end

  # Test 4: Full prediction function
  IO.puts("\n4. Testing full prediction system...")
  result = MoviePredictor.predict_2020s_movies(10)

  IO.puts("   Total candidates: #{result.total_candidates}")
  IO.puts("   Predictions generated: #{length(result.predictions)}")

  if length(result.predictions) > 0 do
    top = hd(result.predictions)
    IO.puts("   Top prediction: #{top.title} (#{top.prediction.likelihood_percentage}%)")

    # Check if all predictions have valid percentages
    invalid =
      Enum.filter(result.predictions, fn p ->
        p.prediction.likelihood_percentage <= 0 or
          p.prediction.likelihood_percentage > 100
      end)

    if length(invalid) == 0 do
      IO.puts("   ✅ All predictions have valid likelihood percentages")
    else
      IO.puts("   ❌ #{length(invalid)} predictions have invalid percentages")
    end
  else
    IO.puts("   ❌ No predictions generated!")
  end
else
  IO.puts("   ❌ No 2020s movies found in database")
end

IO.puts("\n✅ Test complete!")
