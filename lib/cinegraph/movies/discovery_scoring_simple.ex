defmodule Cinegraph.Movies.DiscoveryScoringSimple do
  @moduledoc """
  Simplified Tunable Movie Discovery System using materialized scores.

  This version pre-calculates component scores for better performance.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Movies.DiscoveryCommon

  @default_weights DiscoveryCommon.default_weights()

  @doc """
  Applies discovery scoring to a movie query with user-defined weights.
  This simplified version uses pre-calculated scores for better performance.
  """
  def apply_scoring(query, weights \\ @default_weights, options \\ %{}) do
    normalized_weights = normalize_weights(weights)
    min_score = Map.get(options, :min_score, 0.0)

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
    |> join(:left, [m], f in subquery(festival_nominations_summary()),
      on: f.movie_id == m.id,
      as: :festivals
    )
    |> select_merge(
      [
        m,
        tmdb_rating: tr,
        imdb_rating: ir,
        metacritic: mc,
        rotten_tomatoes: rt,
        popularity: pop,
        festivals: f
      ],
      %{
        discovery_score:
          fragment(
            "? * COALESCE((COALESCE(?, 0) / 10.0 * 0.5 + COALESCE(?, 0) / 10.0 * 0.5), 0) + 
         ? * COALESCE((COALESCE(?, 0) / 100.0 * 0.5 + COALESCE(?, 0) / 100.0 * 0.5), 0) +
         ? * COALESCE(LEAST(1.0, (COALESCE(?, 0) * 0.2 + COALESCE(?, 0) * 0.05)), 0) +
         ? * COALESCE(LEAST(1.0, 
           COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + COALESCE(?, 0) / 1000.0), 0)",
            ^normalized_weights.popular_opinion,
            tr.value,
            ir.value,
            ^normalized_weights.critical_acclaim,
            mc.value,
            rt.value,
            ^normalized_weights.industry_recognition,
            f.wins,
            f.nominations,
            ^normalized_weights.cultural_impact,
            m.canonical_sources,
            pop.value
          ),
        score_components: %{
          popular_opinion:
            fragment(
              "COALESCE((COALESCE(?, 0) / 10.0 * 0.5 + COALESCE(?, 0) / 10.0 * 0.5), 0)",
              tr.value,
              ir.value
            ),
          critical_acclaim:
            fragment(
              "COALESCE((COALESCE(?, 0) / 100.0 * 0.5 + COALESCE(?, 0) / 100.0 * 0.5), 0)",
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
              "COALESCE(LEAST(1.0, 
           COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + 
           COALESCE(?, 0) / 1000.0), 0)",
              m.canonical_sources,
              pop.value
            )
        }
      }
    )
    |> where(
      [
        m,
        tmdb_rating: tr,
        imdb_rating: ir,
        metacritic: mc,
        rotten_tomatoes: rt,
        popularity: pop,
        festivals: f
      ],
      fragment(
        "? * COALESCE((COALESCE(?, 0) / 10.0 * 0.5 + COALESCE(?, 0) / 10.0 * 0.5), 0) + 
         ? * COALESCE((COALESCE(?, 0) / 100.0 * 0.5 + COALESCE(?, 0) / 100.0 * 0.5), 0) +
         ? * COALESCE(LEAST(1.0, (COALESCE(?, 0) * 0.2 + COALESCE(?, 0) * 0.05)), 0) +
         ? * COALESCE(LEAST(1.0, 
           COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + COALESCE(?, 0) / 1000.0), 0) >= ?",
        ^normalized_weights.popular_opinion,
        tr.value,
        ir.value,
        ^normalized_weights.critical_acclaim,
        mc.value,
        rt.value,
        ^normalized_weights.industry_recognition,
        f.wins,
        f.nominations,
        ^normalized_weights.cultural_impact,
        m.canonical_sources,
        pop.value,
        ^min_score
      )
    )
    |> order_by(
      [
        m,
        tmdb_rating: tr,
        imdb_rating: ir,
        metacritic: mc,
        rotten_tomatoes: rt,
        popularity: pop,
        festivals: f
      ],
      desc:
        fragment(
          "? * COALESCE((COALESCE(?, 0) / 10.0 * 0.5 + COALESCE(?, 0) / 10.0 * 0.5), 0) + 
         ? * COALESCE((COALESCE(?, 0) / 100.0 * 0.5 + COALESCE(?, 0) / 100.0 * 0.5), 0) +
         ? * COALESCE(LEAST(1.0, (COALESCE(?, 0) * 0.2 + COALESCE(?, 0) * 0.05)), 0) +
         ? * COALESCE(LEAST(1.0, 
           COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * 0.1 + COALESCE(?, 0) / 1000.0), 0)",
          ^normalized_weights.popular_opinion,
          tr.value,
          ir.value,
          ^normalized_weights.critical_acclaim,
          mc.value,
          rt.value,
          ^normalized_weights.industry_recognition,
          f.wins,
          f.nominations,
          ^normalized_weights.cultural_impact,
          m.canonical_sources,
          pop.value
        )
    )
  end

  @doc """
  Returns scoring presets for common use cases.
  """
  def get_presets do
    DiscoveryCommon.get_presets()
  end

  # Private functions

  defp normalize_weights(weights) do
    DiscoveryCommon.normalize_weights(weights)
  end

  defp festival_nominations_summary do
    from(f in "festival_nominations",
      group_by: f.movie_id,
      select: %{
        movie_id: f.movie_id,
        wins: count(fragment("CASE WHEN ? = true THEN 1 END", f.won)),
        nominations: count(f.id)
      }
    )
  end
end
