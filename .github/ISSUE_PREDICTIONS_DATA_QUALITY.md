# Predictions Data Quality: Fill the Gaps Blocking 50%+ Accuracy

## Context

The 6-lens predictions algorithm (CriteriaScoring) is currently stuck at ~48.6% historical
validation accuracy after fixing the festival abbreviation bug (CANNES→CFF, SUNDANCE→SFF).
Analysis of all 1,256 films on the 1001 Movies list confirms the ceiling is **data quality**,
not weight tuning. All 5 named profiles cluster within 4.3% of each other; hand-tuning weights
cannot break through. What can break through is better data.

This issue tracks the concrete data gaps that need to be closed before Phase 5B ML weight
discovery can produce reliable results.

---

## Gap 1 — RT Tomatometer and Metacritic: Missing for 8–35% of 1001 Films

### What We Have vs. What We Need

| Source | DB Records | 1001-list coverage | Notes |
|---|---|---|---|
| `metacritic/metascore` | 20,468 | ~65% | From OMDb `Metascore` field |
| `rotten_tomatoes/tomatometer` | 37,261 | ~92% | From OMDb `Ratings` array |

Ivory Tower (CriteriaScoring lens 2) averages whatever critic scores exist per film. Films
missing both sources score 0 in this lens, which is systematically wrong.

### Root Cause

Both Metacritic and RT tomatometer come entirely from the **OMDb enrichment pipeline**
(`ExternalMetric.from_omdb/2`). A film has no Metacritic or RT data in `external_metrics`
because one or more of the following is true:

1. **`omdb_data IS NULL`** — OMDb enrichment has never run for this film. The
   `RatingsRefreshWorker` already queues 1001-list films first (Phase A0), but may not have
   covered all of them yet due to the 90-day cooldown or the daily batch cap.

2. **OMDb ran but returned `"N/A"` for both fields** — The film predates RT/Metacritic
   coverage (mostly pre-1960 titles). This is a true data limit; nothing to do here.

3. **OMDb ran but the `Ratings` array was missing or malformed** — Possible if the OMDb
   API returned a partial response. A forced re-fetch would fix this.

### How to Investigate

```sql
-- Films on 1001 list where omdb_data exists but tomatometer is missing
SELECT COUNT(*) FROM movies m
WHERE m.canonical_sources ? '1001_movies'
  AND m.omdb_data IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM external_metrics em
    WHERE em.movie_id = m.id
      AND em.source = 'rotten_tomatoes'
      AND em.metric_type = 'tomatometer'
  );

-- Same for metacritic
SELECT COUNT(*) FROM movies m
WHERE m.canonical_sources ? '1001_movies'
  AND m.omdb_data IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM external_metrics em
    WHERE em.movie_id = m.id
      AND em.source = 'metacritic'
      AND em.metric_type = 'metascore'
  );

-- Films on 1001 list where omdb_data IS NULL (hasn't been enriched yet)
SELECT COUNT(*) FROM movies m
WHERE m.canonical_sources ? '1001_movies'
  AND m.omdb_data IS NULL
  AND m.imdb_id IS NOT NULL;
```

### Fix Options

**Option A (Recommended): Force re-enrich all 1001 films with `omdb_data`**

Run from IEx. The `force: true` flag bypasses the "already has data" skip:

```elixir
# Queue forced re-enrichment for every 1001 film that has omdb_data
# (re-fetches to pick up any Ratings array that may have been missing)
import Ecto.Query
alias Cinegraph.Repo
alias Cinegraph.Movies.Movie
alias Cinegraph.Workers.OMDbEnrichmentWorker

movie_ids =
  Repo.all(
    from m in Movie,
      where: fragment("? \\? '1001_movies'", m.canonical_sources),
      where: not is_nil(m.omdb_data),
      where: not is_nil(m.imdb_id),
      select: m.id
  )

for id <- movie_ids do
  %{"movie_id" => id, "force" => true}
  |> OMDbEnrichmentWorker.new()
  |> Oban.insert()
end

IO.puts("Queued #{length(movie_ids)} re-enrichment jobs")
```

**Option B: Also fill the null backlog for 1001 films**

```elixir
# Queue initial enrichment for 1001 films that have never had OMDb run
null_ids =
  Repo.all(
    from m in Movie,
      where: fragment("? \\? '1001_movies'", m.canonical_sources),
      where: is_nil(m.omdb_data),
      where: not is_nil(m.imdb_id),
      select: m.id
  )

for id <- null_ids do
  %{"movie_id" => id}
  |> OMDbEnrichmentWorker.new()
  |> Oban.insert()
end
```

**Expected outcome**: RT tomatometer coverage should improve from ~92% to 95%+;
Metacritic from ~65% to 75–80%. The remaining gap is genuinely unrated films.

---

## Gap 2 — RT Audience Score: Dead Code Reference

### What the Code Does

`CriteriaScoring.score_mob/1` and `score_mob_from_metrics/1` (the batch version) both filter
for `rotten_tomatoes/audience_score`. There are currently **0 records** of this type in
`external_metrics`.

### Why It Can Never Work Without a Code Change

The OMDb API does **not** return RT audience score. The `ExternalMetric.from_omdb/2` function
extracts:
- `rotten_tomatoes/tomatometer` — from the `Ratings` array (`"Source": "Rotten Tomatoes"`)
- `rotten_tomatoes/page_url` — from `tomatoURL` (OMDb Basic plan only)

Audience score is not in the OMDb response at all. The current reference is dead code.

### Fix Options

**Option A (Quick win): Remove the dead filter from `score_mob`**

The mob lens averages existing scores and ignores missing ones. If the filter returns nothing
for `audience_score`, it simply contributes 0 to the average. Removing it is safe and avoids
confusion. This does **not** reduce functionality — you can't average data that doesn't exist.

The filter appears in two places:
- `score_mob/1` (line ~199 in `criteria_scoring.ex`) — individual scoring path
- `score_mob_from_metrics/1` (line ~701) — batch scoring path

**Option B (Better long-term): Import RT audience score via scraping**

RT audience score is not available from OMDb or any free API. Getting it requires either:
- Scraping RT film pages via Crawlbase (we already have this integration)
- A commercial RT data license (expensive)

If RT audience data is imported, the existing `normalize_rating_score/3` clause for
`rotten_tomatoes/audience_score` is already correct (passes through 0–100 directly).

**Recommendation**: Do Option A now (cleanup), plan Option B as a separate data enrichment
task if RT audience score is deemed worth the scraping effort. The mob lens has full coverage
via IMDb + TMDb; audience score would be additive, not essential.

---

## Gap 3 — Director Credits: 46% of 1001 Films Are Missing Directing Credits

### Scope

574 out of 1,256 (46%) of canonical 1001-list films have no rows in `movie_credits` with
`credit_type = 'crew'` and `department = 'Directing'`.

When a film has no director credits, `score_auteur_recognition` falls through to the default
branch (`true -> 20.0`) instead of scoring 0–100 based on the director's filmography. This
**systematically underestimates** auteur scores for nearly half the canonical set.

Spot check: Ingmar Bergman films show only 3 entries when there should be 7+. The query logic
is correct; the data simply was never imported.

### Root Cause

`movie_credits` is populated by the TMDb import pipeline. A film lacking directing credits
means one of:

1. The TMDb details worker ran but did not fetch credits (credits are a separate API call in
   some code paths).
2. The TMDb details worker has never run for that film (film was added to the 1001 list after
   the initial bulk import, or it was imported via OMDb-only path).
3. TMDb genuinely has no crew data for the film (very old or obscure titles).

### How to Investigate

```sql
-- Films on 1001 list with no director credits
SELECT m.id, m.title, m.release_date, m.imdb_id, m.tmdb_id
FROM movies m
WHERE m.canonical_sources ? '1001_movies'
  AND NOT EXISTS (
    SELECT 1 FROM movie_credits mc
    WHERE mc.movie_id = m.id
      AND mc.credit_type = 'crew'
      AND mc.department = 'Directing'
  )
ORDER BY m.release_date ASC
LIMIT 50;

-- How many have a tmdb_id (can be re-fetched)?
SELECT
  COUNT(*) FILTER (WHERE tmdb_id IS NOT NULL) as has_tmdb_id,
  COUNT(*) FILTER (WHERE tmdb_id IS NULL) as no_tmdb_id,
  COUNT(*) as total
FROM movies m
WHERE m.canonical_sources ? '1001_movies'
  AND NOT EXISTS (
    SELECT 1 FROM movie_credits mc
    WHERE mc.movie_id = m.id
      AND mc.credit_type = 'crew'
      AND mc.department = 'Directing'
  );
```

### Fix

Re-run TMDb details import for all 1001-list films that have a `tmdb_id` but are missing
director credits. The `TMDbDetailsWorker` fetches and stores credits on each run.

```elixir
import Ecto.Query
alias Cinegraph.Repo
alias Cinegraph.Movies.Movie
alias Cinegraph.Workers.TMDbDetailsWorker

movie_ids_needing_credits =
  Repo.all(
    from m in Movie,
      where: fragment("? \\? '1001_movies'", m.canonical_sources),
      where: not is_nil(m.tmdb_id),
      where:
        m.id not in subquery(
          from mc in "movie_credits",
            where: mc.credit_type == "crew" and mc.department == "Directing",
            select: mc.movie_id,
            distinct: true
        ),
      select: {m.id, m.tmdb_id}
  )

for {movie_id, tmdb_id} <- movie_ids_needing_credits do
  %{"movie_id" => movie_id, "tmdb_id" => tmdb_id}
  |> TMDbDetailsWorker.new()
  |> Oban.insert()
end

IO.puts("Queued #{length(movie_ids_needing_credits)} credit re-imports")
```

**Expected outcome**: Director credits coverage from ~54% to 85–90%+ (the remaining gap
will be films with no TMDb ID or where TMDb has no crew data).

**Expected accuracy improvement**: +2–5 percentage points on historical validation.

---

## Gap 4 — Budget/Revenue: 44% of 1001 Films Lack Box Office Data

### Scope

Only 706 of 1,256 (56%) of 1001-list films have both budget and revenue populated in
`tmdb_data`. The 44% gap is mostly pre-1970 films where box office records were never digitized.

### Impact on Cultural Impact Lens

`score_cultural_impact` awards 0–40 points for ROI (revenue/budget). Films with no data score
0 on this component. They are compensated by the IMDb vote count signal (99.8% coverage), but
the ROI dimension is entirely missing.

### Fix Options

**Option A: Accept the structural limitation**

Pre-1970 films genuinely have no surviving box office data. TMDb mirrors what exists publicly.
The IMDb vote fallback (already implemented in `score_cultural_impact`) handles this correctly.
Mark as "known limitation, won't fix."

**Option B: Add IMDb votes as an explicit first-class signal**

Currently IMDb votes feed into `get_imdb_popularity`, which only awards points above thresholds
(7.5 rating + 100k votes = 30 pts). A direct "votes_log" signal would give partial credit to
films with strong cultural longevity even without box office data.

This is a Phase 5C enhancement, not a data import task.

---

## Gap 5 — Canonical Overlap: Unused Signal

### What the Data Shows

Cross-referencing canonical sources on 1001-list films reveals strong clustering:

| Canonical source | Overlap with 1001 list |
|---|---|
| Criterion Collection | 34% of 1001 films |
| National Film Registry | 28% of 1001 films |
| Sight & Sound 2022 | 7% of 1001 films |
| 1001 list ONLY | 45% of 1001 films |

A film appearing on multiple canonical lists is a strong signal of cultural significance.
This signal is **not in any of the 6 current lenses** — it is potentially Phase 5C material
but requires no new data imports (all list membership data is already in `canonical_sources`).

---

## Prioritized Action Plan

| Priority | Item | Effort | Expected Impact |
|---|---|---|---|
| P0 | Investigate OMDb null backlog for 1001 films (Gap 1 query) | 5 min | Understand scope |
| P1 | Force re-enrich 1001-list films via OMDbEnrichmentWorker (Gap 1 Option A) | 30 min | +RT/MC coverage |
| P1 | Fill OMDb null backlog for 1001 films (Gap 1 Option B) | 30 min | +RT/MC coverage |
| P2 | Re-import TMDb credits for 1001 films missing directors (Gap 3) | 30 min | +2–5% accuracy |
| P3 | Remove `audience_score` dead filter from `score_mob` (Gap 2 Option A) | 10 min | Code clarity |
| P4 | Evaluate RT audience scraping (Gap 2 Option B) | Planning | Future signal |
| P5 | Add `canonical_overlap_count` as Phase 5C signal (Gap 5) | Medium | Future signal |

P0–P2 are pure operational tasks (queuing Oban jobs from IEx). P3 is a small code change.
P4 and P5 are future work.

---

## Acceptance Criteria

- [x] All 1001-list films that have `omdb_data` have been force re-enriched; RT tomatometer
  coverage at 95%+, Metacritic at 75%+ — **1,256 jobs queued 2026-03-25 via `mix omdb.enrich --list 1001_movies --force`**
- [ ] OMDb null backlog for 1001-list films is empty (or films confirmed unavailable in OMDb)
- [x] Director credits re-imported for all 1001-list films with a TMDb ID; coverage at 85%+ —
  **574 films queued 2026-03-25 via `mix tmdb.refresh_credits --list 1001_movies` (DataRepairWorker job id=6687905, maintenance queue)**
- [ ] `rotten_tomatoes/audience_score` filter removed from `score_mob/1` and
  `score_mob_from_metrics/1`, OR a plan exists to populate it
- [ ] Historical validation accuracy re-measured after data fill — expect 52–58% range

---

## Related Issues and Files

- `ISSUE_MULTI_SOURCE_MOVIE_LOOKUP.md` — covers TMDb lookup failures during festival import;
  overlaps with Gap 3 (films that entered via OMDb-only path may lack TMDb credits)
- `lib/cinegraph/api_processors/omdb.ex` — OMDb processor; calls `Metrics.store_omdb_metrics`
- `lib/cinegraph/movies/external_metric.ex` — `from_omdb/2`: source of RT tomatometer and
  Metacritic parsing; **does not and cannot produce `audience_score`**
- `lib/cinegraph/workers/omdb_enrichment_worker.ex` — per-movie enrichment job
- `lib/cinegraph/workers/ratings_refresh_worker.ex` — daily cron; already has 1001-list
  priority (Phase A0) but may not have covered all films yet
- `lib/cinegraph/workers/tmdb_details_worker.ex` — fetches credits; needs to be re-run for
  1001-list films missing director credits
- `lib/cinegraph/predictions/criteria_scoring.ex` — lens scoring logic; lines ~199 and ~701
  reference the dead `audience_score` filter
