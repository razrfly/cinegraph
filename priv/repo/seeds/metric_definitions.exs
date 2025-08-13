# Seed file for Metric Definitions
# Run with: mix run priv/repo/seeds/metric_definitions.exs

alias Cinegraph.Repo
alias Cinegraph.Metrics.MetricDefinition

# Clear existing definitions
Repo.delete_all(MetricDefinition)

metric_definitions = [
  # ========== USER & CRITIC RATINGS ==========
  %{
    code: "tmdb_rating",
    name: "TMDb Rating",
    category: "rating",
    cri_dimension: "public",
    data_type: "numeric",
    source: "tmdb",
    raw_scale_min: 0.0,
    raw_scale_max: 10.0,
    normalization_type: "linear",
    source_reliability: 0.9
  },
  %{
    code: "tmdb_vote_count",
    name: "TMDb Vote Count",
    category: "popularity",
    cri_dimension: "cultural_penetration",
    data_type: "numeric",
    source: "tmdb",
    raw_scale_min: 0.0,
    normalization_type: "logarithmic",
    normalization_params: %{"threshold" => 1_000_000},
    source_reliability: 0.9
  },
  %{
    code: "imdb_rating",
    name: "IMDb Rating",
    category: "rating",
    cri_dimension: "public",
    data_type: "numeric",
    source: "imdb",
    raw_scale_min: 0.0,
    raw_scale_max: 10.0,
    normalization_type: "linear",
    source_reliability: 0.95
  },
  %{
    code: "imdb_vote_count",
    name: "IMDb Vote Count",
    category: "popularity",
    cri_dimension: "cultural_penetration",
    data_type: "numeric",
    source: "imdb",
    raw_scale_min: 0.0,
    normalization_type: "logarithmic",
    normalization_params: %{"threshold" => 10_000_000},
    source_reliability: 0.95
  },
  %{
    code: "metacritic_score",
    name: "Metacritic Score",
    category: "rating",
    cri_dimension: "artistic_impact",
    data_type: "numeric",
    source: "metacritic",
    raw_scale_min: 0.0,
    raw_scale_max: 100.0,
    normalization_type: "linear",
    source_reliability: 0.85
  },
  %{
    code: "rt_tomatometer",
    name: "Rotten Tomatoes Tomatometer",
    category: "rating",
    cri_dimension: "artistic_impact",
    data_type: "numeric",
    source: "rotten_tomatoes",
    raw_scale_min: 0.0,
    raw_scale_max: 100.0,
    raw_unit: "%",
    normalization_type: "linear",
    source_reliability: 0.8
  },
  %{
    code: "rt_audience_score",
    name: "Rotten Tomatoes Audience Score",
    category: "rating",
    cri_dimension: "public",
    data_type: "numeric",
    source: "rotten_tomatoes",
    raw_scale_min: 0.0,
    raw_scale_max: 100.0,
    raw_unit: "%",
    normalization_type: "linear",
    source_reliability: 0.75
  },
  
  # ========== FINANCIAL PERFORMANCE ==========
  %{
    code: "tmdb_budget",
    name: "TMDb Budget",
    category: "financial",
    cri_dimension: "cultural_penetration",
    data_type: "numeric",
    source: "tmdb",
    raw_scale_min: 0.0,
    raw_unit: "$",
    normalization_type: "logarithmic",
    normalization_params: %{"threshold" => 500_000_000},
    source_reliability: 0.7
  },
  %{
    code: "tmdb_revenue",
    name: "TMDb Revenue",
    category: "financial",
    cri_dimension: "cultural_penetration",
    data_type: "numeric",
    source: "tmdb",
    raw_scale_min: 0.0,
    raw_unit: "$",
    normalization_type: "logarithmic",
    normalization_params: %{"threshold" => 2_000_000_000},
    source_reliability: 0.7
  },
  %{
    code: "omdb_box_office",
    name: "OMDb Box Office",
    category: "financial",
    cri_dimension: "cultural_penetration",
    data_type: "numeric",
    source: "omdb",
    raw_scale_min: 0.0,
    raw_unit: "$",
    normalization_type: "logarithmic",
    normalization_params: %{"threshold" => 1_000_000_000},
    source_reliability: 0.65
  },
  
  # ========== AWARDS & RECOGNITION ==========
  %{
    code: "oscar_nominations",
    name: "Oscar Nominations",
    category: "award",
    cri_dimension: "institutional",
    data_type: "numeric",
    source: "oscars",
    raw_scale_min: 0.0,
    raw_unit: "count",
    normalization_type: "custom",
    normalization_params: %{"0" => 0.0, "1" => 0.5, "2" => 0.7, "3+" => 1.0},
    source_reliability: 1.0
  },
  %{
    code: "oscar_wins",
    name: "Oscar Wins",
    category: "award",
    cri_dimension: "institutional",
    data_type: "numeric",
    source: "oscars",
    raw_scale_min: 0.0,
    raw_unit: "count",
    normalization_type: "custom",
    normalization_params: %{"0" => 0.0, "1" => 0.6, "2" => 0.8, "3+" => 1.0},
    source_reliability: 1.0
  },
  %{
    code: "cannes_palme_dor",
    name: "Cannes Palme d'Or",
    category: "award",
    cri_dimension: "institutional",
    data_type: "boolean",
    source: "cannes",
    normalization_type: "boolean",
    source_reliability: 1.0
  },
  %{
    code: "cannes_selection",
    name: "Cannes Selection",
    category: "award",
    cri_dimension: "institutional",
    data_type: "boolean",
    source: "cannes",
    normalization_type: "boolean",
    normalization_params: %{"true" => 0.3, "false" => 0.0},
    source_reliability: 0.95
  },
  %{
    code: "venice_golden_lion",
    name: "Venice Golden Lion",
    category: "award",
    cri_dimension: "institutional",
    data_type: "boolean",
    source: "venice",
    normalization_type: "boolean",
    normalization_params: %{"true" => 0.95, "false" => 0.0},
    source_reliability: 1.0
  },
  %{
    code: "venice_selection",
    name: "Venice Selection",
    category: "award",
    cri_dimension: "institutional",
    data_type: "boolean",
    source: "venice",
    normalization_type: "boolean",
    normalization_params: %{"true" => 0.3, "false" => 0.0},
    source_reliability: 0.95
  },
  %{
    code: "berlin_golden_bear",
    name: "Berlin Golden Bear",
    category: "award",
    cri_dimension: "institutional",
    data_type: "boolean",
    source: "berlin",
    normalization_type: "boolean",
    normalization_params: %{"true" => 0.9, "false" => 0.0},
    source_reliability: 1.0
  },
  %{
    code: "sundance_grand_jury",
    name: "Sundance Grand Jury Prize",
    category: "award",
    cri_dimension: "institutional",
    data_type: "boolean",
    source: "sundance",
    normalization_type: "boolean",
    normalization_params: %{"true" => 0.85, "false" => 0.0},
    source_reliability: 0.95
  },
  
  # ========== CULTURAL IMPACT ==========
  %{
    code: "afi_top_100",
    name: "AFI Top 100",
    category: "cultural",
    cri_dimension: "artistic_impact",
    data_type: "rank",
    source: "afi",
    raw_scale_min: 1.0,
    raw_scale_max: 100.0,
    normalization_type: "sigmoid",
    normalization_params: %{"k" => 0.05, "midpoint" => 50},
    source_reliability: 0.9
  },
  %{
    code: "bfi_top_100",
    name: "BFI Top 100",
    category: "cultural",
    cri_dimension: "artistic_impact",
    data_type: "rank",
    source: "bfi",
    raw_scale_min: 1.0,
    raw_scale_max: 100.0,
    normalization_type: "sigmoid",
    normalization_params: %{"k" => 0.05, "midpoint" => 50},
    source_reliability: 0.9
  },
  %{
    code: "sight_sound_rank",
    name: "Sight & Sound Top 250",
    category: "cultural",
    cri_dimension: "artistic_impact",
    data_type: "rank",
    source: "sight_sound",
    raw_scale_min: 1.0,
    raw_scale_max: 250.0,
    normalization_type: "sigmoid",
    normalization_params: %{"k" => 0.02, "midpoint" => 125},
    source_reliability: 0.95
  },
  %{
    code: "criterion_collection",
    name: "Criterion Collection",
    category: "cultural",
    cri_dimension: "timelessness",
    data_type: "boolean",
    source: "criterion",
    normalization_type: "boolean",
    normalization_params: %{"true" => 0.7, "false" => 0.0},
    source_reliability: 0.9
  },
  %{
    code: "1001_movies",
    name: "1001 Movies Before You Die",
    category: "cultural",
    cri_dimension: "timelessness",
    data_type: "boolean",
    source: "1001_movies",
    normalization_type: "boolean",
    normalization_params: %{"true" => 0.6, "false" => 0.0},
    source_reliability: 0.85
  },
  %{
    code: "nfr_preserved",
    name: "National Film Registry",
    category: "cultural",
    cri_dimension: "timelessness",
    data_type: "boolean",
    source: "nfr",
    normalization_type: "boolean",
    normalization_params: %{"true" => 0.8, "false" => 0.0},
    source_reliability: 0.95
  },
  
  # ========== POPULARITY & ENGAGEMENT ==========
  %{
    code: "tmdb_popularity",
    name: "TMDb Popularity",
    category: "popularity",
    cri_dimension: "cultural_penetration",
    data_type: "numeric",
    source: "tmdb",
    raw_scale_min: 0.0,
    normalization_type: "logarithmic",
    normalization_params: %{"threshold" => 1000},
    source_reliability: 0.7
  },
  %{
    code: "letterboxd_rating",
    name: "Letterboxd Rating",
    category: "rating",
    cri_dimension: "timelessness",
    data_type: "numeric",
    source: "letterboxd",
    raw_scale_min: 0.0,
    raw_scale_max: 5.0,
    normalization_type: "linear",
    source_reliability: 0.8
  },
  %{
    code: "letterboxd_watches",
    name: "Letterboxd Watch Count",
    category: "popularity",
    cri_dimension: "cultural_penetration",
    data_type: "numeric",
    source: "letterboxd",
    raw_scale_min: 0.0,
    normalization_type: "logarithmic",
    normalization_params: %{"threshold" => 500_000},
    source_reliability: 0.75
  },
  %{
    code: "wikipedia_views",
    name: "Wikipedia Page Views",
    category: "popularity",
    cri_dimension: "cultural_penetration",
    data_type: "numeric",
    source: "wikipedia",
    raw_scale_min: 0.0,
    normalization_type: "logarithmic",
    normalization_params: %{"threshold" => 10_000_000},
    source_reliability: 0.6
  },
  %{
    code: "restoration_count",
    name: "Restoration Count",
    category: "cultural",
    cri_dimension: "timelessness",
    data_type: "numeric",
    source: "various",
    raw_scale_min: 0.0,
    raw_unit: "count",
    normalization_type: "custom",
    normalization_params: %{"0" => 0.0, "1" => 0.5, "2" => 0.8, "3+" => 1.0},
    source_reliability: 0.7
  }
]

# Insert all metric definitions
Enum.each(metric_definitions, fn attrs ->
  %MetricDefinition{}
  |> MetricDefinition.changeset(attrs)
  |> Repo.insert!()
end)

IO.puts "Inserted #{length(metric_definitions)} metric definitions"