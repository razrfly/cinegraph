# Seed file for metric weight profiles
# Run with: mix run priv/repo/seeds/metric_weight_profiles.exs

alias Cinegraph.Repo
import Ecto.Query

# Only clear system profiles to preserve user-created ones
Repo.delete_all(from mwp in "metric_weight_profiles", where: field(mwp, :is_system) == true)

weight_profiles = [
  %{
    name: "Balanced",
    description: "Balanced weight across all six criteria: mob (15%), ivory tower (15%), awards (20%), financial success (20%), cultural impact (15%), people quality (15%)",
    weights: %{
      # Mob (audience ratings)
      "imdb_rating" => 1.0,
      "tmdb_rating" => 1.0,
      "imdb_rating_votes" => 0.5,
      "rotten_tomatoes_audience_score" => 0.8,

      # Ivory Tower (critic ratings)
      "metacritic_metascore" => 1.0,
      "rotten_tomatoes_tomatometer" => 1.0,

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
      "mob" => 0.15,
      "ivory_tower" => 0.15,
      "awards" => 0.20,
      "financial" => 0.20,
      "cultural" => 0.15,
      "people" => 0.15
    },
    active: true,
    is_default: true,
    is_system: true
  },

  %{
    name: "Award Winner",
    description: "Emphasizes festival awards and industry recognition (45% awards, 20% cultural, 12.5% mob, 12.5% ivory tower, 10% people)",
    weights: %{
      # Industry Recognition (45%)
      "oscar_wins" => 3.0,
      "oscar_nominations" => 2.0,
      "cannes_palme_dor" => 2.5,
      "venice_golden_lion" => 2.5,
      "berlin_golden_bear" => 2.5,

      # Mob (12.5%)
      "imdb_rating" => 0.8,
      "tmdb_rating" => 0.8,

      # Ivory Tower (12.5%)
      "metacritic_metascore" => 1.0,
      "rotten_tomatoes_tomatometer" => 1.0,

      # Cultural Impact (20%)
      "1001_movies" => 1.0,
      "criterion" => 1.0,
      "sight_sound_critics_2022" => 1.0,

      # People Quality (10%)
      "person_quality_score" => 1.0
    },
    category_weights: %{
      "mob" => 0.125,
      "ivory_tower" => 0.125,
      "awards" => 0.45,
      "financial" => 0.00,
      "cultural" => 0.20,
      "people" => 0.10
    },
    active: true,
    is_default: false,
    is_system: true
  },

  %{
    name: "Critics Choice",
    description: "Prioritizes critic-favored platforms (25% mob, 25% ivory tower) with cultural impact (30%), some awards (15%), minimal people (5%)",
    weights: %{
      # Ivory Tower with critic platforms weighted higher (25%)
      "metacritic_metascore" => 3.0,
      "rotten_tomatoes_tomatometer" => 3.0,

      # Mob (25%)
      "imdb_rating" => 0.5,
      "tmdb_rating" => 0.5,

      # Cultural Impact (30%)
      "sight_sound_critics_2022" => 2.0,
      "criterion" => 2.0,
      "1001_movies" => 1.5,
      "national_film_registry" => 1.5,

      # Industry Recognition (15%)
      "oscar_wins" => 1.0,
      "oscar_nominations" => 0.8,
      "cannes_palme_dor" => 1.0,

      # People Quality (5%)
      "person_quality_score" => 0.5
    },
    category_weights: %{
      "mob" => 0.25,
      "ivory_tower" => 0.25,
      "awards" => 0.15,
      "financial" => 0.00,
      "cultural" => 0.30,
      "people" => 0.05
    },
    active: true,
    is_default: false,
    is_system: true
  },

  %{
    name: "Crowd Pleaser",
    description: "Focuses on mainstream audience (22.5% mob), cultural reach (35%), ivory tower (22.5%), minimal awards (10%), financial (10%)",
    weights: %{
      # Mob with mainstream platforms weighted higher (22.5%)
      "imdb_rating" => 2.5,
      "tmdb_rating" => 2.0,
      "imdb_rating_votes" => 1.5,
      "rotten_tomatoes_audience_score" => 2.0,

      # Ivory Tower (22.5%)
      "metacritic_metascore" => 0.5,
      "rotten_tomatoes_tomatometer" => 0.5,

      # Financial Success
      "tmdb_revenue_worldwide" => 2.0,
      "tmdb_budget" => 0.5,

      # Industry Recognition (10%)
      "oscar_wins" => 0.5,
      "oscar_nominations" => 0.3,

      # People Quality (5%)
      "person_quality_score" => 0.5
    },
    category_weights: %{
      "mob" => 0.225,
      "ivory_tower" => 0.225,
      "awards" => 0.10,
      "financial" => 0.10,
      "cultural" => 0.30,
      "people" => 0.05
    },
    active: true,
    is_default: false,
    is_system: true
  },

  %{
    name: "Cult Classic",
    description: "Finds films with dedicated followings: cultural lists (35%), moderate ratings (40% split mob/ivory), some awards (10%), people (15%)",
    weights: %{
      # Cultural Lists (35%)
      "criterion" => 2.5,
      "1001_movies" => 2.0,
      "sight_sound_critics_2022" => 1.5,

      # Mob (20%)
      "imdb_rating" => 1.0,
      "tmdb_rating" => 0.8,
      "imdb_rating_votes" => 0.3,

      # Ivory Tower (20%)
      "metacritic_metascore" => 0.8,
      "rotten_tomatoes_tomatometer" => 0.6,

      # Festival presence (10%)
      "cannes_palme_dor" => 1.5,
      "venice_golden_lion" => 1.5,
      "berlin_golden_bear" => 1.5,

      # People Quality (15% - important for cult films)
      "person_quality_score" => 2.0

      # Note: Financial metrics intentionally excluded
      # Cult classics often have low box office but high cultural impact
    },
    category_weights: %{
      "mob" => 0.20,
      "ivory_tower" => 0.20,
      "awards" => 0.10,
      "financial" => 0.00,
      "cultural" => 0.35,
      "people" => 0.15
    },
    active: true,
    is_default: false,
    is_system: true
  },

  %{
    name: "Cinegraph Editorial",
    description: "Calibrated against 1001 Movies You Must See Before You Die. Emphasizes cultural impact and critical consensus over popularity and financial metrics.",
    weights: %{
      # Ivory Tower (25%)
      "metacritic_metascore" => 2.0,
      "rotten_tomatoes_tomatometer" => 2.0,

      # Mob (10%)
      "imdb_rating" => 0.8,
      "tmdb_rating" => 0.8,
      "rotten_tomatoes_audience_score" => 0.5,

      # Industry Recognition (20%)
      "oscar_wins" => 2.0,
      "oscar_nominations" => 1.0,
      "cannes_palme_dor" => 2.0,
      "venice_golden_lion" => 2.0,
      "berlin_golden_bear" => 2.0,

      # Cultural Impact (30%)
      "1001_movies" => 2.0,
      "criterion" => 2.0,
      "sight_sound_critics_2022" => 2.0,
      "national_film_registry" => 1.5,
      "afi_top_100" => 1.0,

      # People Quality (10%)
      "person_quality_score" => 1.0,

      # Financial (5% — de-emphasized)
      "tmdb_revenue_worldwide" => 0.2,
      "tmdb_budget" => 0.1
    },
    category_weights: %{
      "mob" => 0.10,
      "ivory_tower" => 0.25,
      "awards" => 0.20,
      "cultural" => 0.30,
      "people" => 0.10,
      "financial" => 0.05
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

  relevant_weights =
    Map.take(weights, ["mob", "ivory_tower", "awards", "cultural", "people", "financial"])

  sum = Map.values(relevant_weights) |> Enum.sum()

  cond do
    sum > 1.01 ->
      IO.puts("WARNING: #{profile.name} category weights sum to #{Float.round(sum, 4)} (> 1.01)")

      IO.puts(
        "  Breakdown: mob=#{weights["mob"]}, ivory_tower=#{weights["ivory_tower"]}, awards=#{weights["awards"]}, cultural=#{weights["cultural"]}, people=#{weights["people"]}, financial=#{weights["financial"]}"
      )

    sum < 0.99 ->
      IO.puts("WARNING: #{profile.name} category weights sum to #{Float.round(sum, 4)} (< 0.99)")

      IO.puts(
        "  Breakdown: mob=#{weights["mob"]}, ivory_tower=#{weights["ivory_tower"]}, awards=#{weights["awards"]}, cultural=#{weights["cultural"]}, people=#{weights["people"]}, financial=#{weights["financial"]}"
      )

    true ->
      :ok
  end

  # Also warn if financial weights are defined but category weight is 0
  financial_weight = weights["financial"] || 0.0

  if financial_weight == 0.0 do
    profile_weights = profile.weights || %{}
    financial_metrics = ["tmdb_revenue_worldwide", "tmdb_budget", "omdb_revenue_domestic"]

    defined_financial =
      Enum.filter(financial_metrics, fn metric ->
        Map.get(profile_weights, metric, 0.0) > 0
      end)

    if length(defined_financial) > 0 do
      IO.puts(
        "INFO: #{profile.name} has financial metric weights defined but financial category weight is 0:"
      )

      IO.puts("  Unused metrics: #{Enum.join(defined_financial, ", ")}")
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
  on_conflict:
    {:replace, [:description, :weights, :category_weights, :active, :is_default, :is_system, :updated_at]}
)

IO.puts("Upserted #{length(weight_profiles)} metric weight profiles")
