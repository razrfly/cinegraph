# Seed file for metric weight profiles
# Run with: mix run priv/repo/seeds/metric_weight_profiles.exs

alias Cinegraph.Repo
import Ecto.Query

# Only clear system profiles to preserve user-created ones
Repo.delete_all(from mwp in "metric_weight_profiles", where: field(mwp, :is_system) == true)

weight_profiles = [
  %{
    name: "Balanced",
    description: "Equal weight across critical acclaim, cultural impact, industry recognition, and popular opinion",
    weights: %{
      # Critical Acclaim
      "metacritic_metascore" => 1.0,
      "rotten_tomatoes_tomatometer" => 1.0,
      
      # Popular Opinion
      "imdb_rating" => 1.0,
      "tmdb_rating" => 1.0,
      "imdb_rating_votes" => 0.5,
      "rotten_tomatoes_audience_score" => 0.8,
      
      # Industry Recognition
      "oscar_wins" => 2.0,
      "oscar_nominations" => 1.0,
      "cannes_palme_dor" => 1.5,
      "venice_golden_lion" => 1.5,
      "berlin_golden_bear" => 1.5,
      
      # Cultural Impact
      "1001_movies" => 1.5,
      "criterion" => 1.5,
      "national_film_registry" => 1.5,
      "sight_sound_critics_2022" => 1.5,
      "afi_top_100" => 1.0,
      "bfi_top_100" => 1.0,
      
      # Financial (included but lower weight in balanced)
      "tmdb_revenue_worldwide" => 0.5,
      "tmdb_budget" => 0.3,
      
      # People Quality
      "person_quality_score" => 1.5
    },
    category_weights: %{
      "ratings" => 0.40,     # 40% (Popular + Critical combined, reduced from 50%)
      "awards" => 0.20,      # 20% (reduced from 25%)
      "financial" => 0.00,   # 0% (not used in current scoring)
      "cultural" => 0.20,    # 20% (reduced from 25%)
      "people" => 0.20       # 20% (new - person quality scores)
    },
    active: true,
    is_default: true,
    is_system: true
  },
  
  %{
    name: "Award Winner",
    description: "Emphasizes festival awards and industry recognition (50% awards, 20% critics, 20% cultural, 10% popular)",
    weights: %{
      # Industry Recognition (50%)
      "oscar_wins" => 3.0,
      "oscar_nominations" => 2.0,
      "cannes_palme_dor" => 2.5,
      "venice_golden_lion" => 2.5,
      "berlin_golden_bear" => 2.5,
      
      # Critical Acclaim (20%)
      "metacritic_metascore" => 1.5,
      "rotten_tomatoes_tomatometer" => 1.5,
      
      # Cultural Impact (20%)
      "1001_movies" => 1.0,
      "criterion" => 1.0,
      "sight_sound_critics_2022" => 1.0,
      
      # Popular Opinion (10%)
      "imdb_rating" => 0.5,
      "tmdb_rating" => 0.5,
      
      # People Quality (10%)
      "person_quality_score" => 1.0
    },
    category_weights: %{
      "ratings" => 0.25,     # 25% (reduced from 30%)
      "awards" => 0.45,      # 45% (reduced from 50%)
      "financial" => 0.00,   # 0%
      "cultural" => 0.20,    # 20% (unchanged)
      "people" => 0.10       # 10% (new - person quality scores)
    },
    active: true,
    is_default: false,
    is_system: true
  },
  
  %{
    name: "Critics Choice",
    description: "Prioritizes critical acclaim (45% critics) with cultural impact (30%), some awards (15%), minimal popular (10%)",
    weights: %{
      # Critical Acclaim (45%)
      "metacritic_metascore" => 3.0,
      "rotten_tomatoes_tomatometer" => 3.0,
      
      # Cultural Impact (30%)
      "sight_sound_critics_2022" => 2.0,
      "criterion" => 2.0,
      "1001_movies" => 1.5,
      "national_film_registry" => 1.5,
      
      # Industry Recognition (15%)
      "oscar_wins" => 1.0,
      "oscar_nominations" => 0.8,
      "cannes_palme_dor" => 1.0,
      
      # Popular Opinion (10%)
      "imdb_rating" => 0.3,
      "tmdb_rating" => 0.3,
      
      # People Quality (5%)
      "person_quality_score" => 0.5
    },
    category_weights: %{
      "ratings" => 0.50,     # 50% (reduced from 55%, critics still favored)
      "awards" => 0.15,      # 15% (unchanged)
      "financial" => 0.00,   # 0%
      "cultural" => 0.30,    # 30% (unchanged)
      "people" => 0.05       # 5% (new - minimal for critics choice)
    },
    active: true,
    is_default: false,
    is_system: true
  },
  
  %{
    name: "Crowd Pleaser", 
    description: "Focuses on popular opinion (40%), with some awards (15%), minimal critics (10%), and cultural (35%)",
    weights: %{
      # Popular Opinion (40%)
      "imdb_rating" => 2.5,
      "tmdb_rating" => 2.0,
      "imdb_rating_votes" => 1.5,
      "rotten_tomatoes_audience_score" => 2.0,
      
      # Financial Success (not directly in categories but influences cultural)
      "tmdb_revenue_worldwide" => 2.0,
      "tmdb_budget" => 0.5,
      
      # Industry Recognition (15%)
      "oscar_wins" => 0.5,
      "oscar_nominations" => 0.3,
      
      # Critical Acclaim (10%)
      "metacritic_metascore" => 0.3,
      "rotten_tomatoes_tomatometer" => 0.3,
      
      # People Quality (5%)
      "person_quality_score" => 0.5
    },
    category_weights: %{
      "ratings" => 0.40,     # 40% (reduced from 45%)
      "awards" => 0.10,      # 10% (unchanged)
      "financial" => 0.10,   # 10% (box office success matters for crowd pleasers)
      "cultural" => 0.35,    # 35% (includes popularity metrics)
      "people" => 0.05       # 5% (new - minimal for crowd pleasers)
    },
    active: true,
    is_default: false,
    is_system: true
  },
  
  %{
    name: "Cult Classic",
    description: "Finds films with dedicated followings: cultural lists (40%), moderate ratings (35%), some awards (10%), popularity (15%)",
    weights: %{
      # Cultural Lists (40%)
      "criterion" => 2.5,
      "1001_movies" => 2.0,
      "sight_sound_critics_2022" => 1.5,
      
      # Moderate ratings with specific engagement patterns (35%)
      "imdb_rating" => 1.0,
      "metacritic_metascore" => 0.8,
      "imdb_rating_votes" => 0.3,  # Some votes but not too mainstream
      
      # Festival presence (10%)
      "cannes_palme_dor" => 1.5,
      "venice_golden_lion" => 1.5,
      "berlin_golden_bear" => 1.5,
      
      # People Quality (15% - important for cult films)
      "person_quality_score" => 2.0
      
      # Note: Financial metrics intentionally excluded
      # Cult classics often have low box office but high cultural impact
      # Setting these to 0 or excluding them entirely
    },
    category_weights: %{
      "ratings" => 0.40,     # 40% (reduced from 50%)
      "awards" => 0.10,      # 10% (unchanged)
      "financial" => 0.00,   # 0%
      "cultural" => 0.35,    # 35% (reduced from 40%)
      "people" => 0.15       # 15% (new - important for cult classics)
    },
    active: true,
    is_default: false,
    is_system: true
  }
]

# Insert or update all system profiles idempotently
now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

# Validate profiles before inserting
Enum.each(weight_profiles, fn profile ->
  weights = profile.category_weights || %{}
  
  # Check relevant weights (excluding financial which is typically 0)
  relevant_weights = Map.take(weights, ["ratings", "awards", "cultural", "people"])
  sum = Map.values(relevant_weights) |> Enum.sum()
  
  # Provide detailed validation feedback
  cond do
    sum > 1.01 ->
      IO.puts "WARNING: #{profile.name} category weights sum to #{Float.round(sum, 4)} (> 1.01)"
      IO.puts "  Breakdown: ratings=#{weights["ratings"]}, awards=#{weights["awards"]}, cultural=#{weights["cultural"]}, people=#{weights["people"]}"
    sum < 0.99 ->
      IO.puts "WARNING: #{profile.name} category weights sum to #{Float.round(sum, 4)} (< 0.99)"
      IO.puts "  Breakdown: ratings=#{weights["ratings"]}, awards=#{weights["awards"]}, cultural=#{weights["cultural"]}, people=#{weights["people"]}"
    true ->
      :ok
  end
  
  # Also warn if financial weights are defined but category weight is 0
  financial_weight = weights["financial"] || 0.0
  if financial_weight == 0.0 do
    profile_weights = profile.weights || %{}
    financial_metrics = ["tmdb_revenue_worldwide", "tmdb_budget", "omdb_revenue_domestic"]
    defined_financial = Enum.filter(financial_metrics, fn metric ->
      Map.get(profile_weights, metric, 0.0) > 0
    end)
    
    if length(defined_financial) > 0 do
      IO.puts "INFO: #{profile.name} has financial metric weights defined but financial category weight is 0:"
      IO.puts "  Unused metrics: #{Enum.join(defined_financial, ", ")}"
    end
  end
end)

entries =
  Enum.map(weight_profiles, fn profile ->
    Map.merge(profile, %{
      usage_count: 0,
      last_used_at: nil,
      inserted_at: now,
      updated_at: now
    })
  end)

# Requires a unique index on metric_weight_profiles.name
Repo.insert_all(
  "metric_weight_profiles",
  entries,
  conflict_target: [:name],
  on_conflict: {:replace, [:description, :weights, :category_weights, :active, :is_default, :is_system, :updated_at]}
)

IO.puts "Upserted #{length(weight_profiles)} metric weight profiles"