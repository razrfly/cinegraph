# Seed file for Weight Profiles
# Run with: mix run priv/repo/seeds/weight_profiles.exs

alias Cinegraph.Repo
alias Cinegraph.Metrics.WeightProfile

# Clear existing profiles
Repo.delete_all(WeightProfile)

weight_profiles = [
  # Balanced profile - equal weights across all dimensions
  %{
    name: "balanced",
    description: "Equal weight to all CRI dimensions",
    profile_type: "manual",
    timelessness_weight: 0.2,
    cultural_penetration_weight: 0.2,
    artistic_impact_weight: 0.2,
    institutional_weight: 0.2,
    public_weight: 0.2,
    metric_weights: %{},
    is_default: true,
    is_system: true,
    active: true
  },
  
  # Critics' choice - emphasizes artistic impact and critical ratings
  %{
    name: "critics_choice",
    description: "Emphasizes critical acclaim and artistic merit",
    profile_type: "manual",
    timelessness_weight: 0.15,
    cultural_penetration_weight: 0.10,
    artistic_impact_weight: 0.35,
    institutional_weight: 0.30,
    public_weight: 0.10,
    metric_weights: %{
      "metacritic_score" => 1.5,
      "rt_tomatometer" => 1.3,
      "sight_sound_rank" => 1.4,
      "criterion_collection" => 1.2
    },
    is_system: true,
    active: true
  },
  
  # Crowd pleaser - emphasizes popular opinion
  %{
    name: "crowd_pleaser",
    description: "Focuses on popular appeal and audience ratings",
    profile_type: "manual",
    timelessness_weight: 0.10,
    cultural_penetration_weight: 0.30,
    artistic_impact_weight: 0.10,
    institutional_weight: 0.10,
    public_weight: 0.40,
    metric_weights: %{
      "imdb_rating" => 1.5,
      "tmdb_rating" => 1.3,
      "rt_audience_score" => 1.4,
      "imdb_vote_count" => 1.2
    },
    is_system: true,
    active: true
  },
  
  # Hidden gems - low popularity but high quality
  %{
    name: "hidden_gems",
    description: "Finds overlooked films with high quality",
    profile_type: "manual",
    timelessness_weight: 0.25,
    cultural_penetration_weight: 0.05,  # Low weight on popularity
    artistic_impact_weight: 0.30,
    institutional_weight: 0.25,
    public_weight: 0.15,
    metric_weights: %{
      "tmdb_popularity" => 0.2,  # Inverse weight - less popular is better
      "imdb_vote_count" => 0.3,
      "letterboxd_rating" => 1.5,
      "nfr_preserved" => 1.4
    },
    is_system: true,
    active: true
  },
  
  # Festival circuit - emphasizes awards and festival recognition
  %{
    name: "festival_circuit",
    description: "Prioritizes festival awards and recognition",
    profile_type: "manual",
    timelessness_weight: 0.15,
    cultural_penetration_weight: 0.10,
    artistic_impact_weight: 0.25,
    institutional_weight: 0.40,  # Heavy on awards
    public_weight: 0.10,
    metric_weights: %{
      "cannes_palme_dor" => 2.0,
      "venice_golden_lion" => 1.8,
      "berlin_golden_bear" => 1.7,
      "oscar_wins" => 1.5,
      "sundance_grand_jury" => 1.4
    },
    is_system: true,
    active: true
  },
  
  # Legacy discovery - matches current discovery scoring
  %{
    name: "legacy_discovery",
    description: "Original discovery scoring weights (for migration)",
    profile_type: "manual",
    timelessness_weight: 0.20,      # cultural_impact
    cultural_penetration_weight: 0.30,  # popular_opinion
    artistic_impact_weight: 0.30,   # critical_acclaim
    institutional_weight: 0.20,     # industry_recognition
    public_weight: 0.00,            # Not used in original
    metric_weights: %{
      "imdb_rating" => 1.0,
      "tmdb_rating" => 1.0,
      "metacritic_score" => 1.2,
      "rt_tomatometer" => 0.8,
      "oscar_nominations" => 1.0,
      "oscar_wins" => 1.5
    },
    is_system: true,
    active: true
  },
  
  # CRI v1 - initial attempt at 1001 Movies replication
  %{
    name: "cri_v1",
    description: "First attempt at replicating 1001 Movies list",
    profile_type: "manual",
    timelessness_weight: 0.25,
    cultural_penetration_weight: 0.15,
    artistic_impact_weight: 0.25,
    institutional_weight: 0.20,
    public_weight: 0.15,
    metric_weights: %{
      "1001_movies" => 0.0,  # Don't use this for prediction
      "criterion_collection" => 1.3,
      "nfr_preserved" => 1.2,
      "sight_sound_rank" => 1.4,
      "afi_top_100" => 1.1
    },
    active: true
  }
]

# Insert all weight profiles
Enum.each(weight_profiles, fn attrs ->
  %WeightProfile{}
  |> WeightProfile.changeset(attrs)
  |> Repo.insert!()
end)

IO.puts "Inserted #{length(weight_profiles)} weight profiles"