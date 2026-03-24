defmodule Cinegraph.Movies.Query.CustomSorting do
  @moduledoc """
  Custom sorting for complex metrics that Flop doesn't handle natively.

  ## Discovery Score

  The `discovery_score` sort combines recency (how new) with relevance (how popular/rated).
  Configure weights in `Cinegraph.Movies.DiscoveryCommon`.

  Formula:
    discovery_score = (recency × recency_weight) + (popularity × pop_weight) +
                      (votes × votes_weight) + (rating × rating_weight)

  Where:
    - recency = exp(-decay_rate × days_since_release)
    - popularity = ln(popularity + 1) / ln(max_expected)
    - votes = ln(votes + 1) / ln(max_expected)
    - rating = avg_rating / 10 (only if votes >= min_threshold)
  """

  import Ecto.Query
  alias Cinegraph.Movies.DiscoveryCommon

  def apply(query, sort, preset_weights \\ nil) do
    # Parse sort parameter to extract field and direction
    {field, direction} = parse_sort(sort)

    cond do
      field == "discovery_score" ->
        apply_discovery_score_sort(query, direction)

      field == "score" ->
        apply_score_cache_sort(query, direction, preset_weights)

      field in ["rating", "popularity"] ->
        apply_simple_metric_sort(query, field, direction)

      field in ~w(mob ivory_tower popular_opinion industry_recognition cultural_impact people_quality) ->
        apply_discovery_metric_sort(query, field, direction)

      true ->
        query
    end
  end

  defp parse_sort(sort) do
    cond do
      String.ends_with?(sort, "_desc") ->
        {String.replace_suffix(sort, "_desc", ""), :desc}

      String.ends_with?(sort, "_asc") ->
        {String.replace_suffix(sort, "_asc", ""), :asc}

      true ->
        # Default to descending for compatibility
        {sort, :desc}
    end
  end

  # ---------------------------------------------------------------------------
  # Discovery Score Sort
  # Combines recency (how new) with relevance (popularity, votes, rating)
  # ---------------------------------------------------------------------------

  defp apply_discovery_score_sort(query, direction) do
    weights = DiscoveryCommon.discovery_weights()
    decay_rate = DiscoveryCommon.recency_decay_rate()
    min_votes = DiscoveryCommon.min_votes_for_rating()

    order_func = if direction == :desc, do: :desc_nulls_last, else: :asc_nulls_last

    order_by(query, [m], [
      {^order_func,
       fragment(
         """
         (
           ?::float * COALESCE(
             EXP(-1.0 * ?::float * GREATEST(0.0, (CURRENT_DATE - COALESCE(?, CURRENT_DATE))::float)),
             0.5
           )
           +
           ?::float * COALESCE(
             (SELECT LN(GREATEST(value::float, 1.0) + 1.0) / LN(1000.0)
              FROM external_metrics
              WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'popularity_score'
              ORDER BY fetched_at DESC LIMIT 1),
             0.0
           )
           +
           ?::float * COALESCE(
             (SELECT LN(GREATEST(value::float, 1.0) + 1.0) / LN(100000.0)
              FROM external_metrics
              WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_votes'
              ORDER BY fetched_at DESC LIMIT 1),
             0.0
           )
           +
           ?::float * COALESCE(
             (SELECT CASE
                WHEN v.value >= ?::float THEN r.value::float / 10.0
                ELSE 0.5
              END
              FROM (
                SELECT COALESCE(value, 0) as value FROM external_metrics
                WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_average'
                ORDER BY fetched_at DESC LIMIT 1
              ) r,
              (
                SELECT COALESCE(value, 0) as value FROM external_metrics
                WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_votes'
                ORDER BY fetched_at DESC LIMIT 1
              ) v),
             0.5
           )
         )
         """,
         ^weights.recency,
         ^decay_rate,
         m.release_date,
         ^weights.popularity,
         m.id,
         ^weights.votes,
         m.id,
         ^weights.rating,
         ^min_votes,
         m.id,
         m.id
       )}
    ])
  end

  defp apply_simple_metric_sort(query, "rating", direction) do
    order_func = if direction == :desc, do: :desc, else: :asc

    order_by(query, [m], [
      {^order_func,
       fragment(
         """
         (SELECT value FROM external_metrics 
          WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_average'
          ORDER BY fetched_at DESC LIMIT 1)
         """,
         m.id
       )}
    ])
  end

  defp apply_simple_metric_sort(query, "popularity", direction) do
    order_func = if direction == :desc, do: :desc, else: :asc

    order_by(query, [m], [
      {^order_func,
       fragment(
         """
         (SELECT value FROM external_metrics 
          WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'popularity_score'
          ORDER BY fetched_at DESC LIMIT 1)
         """,
         m.id
       )}
    ])
  end

  defp apply_discovery_metric_sort(query, "mob", direction) do
    order_func = if direction == :desc, do: :desc_nulls_last, else: :asc_nulls_last

    order_by(query, [m], [
      {^order_func,
       fragment(
         """
         (
           SELECT CASE
             WHEN ir_v IS NOT NULL AND tr_v IS NOT NULL THEN (ir_v / 10.0 + tr_v / 10.0) / 2.0
             WHEN ir_v IS NOT NULL THEN ir_v / 10.0
             WHEN tr_v IS NOT NULL THEN tr_v / 10.0
             ELSE NULL
           END
           FROM (
             SELECT
               (SELECT value FROM external_metrics
                WHERE movie_id = ? AND source = 'imdb' AND metric_type = 'rating_average'
                ORDER BY fetched_at DESC LIMIT 1) AS ir_v,
               (SELECT value FROM external_metrics
                WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_average'
                ORDER BY fetched_at DESC LIMIT 1) AS tr_v
           ) AS vals
         )
         """,
         m.id,
         m.id
       )}
    ])
  end

  defp apply_discovery_metric_sort(query, "ivory_tower", direction) do
    order_func = if direction == :desc, do: :desc_nulls_last, else: :asc_nulls_last

    order_by(query, [m], [
      {^order_func,
       fragment(
         """
         (
           SELECT CASE
             WHEN rt_v IS NOT NULL AND mc_v IS NOT NULL THEN (rt_v / 100.0 + mc_v / 100.0) / 2.0
             WHEN rt_v IS NOT NULL THEN rt_v / 100.0
             WHEN mc_v IS NOT NULL THEN mc_v / 100.0
             ELSE NULL
           END
           FROM (
             SELECT
               (SELECT value FROM external_metrics
                WHERE movie_id = ? AND source = 'rotten_tomatoes' AND metric_type = 'tomatometer'
                ORDER BY fetched_at DESC LIMIT 1) AS rt_v,
               (SELECT value FROM external_metrics
                WHERE movie_id = ? AND source = 'metacritic' AND metric_type = 'metascore'
                ORDER BY fetched_at DESC LIMIT 1) AS mc_v
           ) AS vals
         )
         """,
         m.id,
         m.id
       )}
    ])
  end

  defp apply_discovery_metric_sort(query, "popular_opinion", direction) do
    order_func = if direction == :desc, do: :desc, else: :asc

    order_by(query, [m], [
      {^order_func,
       fragment(
         """
         COALESCE((
           SELECT (COALESCE(tr.value, 0) / 10.0 * 0.25 +
                   COALESCE(ir.value, 0) / 10.0 * 0.25 +
                   COALESCE(mc.value, 0) / 100.0 * 0.25 +
                   COALESCE(rt.value, 0) / 100.0 * 0.25)
           FROM (
                 SELECT value FROM external_metrics
                 WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_average'
                 ORDER BY fetched_at DESC LIMIT 1
                ) tr,
                (
                 SELECT value FROM external_metrics
                 WHERE movie_id = ? AND source = 'imdb' AND metric_type = 'rating_average'
                 ORDER BY fetched_at DESC LIMIT 1
                ) ir,
                (
                 SELECT value FROM external_metrics
                 WHERE movie_id = ? AND source = 'metacritic' AND metric_type = 'metascore'
                 ORDER BY fetched_at DESC LIMIT 1
                ) mc,
                (
                 SELECT value FROM external_metrics
                 WHERE movie_id = ? AND source = 'rotten_tomatoes' AND metric_type = 'tomatometer'
                 ORDER BY fetched_at DESC LIMIT 1
                ) rt
         ), 0)
         """,
         m.id,
         m.id,
         m.id,
         m.id
       )}
    ])
  end

  defp apply_discovery_metric_sort(query, "industry_recognition", direction) do
    order_func = if direction == :desc, do: :desc, else: :asc

    order_by(query, [m], [
      {^order_func,
       fragment(
         """
         COALESCE((
           SELECT LEAST(1.0, (COALESCE(f.wins, 0) * 0.2 + COALESCE(f.nominations, 0) * 0.05))
           FROM (
             SELECT COUNT(CASE WHEN won = true THEN 1 END) as wins,
                    COUNT(*) as nominations
             FROM festival_nominations
             WHERE movie_id = ?
           ) f
         ), 0)
         """,
         m.id
       )}
    ])
  end

  defp apply_discovery_metric_sort(query, "cultural_impact", direction) do
    order_func = if direction == :desc, do: :desc, else: :asc

    order_by(query, [m], [
      {^order_func,
       fragment(
         """
         COALESCE(
           LEAST(1.0, 
             COALESCE(
               (SELECT COUNT(*) * 0.1
                FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 
               0
             ) + 
             COALESCE(
               (SELECT CASE 
                 WHEN value IS NULL OR value = 0 THEN 0
                 ELSE LN(value + 1) / LN(1001)
               END
               FROM external_metrics 
               WHERE movie_id = ? 
                 AND source = 'tmdb' 
                 AND metric_type = 'popularity_score'
               ORDER BY fetched_at DESC
               LIMIT 1), 
               0
             )
           ), 
           0
         )
         """,
         m.canonical_sources,
         m.id
       )}
    ])
  end

  defp apply_discovery_metric_sort(query, "people_quality", direction) do
    order_func = if direction == :desc, do: :desc, else: :asc

    order_by(query, [m], [
      {^order_func,
       fragment(
         """
         COALESCE((
           SELECT AVG(DISTINCT pm.score) / 100.0
           FROM person_metrics pm
           JOIN movie_credits mc ON pm.person_id = mc.person_id
           WHERE mc.movie_id = ? AND pm.metric_type = 'quality_score'
         ), 0)
         """,
         m.id
       )}
    ])
  end

  defp apply_discovery_metric_sort(query, _, _), do: query

  # ---------------------------------------------------------------------------
  # Score Cache Sort
  # Sorts by pre-computed overall_score from movie_score_caches
  # ---------------------------------------------------------------------------

  # Sorts by the pre-computed overall_score when no preset weights are given
  defp apply_score_cache_sort(query, direction, nil) do
    order_func = if direction == :desc, do: :desc_nulls_last, else: :asc_nulls_last

    query
    |> maybe_join_score_cache()
    |> select_merge([m, score_cache: sc], %{overall_score: sc.overall_score})
    |> order_by([score_cache: sc], [{^order_func, sc.overall_score}])
  end

  # Sorts by a weighted combination of the individual lens scores from the cache
  defp apply_score_cache_sort(query, direction, weights) when is_map(weights) do
    mob = weights["mob"] || 0.0
    ivory = weights["ivory_tower"] || 0.0
    industry = weights["industry_recognition"] || 0.0
    cultural = weights["cultural_impact"] || 0.0
    people = weights["people_quality"] || 0.0
    financial = weights["financial_performance"] || 0.0

    order_func = if direction == :desc, do: :desc_nulls_last, else: :asc_nulls_last

    query
    |> maybe_join_score_cache()
    |> select_merge([m, score_cache: sc], %{
      overall_score:
        fragment(
          "?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0)",
          ^mob, sc.mob_score,
          ^ivory, sc.ivory_tower_score,
          ^industry, sc.industry_recognition_score,
          ^cultural, sc.cultural_impact_score,
          ^people, sc.people_quality_score,
          ^financial, sc.financial_performance_score
        )
    })
    |> order_by([score_cache: sc], [
      {^order_func,
       fragment(
         "?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0) + ?::float * COALESCE(?, 0)",
         ^mob, sc.mob_score,
         ^ivory, sc.ivory_tower_score,
         ^industry, sc.industry_recognition_score,
         ^cultural, sc.cultural_impact_score,
         ^people, sc.people_quality_score,
         ^financial, sc.financial_performance_score
       )}
    ])
  end

  defp maybe_join_score_cache(query) do
    if has_named_binding?(query, :score_cache) do
      query
    else
      join(query, :left, [m], sc in "movie_score_caches",
        on: sc.movie_id == m.id,
        as: :score_cache
      )
    end
  end
end
