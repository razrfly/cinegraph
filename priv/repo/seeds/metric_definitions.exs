# Seed file for metric definitions
# Run with: mix run priv/repo/seeds/metric_definitions.exs

alias Cinegraph.Repo
import Ecto.Query

# Definitions are system-owned; no need to hard-delete. We'll upsert below.

metric_definitions = [
  # ========== RATINGS (Public Opinion) ==========
  %{
    code: "imdb_rating",
    name: "IMDb Rating",
    description: "Average user rating on IMDb",
    source_table: "external_metrics",
    source_type: "imdb",
    source_field: "rating_average",
    category: "ratings",
    subcategory: "audience_rating",
    normalization_type: "linear",
    normalization_params: %{},
    raw_scale_min: 0.0,
    raw_scale_max: 10.0,
    source_reliability: 0.95,
    active: true
  },
  %{
    code: "tmdb_rating",
    name: "TMDb Rating",
    description: "Average user rating on The Movie Database",
    source_table: "external_metrics",
    source_type: "tmdb",
    source_field: "rating_average",
    category: "ratings",
    subcategory: "audience_rating",
    normalization_type: "linear",
    normalization_params: %{},
    raw_scale_min: 0.0,
    raw_scale_max: 10.0,
    source_reliability: 0.9,
    active: true
  },
  
  # ========== CRITICAL RATINGS (Artistic Impact) ==========
  %{
    code: "metacritic_metascore",
    name: "Metacritic Score",
    description: "Weighted average of critic reviews",
    source_table: "external_metrics",
    source_type: "metacritic",
    source_field: "metascore",
    category: "ratings",
    subcategory: "critic_rating",
    normalization_type: "linear",
    normalization_params: %{},
    raw_scale_min: 0.0,
    raw_scale_max: 100.0,
    source_reliability: 0.85,
    active: true
  },
  %{
    code: "rotten_tomatoes_tomatometer",
    name: "Rotten Tomatoes Tomatometer",
    description: "Percentage of positive critic reviews",
    source_table: "external_metrics",
    source_type: "rotten_tomatoes",
    source_field: "tomatometer",
    category: "ratings",
    subcategory: "critic_rating",
    normalization_type: "linear",
    normalization_params: %{},
    raw_scale_min: 0.0,
    raw_scale_max: 100.0,
    source_reliability: 0.8,
    active: true
  },
  %{
    code: "rotten_tomatoes_audience_score",
    name: "Rotten Tomatoes Audience Score",
    description: "Percentage of positive audience reviews",
    source_table: "external_metrics",
    source_type: "rotten_tomatoes",
    source_field: "audience_score",
    category: "ratings",
    subcategory: "audience_rating",
    normalization_type: "linear",
    normalization_params: %{},
    raw_scale_min: 0.0,
    raw_scale_max: 100.0,
    source_reliability: 0.75,
    active: true
  },
  
  # ========== POPULARITY METRICS (Cultural Penetration) ==========
  %{
    code: "imdb_rating_votes",
    name: "IMDb Vote Count",
    description: "Number of user ratings on IMDb",
    source_table: "external_metrics",
    source_type: "imdb",
    source_field: "rating_votes",
    category: "ratings",
    subcategory: "audience_rating",
    normalization_type: "logarithmic",
    normalization_params: %{"threshold" => 10_000_000},
    raw_scale_min: 0.0,
    raw_scale_max: nil,
    source_reliability: 0.95,
    active: true
  },
  %{
    code: "tmdb_rating_votes",
    name: "TMDb Vote Count",
    description: "Number of user ratings on TMDb",
    source_table: "external_metrics",
    source_type: "tmdb",
    source_field: "rating_votes",
    category: "ratings",
    subcategory: "audience_rating",
    normalization_type: "logarithmic",
    normalization_params: %{"threshold" => 1_000_000},
    raw_scale_min: 0.0,
    raw_scale_max: nil,
    source_reliability: 0.9,
    active: true
  },
  %{
    code: "tmdb_popularity_score",
    name: "TMDb Popularity",
    description: "TMDb's proprietary popularity metric",
    source_table: "external_metrics",
    source_type: "tmdb",
    source_field: "popularity_score",
    category: "ratings",
    subcategory: "audience_rating",
    normalization_type: "logarithmic",
    normalization_params: %{"threshold" => 1000},
    raw_scale_min: 0.0,
    raw_scale_max: nil,
    source_reliability: 0.7,
    active: true
  },
  
  # ========== FINANCIAL METRICS (Cultural Penetration) ==========
  %{
    code: "tmdb_budget",
    name: "Production Budget",
    description: "Movie production budget",
    source_table: "external_metrics",
    source_type: "tmdb",
    source_field: "budget",
    category: "financial",
    subcategory: "box_office",
    normalization_type: "logarithmic",
    normalization_params: %{"threshold" => 500_000_000},
    raw_scale_min: 0.0,
    raw_scale_max: nil,
    source_reliability: 0.7,
    active: true
  },
  %{
    code: "tmdb_revenue_worldwide",
    name: "Worldwide Revenue",
    description: "Total worldwide box office revenue",
    source_table: "external_metrics",
    source_type: "tmdb",
    source_field: "revenue_worldwide",
    category: "financial",
    subcategory: "box_office",
    normalization_type: "logarithmic",
    normalization_params: %{"threshold" => 2_000_000_000},
    raw_scale_min: 0.0,
    raw_scale_max: nil,
    source_reliability: 0.7,
    active: true
  },
  %{
    code: "omdb_revenue_domestic",
    name: "Domestic Box Office",
    description: "US domestic box office revenue",
    source_table: "external_metrics",
    source_type: "omdb",
    source_field: "revenue_domestic",
    category: "financial",
    subcategory: "box_office",
    normalization_type: "logarithmic",
    normalization_params: %{"threshold" => 1_000_000_000},
    raw_scale_min: 0.0,
    raw_scale_max: nil,
    source_reliability: 0.65,
    active: true
  },
  
  # ========== AWARDS (Institutional Recognition) ==========
  %{
    code: "oscar_wins",
    name: "Oscar Wins",
    description: "Number of Academy Awards won",
    source_table: "festival_nominations",
    source_type: "AMPAS",
    source_field: "won",
    category: "awards",
    subcategory: "major_award",
    normalization_type: "custom",
    normalization_params: %{"0" => 0.0, "1" => 0.6, "2" => 0.8, "3+" => 1.0},
    raw_scale_min: 0.0,
    raw_scale_max: nil,
    source_reliability: 1.0,
    active: true
  },
  %{
    code: "oscar_nominations",
    name: "Oscar Nominations",
    description: "Number of Academy Award nominations",
    source_table: "festival_nominations",
    source_type: "AMPAS",
    source_field: "nominated",
    category: "awards",
    subcategory: "major_award",
    normalization_type: "custom",
    normalization_params: %{"0" => 0.0, "1" => 0.5, "2" => 0.7, "3+" => 1.0},
    raw_scale_min: 0.0,
    raw_scale_max: nil,
    source_reliability: 1.0,
    active: true
  },
  %{
    code: "cannes_palme_dor",
    name: "Cannes Palme d'Or",
    description: "Won the Palme d'Or at Cannes Film Festival",
    source_table: "festival_nominations",
    source_type: "CANNES",
    source_field: "won",
    category: "awards",
    subcategory: "major_award",
    normalization_type: "boolean",
    normalization_params: %{},
    raw_scale_min: 0.0,
    raw_scale_max: 1.0,
    source_reliability: 1.0,
    active: true
  },
  %{
    code: "venice_golden_lion",
    name: "Venice Golden Lion",
    description: "Won the Golden Lion at Venice Film Festival",
    source_table: "festival_nominations",
    source_type: "VIFF",
    source_field: "won",
    category: "awards",
    subcategory: "major_award",
    normalization_type: "boolean",
    normalization_params: %{},
    raw_scale_min: 0.0,
    raw_scale_max: 1.0,
    source_reliability: 1.0,
    active: true
  },
  %{
    code: "berlin_golden_bear",
    name: "Berlin Golden Bear",
    description: "Won the Golden Bear at Berlin Film Festival",
    source_table: "festival_nominations",
    source_type: "BERLINALE",
    source_field: "won",
    category: "awards",
    subcategory: "major_award",
    normalization_type: "boolean",
    normalization_params: %{},
    raw_scale_min: 0.0,
    raw_scale_max: 1.0,
    source_reliability: 1.0,
    active: true
  },
  
  # ========== CANONICAL LISTS (Timelessness) ==========
  %{
    code: "1001_movies",
    name: "1001 Movies Before You Die",
    description: "Included in the 1001 Movies list",
    source_table: "canonical_sources",
    source_type: "1001_movies",
    source_field: "included",
    category: "cultural",
    subcategory: "canonical_list",
    normalization_type: "boolean",
    normalization_params: %{},
    raw_scale_min: 0.0,
    raw_scale_max: 1.0,
    source_reliability: 0.85,
    active: true
  },
  %{
    code: "criterion",
    name: "Criterion Collection",
    description: "Part of the Criterion Collection",
    source_table: "canonical_sources",
    source_type: "criterion",
    source_field: "included",
    category: "cultural",
    subcategory: "canonical_list",
    normalization_type: "boolean",
    normalization_params: %{},
    raw_scale_min: 0.0,
    raw_scale_max: 1.0,
    source_reliability: 0.9,
    active: true
  },
  %{
    code: "national_film_registry",
    name: "National Film Registry",
    description: "Preserved in the National Film Registry",
    source_table: "canonical_sources",
    source_type: "national_film_registry",
    source_field: "included",
    category: "cultural",
    subcategory: "canonical_list",
    normalization_type: "boolean",
    normalization_params: %{},
    raw_scale_min: 0.0,
    raw_scale_max: 1.0,
    source_reliability: 0.95,
    active: true
  },
  %{
    code: "sight_sound_critics_2022",
    name: "Sight & Sound Critics' Poll 2022",
    description: "Ranked in the 2022 Sight & Sound critics' poll",
    source_table: "canonical_sources",
    source_type: "sight_sound_critics_2022",
    source_field: "rank",
    category: "cultural",
    subcategory: "critics_poll",
    normalization_type: "sigmoid",
    normalization_params: %{"k" => 0.02, "midpoint" => 125},
    raw_scale_min: 1.0,
    raw_scale_max: 250.0,
    source_reliability: 0.95,
    active: true
  },
  %{
    code: "afi_top_100",
    name: "AFI Top 100",
    description: "Rank in AFI's Top 100 Films",
    source_table: "canonical_sources",
    source_type: "afi_top_100",
    source_field: "rank",
    category: "cultural",
    subcategory: "critics_poll",
    normalization_type: "sigmoid",
    normalization_params: %{"k" => 0.05, "midpoint" => 50},
    raw_scale_min: 1.0,
    raw_scale_max: 100.0,
    source_reliability: 0.9,
    active: true
  },
  %{
    code: "bfi_top_100",
    name: "BFI Top 100",
    description: "Rank in BFI's Top 100 Films",
    source_table: "canonical_sources",
    source_type: "bfi_top_100",
    source_field: "rank",
    category: "cultural",
    subcategory: "critics_poll",
    normalization_type: "sigmoid",
    normalization_params: %{"k" => 0.05, "midpoint" => 50},
    raw_scale_min: 1.0,
    raw_scale_max: 100.0,
    source_reliability: 0.9,
    active: true
  }
]

# Insert or update all metric definitions idempotently
now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
entries =
  Enum.map(metric_definitions, fn definition ->
    Map.merge(definition, %{inserted_at: now, updated_at: now})
  end)

# Requires a unique index on metric_definitions(code)
Repo.insert_all(
  "metric_definitions",
  entries,
  conflict_target: [:code],
  on_conflict: {:replace, [
    :name,
    :description,
    :source_table,
    :source_type,
    :source_field,
    :category,
    :subcategory,
    :normalization_type,
    :normalization_params,
    :raw_scale_min,
    :raw_scale_max,
    :source_reliability,
    :active,
    :updated_at
  ]}
)

IO.puts "Upserted #{length(metric_definitions)} metric definitions"