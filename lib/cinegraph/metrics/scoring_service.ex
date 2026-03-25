defmodule Cinegraph.Metrics.ScoringService do
  @moduledoc """
  Service module for calculating movie scores using database-driven weight profiles.
  Replaces the hard-coded discovery scoring system with a flexible, database-backed approach.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo
  alias Cinegraph.Metrics.MetricWeightProfile
  alias Cinegraph.Scoring.Lenses

  require Logger

  @default_category_weights Lenses.default_weights()

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
  Gets a weight profile by URL slug (e.g. "critics_choice" → "Critics Choice").
  """
  def get_profile_by_slug(slug) when is_binary(slug) do
    slug
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
    |> get_profile()
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
      category_weights: @default_category_weights,
      weights: %{},
      active: true,
      is_default: true
    }
  end

  @doc """
  Converts a database weight profile to the format expected by the discovery UI.
  Maps category_weights to the six scoring lenses.

  Note:
  - "box_office" represents box office success (revenue, budget, ROI)
  - "auteurs" represents person quality scores (directors, actors, etc.)
  """
  def profile_to_discovery_weights(%MetricWeightProfile{} = profile) do
    %{
      mob: get_category_weight(profile, "mob", @default_category_weights["mob"]),
      critics: get_category_weight(profile, "critics", @default_category_weights["critics"]),
      festival_recognition:
        get_category_weight(
          profile,
          "festival_recognition",
          @default_category_weights["festival_recognition"]
        ),
      time_machine:
        get_category_weight(
          profile,
          "time_machine",
          @default_category_weights["time_machine"]
        ),
      auteurs:
        get_category_weight(
          profile,
          "auteurs",
          @default_category_weights["auteurs"]
        ),
      box_office:
        get_category_weight(
          profile,
          "box_office",
          @default_category_weights["box_office"]
        )
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
        "mob" => Map.get(weights, :mob, @default_category_weights["mob"]),
        "critics" => Map.get(weights, :critics, @default_category_weights["critics"]),
        "festival_recognition" =>
          Map.get(
            weights,
            :festival_recognition,
            @default_category_weights["festival_recognition"]
          ),
        "box_office" =>
          Map.get(
            weights,
            :box_office,
            @default_category_weights["box_office"]
          ),
        "time_machine" =>
          Map.get(weights, :time_machine, @default_category_weights["time_machine"]),
        "auteurs" => Map.get(weights, :auteurs, @default_category_weights["auteurs"])
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
    mob_weight = Map.get(weights, :mob, 0.2)
    critics_weight = Map.get(weights, :critics, 0.2)
    award_weight = Map.get(weights, :festival_recognition, 0.2)
    cultural_weight = Map.get(weights, :time_machine, 0.2)

    %{
      # Mob (audience) metrics
      "imdb_rating" => mob_weight * 1.0,
      "tmdb_rating" => mob_weight * 1.0,
      "imdb_rating_votes" => mob_weight * 0.5,
      # Critics metrics
      "metacritic_metascore" => critics_weight * 1.0,
      "rotten_tomatoes_tomatometer" => critics_weight * 1.0,

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
      Lenses.default_atom_weights()
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
    |> join(:left, [m], em_rta in "external_metrics",
      on:
        em_rta.movie_id == m.id and
          em_rta.source == "rotten_tomatoes" and
          em_rta.metric_type == "audience_score",
      as: :rt_audience
    )
    |> join(:left, [m], em_pop in "external_metrics",
      on:
        em_pop.movie_id == m.id and
          em_pop.source == "tmdb" and
          em_pop.metric_type == "popularity_score",
      as: :popularity
    )
    |> join(:left, [m], em_budget in "external_metrics",
      on:
        em_budget.movie_id == m.id and
          em_budget.source == "tmdb" and
          em_budget.metric_type == "budget",
      as: :budget
    )
    |> join(:left, [m], em_revenue in "external_metrics",
      on:
        em_revenue.movie_id == m.id and
          em_revenue.source == "tmdb" and
          em_revenue.metric_type == "revenue_worldwide",
      as: :revenue
    )
  end

  defp join_festival_data(query) do
    festival_subquery =
      from(fnom in "festival_nominations",
        join: fc in "festival_categories",
        on: fnom.category_id == fc.id,
        join: fcer in "festival_ceremonies",
        on: fnom.ceremony_id == fcer.id,
        join: fo in "festival_organizations",
        on: fcer.organization_id == fo.id,
        group_by: fnom.movie_id,
        select: %{
          movie_id: fnom.movie_id,
          prestige_score:
            fragment(
              """
              LEAST(10.0, SUM(
                CASE ?
                  WHEN 'AMPAS'  THEN (CASE WHEN ? THEN 10.0 ELSE 8.0 END)
                  WHEN 'CFF'    THEN (CASE WHEN ? THEN 9.5  ELSE 7.5 END)
                  WHEN 'VIFF'   THEN (CASE WHEN ? THEN 9.0  ELSE 7.0 END)
                  WHEN 'BIFF'   THEN (CASE WHEN ? THEN 9.0  ELSE 7.0 END)
                  WHEN 'BAFTA'  THEN (CASE WHEN ? THEN 8.5  ELSE 6.5 END)
                  WHEN 'HFPA'   THEN (CASE WHEN ? THEN 8.0  ELSE 6.0 END)
                  WHEN 'SFF'    THEN (CASE WHEN ? THEN 7.5  ELSE 6.0 END)
                  WHEN 'CCA'    THEN (CASE WHEN ? THEN 7.0  ELSE 5.0 END)
                  ELSE               (CASE WHEN ? THEN 5.0  ELSE 3.0 END)
                END +
                CASE WHEN LOWER(?) LIKE ANY(ARRAY['%picture%','%film%','%director%'])
                     THEN 1.0 ELSE 0.0 END
              ))
              """,
              fo.abbreviation,
              fnom.won,
              fnom.won,
              fnom.won,
              fnom.won,
              fnom.won,
              fnom.won,
              fnom.won,
              fnom.won,
              fnom.won,
              fc.name
            )
        }
      )

    join(query, :left, [m], f in subquery(festival_subquery),
      on: f.movie_id == m.id,
      as: :festivals
    )
  end

  defp join_person_quality_data(query) do
    # Layer 1: dedup — max score + role weight per (movie, person)
    deduped =
      from(mc in "movie_credits",
        join: pm in "person_metrics",
        on: pm.person_id == mc.person_id and pm.metric_type == "quality_score",
        group_by: [mc.movie_id, mc.person_id],
        select: %{
          movie_id: mc.movie_id,
          person_id: mc.person_id,
          max_score: max(pm.score),
          role_weight:
            max(
              fragment(
                "CASE ? WHEN 'Directing' THEN 3.0 WHEN 'Writing' THEN 1.5 WHEN 'Production' THEN 1.0 ELSE CASE WHEN ? <= 3 THEN 2.0 WHEN ? <= 10 THEN 1.5 ELSE 1.0 END END",
                mc.department,
                mc.cast_order,
                mc.cast_order
              )
            )
        }
      )

    # Layer 2: rank by weighted score within each movie
    ranked =
      from(d in subquery(deduped),
        select: %{
          movie_id: d.movie_id,
          max_score: d.max_score,
          role_weight: d.role_weight,
          rn:
            fragment(
              "ROW_NUMBER() OVER (PARTITION BY ? ORDER BY ? * ? DESC)",
              d.movie_id,
              d.max_score,
              d.role_weight
            )
        }
      )

    # Layer 3: top-10, weighted average
    aggregated =
      from(r in subquery(ranked),
        where: r.rn <= 10,
        group_by: r.movie_id,
        select: %{
          movie_id: r.movie_id,
          avg_person_quality:
            fragment(
              "SUM(? * ?) / NULLIF(SUM(?), 0)",
              r.max_score,
              r.role_weight,
              r.role_weight
            ),
          total_quality_people: count(r.movie_id)
        }
      )

    join(query, :left, [m], pq in subquery(aggregated),
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
        rt_audience: ra,
        popularity: pop,
        festivals: f,
        person_quality: pq,
        budget: b,
        revenue: r
      ],
      %{
        discovery_score:
          fragment(
            """
            ? * COALESCE(
              (COALESCE(NULLIF(?, 0), 0) / 10.0 +
               COALESCE(NULLIF(?, 0), 0) / 10.0 +
               COALESCE(NULLIF(?, 0), 0) / 100.0) /
              NULLIF(
                CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END +
                CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END +
                CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END,
                0
              ),
              0.0
            ) +
            ? * CASE
              WHEN NULLIF(?, 0) IS NOT NULL AND NULLIF(?, 0) IS NOT NULL THEN (? / 100.0 + ? / 100.0) / 2.0
              WHEN NULLIF(?, 0) IS NOT NULL THEN ? / 100.0
              WHEN NULLIF(?, 0) IS NOT NULL THEN ? / 100.0
              ELSE 0.0
            END +
            ? * COALESCE(LEAST(1.0, COALESCE(?, 0) / 10.0), 0) +
            ? * COALESCE(LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + CASE WHEN COALESCE(?, 0) = 0 THEN 0 ELSE LN(COALESCE(?, 0) + 1) / LN(1001) END), 0) +
            ? * COALESCE(COALESCE(?, 0) / 100.0, 0) +
            ? * COALESCE(CASE
              WHEN COALESCE(?, 0) > 0 AND COALESCE(?, 0) > 0
              THEN LEAST(1.0, (LN(COALESCE(?, 0) + 1) / LN(1000000000)) * 0.6 + (COALESCE(?, 0) / COALESCE(?, 0)) * 0.4)
              ELSE COALESCE(LN(COALESCE(?, 0) + 1) / LN(1000000000), 0)
            END, 0)
            """,
            ^Map.get(weights, :mob, 0.0),
            ir.value,
            tr.value,
            ra.value,
            ir.value,
            tr.value,
            ra.value,
            ^Map.get(weights, :critics, 0.0),
            rt.value,
            mc.value,
            rt.value,
            mc.value,
            rt.value,
            rt.value,
            mc.value,
            mc.value,
            ^weights.festival_recognition,
            f.prestige_score,
            ^weights.time_machine,
            m.canonical_sources,
            pop.value,
            pop.value,
            ^weights.auteurs,
            pq.avg_person_quality,
            ^Map.get(weights, :box_office, 0.0),
            b.value,
            r.value,
            r.value,
            r.value,
            b.value,
            r.value
          ),
        mob_score:
          fragment(
            "COALESCE((COALESCE(NULLIF(?, 0), 0) / 10.0 + COALESCE(NULLIF(?, 0), 0) / 10.0 + COALESCE(NULLIF(?, 0), 0) / 100.0) / NULLIF(CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END + CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END + CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END, 0), 0.0)",
            ir.value,
            tr.value,
            ra.value,
            ir.value,
            tr.value,
            ra.value
          ),
        critics_score:
          fragment(
            "CASE WHEN NULLIF(?, 0) IS NOT NULL AND NULLIF(?, 0) IS NOT NULL THEN (? / 100.0 + ? / 100.0) / 2.0 WHEN NULLIF(?, 0) IS NOT NULL THEN ? / 100.0 WHEN NULLIF(?, 0) IS NOT NULL THEN ? / 100.0 ELSE 0.0 END",
            rt.value,
            mc.value,
            rt.value,
            mc.value,
            rt.value,
            rt.value,
            mc.value,
            mc.value
          ),
        score_confidence:
          fragment(
            "(CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END + CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END + CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END + CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END + CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END) / 5.0",
            ir.value,
            tr.value,
            rt.value,
            mc.value,
            ra.value
          ),
        score_components: %{
          mob:
            fragment(
              "COALESCE((COALESCE(NULLIF(?, 0), 0) / 10.0 + COALESCE(NULLIF(?, 0), 0) / 10.0 + COALESCE(NULLIF(?, 0), 0) / 100.0) / NULLIF(CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END + CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END + CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END, 0), 0.0)",
              ir.value,
              tr.value,
              ra.value,
              ir.value,
              tr.value,
              ra.value
            ),
          critics:
            fragment(
              "CASE WHEN NULLIF(?, 0) IS NOT NULL AND NULLIF(?, 0) IS NOT NULL THEN (? / 100.0 + ? / 100.0) / 2.0 WHEN NULLIF(?, 0) IS NOT NULL THEN ? / 100.0 WHEN NULLIF(?, 0) IS NOT NULL THEN ? / 100.0 ELSE 0.0 END",
              rt.value,
              mc.value,
              rt.value,
              mc.value,
              rt.value,
              rt.value,
              mc.value,
              mc.value
            ),
          festival_recognition:
            fragment(
              "COALESCE(LEAST(1.0, COALESCE(?, 0) / 10.0), 0)",
              f.prestige_score
            ),
          time_machine:
            fragment(
              "COALESCE(LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + CASE WHEN COALESCE(?, 0) = 0 THEN 0 ELSE LN(COALESCE(?, 0) + 1) / LN(1001) END), 0)",
              m.canonical_sources,
              pop.value,
              pop.value
            ),
          auteurs:
            fragment(
              "COALESCE(COALESCE(?, 0) / 100.0, 0)",
              pq.avg_person_quality
            ),
          box_office:
            fragment(
              """
              COALESCE(CASE
                WHEN COALESCE(?, 0) > 0 AND COALESCE(?, 0) > 0
                THEN LEAST(1.0, (LN(COALESCE(?, 0) + 1) / LN(1000000000)) * 0.6 + (COALESCE(?, 0) / COALESCE(?, 0)) * 0.4)
                ELSE COALESCE(LN(COALESCE(?, 0) + 1) / LN(1000000000), 0)
              END, 0)
              """,
              b.value,
              r.value,
              r.value,
              r.value,
              b.value,
              r.value
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
        rt_audience: ra,
        popularity: pop,
        festivals: f,
        person_quality: pq,
        budget: b,
        revenue: r
      ],
      %{
        discovery_score:
          fragment(
            """
            ? * COALESCE(
              (COALESCE(NULLIF(MAX(?), 0), 0) / 10.0 +
               COALESCE(NULLIF(MAX(?), 0), 0) / 10.0 +
               COALESCE(NULLIF(MAX(?), 0), 0) / 100.0) /
              NULLIF(
                CASE WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN 1 ELSE 0 END +
                CASE WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN 1 ELSE 0 END +
                CASE WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN 1 ELSE 0 END,
                0
              ),
              0.0
            ) +
            ? * CASE
              WHEN NULLIF(MAX(?), 0) IS NOT NULL AND NULLIF(MAX(?), 0) IS NOT NULL THEN (MAX(?) / 100.0 + MAX(?) / 100.0) / 2.0
              WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN MAX(?) / 100.0
              WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN MAX(?) / 100.0
              ELSE 0.0
            END +
            ? * COALESCE(LEAST(1.0, COALESCE(MAX(?), 0) / 10.0), 0) +
            ? * COALESCE(LEAST(1.0, COALESCE(MAX((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb)))), 0) * 0.1 + CASE WHEN COALESCE(MAX(?), 0) = 0 THEN 0 ELSE LN(COALESCE(MAX(?), 0) + 1) / LN(1001) END), 0) +
            ? * COALESCE(COALESCE(MAX(?), 0) / 100.0, 0) +
            ? * COALESCE(CASE
              WHEN COALESCE(MAX(?), 0) > 0 AND COALESCE(MAX(?), 0) > 0
              THEN LEAST(1.0, (LN(COALESCE(MAX(?), 0) + 1) / LN(1000000000)) * 0.6 + (COALESCE(MAX(?), 0) / COALESCE(MAX(?), 0)) * 0.4)
              ELSE COALESCE(LN(COALESCE(MAX(?), 0) + 1) / LN(1000000000), 0)
            END, 0)
            """,
            ^Map.get(weights, :mob, 0.0),
            ir.value,
            tr.value,
            ra.value,
            ir.value,
            tr.value,
            ra.value,
            ^Map.get(weights, :critics, 0.0),
            rt.value,
            mc.value,
            rt.value,
            mc.value,
            rt.value,
            rt.value,
            mc.value,
            mc.value,
            ^weights.festival_recognition,
            f.prestige_score,
            ^weights.time_machine,
            m.canonical_sources,
            pop.value,
            pop.value,
            ^weights.auteurs,
            pq.avg_person_quality,
            ^Map.get(weights, :box_office, 0.0),
            b.value,
            r.value,
            r.value,
            r.value,
            b.value,
            r.value
          ),
        score_components: %{
          mob:
            fragment(
              "COALESCE((COALESCE(NULLIF(MAX(?), 0), 0) / 10.0 + COALESCE(NULLIF(MAX(?), 0), 0) / 10.0 + COALESCE(NULLIF(MAX(?), 0), 0) / 100.0) / NULLIF(CASE WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN 1 ELSE 0 END + CASE WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN 1 ELSE 0 END + CASE WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN 1 ELSE 0 END, 0), 0.0)",
              ir.value,
              tr.value,
              ra.value,
              ir.value,
              tr.value,
              ra.value
            ),
          critics:
            fragment(
              "CASE WHEN NULLIF(MAX(?), 0) IS NOT NULL AND NULLIF(MAX(?), 0) IS NOT NULL THEN (MAX(?) / 100.0 + MAX(?) / 100.0) / 2.0 WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN MAX(?) / 100.0 WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN MAX(?) / 100.0 ELSE 0.0 END",
              rt.value,
              mc.value,
              rt.value,
              mc.value,
              rt.value,
              rt.value,
              mc.value,
              mc.value
            ),
          festival_recognition:
            fragment(
              "COALESCE(LEAST(1.0, COALESCE(MAX(?), 0) / 10.0), 0)",
              f.prestige_score
            ),
          time_machine:
            fragment(
              "COALESCE(LEAST(1.0, COALESCE(MAX((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb)))), 0) * 0.1 + CASE WHEN COALESCE(MAX(?), 0) = 0 THEN 0 ELSE LN(COALESCE(MAX(?), 0) + 1) / LN(1001) END), 0)",
              m.canonical_sources,
              pop.value,
              pop.value
            ),
          auteurs:
            fragment(
              "COALESCE(COALESCE(MAX(?), 0) / 100.0, 0)",
              pq.avg_person_quality
            ),
          box_office:
            fragment(
              """
              COALESCE(CASE
                WHEN COALESCE(MAX(?), 0) > 0 AND COALESCE(MAX(?), 0) > 0
                THEN LEAST(1.0, (LN(COALESCE(MAX(?), 0) + 1) / LN(1000000000)) * 0.6 + (COALESCE(MAX(?), 0) / COALESCE(MAX(?), 0)) * 0.4)
                ELSE COALESCE(LN(COALESCE(MAX(?), 0) + 1) / LN(1000000000), 0)
              END, 0)
              """,
              b.value,
              r.value,
              r.value,
              r.value,
              b.value,
              r.value
            )
        }
      }
    )
  end

  defp filter_by_min_score(query, _weights, nil), do: query

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
          rt_audience: ra,
          popularity: pop,
          festivals: f,
          person_quality: pq,
          budget: b,
          revenue: r
        ],
        fragment(
          """
          ? * COALESCE(
            (COALESCE(NULLIF(MAX(?), 0), 0) / 10.0 +
             COALESCE(NULLIF(MAX(?), 0), 0) / 10.0 +
             COALESCE(NULLIF(MAX(?), 0), 0) / 100.0) /
            NULLIF(
              CASE WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN 1 ELSE 0 END +
              CASE WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN 1 ELSE 0 END +
              CASE WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN 1 ELSE 0 END,
              0
            ),
            0.0
          ) +
          ? * CASE
            WHEN NULLIF(MAX(?), 0) IS NOT NULL AND NULLIF(MAX(?), 0) IS NOT NULL THEN (MAX(?) / 100.0 + MAX(?) / 100.0) / 2.0
            WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN MAX(?) / 100.0
            WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN MAX(?) / 100.0
            ELSE 0.0
          END +
          ? * COALESCE(LEAST(1.0, COALESCE(MAX(?), 0) / 10.0), 0) +
          ? * COALESCE(LEAST(1.0, COALESCE(MAX((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb)))), 0) * 0.1 + CASE WHEN COALESCE(MAX(?), 0) = 0 THEN 0 ELSE LN(COALESCE(MAX(?), 0) + 1) / LN(1001) END), 0) +
          ? * COALESCE(COALESCE(MAX(?), 0) / 100.0, 0) +
          ? * COALESCE(CASE
            WHEN COALESCE(MAX(?), 0) > 0 AND COALESCE(MAX(?), 0) > 0
            THEN LEAST(1.0, (LN(COALESCE(MAX(?), 0) + 1) / LN(1000000000)) * 0.6 + (COALESCE(MAX(?), 0) / COALESCE(MAX(?), 0)) * 0.4)
            ELSE COALESCE(LN(COALESCE(MAX(?), 0) + 1) / LN(1000000000), 0)
          END, 0) >= ?
          """,
          ^Map.get(weights, :mob, 0.0),
          ir.value,
          tr.value,
          ra.value,
          ir.value,
          tr.value,
          ra.value,
          ^Map.get(weights, :critics, 0.0),
          rt.value,
          mc.value,
          rt.value,
          mc.value,
          rt.value,
          rt.value,
          mc.value,
          mc.value,
          ^weights.festival_recognition,
          f.prestige_score,
          ^weights.time_machine,
          m.canonical_sources,
          pop.value,
          pop.value,
          ^weights.auteurs,
          pq.avg_person_quality,
          ^Map.get(weights, :box_office, 0.0),
          b.value,
          r.value,
          r.value,
          r.value,
          b.value,
          r.value,
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
          rt_audience: ra,
          popularity: pop,
          festivals: f,
          person_quality: pq,
          budget: b,
          revenue: r
        ],
        fragment(
          """
          ? * COALESCE(
            (COALESCE(NULLIF(?, 0), 0) / 10.0 +
             COALESCE(NULLIF(?, 0), 0) / 10.0 +
             COALESCE(NULLIF(?, 0), 0) / 100.0) /
            NULLIF(
              CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END +
              CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END +
              CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END,
              0
            ),
            0.0
          ) +
          ? * CASE
            WHEN NULLIF(?, 0) IS NOT NULL AND NULLIF(?, 0) IS NOT NULL THEN (? / 100.0 + ? / 100.0) / 2.0
            WHEN NULLIF(?, 0) IS NOT NULL THEN ? / 100.0
            WHEN NULLIF(?, 0) IS NOT NULL THEN ? / 100.0
            ELSE 0.0
          END +
          ? * COALESCE(LEAST(1.0, COALESCE(?, 0) / 10.0), 0) +
          ? * COALESCE(LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + CASE WHEN COALESCE(?, 0) = 0 THEN 0 ELSE LN(COALESCE(?, 0) + 1) / LN(1001) END), 0) +
          ? * COALESCE(COALESCE(?, 0) / 100.0, 0) +
          ? * COALESCE(CASE
            WHEN COALESCE(?, 0) > 0 AND COALESCE(?, 0) > 0
            THEN LEAST(1.0, (LN(COALESCE(?, 0) + 1) / LN(1000000000)) * 0.6 + (COALESCE(?, 0) / COALESCE(?, 0)) * 0.4)
            ELSE COALESCE(LN(COALESCE(?, 0) + 1) / LN(1000000000), 0)
          END, 0) >= ?
          """,
          ^Map.get(weights, :mob, 0.0),
          ir.value,
          tr.value,
          ra.value,
          ir.value,
          tr.value,
          ra.value,
          ^Map.get(weights, :critics, 0.0),
          rt.value,
          mc.value,
          rt.value,
          mc.value,
          rt.value,
          rt.value,
          mc.value,
          mc.value,
          ^weights.festival_recognition,
          f.prestige_score,
          ^weights.time_machine,
          m.canonical_sources,
          pop.value,
          pop.value,
          ^weights.auteurs,
          pq.avg_person_quality,
          ^Map.get(weights, :box_office, 0.0),
          b.value,
          r.value,
          r.value,
          r.value,
          b.value,
          r.value,
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
          rt_audience: ra,
          popularity: pop,
          festivals: f,
          person_quality: pq,
          budget: b,
          revenue: r
        ],
        desc:
          fragment(
            """
            ? * COALESCE(
              (COALESCE(NULLIF(MAX(?), 0), 0) / 10.0 +
               COALESCE(NULLIF(MAX(?), 0), 0) / 10.0 +
               COALESCE(NULLIF(MAX(?), 0), 0) / 100.0) /
              NULLIF(
                CASE WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN 1 ELSE 0 END +
                CASE WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN 1 ELSE 0 END +
                CASE WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN 1 ELSE 0 END,
                0
              ),
              0.0
            ) +
            ? * CASE
              WHEN NULLIF(MAX(?), 0) IS NOT NULL AND NULLIF(MAX(?), 0) IS NOT NULL THEN (MAX(?) / 100.0 + MAX(?) / 100.0) / 2.0
              WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN MAX(?) / 100.0
              WHEN NULLIF(MAX(?), 0) IS NOT NULL THEN MAX(?) / 100.0
              ELSE 0.0
            END +
            ? * COALESCE(LEAST(1.0, COALESCE(MAX(?), 0) / 10.0), 0) +
            ? * COALESCE(LEAST(1.0, COALESCE(MAX((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb)))), 0) * 0.1 + CASE WHEN COALESCE(MAX(?), 0) = 0 THEN 0 ELSE LN(COALESCE(MAX(?), 0) + 1) / LN(1001) END), 0) +
            ? * COALESCE(COALESCE(MAX(?), 0) / 100.0, 0) +
            ? * COALESCE(CASE
              WHEN COALESCE(MAX(?), 0) > 0 AND COALESCE(MAX(?), 0) > 0
              THEN LEAST(1.0, (LN(COALESCE(MAX(?), 0) + 1) / LN(1000000000)) * 0.6 + (COALESCE(MAX(?), 0) / COALESCE(MAX(?), 0)) * 0.4)
              ELSE COALESCE(LN(COALESCE(MAX(?), 0) + 1) / LN(1000000000), 0)
            END, 0)
            """,
            ^Map.get(weights, :mob, 0.0),
            ir.value,
            tr.value,
            ra.value,
            ir.value,
            tr.value,
            ra.value,
            ^Map.get(weights, :critics, 0.0),
            rt.value,
            mc.value,
            rt.value,
            mc.value,
            rt.value,
            rt.value,
            mc.value,
            mc.value,
            ^weights.festival_recognition,
            f.prestige_score,
            ^weights.time_machine,
            m.canonical_sources,
            pop.value,
            pop.value,
            ^weights.auteurs,
            pq.avg_person_quality,
            ^Map.get(weights, :box_office, 0.0),
            b.value,
            r.value,
            r.value,
            r.value,
            b.value,
            r.value
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
          rt_audience: ra,
          popularity: pop,
          festivals: f,
          person_quality: pq,
          budget: b,
          revenue: r
        ],
        desc:
          fragment(
            """
            ? * COALESCE(
              (COALESCE(NULLIF(?, 0), 0) / 10.0 +
               COALESCE(NULLIF(?, 0), 0) / 10.0 +
               COALESCE(NULLIF(?, 0), 0) / 100.0) /
              NULLIF(
                CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END +
                CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END +
                CASE WHEN NULLIF(?, 0) IS NOT NULL THEN 1 ELSE 0 END,
                0
              ),
              0.0
            ) +
            ? * CASE
              WHEN NULLIF(?, 0) IS NOT NULL AND NULLIF(?, 0) IS NOT NULL THEN (? / 100.0 + ? / 100.0) / 2.0
              WHEN NULLIF(?, 0) IS NOT NULL THEN ? / 100.0
              WHEN NULLIF(?, 0) IS NOT NULL THEN ? / 100.0
              ELSE 0.0
            END +
            ? * COALESCE(LEAST(1.0, COALESCE(?, 0) / 10.0), 0) +
            ? * COALESCE(LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + CASE WHEN COALESCE(?, 0) = 0 THEN 0 ELSE LN(COALESCE(?, 0) + 1) / LN(1001) END), 0) +
            ? * COALESCE(COALESCE(?, 0) / 100.0, 0) +
            ? * COALESCE(CASE
              WHEN COALESCE(?, 0) > 0 AND COALESCE(?, 0) > 0
              THEN LEAST(1.0, (LN(COALESCE(?, 0) + 1) / LN(1000000000)) * 0.6 + (COALESCE(?, 0) / COALESCE(?, 0)) * 0.4)
              ELSE COALESCE(LN(COALESCE(?, 0) + 1) / LN(1000000000), 0)
            END, 0)
            """,
            ^Map.get(weights, :mob, 0.0),
            ir.value,
            tr.value,
            ra.value,
            ir.value,
            tr.value,
            ra.value,
            ^Map.get(weights, :critics, 0.0),
            rt.value,
            mc.value,
            rt.value,
            mc.value,
            rt.value,
            rt.value,
            mc.value,
            mc.value,
            ^weights.festival_recognition,
            f.prestige_score,
            ^weights.time_machine,
            m.canonical_sources,
            pop.value,
            pop.value,
            ^weights.auteurs,
            pq.avg_person_quality,
            ^Map.get(weights, :box_office, 0.0),
            b.value,
            r.value,
            r.value,
            r.value,
            b.value,
            r.value
          )
      )
    end
  end
end
