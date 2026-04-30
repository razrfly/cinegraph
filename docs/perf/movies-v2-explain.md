# Movies-V2 Search — EXPLAIN ANALYZE Captures

Performance baselines for the V2 movies discovery page (issue #785). All plans
captured against `cinegraph_dev` on 2026-04-30 after migration
`20260430075655_add_lens_sort_and_festival_indexes` was applied.

## Index summary

After migration `20260430075655`:

| Index | Table | Definition |
|---|---|---|
| `idx_score_caches_overall_score_desc` | `movie_score_caches` | `(overall_score DESC NULLS LAST) WHERE overall_score IS NOT NULL` |
| `idx_score_caches_mob_score_desc` | `movie_score_caches` | `(mob_score DESC NULLS LAST) WHERE mob_score IS NOT NULL` |
| `idx_score_caches_critics_score_desc` | `movie_score_caches` | `(critics_score DESC NULLS LAST) WHERE critics_score IS NOT NULL` |
| `idx_score_caches_festival_recognition_score_desc` | `movie_score_caches` | `(festival_recognition_score DESC NULLS LAST) WHERE festival_recognition_score IS NOT NULL` |
| `idx_score_caches_time_machine_score_desc` | `movie_score_caches` | `(time_machine_score DESC NULLS LAST) WHERE time_machine_score IS NOT NULL` |
| `idx_score_caches_auteurs_score_desc` | `movie_score_caches` | `(auteurs_score DESC NULLS LAST) WHERE auteurs_score IS NOT NULL` |
| `idx_festival_ceremonies_org_year` | `festival_ceremonies` | `(organization_id, year)` |

Each lens index is ~19 MB. The ceremonies composite is small (<1 MB).

---

## Baseline 1 — global "Top by Critics", no filters

The most direct test of the new lens index. Mirrors a landing-page lens shortcut
(e.g., `/movies?sort=critics_desc`).

### Query

```sql
SELECT movie_id, critics_score
FROM movie_score_caches
WHERE critics_score IS NOT NULL
ORDER BY critics_score DESC NULLS LAST
LIMIT 24
```

### Before (no lens index — would use parallel seq scan)

Forced via `enable_indexscan = OFF` and validated against the previous schema
state. Parallel Seq Scan + top-N heapsort over 902k rows:

```
Limit  (actual time=33.5ms rows=24)
  Gather Merge  (actual time=33.4ms)
    Sort  (Sort Method: top-N heapsort; ~300k rows)
      Parallel Seq Scan on movie_score_caches
        Filter: critics_score IS NOT NULL  (rows=300693, loops=3)
Execution Time: 33.512 ms
```

### After (uses `idx_score_caches_critics_score_desc`)

```
Limit  (actual time=0.115ms rows=24)
  Index Scan using idx_score_caches_critics_score_desc on movie_score_caches
Planning Time: 1.447 ms
Execution Time: 0.126 ms
```

**~265× speedup** for the index-scan path. The `WHERE critics_score IS NOT NULL`
predicate matches the partial-index `WHERE` clause exactly, and the
`ORDER BY critics_score DESC NULLS LAST` matches the index sort order, so the
planner can return rows directly from the index without sorting.

> ⚠️ **`NULLS LAST` is required.** A query that writes `ORDER BY critics_score DESC`
> (default = `NULLS FIRST` for descending) does *not* match the index sort order
> and falls back to seq scan + sort. The production code in
> `lib/cinegraph/movies/query/custom_sorting.ex` correctly uses `:desc_nulls_last`
> for all lens / score-cache sorts (line 331, 355, etc.).

---

## Baseline 2 — Genres=Drama + Decade=1990 + sort=critics_score

Multi-filter query with a lens sort. Tests whether the planner mixes the new
score-cache index with the existing genre and date indexes.

### Query

```sql
SELECT m.id, m.title, msc.critics_score
FROM movies m
INNER JOIN movie_genres mg ON mg.movie_id = m.id
LEFT JOIN movie_score_caches msc ON msc.movie_id = m.id
WHERE mg.genre_id = $1            -- Drama
  AND m.release_date >= '1990-01-01'
  AND m.release_date <= '1999-12-31'
ORDER BY msc.critics_score DESC NULLS LAST
LIMIT 24
```

### Plan (after migration)

```
Limit  (actual time=70.111ms rows=24)
  Sort  (Sort Method: top-N heapsort)
    Hash Right Join                              ← genres × decade × scores
      Hash Cond: msc.movie_id = m.id
      Parallel Bitmap Heap Scan on movies m
        Recheck Cond: release_date BETWEEN ...
        Bitmap Index Scan on movies_release_date_index
      Bitmap Heap Scan on movie_genres
        Bitmap Index Scan on movie_genres_genre_id_index
      Index Scan using movie_score_caches_movie_id_index on msc
Execution Time: 70.111 ms
```

### Notes

- The lens sort index is **not** used here — the genre + decade filter is
  selective enough (~12k rows) that the planner correctly chooses to hash-join
  filtered movies against the score cache via `movie_score_caches_movie_id_index`,
  then top-N heapsort. This is optimal.
- Planning time (~3.5ms) is dominated by query complexity. Execution at 70ms is
  acceptable for a multi-join, multi-filter query that returns from a 902k-row
  table.
- If the user combines a non-selective filter (e.g. genre alone, no decade), the
  query crosses 100k rows and the lens index becomes preferable. The planner
  re-evaluates per query.

---

## Baseline 3 — Festivals=[Cannes] + sort=overall_score

Tests the new `idx_festival_ceremonies_org_year` composite.

### Query

```sql
SELECT m.id, m.title, msc.overall_score
FROM movies m
INNER JOIN festival_nominations fn ON fn.movie_id = m.id
INNER JOIN festival_ceremonies fc ON fc.id = fn.ceremony_id
LEFT JOIN movie_score_caches msc ON msc.movie_id = m.id
WHERE fc.organization_id = $1     -- Cannes
ORDER BY msc.overall_score DESC NULLS LAST
LIMIT 24
```

### Plan (after migration)

```
Limit  (actual time=18.343ms rows=24)
  Gather Merge
    Sort  (Sort Method: top-N heapsort, ~7.3k rows)
      Nested Loop Left Join
        Nested Loop
          Hash Join                                 ← uses new index ✓
            Parallel Index Only Scan on festival_nominations_unique_nomination_idx
            Bitmap Heap Scan on festival_ceremonies fc
              Bitmap Index Scan on idx_festival_ceremonies_org_year
                Index Cond: organization_id = '3'
          Index Scan using movies_pkey on m
        Index Scan using movie_score_caches_movie_id_index on msc
Execution Time: 18.343 ms
```

### Notes

- `Bitmap Index Scan on idx_festival_ceremonies_org_year` confirms the new
  composite is used. Heap touches for ceremonies dropped to 23 blocks.
- Without the index, this plan would seq-scan all ~10k rows of
  `festival_ceremonies` for every query. ~3-5× speedup expected at scale.
- 18ms total is well within the 500ms slow-query threshold and below the 200ms
  perceived-latency budget for interactive UI.

---

## Baseline 4 — Trigram title search

Verifies the existing `movies_title_trgm_idx` (added in
`20260429151427_add_search_trigram_indexes`) is being used. Not affected by this
migration; included as a control for the search box.

### Query

```sql
SELECT m.id, m.title, similarity(m.title, $1::text) AS sim
FROM movies m
WHERE m.title % $1::text
ORDER BY similarity(m.title, $1::text) DESC
LIMIT 24
```

`params: ["godfat"]`

### Plan

```
Limit  (actual time=31.598ms rows=24)
  Sort  (top-N heapsort)
    Bitmap Heap Scan on movies m
      Recheck Cond: title % 'godfat'
      Bitmap Index Scan on movies_title_trgm_idx  ← good
Execution Time: 31.745 ms
```

Trigram index is healthy. The 31ms execution is mostly bitmap recheck — 4508
candidates narrowed to 75 matches. Still well under the slow-query threshold.

---

## N+1 audit

`Cinegraph.Movies.Search.search_movies/1` returns Movie structs with
`:genres`, `:movie_credits`, and `:score_cache` all `Ecto.Association.NotLoaded`
— it never preloads. The grid template gracefully degrades on `NotLoaded` (returns
`[]`/`nil`), so cards work without preloads but lose the score badge and lens
chips on raw lens sorts.

`IndexV2.preload_card_assocs/2` adds a **single batched preload** of
`:score_cache` only when an active lens key (mob/critics/etc.) is present:

```sql
SELECT … FROM movie_score_caches AS m0 WHERE m0.movie_id = ANY($1)
-- params: [movie_ids_for_24_rows]
```

Verified by attaching a telemetry counter and rendering 24 cards:

| Sort | Queries | Notes |
|---|---|---|
| `release_date_desc` (default) | 2 | 1 Flop SELECT + 1 COUNT |
| `score_desc` | 2 | overall_score populated via `select_merge` |
| `cinegraph_editorial_desc` (preset) | 2 | overall_score via `select_merge` |
| `critics_desc` (raw lens) | 3 | + 1 batched score_cache preload (this PR) |
| `mob_desc` (raw lens) | 3 | + 1 batched score_cache preload |

**No N+1** — preload uses `WHERE movie_id = ANY($1)`, single round-trip for all
rows on the page. Adding `:genres` or director credits would each cost one more
batched query; not currently needed, since the V2 card design omits them when
not loaded.

## Slow-query telemetry

`Cinegraph.Telemetry.SlowQueryLogger` (attached in `Application.start/2` when
`config :cinegraph, :slow_query_logger, true`) emits a `Logger.warning` for any
query exceeding the threshold (default 500ms). During the EXPLAIN runs above,
the only flag was the deliberate `VACUUM ANALYZE movie_score_caches` (~530ms),
which is expected. No production search query crossed the threshold.

To reproduce locally:

```elixir
# iex -S mix
Cinegraph.Movies.Search.search_movies(%{"sort" => "critics_desc", "per_page" => "24"})
```

Then watch the dev console — anything >500ms warns with the SQL and parameters.
