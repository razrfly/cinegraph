# Phase 5 CineGraph Scoreability Performance Audit

Generated at: 2026-05-02T16:52:26Z

This report captures read-only query plans and local endpoint timings for Phase 5
scoreability performance hardening. The product behavior remains Phase 4:
numeric scores are public only for movies with 2+ present lenses.

## Query Plan Summary

| Query | Execution ms | Planning ms | Temp I/O |
| --- | --- | --- | --- |
| generic_left_join_scoreability_sort_page_1 | 813.085 | 2.625 | yes |
| score_cache_first_scoreability_sort_page_1 | 0.290 | 2.722 | no |
| score_cache_first_scoreability_sort_page_10 | 1.719 | 1.768 | no |
| score_cache_first_scoreability_sort_page_size_48 | 0.196 | 1.657 | no |
| scoreability_view_display_lookup_page_1 | 1084.351 | 1.618 | yes |
| representative_filtered_generic_score_sort | 1109.939 | 1.830 | yes |

## Endpoint Timing

These timings require a local Phoenix server on `localhost:4001`. If the server is
not running, the rows are marked as errors.

| URL | Run | Status | Total ms | Error |
| --- | --- | --- | --- | --- |
| http://localhost:4001/movies?sort=score_desc | 1 | 200 | 232 |  |
| http://localhost:4001/movies?sort=score_desc | 2 | 200 | 140 |  |
| http://localhost:4001/movies?sort=score_desc | 3 | 200 | 145 |  |
| http://localhost:4001/movies?sort=score_desc&page=10 | 1 | 200 | 137 |  |
| http://localhost:4001/movies?sort=score_desc&page=10 | 2 | 200 | 113 |  |
| http://localhost:4001/movies?sort=score_desc&page=10 | 3 | 200 | 104 |  |
| http://localhost:4001/movies?sort=score_desc&per_page=48 | 1 | 200 | 108 |  |
| http://localhost:4001/movies?sort=score_desc&per_page=48 | 2 | 200 | 121 |  |
| http://localhost:4001/movies?sort=score_desc&per_page=48 | 3 | 200 | 121 |  |

## Full Plans

### generic_left_join_scoreability_sort_page_1

```text
Limit  (cost=283802.69..283805.48 rows=24 width=44) (actual time=562.548..813.030 rows=24.00 loops=1)
  Buffers: shared hit=1815 read=193804, temp read=15314 written=15388
  ->  Gather Merge  (cost=283802.69..377892.00 rows=807866 width=44) (actual time=562.548..813.028 rows=24.00 loops=1)
        Workers Planned: 2
        Workers Launched: 2
        Buffers: shared hit=1815 read=193804, temp read=15314 written=15388
        ->  Sort  (cost=282802.66..283644.19 rows=336611 width=44) (actual time=558.477..558.492 rows=19.00 loops=3)
              Sort Key: (CASE WHEN ((sc.id IS NOT NULL) AND ((((((((COALESCE(sc.mob_score, '0'::double precision) > '0'::double precision))::integer + ((COALESCE(sc.critics_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.festival_recognition_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.time_machine_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.auteurs_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.box_office_score, '0'::double precision) > '0'::double precision))::integer) >= 2)) THEN 0 ELSE 1 END), (CASE WHEN ((((((((COALESCE(sc.mob_score, '0'::double precision) > '0'::double precision))::integer + ((COALESCE(sc.critics_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.festival_recognition_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.time_machine_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.auteurs_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.box_office_score, '0'::double precision) > '0'::double precision))::integer) >= 2) THEN (sc.overall_score * (((((((((COALESCE(sc.mob_score, '0'::double precision) > '0'::double precision))::integer + ((COALESCE(sc.critics_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.festival_recognition_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.time_machine_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.auteurs_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.box_office_score, '0'::double precision) > '0'::double precision))::integer))::double precision / '6'::double precision)) ELSE NULL::double precision END) DESC NULLS LAST, m.release_date DESC NULLS LAST, m.id
              Sort Method: top-N heapsort  Memory: 28kB
              Buffers: shared hit=1815 read=193804, temp read=15314 written=15388
              Worker 0:  Sort Method: top-N heapsort  Memory: 28kB
              Worker 1:  Sort Method: top-N heapsort  Memory: 28kB
              ->  Parallel Hash Right Join  (cost=192581.85..273402.86 rows=336611 width=44) (actual time=439.437..534.902 rows=301095.67 loops=3)
                    Hash Cond: (sc.movie_id = m.id)
                    Buffers: shared hit=1755 read=193804, temp read=15314 written=15388
                    ->  Parallel Seq Scan on movie_score_caches sc  (cost=0.00..21592.38 rows=376038 width=72) (actual time=0.081..23.932 rows=300830.00 loops=3)
                          Buffers: shared read=17832
                    ->  Parallel Hash  (cost=186072.21..186072.21 rows=336611 width=32) (actual time=181.624..181.624 rows=301095.67 loops=3)
                          Buckets: 131072  Batches: 8  Memory Usage: 8544kB
                          Buffers: shared hit=1755 read=175972, temp written=5200
                          ->  Parallel Seq Scan on movies m  (cost=0.00..186072.21 rows=336611 width=32) (actual time=0.070..110.583 rows=301095.67 loops=3)
                                Filter: (((import_status)::text = 'full'::text) AND ((release_date IS NULL) OR (release_date <= CURRENT_DATE)))
                                Rows Removed by Filter: 80460
                                Buffers: shared hit=1755 read=175972
Planning:
  Buffers: shared hit=757 read=109
Planning Time: 2.625 ms
Execution Time: 813.085 ms
```

### score_cache_first_scoreability_sort_page_1

```text
Limit  (cost=11.03..113.47 rows=24 width=40) (actual time=0.262..0.264 rows=24.00 loops=1)
  Buffers: shared hit=92 read=64
  ->  Incremental Sort  (cost=11.03..906567.31 rows=212374 width=40) (actual time=0.262..0.262 rows=24.00 loops=1)
        Sort Key: ((sc.overall_score * (((((((((COALESCE(sc.mob_score, '0'::double precision) > '0'::double precision))::integer + ((COALESCE(sc.critics_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.festival_recognition_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.time_machine_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.auteurs_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.box_office_score, '0'::double precision) > '0'::double precision))::integer))::double precision / '6'::double precision))) DESC NULLS LAST, m.release_date DESC NULLS LAST, m.id
        Presorted Key: ((sc.overall_score * (((((((((COALESCE(sc.mob_score, '0'::double precision) > '0'::double precision))::integer + ((COALESCE(sc.critics_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.festival_recognition_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.time_machine_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.auteurs_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.box_office_score, '0'::double precision) > '0'::double precision))::integer))::double precision / '6'::double precision)))
        Full-sort Groups: 1  Sort Method: quicksort  Average Memory: 27kB  Peak Memory: 27kB
        Buffers: shared hit=92 read=64
        ->  Nested Loop  (cost=0.85..900801.15 rows=212374 width=40) (actual time=0.025..0.244 rows=28.00 loops=1)
              Buffers: shared hit=80 read=64
              ->  Index Only Scan using idx_score_caches_scoreability_sort_desc on movie_score_caches sc  (cost=0.42..89748.88 rows=300830 width=64) (actual time=0.014..0.098 rows=28.00 loops=1)
                    Heap Fetches: 28
                    Index Searches: 1
                    Buffers: shared hit=4 read=28
              ->  Index Scan using movies_pkey on movies m  (cost=0.43..2.66 rows=1 width=32) (actual time=0.005..0.005 rows=1.00 loops=28)
                    Index Cond: (id = sc.movie_id)
                    Filter: (((import_status)::text = 'full'::text) AND ((release_date IS NULL) OR (release_date <= CURRENT_DATE)))
                    Index Searches: 28
                    Buffers: shared hit=76 read=36
Planning:
  Buffers: shared hit=744 read=120
Planning Time: 2.722 ms
Execution Time: 0.290 ms
```

### score_cache_first_scoreability_sort_page_10

```text
Limit  (cost=933.06..1035.51 rows=24 width=40) (actual time=1.689..1.700 rows=24.00 loops=1)
  Buffers: shared hit=1057 read=324
  ->  Incremental Sort  (cost=11.03..906567.31 rows=212374 width=40) (actual time=0.219..1.694 rows=240.00 loops=1)
        Sort Key: ((sc.overall_score * (((((((((COALESCE(sc.mob_score, '0'::double precision) > '0'::double precision))::integer + ((COALESCE(sc.critics_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.festival_recognition_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.time_machine_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.auteurs_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.box_office_score, '0'::double precision) > '0'::double precision))::integer))::double precision / '6'::double precision))) DESC NULLS LAST, m.release_date DESC NULLS LAST, m.id
        Presorted Key: ((sc.overall_score * (((((((((COALESCE(sc.mob_score, '0'::double precision) > '0'::double precision))::integer + ((COALESCE(sc.critics_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.festival_recognition_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.time_machine_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.auteurs_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.box_office_score, '0'::double precision) > '0'::double precision))::integer))::double precision / '6'::double precision)))
        Full-sort Groups: 6  Sort Method: quicksort  Average Memory: 27kB  Peak Memory: 27kB
        Pre-sorted Groups: 2  Sort Methods: top-N heapsort, quicksort  Average Memory: 27kB  Peak Memory: 27kB
        Buffers: shared hit=1057 read=324
        ->  Nested Loop  (cost=0.85..900801.15 rows=212374 width=40) (actual time=0.013..1.616 rows=273.00 loops=1)
              Buffers: shared hit=1045 read=324
              ->  Index Only Scan using idx_score_caches_scoreability_sort_desc on movie_score_caches sc  (cost=0.42..89748.88 rows=300830 width=64) (actual time=0.005..0.567 rows=273.00 loops=1)
                    Heap Fetches: 273
                    Index Searches: 1
                    Buffers: shared hit=148 read=129
              ->  Index Scan using movies_pkey on movies m  (cost=0.43..2.66 rows=1 width=32) (actual time=0.004..0.004 rows=1.00 loops=273)
                    Index Cond: (id = sc.movie_id)
                    Filter: (((import_status)::text = 'full'::text) AND ((release_date IS NULL) OR (release_date <= CURRENT_DATE)))
                    Index Searches: 273
                    Buffers: shared hit=897 read=195
Planning:
  Buffers: shared hit=864
Planning Time: 1.768 ms
Execution Time: 1.719 ms
```

### score_cache_first_scoreability_sort_page_size_48

```text
Limit  (cost=11.03..215.92 rows=48 width=40) (actual time=0.142..0.175 rows=48.00 loops=1)
  Buffers: shared hit=261
  ->  Incremental Sort  (cost=11.03..906567.31 rows=212374 width=40) (actual time=0.141..0.173 rows=48.00 loops=1)
        Sort Key: ((sc.overall_score * (((((((((COALESCE(sc.mob_score, '0'::double precision) > '0'::double precision))::integer + ((COALESCE(sc.critics_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.festival_recognition_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.time_machine_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.auteurs_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.box_office_score, '0'::double precision) > '0'::double precision))::integer))::double precision / '6'::double precision))) DESC NULLS LAST, m.release_date DESC NULLS LAST, m.id
        Presorted Key: ((sc.overall_score * (((((((((COALESCE(sc.mob_score, '0'::double precision) > '0'::double precision))::integer + ((COALESCE(sc.critics_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.festival_recognition_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.time_machine_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.auteurs_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.box_office_score, '0'::double precision) > '0'::double precision))::integer))::double precision / '6'::double precision)))
        Full-sort Groups: 2  Sort Method: quicksort  Average Memory: 27kB  Peak Memory: 27kB
        Buffers: shared hit=261
        ->  Nested Loop  (cost=0.85..900801.15 rows=212374 width=40) (actual time=0.012..0.154 rows=49.00 loops=1)
              Buffers: shared hit=249
              ->  Index Only Scan using idx_score_caches_scoreability_sort_desc on movie_score_caches sc  (cost=0.42..89748.88 rows=300830 width=64) (actual time=0.006..0.051 rows=49.00 loops=1)
                    Heap Fetches: 49
                    Index Searches: 1
                    Buffers: shared hit=53
              ->  Index Scan using movies_pkey on movies m  (cost=0.43..2.66 rows=1 width=32) (actual time=0.002..0.002 rows=1.00 loops=49)
                    Index Cond: (id = sc.movie_id)
                    Filter: (((import_status)::text = 'full'::text) AND ((release_date IS NULL) OR (release_date <= CURRENT_DATE)))
                    Index Searches: 49
                    Buffers: shared hit=196
Planning:
  Buffers: shared hit=864
Planning Time: 1.657 ms
Execution Time: 0.196 ms
```

### scoreability_view_display_lookup_page_1

```text
Limit  (cost=314459.50..314462.29 rows=24 width=72) (actual time=871.942..1084.305 rows=24.00 loops=1)
  Buffers: shared hit=300637 read=195430, temp read=24591 written=24748
  ->  Gather Merge  (cost=314459.50..408548.81 rows=807866 width=72) (actual time=871.941..1084.303 rows=24.00 loops=1)
        Workers Planned: 2
        Workers Launched: 2
        Buffers: shared hit=300637 read=195430, temp read=24591 written=24748
        ->  Sort  (cost=313459.47..314301.00 rows=336611 width=72) (actual time=868.262..868.278 rows=19.33 loops=3)
              Sort Key: m.release_date DESC NULLS LAST, m.id
              Sort Method: top-N heapsort  Memory: 28kB
              Buffers: shared hit=300637 read=195430, temp read=24591 written=24748
              Worker 0:  Sort Method: top-N heapsort  Memory: 28kB
              Worker 1:  Sort Method: top-N heapsort  Memory: 29kB
              ->  Parallel Hash Right Join  (cost=222915.13..304059.68 rows=336611 width=72) (actual time=784.123..848.496 rows=301095.67 loops=3)
                    Hash Cond: (sv.movie_id = m.id)
                    Buffers: shared hit=300605 read=195430, temp read=24591 written=24748
                    ->  Subquery Scan on sv  (cost=30333.28..99542.19 rows=476812 width=48) (actual time=289.710..499.975 rows=381555.33 loops=3)
                          Buffers: shared hit=298545 read=19762, temp read=12642 written=12748
                          ->  Parallel Hash Left Join  (cost=30333.28..94774.07 rows=476812 width=1388) (actual time=289.708..485.291 rows=381555.33 loops=3)
                                Hash Cond: (m_1.id = msc.movie_id)
                                Buffers: shared hit=298545 read=19762, temp read=12642 written=12748
                                ->  Parallel Index Only Scan using movies_pkey on movies m_1  (cost=0.43..23238.78 rows=476812 width=8) (actual time=0.101..26.275 rows=381555.33 loops=3)
                                      Heap Fetches: 0
                                      Index Searches: 1
                                      Buffers: shared hit=298298 read=1898
                                ->  Parallel Hash  (cost=21592.38..21592.38 rows=376038 width=64) (actual time=175.398..175.398 rows=300830.00 loops=3)
                                      Buckets: 131072  Batches: 16  Memory Usage: 6368kB
                                      Buffers: shared read=17832, temp written=8768
                                      ->  Parallel Seq Scan on movie_score_caches msc  (cost=0.00..21592.38 rows=376038 width=64) (actual time=0.058..21.545 rows=300830.00 loops=3)
                                            Buffers: shared read=17832
                    ->  Parallel Hash  (cost=186072.21..186072.21 rows=336611 width=32) (actual time=206.374..206.374 rows=301095.67 loops=3)
                          Buckets: 131072  Batches: 8  Memory Usage: 8544kB
                          Buffers: shared hit=2060 read=175668, temp written=5188
                          ->  Parallel Seq Scan on movies m  (cost=0.00..186072.21 rows=336611 width=32) (actual time=0.055..99.725 rows=301095.67 loops=3)
                                Filter: (((import_status)::text = 'full'::text) AND ((release_date IS NULL) OR (release_date <= CURRENT_DATE)))
                                Rows Removed by Filter: 80460
                                Buffers: shared hit=2060 read=175668
Planning:
  Buffers: shared hit=900 read=4
Planning Time: 1.618 ms
Execution Time: 1084.351 ms
```

### representative_filtered_generic_score_sort

```text
Limit  (cost=275438.38..275460.93 rows=24 width=44) (actual time=880.983..1082.211 rows=24.00 loops=1)
  Buffers: shared hit=2297 read=193384, temp read=16720 written=29119
  ->  Nested Loop  (cost=275438.38..881491.62 rows=644862 width=44) (actual time=880.983..1082.209 rows=24.00 loops=1)
        Buffers: shared hit=2297 read=193384, temp read=16720 written=29119
        ->  Gather Merge  (cost=275437.95..369527.26 rows=807866 width=96) (actual time=880.537..1080.838 rows=12.00 loops=1)
              Workers Planned: 2
              Workers Launched: 2
              Buffers: shared hit=2260 read=193360, temp read=16720 written=29119
              ->  Sort  (cost=274437.93..275279.46 rows=336611 width=96) (actual time=875.347..875.493 rows=324.00 loops=3)
                    Sort Key: (CASE WHEN ((sc.id IS NOT NULL) AND ((((((((COALESCE(sc.mob_score, '0'::double precision) > '0'::double precision))::integer + ((COALESCE(sc.critics_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.festival_recognition_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.time_machine_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.auteurs_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.box_office_score, '0'::double precision) > '0'::double precision))::integer) >= 2)) THEN 0 ELSE 1 END), (CASE WHEN ((((((((COALESCE(sc.mob_score, '0'::double precision) > '0'::double precision))::integer + ((COALESCE(sc.critics_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.festival_recognition_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.time_machine_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.auteurs_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.box_office_score, '0'::double precision) > '0'::double precision))::integer) >= 2) THEN (sc.overall_score * (((((((((COALESCE(sc.mob_score, '0'::double precision) > '0'::double precision))::integer + ((COALESCE(sc.critics_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.festival_recognition_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.time_machine_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.auteurs_score, '0'::double precision) > '0'::double precision))::integer) + ((COALESCE(sc.box_office_score, '0'::double precision) > '0'::double precision))::integer))::double precision / '6'::double precision)) ELSE NULL::double precision END) DESC NULLS LAST, m.release_date DESC NULLS LAST, m.id
                    Sort Method: external merge  Disk: 39776kB
                    Buffers: shared hit=2260 read=193360, temp read=16720 written=29119
                    Worker 0:  Sort Method: external merge  Disk: 34952kB
                    Worker 1:  Sort Method: external merge  Disk: 34888kB
                    ->  Parallel Hash Right Join  (cost=192581.85..226277.32 rows=336611 width=96) (actual time=419.173..517.684 rows=301095.67 loops=3)
                          Hash Cond: (sc.movie_id = m.id)
                          Buffers: shared hit=2203 read=193357, temp read=15316 written=15384
                          ->  Parallel Seq Scan on movie_score_caches sc  (cost=0.00..21592.38 rows=376038 width=72) (actual time=0.076..20.918 rows=300830.00 loops=3)
                                Buffers: shared read=17832
                          ->  Parallel Hash  (cost=186072.21..186072.21 rows=336611 width=32) (actual time=219.769..219.770 rows=301095.67 loops=3)
                                Buckets: 131072  Batches: 8  Memory Usage: 8544kB
                                Buffers: shared hit=2203 read=175525, temp written=5196
                                ->  Parallel Seq Scan on movies m  (cost=0.00..186072.21 rows=336611 width=32) (actual time=0.061..101.962 rows=301095.67 loops=3)
                                      Filter: (((import_status)::text = 'full'::text) AND ((release_date IS NULL) OR (release_date <= CURRENT_DATE)))
                                      Rows Removed by Filter: 80460
                                      Buffers: shared hit=2203 read=175525
        ->  Index Only Scan using movie_genres_movie_id_genre_id_index on movie_genres mg  (cost=0.42..0.50 rows=2 width=8) (actual time=0.089..0.112 rows=2.00 loops=12)
              Index Cond: (movie_id = m.id)
              Heap Fetches: 24
              Index Searches: 12
              Buffers: shared hit=37 read=24
Planning:
  Buffers: shared hit=47 read=44
Planning Time: 1.830 ms
Execution Time: 1109.939 ms
```

## Recommendation

Prefer a score-cache-first fast path for plain CineGraph score sorts and keep
`movie_scoreability_view` as the display/API contract. If endpoint timings stay
above the Phase 5 threshold after the expression index and fast path, move
materialized-view/cache work into a separate follow-up.
