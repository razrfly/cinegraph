# Test script for the Tunable Movie Discovery System

import Ecto.Query

alias Cinegraph.Movies
alias Cinegraph.Movies.DiscoveryScoringSimple, as: DiscoveryScoring
alias Cinegraph.Repo

IO.puts("Testing Tunable Movie Discovery System")
IO.puts("=" |> String.duplicate(50))

# Test with different presets
presets = DiscoveryScoring.get_presets()

Enum.each(presets, fn {preset_name, weights} ->
  IO.puts("\n#{preset_name |> to_string() |> String.upcase()} PRESET")
  IO.puts("-" |> String.duplicate(30))
  
  IO.puts("Weights:")
  Enum.each(weights, fn {dimension, weight} ->
    IO.puts("  #{dimension}: #{Float.round(weight * 100, 1)}%")
  end)
  
  # Get top 5 movies with this preset
  movies = 
    Movies.Movie
    |> DiscoveryScoring.apply_scoring(weights, %{min_score: 0.2})
    |> limit(5)
    |> Repo.all()
    |> Repo.preload([:genres])
  
  IO.puts("\nTop 5 Movies:")
  Enum.with_index(movies, 1) |> Enum.each(fn {movie, index} ->
    IO.puts("#{index}. #{movie.title} (#{movie.release_date && movie.release_date.year})")
    
    if movie[:discovery_score] do
      IO.puts("   Total Score: #{Float.round(movie.discovery_score * 100, 1)}%")
    end
    
    if movie[:score_components] do
      IO.puts("   Components:")
      Enum.each(movie.score_components, fn {dimension, score} ->
        if is_float(score) do
          IO.puts("     #{dimension}: #{Float.round(score * 100, 1)}%")
        end
      end)
    end
  end)
end)

# Test custom weights
IO.puts("\n" <> "=" |> String.duplicate(50))
IO.puts("CUSTOM WEIGHTS TEST")
IO.puts("-" |> String.duplicate(30))

custom_weights = %{
  popular_opinion: 0.1,
  critical_acclaim: 0.1,
  industry_recognition: 0.7,  # Heavy emphasis on awards
  cultural_impact: 0.1
}

IO.puts("Custom weights (awards-focused):")
Enum.each(custom_weights, fn {dimension, weight} ->
  IO.puts("  #{dimension}: #{Float.round(weight * 100, 1)}%")
end)

movies = 
  Movies.Movie
  |> DiscoveryScoring.apply_scoring(custom_weights, %{min_score: 0.1})
  |> limit(10)
  |> Repo.all()
  |> Repo.preload([:genres])

IO.puts("\nTop 10 Movies with Awards Focus:")
Enum.with_index(movies, 1) |> Enum.each(fn {movie, index} ->
  IO.puts("#{index}. #{movie.title} (#{movie.release_date && movie.release_date.year})")
  
  if movie[:discovery_score] do
    IO.puts("   Total Score: #{Float.round(movie.discovery_score * 100, 1)}%")
  end
end)

IO.puts("\n" <> "=" |> String.duplicate(50))
IO.puts("Discovery Scoring System Test Complete!")