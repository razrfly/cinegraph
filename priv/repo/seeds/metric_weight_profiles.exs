# Seed file for metric weight profiles
# Run with: mix run priv/repo/seeds/metric_weight_profiles.exs

alias Cinegraph.Repo
import Ecto.Query

# Clear existing profiles
Repo.delete_all(from mwp in "metric_weight_profiles")

weight_profiles = [
  %{
    name: "Balanced",
    description: "Equal weight across critical acclaim, cultural impact, industry recognition, and popular opinion",
    weights: %{
      # Critical Acclaim (25%)
      "metacritic_metascore" => 1.0,
      "rotten_tomatoes_tomatometer" => 1.0,
      
      # Popular Opinion (25%)  
      "imdb_rating" => 1.0,
      "tmdb_rating" => 1.0,
      "imdb_rating_votes" => 0.5,
      "rotten_tomatoes_audience_score" => 0.8,
      
      # Industry Recognition (25%)
      "oscar_wins" => 2.0,
      "oscar_nominations" => 1.0,
      "cannes_palme_dor" => 1.5,
      "venice_golden_lion" => 1.5,
      "berlin_golden_bear" => 1.5,
      
      # Cultural Impact (25%)
      "1001_movies" => 1.5,
      "criterion" => 1.5,
      "national_film_registry" => 1.5,
      "sight_sound_critics_2022" => 1.5,
      "afi_top_100" => 1.0,
      "bfi_top_100" => 1.0,
      
      # Financial (included but lower weight in balanced)
      "tmdb_revenue_worldwide" => 0.5,
      "tmdb_budget" => 0.3
    },
    category_weights: %{
      "ratings" => 1.0,
      "awards" => 1.0,
      "financial" => 0.5,
      "cultural" => 1.0
    },
    active: true,
    is_default: true,
    is_system: true
  },
  
  %{
    name: "Award Winner",
    description: "Emphasizes festival awards and industry recognition",
    weights: %{
      # Industry Recognition (50%)
      "oscar_wins" => 3.0,
      "oscar_nominations" => 2.0,
      "cannes_palme_dor" => 2.5,
      "venice_golden_lion" => 2.5,
      "berlin_golden_bear" => 2.5,
      
      # Critical Acclaim (30%)
      "metacritic_metascore" => 1.5,
      "rotten_tomatoes_tomatometer" => 1.5,
      
      # Cultural Impact (15%)
      "1001_movies" => 1.0,
      "criterion" => 1.0,
      "sight_sound_critics_2022" => 1.0,
      
      # Popular Opinion (5%)
      "imdb_rating" => 0.5,
      "tmdb_rating" => 0.5
    },
    category_weights: %{
      "ratings" => 0.5,
      "awards" => 2.0,
      "financial" => 0.2,
      "cultural" => 0.8
    },
    active: true,
    is_default: false,
    is_system: true
  },
  
  %{
    name: "Critics Choice",
    description: "Prioritizes critical acclaim from professional reviewers",
    weights: %{
      # Critical Acclaim (50%)
      "metacritic_metascore" => 2.5,
      "rotten_tomatoes_tomatometer" => 2.5,
      
      # Cultural Impact (30%)
      "sight_sound_critics_2022" => 2.0,
      "criterion" => 2.0,
      "1001_movies" => 1.5,
      "national_film_registry" => 1.5,
      
      # Industry Recognition (15%)
      "oscar_wins" => 1.0,
      "oscar_nominations" => 0.8,
      "cannes_palme_dor" => 1.0,
      
      # Popular Opinion (5%)
      "imdb_rating" => 0.3,
      "tmdb_rating" => 0.3
    },
    category_weights: %{
      "ratings" => 1.5,  # But only critic ratings weighted high
      "awards" => 0.8,
      "financial" => 0.1,
      "cultural" => 1.2
    },
    active: true,
    is_default: false,
    is_system: true
  },
  
  %{
    name: "Crowd Pleaser", 
    description: "Focuses on popular opinion and box office success",
    weights: %{
      # Popular Opinion (50%)
      "imdb_rating" => 2.5,
      "tmdb_rating" => 2.0,
      "imdb_rating_votes" => 1.5,
      "rotten_tomatoes_audience_score" => 2.0,
      
      # Financial Success (30%)
      "tmdb_revenue_worldwide" => 2.0,
      "tmdb_budget" => 0.5,
      "omdb_revenue_domestic" => 1.5,
      
      # Industry Recognition (15%)
      "oscar_wins" => 0.5,
      "oscar_nominations" => 0.3,
      
      # Critical Acclaim (5%)
      "metacritic_metascore" => 0.3,
      "rotten_tomatoes_tomatometer" => 0.3
    },
    category_weights: %{
      "ratings" => 2.0,  # Audience ratings weighted high
      "awards" => 0.3,
      "financial" => 1.5,
      "cultural" => 0.2
    },
    active: true,
    is_default: false,
    is_system: true
  },
  
  %{
    name: "Cult Classic",
    description: "Finds films with dedicated followings despite mainstream metrics",
    weights: %{
      # Cultural Lists (40%)
      "criterion" => 2.5,
      "1001_movies" => 2.0,
      "sight_sound_critics_2022" => 1.5,
      
      # Moderate ratings with specific engagement patterns (30%)
      "imdb_rating" => 1.0,
      "metacritic_metascore" => 0.8,
      "imdb_rating_votes" => -0.5,  # Negative weight for too popular
      
      # Festival presence (20%)
      "cannes_palme_dor" => 1.5,
      "venice_golden_lion" => 1.5,
      "berlin_golden_bear" => 1.5,
      
      # Low financial success (10%)
      "tmdb_revenue_worldwide" => -0.3,  # Negative weight for blockbusters
      "tmdb_budget" => -0.2
    },
    category_weights: %{
      "ratings" => 0.8,
      "awards" => 0.6,
      "financial" => -0.2,  # Penalize high revenue
      "cultural" => 2.0
    },
    active: true,
    is_default: false,
    is_system: true
  }
]

# Insert all weight profiles
now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

Enum.each(weight_profiles, fn profile ->
  Repo.insert_all("metric_weight_profiles", [
    Map.merge(profile, %{
      usage_count: 0,
      last_used_at: nil,
      inserted_at: now,
      updated_at: now
    })
  ])
end)

IO.puts "Inserted #{length(weight_profiles)} metric weight profiles"