# Seed file for metric weight profiles
# Run with: mix run priv/repo/seeds/metric_weight_profiles.exs

alias Cinegraph.Repo
import Ecto.Query

# Only clear system profiles to preserve user-created ones
Repo.delete_all(from mwp in "metric_weight_profiles", where: field(mwp, :is_system) == true)

weight_profiles = [
  %{
    name: "Cinegraph Editorial",
    description:
      "Calibrated against 1001 Movies You Must See Before You Die. Emphasizes cultural impact and critical consensus over popularity and financial metrics.",
    weights: %{
      # Critics (25%)
      "metacritic_metascore" => 2.0,
      "rotten_tomatoes_tomatometer" => 2.0,

      # Mob (5%)
      "imdb_rating" => 0.8,
      "tmdb_rating" => 0.8,
      "rotten_tomatoes_audience_score" => 0.5,

      # Industry Recognition (20%)
      "oscar_wins" => 2.0,
      "oscar_nominations" => 1.0,
      "cannes_palme_dor" => 2.0,
      "venice_golden_lion" => 2.0,
      "berlin_golden_bear" => 2.0,

      # Time Machine (30%)
      "1001_movies" => 2.0,
      "criterion" => 2.0,
      "sight_sound_critics_2022" => 2.0,
      "national_film_registry" => 1.5,
      "afi_top_100" => 1.0,

      # Auteurs (15%)
      "person_quality_score" => 1.0,

      # Box Office (5% — de-emphasized)
      "tmdb_revenue_worldwide" => 0.2,
      "tmdb_budget" => 0.1
    },
    category_weights: %{
      "mob" => 0.05,
      "critics" => 0.25,
      "festival_recognition" => 0.20,
      "box_office" => 0.05,
      "time_machine" => 0.30,
      "auteurs" => 0.15
    },
    active: true,
    is_default: true,
    is_system: true
  },
  %{
    name: "Critics Choice",
    description:
      "Prioritizes critic scores. Critics lens is dominant with cultural recognition secondary.",
    weights: %{
      # Mob (10%)
      "imdb_rating" => 0.8,
      "tmdb_rating" => 0.8,
      "rotten_tomatoes_audience_score" => 0.5,

      # Critics (50%)
      "metacritic_metascore" => 3.0,
      "rotten_tomatoes_tomatometer" => 3.0,

      # Industry Recognition (20%)
      "oscar_wins" => 2.0,
      "oscar_nominations" => 1.0,
      "cannes_palme_dor" => 2.0,
      "venice_golden_lion" => 2.0,
      "berlin_golden_bear" => 2.0,

      # Time Machine (20%)
      "1001_movies" => 1.5,
      "criterion" => 1.5,
      "sight_sound_critics_2022" => 1.5
    },
    category_weights: %{
      "mob" => 0.10,
      "critics" => 0.50,
      "festival_recognition" => 0.20,
      "box_office" => 0.00,
      "time_machine" => 0.20,
      "auteurs" => 0.00
    },
    active: true,
    is_default: false,
    is_system: true
  },
  %{
    name: "Crowd Pleaser",
    description:
      "Focuses on what mainstream audiences love. Mob score dominant with box office secondary.",
    weights: %{
      # Mob (60%)
      "imdb_rating" => 2.5,
      "tmdb_rating" => 2.0,
      "imdb_rating_votes" => 1.5,
      "rotten_tomatoes_audience_score" => 2.0,

      # Time Machine (15%)
      "1001_movies" => 1.0,
      "criterion" => 1.0,

      # Box Office (25%)
      "tmdb_revenue_worldwide" => 2.0,
      "tmdb_budget" => 0.5
    },
    category_weights: %{
      "mob" => 0.60,
      "critics" => 0.00,
      "festival_recognition" => 0.00,
      "box_office" => 0.25,
      "time_machine" => 0.15,
      "auteurs" => 0.00
    },
    active: true,
    is_default: false,
    is_system: true
  },
  %{
    name: "Award Season",
    description:
      "Finds films that win awards. Industry recognition is dominant with critical consensus secondary.",
    weights: %{
      # Critics (30%)
      "metacritic_metascore" => 2.0,
      "rotten_tomatoes_tomatometer" => 2.0,

      # Industry Recognition (60%)
      "oscar_wins" => 3.0,
      "oscar_nominations" => 2.0,
      "cannes_palme_dor" => 2.5,
      "venice_golden_lion" => 2.5,
      "berlin_golden_bear" => 2.5,

      # Time Machine (10%)
      "1001_movies" => 1.0,
      "criterion" => 1.0
    },
    category_weights: %{
      "mob" => 0.00,
      "critics" => 0.30,
      "festival_recognition" => 0.60,
      "box_office" => 0.00,
      "time_machine" => 0.10,
      "auteurs" => 0.00
    },
    active: true,
    is_default: false,
    is_system: true
  },
  %{
    name: "Hidden Gems",
    description:
      "Surfaces overlooked films with strong cultural longevity and auteur craft over mass appeal.",
    weights: %{
      # Mob (20%)
      "imdb_rating" => 1.0,
      "tmdb_rating" => 1.0,

      # Critics (10%)
      "metacritic_metascore" => 1.0,
      "rotten_tomatoes_tomatometer" => 1.0,

      # Time Machine (40%)
      "1001_movies" => 2.0,
      "criterion" => 2.0,
      "sight_sound_critics_2022" => 2.0,
      "national_film_registry" => 1.5,

      # Auteurs (30%)
      "person_quality_score" => 2.0
    },
    category_weights: %{
      "mob" => 0.20,
      "critics" => 0.10,
      "festival_recognition" => 0.00,
      "box_office" => 0.00,
      "time_machine" => 0.40,
      "auteurs" => 0.30
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
    Map.take(weights, [
      "mob",
      "critics",
      "festival_recognition",
      "box_office",
      "time_machine",
      "auteurs"
    ])

  sum = Map.values(relevant_weights) |> Enum.sum()

  cond do
    sum > 1.01 ->
      IO.puts("WARNING: #{profile.name} category weights sum to #{Float.round(sum, 4)} (> 1.01)")

      IO.puts(
        "  Breakdown: mob=#{weights["mob"]}, critics=#{weights["critics"]}, festival_recognition=#{weights["festival_recognition"]}, time_machine=#{weights["time_machine"]}, auteurs=#{weights["auteurs"]}, box_office=#{weights["box_office"]}"
      )

    sum < 0.99 ->
      IO.puts("WARNING: #{profile.name} category weights sum to #{Float.round(sum, 4)} (< 0.99)")

      IO.puts(
        "  Breakdown: mob=#{weights["mob"]}, critics=#{weights["critics"]}, festival_recognition=#{weights["festival_recognition"]}, time_machine=#{weights["time_machine"]}, auteurs=#{weights["auteurs"]}, box_office=#{weights["box_office"]}"
      )

    true ->
      :ok
  end

  # Also warn if box_office weights are defined but category weight is 0
  box_office_weight = weights["box_office"] || 0.0

  if box_office_weight == 0.0 do
    profile_weights = profile.weights || %{}
    box_office_metrics = ["tmdb_revenue_worldwide", "tmdb_budget", "omdb_revenue_domestic"]

    defined_box_office =
      Enum.filter(box_office_metrics, fn metric ->
        Map.get(profile_weights, metric, 0.0) > 0
      end)

    if length(defined_box_office) > 0 do
      IO.puts(
        "INFO: #{profile.name} has box office metric weights defined but box_office category weight is 0:"
      )

      IO.puts("  Unused metrics: #{Enum.join(defined_box_office, ", ")}")
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
    {:replace,
     [:description, :weights, :category_weights, :active, :is_default, :is_system, :updated_at]}
)

IO.puts("Upserted #{length(weight_profiles)} metric weight profiles")
