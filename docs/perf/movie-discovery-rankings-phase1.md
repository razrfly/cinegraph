# Movie Discovery Rankings MV — Phase 1

Issue: #805  
Date started: 2026-05-01  
Local audit: 2026-05-01 against `cinegraph_dev` with 1,144,134 MV rows

Phase 1 moves only the no-filter default `/movies` browse path from the inline
`discovery_score_desc` expression to `movie_discovery_rankings_mv`.

## Optimized Query Shape

```sql
SELECT m.*
FROM movie_discovery_rankings_mv r
JOIN movies m ON m.id = r.movie_id
WHERE r.import_status = 'full'
  AND r.is_released = true
ORDER BY r.default_discovery_score DESC NULLS LAST,
         r.release_date DESC NULLS LAST,
         r.movie_id
LIMIT 24 OFFSET 0;
```

The optimized total count is:

```sql
SELECT count(*)
FROM movie_discovery_rankings_mv r
WHERE r.import_status = 'full'
  AND r.is_released = true;
```

## Refresh

Manual refresh:

```bash
mix cinegraph.discovery_rankings.refresh
```

The task uses `REFRESH MATERIALIZED VIEW CONCURRENTLY` by default and reports
duration plus row count. Use `--no-concurrent` only for first-population recovery
or local maintenance.

## Baseline Capture Checklist

Captured before/after on `cinegraph_dev` with a temporary `mix run --no-start`
benchmark script and background children disabled. Timings are medians of three
measured runs after one warm-up run. Page timings below use the backend SQL page
query; the app-level row includes page + exact count through
`Search.search_movies_uncached/1`.

| Scenario | Before | After | Notes |
|---|---:|---:|---|
| Default page 1, `LIMIT 24 OFFSET 0` | 3827.6 ms | 1.8 ms | raw page query |
| Default page 2, `LIMIT 24 OFFSET 24` | 3775.8 ms | 1.6 ms | raw page query |
| Default page 10, `LIMIT 24 OFFSET 216` | 3768.8 ms | 0.9 ms | raw page query |
| Default total count | 16.5 ms | 50.7 ms | MV predicate, exact count |
| `Search.search_movies_uncached/1` page 1 | n/a | 45.7 ms | page + MV count |
| `Search.search_movies_uncached/1` page 2 | n/a | 40.5 ms | page + MV count |
| `Search.search_movies_uncached/1` page 10 | n/a | 40.0 ms | page + MV count |

The previous local audit reported V2 default browse at 3970 ms p50. The Phase 1
page query is now ~1 ms and the full uncached Search path is ~40-46 ms, comfortably
under the 1s acceptance target.

## EXPLAIN Summary

### Optimized page 1

```text
Limit  (actual time=0.155..1.120 rows=24 loops=1)
  -> Index Only Scan using movie_discovery_rankings_mv_default_rank_idx ... rows=24
  -> Index Scan using movies_pkey ... loops=24
Planning Time: 2.445 ms
Execution Time: 1.148 ms
```

### Optimized count

```text
Finalize Aggregate  (actual time=53.586..54.893 rows=1 loops=1)
  -> Partial Aggregate
    -> Parallel Index Only Scan using movie_discovery_rankings_mv_default_rank_idx
Planning Time: 0.023 ms
Execution Time: 54.903 ms
```

The MV count is exact and uses the MV predicate/index, so it avoids the old
generic discovery sort path. It is slower than the old simple movies count, but
still well below the page-load target.

### Old inline discovery page 1

```text
Limit  (actual time=4157.848..4157.850 rows=24 loops=1)
  -> Sort  (top-N heapsort)
    -> Seq Scan on movies ... rows=842285
      -> repeated external_metrics Index Scan subplans
Planning Time: 1.225 ms
Execution Time: 4157.894 ms
```

## Ranking Parity Check

Top 10 IDs matched exactly between the old inline discovery formula and the MV
query on 2026-05-01:

```text
434834, 369762, 955, 461571, 392936, 367559, 120, 388685, 336974, 361118
```

## Notes

- The MV preserves the current `Cinegraph.Movies.Query.CustomSorting`
  `discovery_score_desc` formula weights and component semantics.
- `CURRENT_DATE` is materialized as `calculated_for_date`; daily refresh is
  expected for Phase 1 freshness.
- Any non-default filter or sort still routes through the existing generic
  search path.
