# CineGraph Production Snapshot - 2026-05-02

This report is the Phase 0 baseline for the confidence-aware CineGraph scoring research track.
It is a production-data restore and measurement snapshot only. It is not a model recommendation,
threshold recommendation, or scoring-methodology decision.

## Restore Summary

| Field | Value |
|---|---:|
| Local restore timestamp | 2026-05-02 12:50 CEST |
| Production dump file | `priv/dumps/cinegraph_prod_20260502_102701.dump` |
| Dump timestamp from filename | 2026-05-02 10:27:01 UTC |
| Dump size | 5.9G |
| Restore command | `mix db.pull_production --parallel 4 --verbose` |
| Restore elapsed time | 1402s |
| Export elapsed time | 473s |
| Import elapsed time | 783s |
| Local database | `cinegraph_dev` |
| Source database | `cinegraph_prod` via SSH `192.168.1.205` |

Pre-flight checks passed for SSH, remote `pg_dump`, local `pg_restore`, local `createdb`, and local PostgreSQL.

## Restore Notes

- The task dropped and recreated local `cinegraph_dev`.
- The task cleaned production Oban jobs after restore, deleting 10 active/scheduled/available rows.
- Two local maintenance jobs became `available` immediately after cleanup (`HealthCacheWarmer`, `MoviesCacheWarmer`), so they were deleted with:

```sql
delete from oban_jobs where state in ('scheduled','available','executing');
```

Final Oban state counts:

| State | Count |
|---|---:|
| completed | 875,056 |
| discarded | 15,705 |

## Warnings / Blockers

- `REFRESH MATERIALIZED VIEW public.person_collaboration_trends` timed out after 120s during post-import cleanup.
- `public.movie_discovery_rankings_mv` refreshed successfully.
- Import verification still passed and core tables are populated.
- The restored schema does not contain `movie_list_entries`; list entities are present in `movie_lists`, and canonical membership appears to be stored in `movies.canonical_sources`.

## Core Table Counts

| Table | Rows |
|---|---:|
| `movies` | 1,144,666 |
| `people` | 675,498 |
| `external_metrics` | 3,198,173 |
| `movie_score_caches` | 902,490 |
| `movie_credits` | 4,567,889 |
| `person_metrics` | 673,394 |
| `festival_nominations` | 43,890 |
| `movie_lists` | 9 |

Additional canonical-source check:

| Metric | Count |
|---|---:|
| Movies with non-empty `canonical_sources` | 3,075 |
| Total movies | 1,144,666 |

## Score Distribution

| Metric | Value |
|---|---:|
| Cached scored movies | 902,490 |
| Average overall score | 0.69 |
| p10 | 0.0 |
| p25 | 0.1 |
| p50 | 0.5 |
| p75 | 1.0 |
| p90 | 1.5 |
| Average rating-source confidence | 0.198 |
| Movies below 1.0 | 74.01% |
| Movies below 2.0 | 94.80% |
| Movies >= 5.0 | 0.55% |
| Movies >= 7.0 | 0.06% |

### Score Buckets

| Bucket | Movies | Percent |
|---:|---:|---:|
| 0-1 | 667,931 | 74.01% |
| 1-2 | 187,600 | 20.79% |
| 2-3 | 26,098 | 2.89% |
| 3-4 | 11,935 | 1.32% |
| 4-5 | 3,928 | 0.44% |
| 5-6 | 3,081 | 0.34% |
| 6-7 | 1,405 | 0.16% |
| 7-8 | 392 | 0.04% |
| 8-9 | 115 | 0.01% |
| 9-10 | 5 | 0.00% |

## Lens Coverage

| Lens | Movies With Non-Zero Score |
|---|---:|
| Mob / audience | 444,682 |
| Critics | 37,913 |
| Festival recognition | 16,658 |
| Time machine / cultural | 402,631 |
| Auteurs | 895,536 |
| Box office | 24,762 |

## Present-Lens Distribution

| Present lenses | Movies | Percent | Avg score | Avg rating confidence |
|---:|---:|---:|---:|---:|
| 0 | 2,690 | 0.30% | 0.00 | 0.000 |
| 1 | 349,003 | 38.67% | 0.23 | 0.001 |
| 2 | 247,965 | 27.48% | 0.61 | 0.173 |
| 3 | 254,276 | 28.17% | 0.96 | 0.391 |
| 4 | 31,670 | 3.51% | 2.37 | 0.655 |
| 5 | 13,575 | 1.50% | 3.64 | 0.885 |
| 6 | 3,311 | 0.37% | 5.78 | 0.956 |

## Popularity Bucket Distribution

| TMDb popularity bucket | Movies | Avg score | Median score | Avg rating confidence | Avg present lenses |
|---|---:|---:|---:|---:|---:|
| 100+ blockbuster | 36 | 2.50 | 1.85 | 0.667 | 4.03 |
| 50-100 major | 50 | 2.80 | 2.35 | 0.661 | 4.16 |
| 10-50 notable | 1,274 | 3.10 | 2.70 | 0.707 | 4.24 |
| 1-10 small | 255,191 | 1.07 | 0.80 | 0.335 | 2.62 |
| <1 tiny/unknown | 645,939 | 0.53 | 0.40 | 0.142 | 1.78 |

## Baseline Interpretation

The restored production snapshot confirms the Phase 0 concern:

- The median cached CineGraph score is 0.5/10.
- 94.80% of scored movies are below 2.0/10.
- Only 0.55% of scored movies are at or above 5.0/10.
- Smaller and tiny/unknown-popularity movies have materially lower confidence and fewer present lenses.
- The score distribution is not credible as a pure quality distribution; it strongly reflects data availability.

This supports proceeding to Phase 1: build a formal evidence matrix that separates quality signal,
coverage, confidence, cohorts, and scoreability.

## Reproducibility

Restore:

```bash
mix db.pull_production --parallel 4 --verbose
```

Representative snapshot queries:

```sql
select 'movies' as table_name, count(*) from movies
union all select 'people', count(*) from people
union all select 'external_metrics', count(*) from external_metrics
union all select 'movie_score_caches', count(*) from movie_score_caches
union all select 'movie_credits', count(*) from movie_credits
union all select 'person_metrics', count(*) from person_metrics
union all select 'festival_nominations', count(*) from festival_nominations
union all select 'movie_lists', count(*) from movie_lists
order by table_name;
```

```sql
select
  count(*) as scored,
  round(avg(overall_score)::numeric, 2) avg_score,
  percentile_cont(0.1) within group (order by overall_score) p10,
  percentile_cont(0.25) within group (order by overall_score) p25,
  percentile_cont(0.5) within group (order by overall_score) p50,
  percentile_cont(0.75) within group (order by overall_score) p75,
  percentile_cont(0.9) within group (order by overall_score) p90,
  round(avg(score_confidence)::numeric, 3) avg_conf,
  round(100.0 * count(*) filter (where overall_score < 1) / count(*), 2) pct_below_1,
  round(100.0 * count(*) filter (where overall_score < 2) / count(*), 2) pct_below_2,
  round(100.0 * count(*) filter (where overall_score >= 5) / count(*), 2) pct_ge_5,
  round(100.0 * count(*) filter (where overall_score >= 7) / count(*), 2) pct_ge_7
from movie_score_caches;
```

```sql
with c as (
  select *,
    (
      (mob_score > 0)::int +
      (critics_score > 0)::int +
      (festival_recognition_score > 0)::int +
      (time_machine_score > 0)::int +
      (auteurs_score > 0)::int +
      (box_office_score > 0)::int
    ) as present_lenses
  from movie_score_caches
)
select
  present_lenses,
  count(*) movies,
  round(100.0 * count(*) / sum(count(*)) over (), 2) pct,
  round(avg(overall_score)::numeric, 2) avg_score,
  round(avg(score_confidence)::numeric, 3) avg_conf
from c
group by present_lenses
order by present_lenses;
```
