# Fix Stale People Quality Scores on Movie Show Pages

## Problem Statement

Movie list and index surfaces are showing fresh, role-weighted `people_quality` scores, but movie show pages can still display stale values from `movie_score_caches`.

Current user-visible failures:

- `The Godfather` index/list scoring reflects the new person-quality logic, while the show page can still render older cached values
- `The Auteurs` block on the show page still shows `5.1` for titles whose cached movie score was calculated before the role-weighted person-quality changes
- Overall scores can diverge between index and show page for the same movie because they come from different data paths

This is not a single bug. It is a combination of:

1. A stale cache lifecycle problem
2. Two different scoring code paths using different data sources
3. A raw SQL ordering bug in `MovieScoring` that previously caused the recalculation query to return bad results

## Root Cause

### 1. Show page is cache-first and does not invalidate stale score caches

[`lib/cinegraph_web/live/movie_live/show.ex`](/Users/holden/Code/projects-2026/cinegraph/lib/cinegraph_web/live/movie_live/show.ex) preloads `:score_cache` and uses it whenever present:

```elixir
movie = Repo.replica().preload(movie, :score_cache)

if movie.score_cache do
  build_display_scores(movie.score_cache, nil)
else
  MovieScoring.calculate_movie_scores(movie)
end
```

That means any existing row in `movie_score_caches` wins, even if:

- the underlying `person_metrics` data changed
- the person-quality formula changed
- the movie scoring query changed

### 2. Index and show page use different scoring sources

- Index/list pages use [`ScoringService.join_person_quality_data/1`](/Users/holden/Code/projects-2026/cinegraph/lib/cinegraph/metrics/scoring_service.ex), which computes fresh role-weighted values from live `person_metrics`
- Show pages use [`movie_score_caches`](/Users/holden/Code/projects-2026/cinegraph/lib/cinegraph/movies/movie_score_cache.ex) when present

As a result, the index can reflect new logic immediately while the show page remains stale until cache rebuild.

### 3. `MovieScoring` had a broken `ORDER BY` alias expression

[`lib/cinegraph/movies/movie_scoring.ex`](/Users/holden/Code/projects-2026/cinegraph/lib/cinegraph/movies/movie_scoring.ex) previously ordered by alias-based expressions like `max_score * role_weight`.

PostgreSQL allows aliases in `ORDER BY` only as bare references, not inside expressions. The fix is to repeat the aggregate expressions directly in `ORDER BY`.

That code fix is already in progress and must ship with this issue, but by itself it does not repair stale `movie_score_caches`.

## Why The Current State Happened

Recent changes updated three separate layers:

1. `person_quality_score.ex` changed the person score normalization formula
2. `movie_scoring.ex` changed movie-level people quality to role-weighted top-10 selection and fixed the `ORDER BY` bug
3. `scoring_service.ex` changed list/index queries to use the new role-weighted logic live

Only the list/index path recomputes from fresh data on every query. The show page does not. Existing cache rows remain valid forever unless explicitly recalculated.

## Immediate Remediation

After the person-quality batch finishes, rebuild all movie score caches so show pages stop reading old values.

### Required operational steps

1. Run the person-quality rebuild:

```bash
mix pqs batch 1
```

2. Rebuild all movie score caches from IEx:

```elixir
Cinegraph.Workers.MovieScoreCacheWorker.queue_all()
```

[`lib/cinegraph/workers/movie_score_cache_worker.ex`](/Users/holden/Code/projects-2026/cinegraph/lib/cinegraph/workers/movie_score_cache_worker.ex) already supports `queue_all/0`, and each job recalculates via `MovieScoring.calculate_movie_scores/1`.

3. Verify with:

```bash
mix cinegraph.audit_people_scores
```

[`lib/mix/tasks/cinegraph.audit_people_scores.ex`](/Users/holden/Code/projects-2026/cinegraph/lib/mix/tasks/cinegraph.audit_people_scores.ex) already contains ground-truth checks, including:

- `The Godfather` >= `8.5`
- `Schindler's List` >= `8.0`
- other known-high-quality titles

4. Manually confirm the movie show page no longer displays the stale `5.1` value and that list/show overall scores match.

## Permanent Fix

We need to fix the cache lifecycle, not just run a one-time rebuild.

### Option A: Version and invalidate movie score caches when scoring inputs change

Recommended first fix:

- Bump `MovieScoreCacheWorker.@calculation_version` whenever movie-scoring logic changes
- Treat old cache versions as stale in the show page
- Fall back to live recalculation or enqueue refresh when `calculation_version` is missing/outdated

Required changes:

1. Define a current movie score calculation version in a single shared place
2. Update show-page cache usage to reject stale versions
3. Optionally backfill/refresh stale caches asynchronously instead of blocking render

This addresses code changes, but not underlying `person_metrics` updates by themselves.

### Option B: Invalidate or refresh affected movie caches when `person_metrics` change

Recommended second fix:

- When person quality scores are recalculated, mark related movie caches stale
- Scope invalidation to movies connected to changed people through `movie_credits`

Possible implementations:

1. Enqueue `MovieScoreCacheWorker` jobs for impacted movie IDs after each person-quality batch
2. Maintain a `stale_at` or `needs_refresh` marker on `movie_score_caches`
3. Delete affected cache rows outright and let read paths repopulate them

This is the real missing dependency in the current architecture: `movie_score_caches` depends on `person_metrics`, but nothing updates that dependency when people scores change.

### Option C: Unify scoring logic across index and show surfaces

Longer-term improvement:

- Move both list/index and show page scoring onto the same source of truth
- Either always use fresh computed values everywhere, or always use versioned caches everywhere

Right now there are two separate implementations of movie people-quality aggregation:

- Ecto query path in `ScoringService`
- raw SQL path in `MovieScoring`

Those implementations can drift. The current incident is partly a cache problem and partly a duplication problem.

## Recommended Implementation Plan

### Phase 1: Ship and remediate

1. Ship the `movie_scoring.ex` `ORDER BY` fix
2. Run `mix pqs batch 1`
3. Run `Cinegraph.Workers.MovieScoreCacheWorker.queue_all()`
4. Verify with `mix cinegraph.audit_people_scores` and manual UI checks

### Phase 2: Prevent recurrence

1. Add score-cache version checking on the show page
2. Reject or refresh stale `movie_score_caches`
3. Trigger targeted cache refresh after person-quality batches complete

### Phase 3: Reduce drift risk

1. Consolidate movie people-quality aggregation into one shared query builder or service
2. Remove duplicated weighting logic between `ScoringService` and `MovieScoring`
3. Add regression coverage around index/show score parity

## Acceptance Criteria

- Movie show pages no longer display stale pre-rebuild people-quality values after person metrics change
- Index/list and show page overall scores converge for the same movie
- A stale `movie_score_caches.calculation_version` is detected and not trusted indefinitely
- Re-running person-quality batches causes dependent movie score caches to refresh
- `mix cinegraph.audit_people_scores` passes with no flagged regressions for the ground-truth set
- `The Godfather` meets the current threshold of `>= 8.5`
- `The Auteurs` block on affected show pages no longer renders the stale `5.1`

## Verification

### Local

1. Run `mix pqs batch 1`
2. In IEx, run `Cinegraph.Workers.MovieScoreCacheWorker.queue_all()`
3. Wait for the `metrics` queue to drain
4. Run `mix cinegraph.audit_people_scores`
5. Open a known affected movie page and confirm the stale score is gone
6. Compare index/list and show page scores for the same title

### Production

1. Deploy the `movie_scoring.ex` fix
2. Run `mix pqs batch 1`
3. Run `Cinegraph.Workers.MovieScoreCacheWorker.queue_all()` in production IEx
4. Confirm queue drain and UI parity

## Risks

- Full cache rebuild enqueues jobs for every movie and may temporarily increase load on the `metrics` queue
- If only the one-time rebuild is done, the issue will recur after the next person-quality recalculation
- Keeping separate list and show scoring implementations increases the chance of future score drift even after cache invalidation is fixed

## Related Files

- [`lib/cinegraph_web/live/movie_live/show.ex`](/Users/holden/Code/projects-2026/cinegraph/lib/cinegraph_web/live/movie_live/show.ex)
- [`lib/cinegraph/movies/movie_scoring.ex`](/Users/holden/Code/projects-2026/cinegraph/lib/cinegraph/movies/movie_scoring.ex)
- [`lib/cinegraph/metrics/scoring_service.ex`](/Users/holden/Code/projects-2026/cinegraph/lib/cinegraph/metrics/scoring_service.ex)
- [`lib/cinegraph/workers/movie_score_cache_worker.ex`](/Users/holden/Code/projects-2026/cinegraph/lib/cinegraph/workers/movie_score_cache_worker.ex)
- [`lib/mix/tasks/cinegraph.audit_people_scores.ex`](/Users/holden/Code/projects-2026/cinegraph/lib/mix/tasks/cinegraph.audit_people_scores.ex)
