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
    get_profile(normalize_profile_name(name))
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
  Maps category_weights to the five main dimensions including People quality.
  
  Note: 
  - "ratings" category is split into popular_opinion and critical_acclaim
  - "financial" category is folded into cultural_impact (box office success affects cultural penetration)
  - "people" category represents person quality scores (directors, actors, etc.)
  """
  def profile_to_discovery_weights(%MetricWeightProfile{} = profile) do
    ratings_weight = get_category_weight(profile, "ratings", 0.4)
    financial_weight = get_category_weight(profile, "financial", 0.0)
    cultural_weight = get_category_weight(profile, "cultural", 0.2)
    people_weight = get_category_weight(profile, "people", 0.2)
    awards_weight = get_category_weight(profile, "awards", 0.2)
    
    # Normalize category weights to sum to 1.0
    total = ratings_weight + financial_weight + cultural_weight + people_weight + awards_weight
    {ratings_weight, financial_weight, cultural_weight, people_weight, awards_weight} = 
      if total > 0 do
        {ratings_weight / total, financial_weight / total, cultural_weight / total, 
         people_weight / total, awards_weight / total}
      else
        {ratings_weight, financial_weight, cultural_weight, people_weight, awards_weight}
      end
    
    # Split ratings into popular and critical based on the profile
    # For now, we'll split it 50/50 for popular vs critical within ratings
    # This could be refined based on individual metric weights
    %{
      popular_opinion: ratings_weight * 0.5,      # Half of ratings weight
      critical_acclaim: ratings_weight * 0.5,     # Half of ratings weight  
      industry_recognition: awards_weight,
      # Financial success contributes to cultural impact (box office affects cultural penetration)
      cultural_impact: cultural_weight + financial_weight * 0.5,
      # Person quality from directors, actors, writers, etc.
      people_quality: people_weight
    }
  end
  
  @doc """
  Converts discovery UI weights back to database format for custom profiles.
  """
  def discovery_weights_to_profile(weights, name \\ "Custom") do
    # Normalize weights to ensure they sum to 1.0
    total = Enum.sum(Map.values(weights))
    normalized_weights = if total > 0 do
      Map.new(weights, fn {k, v} -> {k, v / total} end)
    else
      # Default equal weights if all are zero
      %{popular_opinion: 0.2, critical_acclaim: 0.2, 
        industry_recognition: 0.2, cultural_impact: 0.2, people_quality: 0.2}
    end
    
    %{
      name: name,
      description: "Custom weight profile created from discovery UI",
      category_weights: %{
        "ratings" => Map.get(normalized_weights, :popular_opinion, 0.2) + Map.get(normalized_weights, :critical_acclaim, 0.2),
        "awards" => Map.get(normalized_weights, :industry_recognition, 0.2),
        # Financial impact is not directly represented in discovery weights
        "financial" => Map.get(normalized_weights, :financial_impact, 0.0),
        "cultural" => Map.get(normalized_weights, :cultural_impact, 0.2),
        "people" => Map.get(normalized_weights, :people_quality, 0.2)
      },
      weights: build_metric_weights_from_discovery(normalized_weights),
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
    |> join_person_quality_data()
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
  
  @doc """
  Adds discovery scores to a query for display purposes without affecting sorting.
  Used when we want movie cards to show scores but preserve custom sorting.
  """
  def add_scores_for_display(query, profile_or_name)
  
  def add_scores_for_display(query, %MetricWeightProfile{} = profile) do
    discovery_weights = profile_to_discovery_weights(profile)
    normalized_weights = normalize_weights(discovery_weights)
    
    query
    |> join_external_metrics()
    |> join_festival_data()
    |> join_person_quality_data()
    |> select_with_scores(normalized_weights)
    # Note: No ordering or filtering - just adds the score fields
  end
  
  def add_scores_for_display(query, profile_name) when is_binary(profile_name) do
    case get_profile(profile_name) do
      nil -> add_scores_for_display(query, get_default_profile())
      profile -> add_scores_for_display(query, profile)
    end
  end
  
  @doc """
  Normalizes a profile name from atom or string format to title case.
  """
  def normalize_profile_name(name) when is_atom(name) do
    name |> Atom.to_string() |> normalize_profile_name()
  end
  
  def normalize_profile_name(name) when is_binary(name) do
    name
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
  
  # Private functions
  
  defp get_category_weight(%MetricWeightProfile{category_weights: weights}, category, default) do
    Map.get(weights || %{}, category, default)
  end
  
  # Note: SQL fragment extraction isn't feasible with Ecto's query compilation
  # The discovery score calculation is kept inline in each context for now
  
  
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
      %{popular_opinion: 0.2, critical_acclaim: 0.2, 
        industry_recognition: 0.2, cultural_impact: 0.2, people_quality: 0.2}
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
  
  defp join_person_quality_data(query) do
    # Get the average person quality score for each movie
    # This includes directors, actors, writers, etc. with quality scores
    person_quality_subquery =
      from(mc in "movie_credits",
        join: pm in "person_metrics", on: pm.person_id == mc.person_id,
        where: pm.metric_type == "quality_score",
        group_by: mc.movie_id,
        select: %{
          movie_id: mc.movie_id,
          avg_person_quality: avg(pm.score),
          director_quality: avg(fragment("CASE WHEN ? IN ('Directing', 'Director') THEN ? END", mc.job, pm.score)),
          actor_quality: avg(fragment("CASE WHEN ? IN ('Acting', 'Actor') THEN ? END", mc.department, pm.score)),
          total_quality_people: count(fragment("DISTINCT ?", mc.person_id))
        }
      )
    
    join(query, :left, [m], pq in subquery(person_quality_subquery),
      on: pq.movie_id == m.id,
      as: :person_quality
    )
  end
  
  defp select_with_scores(query, weights) do
    select_merge(query,
      [m, tmdb_rating: tr, imdb_rating: ir, metacritic: mc, 
       rotten_tomatoes: rt, popularity: pop, festivals: f, person_quality: pq],
      %{
        # Include the calculated discovery score in the select list
        # This ensures it's available for ORDER BY when DISTINCT is applied
        discovery_score: fragment(
          """
          ? * COALESCE((COALESCE(?, 0) / 10.0 * 0.5 + COALESCE(?, 0) / 10.0 * 0.5), 0) + 
          ? * COALESCE((COALESCE(?, 0) / 100.0 * 0.5 + COALESCE(?, 0) / 100.0 * 0.5), 0) + 
          ? * COALESCE(LEAST(1.0, (COALESCE(?, 0) * 0.2 + COALESCE(?, 0) * 0.05)), 0) + 
          ? * COALESCE(LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + CASE WHEN COALESCE(?, 0) = 0 THEN 0 ELSE LN(COALESCE(?, 0) + 1) / LN(1001) END), 0) +
          ? * COALESCE(COALESCE(?, 0) / 100.0, 0)
          """,
          ^weights.popular_opinion, tr.value, ir.value,
          ^weights.critical_acclaim, mc.value, rt.value,
          ^weights.industry_recognition, f.wins, f.nominations,
          ^weights.cultural_impact, m.canonical_sources, pop.value, pop.value,
          ^weights.people_quality, pq.avg_person_quality
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
            "COALESCE(LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + CASE WHEN COALESCE(?, 0) = 0 THEN 0 ELSE LN(COALESCE(?, 0) + 1) / LN(1001) END), 0)",
            m.canonical_sources, pop.value, pop.value
          ),
          people_quality: fragment(
            "COALESCE(COALESCE(?, 0) / 100.0, 0)",
            pq.avg_person_quality
          )
        }
      }
    )
  end
  
  defp filter_by_min_score(query, weights, min_score) do
    where(query,
      [m, tmdb_rating: tr, imdb_rating: ir, metacritic: mc,
       rotten_tomatoes: rt, popularity: pop, festivals: f, person_quality: pq],
fragment(
        "? * COALESCE((COALESCE(?, 0) / 10.0 * 0.5 + COALESCE(?, 0) / 10.0 * 0.5), 0) + ? * COALESCE((COALESCE(?, 0) / 100.0 * 0.5 + COALESCE(?, 0) / 100.0 * 0.5), 0) + ? * COALESCE(LEAST(1.0, (COALESCE(?, 0) * 0.2 + COALESCE(?, 0) * 0.05)), 0) + ? * COALESCE(LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + CASE WHEN COALESCE(?, 0) = 0 THEN 0 ELSE LN(COALESCE(?, 0) + 1) / LN(1001) END), 0) + ? * COALESCE(COALESCE(?, 0) / 100.0, 0) >= ?",
        ^weights.popular_opinion, tr.value, ir.value,
        ^weights.critical_acclaim, mc.value, rt.value,
        ^weights.industry_recognition, f.wins, f.nominations,
        ^weights.cultural_impact, m.canonical_sources, pop.value, pop.value,
        ^weights.people_quality, pq.avg_person_quality,
        ^min_score
      )
    )
  end
  
  defp order_by_score(query, weights) do
    order_by(query,
      [m, tmdb_rating: tr, imdb_rating: ir, metacritic: mc,
       rotten_tomatoes: rt, popularity: pop, festivals: f, person_quality: pq],
      desc: fragment(
        "? * COALESCE((COALESCE(?, 0) / 10.0 * 0.5 + COALESCE(?, 0) / 10.0 * 0.5), 0) + ? * COALESCE((COALESCE(?, 0) / 100.0 * 0.5 + COALESCE(?, 0) / 100.0 * 0.5), 0) + ? * COALESCE(LEAST(1.0, (COALESCE(?, 0) * 0.2 + COALESCE(?, 0) * 0.05)), 0) + ? * COALESCE(LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + CASE WHEN COALESCE(?, 0) = 0 THEN 0 ELSE LN(COALESCE(?, 0) + 1) / LN(1001) END), 0) + ? * COALESCE(COALESCE(?, 0) / 100.0, 0)",
        ^weights.popular_opinion, tr.value, ir.value,
        ^weights.critical_acclaim, mc.value, rt.value,
        ^weights.industry_recognition, f.wins, f.nominations,
        ^weights.cultural_impact, m.canonical_sources, pop.value, pop.value,
        ^weights.people_quality, pq.avg_person_quality
      )
    )
  end
end