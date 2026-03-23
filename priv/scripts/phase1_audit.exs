# Phase 1 Audit Script — Issue #597
# Run with: mix run priv/scripts/phase1_audit.exs
#
# Answers all Phase 1 baseline questions:
#   1. How many 1001-list films are in the DB?
#   2. Per-source metric coverage for those films
#   3. Current scoring distribution (decile buckets)
#   4. What % of 1001 films land in the top 20% of all scored films

alias Cinegraph.{Repo, Movies}
alias Cinegraph.Metrics.ScoringService
import Ecto.Query

IO.puts("\n=== Phase 1 Audit: 1001 Movies Baseline ===\n")

# ---------------------------------------------------------------------------
# 1. DB coverage count
# ---------------------------------------------------------------------------
total_1001 = Movies.count_canonical_movies("1001_movies")
IO.puts("1. 1001 Movies DB coverage: #{total_1001} films")
IO.puts("   (target ≥ 90% of ~1,214 editions = ~1,093 films)")
# 1,214 = total films across all known editions of the 1001 Movies book
coverage_pct = Float.round(total_1001 / 1214 * 100, 1)
IO.puts("   Current coverage: #{coverage_pct}%\n")

# ---------------------------------------------------------------------------
# 2. Per-source external metrics coverage
# ---------------------------------------------------------------------------
IO.puts("2. External metrics coverage for 1001-list films:")

coverage_sql = """
SELECT
  COUNT(*) FILTER (WHERE em.source = 'imdb' AND em.metric_type = 'rating_average')           AS imdb_count,
  COUNT(*) FILTER (WHERE em.source = 'rotten_tomatoes' AND em.metric_type = 'tomatometer')   AS rt_tomatometer_count,
  COUNT(*) FILTER (WHERE em.source = 'rotten_tomatoes' AND em.metric_type = 'audience_score') AS rt_audience_count,
  COUNT(*) FILTER (WHERE em.source = 'metacritic' AND em.metric_type = 'metascore')          AS metacritic_count,
  COUNT(*) FILTER (WHERE em.source = 'tmdb' AND em.metric_type = 'rating_average')           AS tmdb_count,
  COUNT(DISTINCT m.id) AS total_1001_films
FROM movies m
LEFT JOIN external_metrics em ON em.movie_id = m.id
WHERE m.canonical_sources ? '1001_movies'
"""

%{rows: [[imdb, rt_tom, rt_aud, meta, tmdb, total_check]]} =
  Repo.query!(coverage_sql)

IO.puts("   Total 1001 films (double-check): #{total_check}")

IO.puts(
  "   IMDb rating:              #{imdb} / #{total_check} (#{Float.round(imdb / max(total_check, 1) * 100, 1)}%)"
)

IO.puts(
  "   RT Tomatometer:           #{rt_tom} / #{total_check} (#{Float.round(rt_tom / max(total_check, 1) * 100, 1)}%)"
)

IO.puts(
  "   RT Audience score:        #{rt_aud} / #{total_check} (#{Float.round(rt_aud / max(total_check, 1) * 100, 1)}%)"
)

IO.puts(
  "   Metacritic metascore:     #{meta} / #{total_check} (#{Float.round(meta / max(total_check, 1) * 100, 1)}%)"
)

IO.puts(
  "   TMDb rating:              #{tmdb} / #{total_check} (#{Float.round(tmdb / max(total_check, 1) * 100, 1)}%)\n"
)

# ---------------------------------------------------------------------------
# 3. Scoring distribution for 1001-list films (decile buckets)
# ---------------------------------------------------------------------------
IO.puts("3. Scoring distribution for 1001 films (decile buckets):")

profile = ScoringService.get_default_profile()

if profile do
  base_query =
    from(m in Cinegraph.Movies.Movie,
      where: fragment("? \\? '1001_movies'", m.canonical_sources)
    )

  scored =
    base_query
    |> ScoringService.apply_scoring(profile, %{min_score: 0.0})
    |> Repo.all()

  # discovery_score is a 0.0–1.0 float; scale to 0–100 for display
  scores = Enum.map(scored, fn m -> (Map.get(m, :discovery_score, 0.0) || 0.0) * 100 end)
  scored_count = length(scores)
  IO.puts("   Scored films: #{scored_count}")

  if scored_count > 0 do
    buckets =
      scores
      |> Enum.group_by(fn s ->
        bucket = trunc(s / 10) * 10
        # cap at 90 so 100 falls in 90–100 bucket
        min(bucket, 90)
      end)
      |> Enum.sort_by(fn {bucket, _} -> bucket end, :desc)

    Enum.each(buckets, fn {bucket, films} ->
      IO.puts(
        "   #{String.pad_leading(to_string(bucket), 3)}–#{bucket + 10}: #{length(films)} films"
      )
    end)
  end
else
  IO.puts("   WARNING: No default profile found — skipping scoring distribution")
end

IO.puts("")

# ---------------------------------------------------------------------------
# 4. % of 1001 films in top 20% of all scored films
# ---------------------------------------------------------------------------
IO.puts("4. 1001 films vs full catalog top-20% recall:")

if profile do
  # Use raw SQL with PERCENT_RANK window function to avoid loading all movies into memory.
  # Weights from the default profile: popular_opinion=0.3, awards=0.2, cultural=0.15,
  # people=0.15, financial=0.2 (these match the normalized weights from the query above).
  pw = profile.category_weights || %{}
  pop_w = Map.get(pw, "popular_opinion") || Map.get(pw, "ratings") || 0.3
  awd_w = Map.get(pw, "awards") || 0.2
  cul_w = Map.get(pw, "cultural") || 0.15
  ppl_w = Map.get(pw, "people") || 0.15
  total_w = pop_w + awd_w + cul_w + ppl_w

  {pop_n, awd_n, cul_n, ppl_n} =
    if total_w > 0,
      do: {pop_w / total_w, awd_w / total_w, cul_w / total_w, ppl_w / total_w},
      else: {0.25, 0.25, 0.25, 0.25}

  recall_sql = """
  WITH scored AS (
    SELECT
      m.id,
      (m.canonical_sources ? '1001_movies') AS is_1001,
      #{pop_n} * COALESCE(
        (COALESCE(tr.value, 0)/10.0 * 0.25 + COALESCE(ir.value, 0)/10.0 * 0.25 +
         COALESCE(mc.value, 0)/100.0 * 0.25 + COALESCE(rt.value, 0)/100.0 * 0.25), 0) +
      #{awd_n} * COALESCE(LEAST(1.0, COALESCE(f.wins, 0) * 0.2 + COALESCE(f.nominations, 0) * 0.05), 0) +
      #{cul_n} * COALESCE(LEAST(1.0,
        COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(m.canonical_sources, '{}'::jsonb))), 0) * 0.1 +
        CASE WHEN COALESCE(pop.value, 0) = 0 THEN 0 ELSE LN(COALESCE(pop.value, 0) + 1) / LN(1001) END), 0) +
      #{ppl_n} * COALESCE(COALESCE(pq.avg_quality, 0) / 100.0, 0)
      AS score
    FROM movies m
    LEFT JOIN external_metrics tr ON tr.movie_id = m.id AND tr.source = 'tmdb' AND tr.metric_type = 'rating_average'
    LEFT JOIN external_metrics ir ON ir.movie_id = m.id AND ir.source = 'imdb' AND ir.metric_type = 'rating_average'
    LEFT JOIN external_metrics mc ON mc.movie_id = m.id AND mc.source = 'metacritic' AND mc.metric_type = 'metascore'
    LEFT JOIN external_metrics rt ON rt.movie_id = m.id AND rt.source = 'rotten_tomatoes' AND rt.metric_type = 'tomatometer'
    LEFT JOIN external_metrics pop ON pop.movie_id = m.id AND pop.source = 'tmdb' AND pop.metric_type = 'popularity_score'
    LEFT JOIN (
      SELECT movie_id, count(CASE WHEN won THEN 1 END) AS wins, count(id) AS nominations
      FROM festival_nominations GROUP BY movie_id
    ) f ON f.movie_id = m.id
    LEFT JOIN (
      SELECT mc2.movie_id, avg(pm.score) AS avg_quality
      FROM movie_credits mc2
      JOIN person_metrics pm ON pm.person_id = mc2.person_id AND pm.metric_type = 'quality_score'
      GROUP BY mc2.movie_id
    ) pq ON pq.movie_id = m.id
  ),
  ranked AS (
    SELECT *, PERCENT_RANK() OVER (ORDER BY score DESC) AS pct_rank
    FROM scored
  )
  SELECT
    COUNT(*) FILTER (WHERE is_1001 AND pct_rank < 0.2)  AS in_top_20,
    COUNT(*) FILTER (WHERE is_1001)                     AS total_1001_scored,
    COUNT(*)                                             AS total_catalog
  FROM ranked
  """

  %{rows: [[in_top_20, total_1001_scored, total_catalog]]} =
    Repo.query!(recall_sql, [], timeout: 120_000)

  recall_pct =
    if total_1001_scored > 0, do: Float.round(in_top_20 / total_1001_scored * 100, 1), else: 0.0

  IO.puts("   Total scored films in catalog: #{total_catalog}")
  IO.puts("   1001 films in catalog (scored): #{total_1001_scored}")
  IO.puts("   1001 films in top 20%: #{in_top_20} (#{recall_pct}% recall)")
  IO.puts("   Baseline target: ≥ 80% recall (phase 1 goal)")
else
  IO.puts("   WARNING: No default profile found — skipping recall calculation")
end

IO.puts("\n=== Audit complete ===\n")
