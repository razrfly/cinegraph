defmodule Cinegraph.Metrics.ScoringService do
  @moduledoc """
  Service module for calculating movie scores using database-driven weight profiles.
  Replaces the hard-coded discovery scoring system with a flexible, database-backed approach.
  """
  
  import Ecto.Query, warn: false
  alias Cinegraph.Repo
  alias Cinegraph.Metrics.MetricWeightProfile
  
  @doc """
  Gets a weight profile by name from the database.
  Returns the profile or nil if not found.
  """
  def get_profile(name) when is_binary(name) do
    Repo.get_by(MetricWeightProfile, name: name, active: true)
  end
  
  def get_profile(name) when is_atom(name) do
    get_profile(Atom.to_string(name) |> String.replace("_", " ") |> String.split() |> Enum.map(&String.capitalize/1) |> Enum.join(" "))
  end
  
  @doc """
  Gets all active weight profiles from the database.
  """
  def get_all_profiles do
    from(p in MetricWeightProfile, where: p.active == true, order_by: [asc: p.name])
    |> Repo.all()
  end
  
  @doc """
  Gets the default weight profile from the database.
  """
  def get_default_profile do
    Repo.get_by(MetricWeightProfile, is_default: true, active: true) ||
      get_profile("Balanced")
  end
  
  @doc """
  Converts a database weight profile to the format expected by the discovery UI.
  Maps category_weights to the four main dimensions.
  
  Note: "ratings" category is split into popular_opinion and critical_acclaim
  """
  def profile_to_discovery_weights(%MetricWeightProfile{} = profile) do
    ratings_weight = get_category_weight(profile, "ratings", 0.5)
    
    # Split ratings into popular and critical based on the profile
    # For now, we'll split it 50/50 for popular vs critical within ratings
    # This could be refined based on individual metric weights
    %{
      popular_opinion: ratings_weight * 0.5,      # Half of ratings weight
      critical_acclaim: ratings_weight * 0.5,     # Half of ratings weight  
      industry_recognition: get_category_weight(profile, "awards", 0.25),
      cultural_impact: get_category_weight(profile, "cultural", 0.25)
    }
  end
  
  @doc """
  Converts discovery UI weights back to database format for custom profiles.
  """
  def discovery_weights_to_profile(weights, name \\ "Custom") do
    %{
      name: name,
      description: "Custom weight profile created from discovery UI",
      category_weights: %{
        "ratings" => Map.get(weights, :popular_opinion, 0.25),
        "awards" => Map.get(weights, :industry_recognition, 0.25),
        "financial" => Map.get(weights, :popular_opinion, 0.25) * 0.3, # Financial correlates with popular
        "cultural" => Map.get(weights, :cultural_impact, 0.25)
      },
      weights: build_metric_weights_from_discovery(weights),
      active: true,
      is_system: false
    }
  end
  
  @doc """
  Applies database-driven scoring to a movie query.
  This replaces the hard-coded scoring in DiscoveryScoringSimple.
  """
  def apply_scoring(query, profile_or_name, options \\ %{})
  
  def apply_scoring(query, %MetricWeightProfile{} = profile, options) do
    discovery_weights = profile_to_discovery_weights(profile)
    normalized_weights = normalize_weights(discovery_weights)
    min_score = Map.get(options, :min_score, 0.0)
    
    # Use the same query structure as DiscoveryScoringSimple but with database weights
    query
    |> join_external_metrics()
    |> join_festival_data()
    |> select_with_scores(normalized_weights)
    |> filter_by_min_score(normalized_weights, min_score)
    |> order_by_score(normalized_weights)
  end
  
  def apply_scoring(query, profile_name, options) when is_binary(profile_name) do
    case get_profile(profile_name) do
      nil -> apply_scoring(query, get_default_profile(), options)
      profile -> apply_scoring(query, profile, options)
    end
  end
  
  # Private functions
  
  defp get_category_weight(%MetricWeightProfile{category_weights: weights}, category, default) do
    Map.get(weights || %{}, category, default)
  end
  
  
  defp build_metric_weights_from_discovery(weights) do
    pop_weight = Map.get(weights, :popular_opinion, 0.25)
    crit_weight = Map.get(weights, :critical_acclaim, 0.25)
    award_weight = Map.get(weights, :industry_recognition, 0.25)
    cultural_weight = Map.get(weights, :cultural_impact, 0.25)
    
    %{
      # Popular Opinion metrics
      "imdb_rating" => pop_weight * 2,
      "tmdb_rating" => pop_weight * 2,
      "rotten_tomatoes_audience_score" => pop_weight * 1.5,
      "imdb_rating_votes" => pop_weight * 0.5,
      
      # Critical Acclaim metrics
      "metacritic_metascore" => crit_weight * 2,
      "rotten_tomatoes_tomatometer" => crit_weight * 2,
      
      # Industry Recognition metrics
      "oscar_wins" => award_weight * 3,
      "oscar_nominations" => award_weight * 2,
      "cannes_palme_dor" => award_weight * 2,
      "venice_golden_lion" => award_weight * 2,
      "berlin_golden_bear" => award_weight * 2,
      
      # Cultural Impact metrics
      "1001_movies" => cultural_weight * 2,
      "criterion" => cultural_weight * 2,
      "sight_sound_critics_2022" => cultural_weight * 1.5,
      "national_film_registry" => cultural_weight * 1.5
    }
  end
  
  defp normalize_weights(weights) do
    total = Enum.sum(Map.values(weights))
    
    if total == 0 do
      %{popular_opinion: 0.25, critical_acclaim: 0.25, 
        industry_recognition: 0.25, cultural_impact: 0.25}
    else
      Map.new(weights, fn {k, v} -> {k, v / total} end)
    end
  end
  
  defp join_external_metrics(query) do
    query
    |> join(:left, [m], em_tmdb in "external_metrics",
      on: em_tmdb.movie_id == m.id and 
          em_tmdb.source == "tmdb" and 
          em_tmdb.metric_type == "rating_average",
      as: :tmdb_rating
    )
    |> join(:left, [m], em_imdb in "external_metrics",
      on: em_imdb.movie_id == m.id and 
          em_imdb.source == "imdb" and 
          em_imdb.metric_type == "rating_average",
      as: :imdb_rating
    )
    |> join(:left, [m], em_meta in "external_metrics",
      on: em_meta.movie_id == m.id and 
          em_meta.source == "metacritic" and 
          em_meta.metric_type == "metascore",
      as: :metacritic
    )
    |> join(:left, [m], em_rt in "external_metrics",
      on: em_rt.movie_id == m.id and 
          em_rt.source == "rotten_tomatoes" and 
          em_rt.metric_type == "tomatometer",
      as: :rotten_tomatoes
    )
    |> join(:left, [m], em_pop in "external_metrics",
      on: em_pop.movie_id == m.id and 
          em_pop.source == "tmdb" and 
          em_pop.metric_type == "popularity_score",
      as: :popularity
    )
  end
  
  defp join_festival_data(query) do
    festival_subquery = 
      from(f in "festival_nominations",
        group_by: f.movie_id,
        select: %{
          movie_id: f.movie_id,
          wins: count(fragment("CASE WHEN ? = true THEN 1 END", f.won)),
          nominations: count(f.id)
        }
      )
    
    join(query, :left, [m], f in subquery(festival_subquery),
      on: f.movie_id == m.id,
      as: :festivals
    )
  end
  
  defp select_with_scores(query, weights) do
    select_merge(query,
      [m, tmdb_rating: tr, imdb_rating: ir, metacritic: mc, 
       rotten_tomatoes: rt, popularity: pop, festivals: f],
      %{
        discovery_score: fragment(
          "? * COALESCE((COALESCE(?, 0) / 10.0 * 0.5 + COALESCE(?, 0) / 10.0 * 0.5), 0) + ? * COALESCE((COALESCE(?, 0) / 100.0 * 0.5 + COALESCE(?, 0) / 100.0 * 0.5), 0) + ? * COALESCE(LEAST(1.0, (COALESCE(?, 0) * 0.2 + COALESCE(?, 0) * 0.05)), 0) + ? * COALESCE(LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + COALESCE(?, 0) / 1000.0), 0)",
          ^weights.popular_opinion, tr.value, ir.value,
          ^weights.critical_acclaim, mc.value, rt.value,
          ^weights.industry_recognition, f.wins, f.nominations,
          ^weights.cultural_impact, m.canonical_sources, pop.value
        ),
        score_components: %{
          popular_opinion: fragment(
            "COALESCE((COALESCE(?, 0) / 10.0 * 0.5 + COALESCE(?, 0) / 10.0 * 0.5), 0)",
            tr.value, ir.value
          ),
          critical_acclaim: fragment(
            "COALESCE((COALESCE(?, 0) / 100.0 * 0.5 + COALESCE(?, 0) / 100.0 * 0.5), 0)",
            mc.value, rt.value
          ),
          industry_recognition: fragment(
            "COALESCE(LEAST(1.0, (COALESCE(?, 0) * 0.2 + COALESCE(?, 0) * 0.05)), 0)",
            f.wins, f.nominations
          ),
          cultural_impact: fragment(
            "COALESCE(LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + COALESCE(?, 0) / 1000.0), 0)",
            m.canonical_sources, pop.value
          )
        }
      }
    )
  end
  
  defp filter_by_min_score(query, weights, min_score) do
    where(query,
      [m, tmdb_rating: tr, imdb_rating: ir, metacritic: mc,
       rotten_tomatoes: rt, popularity: pop, festivals: f],
      fragment(
        "? * COALESCE((COALESCE(?, 0) / 10.0 * 0.5 + COALESCE(?, 0) / 10.0 * 0.5), 0) + ? * COALESCE((COALESCE(?, 0) / 100.0 * 0.5 + COALESCE(?, 0) / 100.0 * 0.5), 0) + ? * COALESCE(LEAST(1.0, (COALESCE(?, 0) * 0.2 + COALESCE(?, 0) * 0.05)), 0) + ? * COALESCE(LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + COALESCE(?, 0) / 1000.0), 0) >= ?",
        ^weights.popular_opinion, tr.value, ir.value,
        ^weights.critical_acclaim, mc.value, rt.value,
        ^weights.industry_recognition, f.wins, f.nominations,
        ^weights.cultural_impact, m.canonical_sources, pop.value,
        ^min_score
      )
    )
  end
  
  defp order_by_score(query, weights) do
    order_by(query,
      [m, tmdb_rating: tr, imdb_rating: ir, metacritic: mc,
       rotten_tomatoes: rt, popularity: pop, festivals: f],
      desc: fragment(
        "? * COALESCE((COALESCE(?, 0) / 10.0 * 0.5 + COALESCE(?, 0) / 10.0 * 0.5), 0) + ? * COALESCE((COALESCE(?, 0) / 100.0 * 0.5 + COALESCE(?, 0) / 100.0 * 0.5), 0) + ? * COALESCE(LEAST(1.0, (COALESCE(?, 0) * 0.2 + COALESCE(?, 0) * 0.05)), 0) + ? * COALESCE(LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + COALESCE(?, 0) / 1000.0), 0)",
        ^weights.popular_opinion, tr.value, ir.value,
        ^weights.critical_acclaim, mc.value, rt.value,
        ^weights.industry_recognition, f.wins, f.nominations,
        ^weights.cultural_impact, m.canonical_sources, pop.value
      )
    )
  end
end