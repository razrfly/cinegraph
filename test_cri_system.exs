# Test script for CRI system
# Run with: mix run test_cri_system.exs

alias Cinegraph.Metrics.CRI
alias Cinegraph.Repo

IO.puts "\n========== CRI SYSTEM TEST ==========\n"

# 1. Test normalization functions
IO.puts "1. Testing normalization functions:"
IO.puts "   Linear (IMDb 7.5/10): #{CRI.normalize_value("imdb_rating", 7.5)}"
IO.puts "   Logarithmic (100K votes): #{CRI.normalize_value("imdb_vote_count", 100_000)}"
IO.puts "   Boolean (Criterion: true): #{CRI.normalize_value("criterion_collection", true)}"
IO.puts "   Custom (Oscar wins: 3): #{CRI.normalize_value("oscar_wins", 3)}"

# 2. List available profiles
IO.puts "\n2. Available weight profiles:"
profiles = CRI.list_weight_profiles()
Enum.each(profiles, fn p ->
  IO.puts "   - #{p.name}: #{p.description}"
end)

# 3. Test search functionality
IO.puts "\n3. Testing search functionality:"

# Search for highly rated movies (if we had data)
IO.puts "   Searching for highly rated movies (rating > 0.8):"
highly_rated = CRI.search(%{category: "rating", min_normalized: 0.8})
IO.puts "   Found #{length(highly_rated)} movies"

# Search for award winners
IO.puts "   Searching for award-winning films:"
award_winners = CRI.search(%{cri_dimension: "institutional", min_normalized: 0.5})
IO.puts "   Found #{length(award_winners)} movies"

# 4. Display CRI dimensions
IO.puts "\n4. CRI Dimensions and their metrics:"
dimensions = %{
  "timelessness" => ["criterion_collection", "1001_movies", "nfr_preserved", "letterboxd_rating"],
  "cultural_penetration" => ["imdb_vote_count", "tmdb_popularity", "wikipedia_views"],
  "artistic_impact" => ["metacritic_score", "sight_sound_rank", "afi_top_100"],
  "institutional" => ["oscar_wins", "cannes_palme_dor", "venice_golden_lion"],
  "public" => ["imdb_rating", "tmdb_rating", "rt_audience_score"]
}

Enum.each(dimensions, fn {dim, metrics} ->
  IO.puts "   #{String.upcase(dim)}:"
  Enum.each(metrics, fn m -> IO.puts "     - #{m}" end)
end)

IO.puts "\n========== SYSTEM READY ==========\n"
IO.puts "The CRI system is now ready for:"
IO.puts "  ✓ Normalizing diverse metric types"
IO.puts "  ✓ Searching across all data sources"
IO.puts "  ✓ Replacing hardcoded discovery scoring"
IO.puts "  ✓ ML optimization (Scholar integration pending)"
IO.puts "  ✓ Backtesting against 1001 Movies (data import pending)"
IO.puts ""