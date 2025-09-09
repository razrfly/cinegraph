defmodule Cinegraph.Metrics.ScoringService do
  @moduledoc """
  Service module for calculating movie scores using database-driven weight profiles.
  Replaces the hard-coded discovery scoring system with a flexible, database-backed approach.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo
  alias Cinegraph.Metrics.MetricWeightProfile

  require Logger

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
    try do
      Repo.get_by(MetricWeightProfile, is_default: true, active: true) ||
        get_profile("Balanced")
    rescue
      e in [DBConnection.ConnectionError, Postgrex.Error, Ecto.QueryError] ->
        Logger.error("Failed to load default profile (DB error): #{inspect(e)}")
        fallback_profile()
    else
      nil ->
        # No default/Balanced rows found; use fallback to honor non-nil contract
        Logger.warning("No default or Balanced profile found, using fallback")
        fallback_profile()

      profile ->
        profile
    end
  end

  # Private helper to create consistent fallback profile
  defp fallback_profile do
    # Emit telemetry for ops visibility when fallback is used
    :telemetry.execute([:cinegraph, :scoring_service, :fallback_profile_used], %{count: 1}, %{})

    %MetricWeightProfile{
      name: "Fallback",
      description: "Emergency fallback profile",
      category_weights: %{
        "popular_opinion" => 0.20,
        "awards" => 0.20,
        "cultural" => 0.20,
        "people" => 0.20,
        "financial" => 0.20
      },
      weights: %{},
      active: true,
      is_default: true
    }
  end

  @doc """
  Converts a database weight profile to the format expected by the discovery UI.
  Maps category_weights to the four main dimensions including People quality.

  Note: 
  - "popular_opinion" category includes all rating sources (IMDb, TMDb, Metacritic, RT)
  - "financial" category is folded into cultural_impact (box office success affects cultural penetration)
  - "people" category represents person quality scores (directors, actors, etc.)
  """
  def profile_to_discovery_weights(%MetricWeightProfile{} = profile) do
    # Use popular_opinion if it exists, otherwise fall back to ratings for backward compatibility
    popular_weight =
      get_category_weight(
        profile,
        "popular_opinion",
        get_category_weight(profile, "ratings", 0.4)
      )

    financial_weight = get_category_weight(profile, "financial", 0.0)
    cultural_weight = get_category_weight(profile, "cultural", 0.2)
    people_weight = get_category_weight(profile, "people", 0.2)

    # All rating sources are now combined into popular_opinion
    %{
      popular_opinion: popular_weight,
      industry_recognition: get_category_weight(profile, "awards", 0.2),
      # Cultural impact (separate from financial now that we expose both)
      cultural_impact: cultural_weight,
      # Person quality from directors, actors, writers, etc.
      people_quality: people_weight,
      # Financial success as separate dimension for UI control
      financial_success: financial_weight
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
        "popular_opinion" => Map.get(weights, :popular_opinion, 0.2),
        "awards" => Map.get(weights, :industry_recognition, 0.2),
        "financial" => Map.get(weights, :financial_success, 0.2),
        "cultural" => Map.get(weights, :cultural_impact, 0.2),
        "people" => Map.get(weights, :people_quality, 0.2)
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

    # Drop financial_success for query execution since SQL fragments only handle 4 dimensions
    # TODO: In the future, integrate financial data joins and scoring fragments
    query_weights = Map.drop(normalized_weights, [:financial_success])

    # Use the same query structure as DiscoveryScoringSimple but with database weights
    query
    |> join_external_metrics()
    |> join_festival_data()
    |> join_person_quality_data()
    |> select_with_scores(query_weights)
    |> filter_by_min_score(query_weights, min_score)
    |> order_by_score(query_weights)
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

    # Drop financial_success for query execution since SQL fragments only handle 4 dimensions
    query_weights = Map.drop(normalized_weights, [:financial_success])

    query
    |> join_external_metrics()
    |> join_festival_data()
    |> join_person_quality_data()
    |> select_with_scores(query_weights)

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
    value = Map.get(weights || %{}, category, default)
    # Ensure we always return a number
    case value do
      nil -> default
      v when is_number(v) -> v
      _ -> default
    end
  end

  # Note: SQL fragment extraction isn't feasible with Ecto's query compilation
  # The discovery score calculation is kept inline in each context for now

  defp build_metric_weights_from_discovery(weights) do
    # All rating sources now combined under popular_opinion
    pop_weight = Map.get(weights, :popular_opinion, 0.4)
    award_weight = Map.get(weights, :industry_recognition, 0.2)
    cultural_weight = Map.get(weights, :cultural_impact, 0.2)

    %{
      # Popular Opinion metrics (all rating sources)
      "imdb_rating" => pop_weight * 1.0,
      "tmdb_rating" => pop_weight * 1.0,
      "metacritic_metascore" => pop_weight * 1.0,
      "rotten_tomatoes_tomatometer" => pop_weight * 1.0,
      "rotten_tomatoes_audience_score" => pop_weight * 0.8,
      "imdb_rating_votes" => pop_weight * 0.5,

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
      %{
        popular_opinion: 0.20,
        industry_recognition: 0.20,
        cultural_impact: 0.20,
        people_quality: 0.20,
        financial_success: 0.20
      }
    else
      Map.new(weights, fn {k, v} -> {k, v / total} end)
    end
  end

  defp join_external_metrics(query) do
    query
    |> join(:left, [m], em_tmdb in "external_metrics",
      on:
        em_tmdb.movie_id == m.id and
          em_tmdb.source == "tmdb" and
          em_tmdb.metric_type == "rating_average",
      as: :tmdb_rating
    )
    |> join(:left, [m], em_imdb in "external_metrics",
      on:
        em_imdb.movie_id == m.id and
          em_imdb.source == "imdb" and
          em_imdb.metric_type == "rating_average",
      as: :imdb_rating
    )
    |> join(:left, [m], em_meta in "external_metrics",
      on:
        em_meta.movie_id == m.id and
          em_meta.source == "metacritic" and
          em_meta.metric_type == "metascore",
      as: :metacritic
    )
    |> join(:left, [m], em_rt in "external_metrics",
      on:
        em_rt.movie_id == m.id and
          em_rt.source == "rotten_tomatoes" and
          em_rt.metric_type == "tomatometer",
      as: :rotten_tomatoes
    )
    |> join(:left, [m], em_pop in "external_metrics",
      on:
        em_pop.movie_id == m.id and
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
        join: pm in "person_metrics",
        on: pm.person_id == mc.person_id,
        where: pm.metric_type == "quality_score",
        group_by: mc.movie_id,
        select: %{
          movie_id: mc.movie_id,
          avg_person_quality: avg(pm.score),
          director_quality:
            avg(fragment("CASE WHEN ? IN ('Directing', 'Director') THEN ? END", mc.job, pm.score)),
          actor_quality:
            avg(
              fragment("CASE WHEN ? IN ('Acting', 'Actor') THEN ? END", mc.department, pm.score)
            ),
          total_quality_people: count(fragment("DISTINCT ?", mc.person_id))
        }
      )

    join(query, :left, [m], pq in subquery(person_quality_subquery),
      on: pq.movie_id == m.id,
      as: :person_quality
    )
  end

  defp select_with_scores(query, weights) do
    # Check if the query already has a GROUP BY clause (e.g., from genre filtering)
    # If it does, we need to handle the selection differently
    if has_group_by?(query) do
      select_with_scores_grouped(query, weights)
    else
      select_with_scores_ungrouped(query, weights)
    end
  end

  defp has_group_by?(query) do
    # Check if the query has a group_by clause
    query.group_bys != []
  end

  defp select_with_scores_ungrouped(query, weights) do
    select_merge(
      query,
      [
        m,
        tmdb_rating: tr,
        imdb_rating: ir,
        metacritic: mc,
        rotten_tomatoes: rt,
        popularity: pop,
        festivals: f,
        person_quality: pq
      ],
      %{
        discovery_score:
          fragment(
            """
            ? * COALESCE((COALESCE(?, 0) / 10.0 * 0.25 + COALESCE(?, 0) / 10.0 * 0.25 + COALESCE(?, 0) / 100.0 * 0.25 + COALESCE(?, 0) / 100.0 * 0.25), 0) + 
            ? * COALESCE(LEAST(1.0, (COALESCE(?, 0) * 0.2 + COALESCE(?, 0) * 0.05)), 0) + 
            ? * COALESCE(LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + CASE WHEN COALESCE(?, 0) = 0 THEN 0 ELSE LN(COALESCE(?, 0) + 1) / LN(1001) END), 0) +
            ? * COALESCE(COALESCE(?, 0) / 100.0, 0)
            """,
            ^weights.popular_opinion,
            tr.value,
            ir.value,
            mc.value,
            rt.value,
            ^weights.industry_recognition,
            f.wins,
            f.nominations,
            ^weights.cultural_impact,
            m.canonical_sources,
            pop.value,
            pop.value,
            ^weights.people_quality,
            pq.avg_person_quality
          ),
        score_components: %{
          popular_opinion:
            fragment(
              "COALESCE((COALESCE(?, 0) / 10.0 * 0.25 + COALESCE(?, 0) / 10.0 * 0.25 + COALESCE(?, 0) / 100.0 * 0.25 + COALESCE(?, 0) / 100.0 * 0.25), 0)",
              tr.value,
              ir.value,
              mc.value,
              rt.value
            ),
          industry_recognition:
            fragment(
              "COALESCE(LEAST(1.0, (COALESCE(?, 0) * 0.2 + COALESCE(?, 0) * 0.05)), 0)",
              f.wins,
              f.nominations
            ),
          cultural_impact:
            fragment(
              "COALESCE(LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + CASE WHEN COALESCE(?, 0) = 0 THEN 0 ELSE LN(COALESCE(?, 0) + 1) / LN(1001) END), 0)",
              m.canonical_sources,
              pop.value,
              pop.value
            ),
          people_quality:
            fragment(
              "COALESCE(COALESCE(?, 0) / 100.0, 0)",
              pq.avg_person_quality
            )
        }
      }
    )
  end

  defp select_with_scores_grouped(query, weights) do
    # When using GROUP BY, we need to use aggregate functions or include columns in GROUP BY
    # Using MAX() here since we're grouping by movie ID, so there's only one value per group
    select_merge(
      query,
      [
        m,
        tmdb_rating: tr,
        imdb_rating: ir,
        metacritic: mc,
        rotten_tomatoes: rt,
        popularity: pop,
        festivals: f,
        person_quality: pq
      ],
      %{
        discovery_score:
          fragment(
            """
            ? * COALESCE((COALESCE(MAX(?), 0) / 10.0 * 0.25 + COALESCE(MAX(?), 0) / 10.0 * 0.25 + COALESCE(MAX(?), 0) / 100.0 * 0.25 + COALESCE(MAX(?), 0) / 100.0 * 0.25), 0) + 
            ? * COALESCE(LEAST(1.0, (COALESCE(MAX(?), 0) * 0.2 + COALESCE(MAX(?), 0) * 0.05)), 0) + 
            ? * COALESCE(LEAST(1.0, COALESCE(MAX((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb)))), 0) * 0.1 + CASE WHEN COALESCE(MAX(?), 0) = 0 THEN 0 ELSE LN(COALESCE(MAX(?), 0) + 1) / LN(1001) END), 0) +
            ? * COALESCE(COALESCE(MAX(?), 0) / 100.0, 0)
            """,
            ^weights.popular_opinion,
            tr.value,
            ir.value,
            mc.value,
            rt.value,
            ^weights.industry_recognition,
            f.wins,
            f.nominations,
            ^weights.cultural_impact,
            m.canonical_sources,
            pop.value,
            pop.value,
            ^weights.people_quality,
            pq.avg_person_quality
          ),
        score_components: %{
          popular_opinion:
            fragment(
              "COALESCE((COALESCE(MAX(?), 0) / 10.0 * 0.25 + COALESCE(MAX(?), 0) / 10.0 * 0.25 + COALESCE(MAX(?), 0) / 100.0 * 0.25 + COALESCE(MAX(?), 0) / 100.0 * 0.25), 0)",
              tr.value,
              ir.value,
              mc.value,
              rt.value
            ),
          industry_recognition:
            fragment(
              "COALESCE(LEAST(1.0, (COALESCE(MAX(?), 0) * 0.2 + COALESCE(MAX(?), 0) * 0.05)), 0)",
              f.wins,
              f.nominations
            ),
          cultural_impact:
            fragment(
              "COALESCE(LEAST(1.0, COALESCE(MAX((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb)))), 0) * 0.1 + CASE WHEN COALESCE(MAX(?), 0) = 0 THEN 0 ELSE LN(COALESCE(MAX(?), 0) + 1) / LN(1001) END), 0)",
              m.canonical_sources,
              pop.value,
              pop.value
            ),
          people_quality:
            fragment(
              "COALESCE(COALESCE(MAX(?), 0) / 100.0, 0)",
              pq.avg_person_quality
            )
        }
      }
    )
  end

  defp filter_by_min_score(query, weights, min_score) do
    if has_group_by?(query) do
      # When grouped, use HAVING instead of WHERE and aggregate functions
      having(
        query,
        [
          m,
          tmdb_rating: tr,
          imdb_rating: ir,
          metacritic: mc,
          rotten_tomatoes: rt,
          popularity: pop,
          festivals: f,
          person_quality: pq
        ],
        fragment(
          "? * COALESCE((COALESCE(MAX(?), 0) / 10.0 * 0.25 + COALESCE(MAX(?), 0) / 10.0 * 0.25 + COALESCE(MAX(?), 0) / 100.0 * 0.25 + COALESCE(MAX(?), 0) / 100.0 * 0.25), 0) + ? * COALESCE(LEAST(1.0, (COALESCE(MAX(?), 0) * 0.2 + COALESCE(MAX(?), 0) * 0.05)), 0) + ? * COALESCE(LEAST(1.0, COALESCE(MAX((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb)))), 0) * 0.1 + CASE WHEN COALESCE(MAX(?), 0) = 0 THEN 0 ELSE LN(COALESCE(MAX(?), 0) + 1) / LN(1001) END), 0) + ? * COALESCE(COALESCE(MAX(?), 0) / 100.0, 0) >= ?",
          ^weights.popular_opinion,
          tr.value,
          ir.value,
          mc.value,
          rt.value,
          ^weights.industry_recognition,
          f.wins,
          f.nominations,
          ^weights.cultural_impact,
          m.canonical_sources,
          pop.value,
          pop.value,
          ^weights.people_quality,
          pq.avg_person_quality,
          ^min_score
        )
      )
    else
      where(
        query,
        [
          m,
          tmdb_rating: tr,
          imdb_rating: ir,
          metacritic: mc,
          rotten_tomatoes: rt,
          popularity: pop,
          festivals: f,
          person_quality: pq
        ],
        fragment(
          "? * COALESCE((COALESCE(?, 0) / 10.0 * 0.25 + COALESCE(?, 0) / 10.0 * 0.25 + COALESCE(?, 0) / 100.0 * 0.25 + COALESCE(?, 0) / 100.0 * 0.25), 0) + ? * COALESCE(LEAST(1.0, (COALESCE(?, 0) * 0.2 + COALESCE(?, 0) * 0.05)), 0) + ? * COALESCE(LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + CASE WHEN COALESCE(?, 0) = 0 THEN 0 ELSE LN(COALESCE(?, 0) + 1) / LN(1001) END), 0) + ? * COALESCE(COALESCE(?, 0) / 100.0, 0) >= ?",
          ^weights.popular_opinion,
          tr.value,
          ir.value,
          mc.value,
          rt.value,
          ^weights.industry_recognition,
          f.wins,
          f.nominations,
          ^weights.cultural_impact,
          m.canonical_sources,
          pop.value,
          pop.value,
          ^weights.people_quality,
          pq.avg_person_quality,
          ^min_score
        )
      )
    end
  end

  defp order_by_score(query, weights) do
    if has_group_by?(query) do
      order_by(
        query,
        [
          m,
          tmdb_rating: tr,
          imdb_rating: ir,
          metacritic: mc,
          rotten_tomatoes: rt,
          popularity: pop,
          festivals: f,
          person_quality: pq
        ],
        desc:
          fragment(
            "? * COALESCE((COALESCE(MAX(?), 0) / 10.0 * 0.25 + COALESCE(MAX(?), 0) / 10.0 * 0.25 + COALESCE(MAX(?), 0) / 100.0 * 0.25 + COALESCE(MAX(?), 0) / 100.0 * 0.25), 0) + ? * COALESCE(LEAST(1.0, (COALESCE(MAX(?), 0) * 0.2 + COALESCE(MAX(?), 0) * 0.05)), 0) + ? * COALESCE(LEAST(1.0, COALESCE(MAX((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb)))), 0) * 0.1 + CASE WHEN COALESCE(MAX(?), 0) = 0 THEN 0 ELSE LN(COALESCE(MAX(?), 0) + 1) / LN(1001) END), 0) + ? * COALESCE(COALESCE(MAX(?), 0) / 100.0, 0)",
            ^weights.popular_opinion,
            tr.value,
            ir.value,
            mc.value,
            rt.value,
            ^weights.industry_recognition,
            f.wins,
            f.nominations,
            ^weights.cultural_impact,
            m.canonical_sources,
            pop.value,
            pop.value,
            ^weights.people_quality,
            pq.avg_person_quality
          )
      )
    else
      order_by(
        query,
        [
          m,
          tmdb_rating: tr,
          imdb_rating: ir,
          metacritic: mc,
          rotten_tomatoes: rt,
          popularity: pop,
          festivals: f,
          person_quality: pq
        ],
        desc:
          fragment(
            "? * COALESCE((COALESCE(?, 0) / 10.0 * 0.25 + COALESCE(?, 0) / 10.0 * 0.25 + COALESCE(?, 0) / 100.0 * 0.25 + COALESCE(?, 0) / 100.0 * 0.25), 0) + ? * COALESCE(LEAST(1.0, (COALESCE(?, 0) * 0.2 + COALESCE(?, 0) * 0.05)), 0) + ? * COALESCE(LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + CASE WHEN COALESCE(?, 0) = 0 THEN 0 ELSE LN(COALESCE(?, 0) + 1) / LN(1001) END), 0) + ? * COALESCE(COALESCE(?, 0) / 100.0, 0)",
            ^weights.popular_opinion,
            tr.value,
            ir.value,
            mc.value,
            rt.value,
            ^weights.industry_recognition,
            f.wins,
            f.nominations,
            ^weights.cultural_impact,
            m.canonical_sources,
            pop.value,
            pop.value,
            ^weights.people_quality,
            pq.avg_person_quality
          )
      )
    end
  end
end
