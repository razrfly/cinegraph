# ISSUE: Auteurs / People Quality Lens — Full Audit

**Date:** 2026-03-25
**Scope:** `criteria_scoring.ex` (auteur_recognition), `movie_scoring.ex` (people_quality)
**Status:** Open — fallback bug confirmed; concept divergence documented; no code changes yet.

---

## 1. Identity & Naming

The auteurs/talent lens has **different names and completely different concepts** in the two subsystems:

| System | Criterion Name | Scale | Weight | File |
|---|---|---|---|---|
| Predictions engine | `auteur_recognition` | 0–100 | **5% default** | `criteria_scoring.ex` |
| Discovery/show UI | `people_quality` | 0–10 | ~15% (editorial) | `movie_scoring.ex` |

These are not the same concept with different names — they measure fundamentally different things.
The shared label "Auteurs / People Quality" in the UI obscures a real design split that needs resolution.

---

## 2. What's Inside Each Lens

### Predictions: `auteur_recognition` (criteria_scoring.ex:355–394, 813–825)

Looks only at **directors**. Counts how many of their prior films appear in the 1001 Movies list.
Returns a coarse step function:

| Director's prior 1001 count | Score |
|---|---|
| ≥ 5 films | 100.0 |
| ≥ 3 films | 80.0 |
| ≥ 1 film | 60.0 |
| 0 films ("new director") | **20.0** ← BUG |
| No director credit found | 0.0 (non-batch only) |

### Display: `people_quality` (movie_scoring.ex:86–125)

Looks at the **entire credited team** (cast + crew). Runs a role-weighted PQS average over
the top 10 unique people by weighted score:

| Role | Weight |
|---|---|
| Director | 3.0× |
| Cast order 1–3 | 2.0× |
| Cast order 4–10 | 1.5× |
| Writer | 1.5× |
| Producer | 1.0× |
| Other crew | 1.0× |

Returns the weighted average of `person_metrics.score` (0–100 scale), then divided by 10 for
the 0–10 display scale.

### Summary of divergence

| Dimension | Predictions (`auteur_recognition`) | Display (`people_quality`) |
|---|---|---|
| Who it covers | Directors only | Full cast + crew |
| Data source | `canonical_sources` / 1001-list count | `person_metrics.quality_score` |
| Scale | Step function (20/60/80/100) | Continuous (0–100 → /10) |
| Zero baseline | Returns 0 if no directors; 20 if unknown director | Returns 0 if no PQS data |

---

## 3. Algorithm Status

### Bug 1 — Fallback returns 20 instead of 0 (confirmed)

**Non-batch path** (`score_auteur_recognition`, line 383–393):
```elixir
cond do
  existing_1001_count >= 5 -> 100.0
  existing_1001_count >= 3 -> 80.0
  existing_1001_count >= 1 -> 60.0
  true -> 20.0   # ← "New director" — should be 0.0
end
```

**Batch path** (`score_auteur_recognition_from_batch`, line 813–825):
```elixir
cond do
  director_1001_count >= 5 -> 100.0
  director_1001_count >= 3 -> 80.0
  director_1001_count >= 1 -> 60.0
  true -> 20.0   # ← same bug
end
```

Every movie whose director has zero 1001 Movies credits receives a free 20-point boost.
This includes debut directors, action franchise directors, and documentary filmmakers
whose work is legitimately outside the 1001-list canon.

**Effect on weighted total:** With 5% weight, 20 points = +1.0 to every film's score.
Uniform inflation — harmless to ranking order between films, but misleads calibration.

### Bug 2 — Batch vs. non-batch inconsistency

`batch_load_director_info` (line 583–630) returns `0` for movies with no director credits
(the `Map.get(director_map, movie_id, [])` path yields `[]`, sum = 0).
`score_auteur_recognition_from_batch(0)` → `true -> 20.0`.

But the non-batch `score_auteur_recognition` (line 355) returns `0.0` when no directors found:
```elixir
if length(director_ids) == 0 do
  0.0
```

So the same film (no director credit) scores **0.0** via non-batch and **20.0** via batch.
This breaks the invariant that both paths produce consistent results.

### Design question — step function vs. continuous score

The step function (20/60/80/100) creates large, arbitrary cliffs. A director with 1 film
on the 1001-list and a director with 4 films both score 60. A director with 5 films jumps
immediately to 100. Whether this coarseness is acceptable depends on what question the
predictions engine is actually trying to answer.

---

## 4. How to Test & Verify

### 4a. Verify the fallback bug

```elixir
iex -S mix
alias Cinegraph.Predictions.CriteriaScoring

# Any movie with a new/debut director should score 0, not 20
# Find a movie with no 1001-list director:
movie = Cinegraph.Repo.get_by(Cinegraph.Movies.Movie, slug: "DEBUT-DIRECTOR-FILM")
IO.inspect CriteriaScoring.score_auteur_recognition(movie)
# Currently: 20.0
# Expected after fix: 0.0
```

### 4b. Verify batch vs. non-batch consistency

```elixir
movies = Cinegraph.Repo.all(Cinegraph.Movies.Movie, limit: 20)

# Batch path
batch_results = CriteriaScoring.batch_score_movies(movies)

# Non-batch path
individual_results = Enum.map(movies, fn m ->
  {m.id, CriteriaScoring.score_auteur_recognition(m)}
end)

# Compare auteur_recognition for each movie — these must match
Enum.each(batch_results, fn %{movie: m, prediction: p} ->
  batch_score = p.criteria_scores.auteur_recognition
  indiv_score = Enum.find_value(individual_results, fn {id, s} -> if id == m.id, do: s end)
  if batch_score != indiv_score do
    IO.puts("MISMATCH #{m.id}: batch=#{batch_score}, individual=#{indiv_score}")
  end
end)
```

### 4c. Verify the display `people_quality` score

```elixir
alias Cinegraph.Movies.MovieScoring

# Known prestige film with A-list cast — expect high score
movie = Cinegraph.Repo.get_by(Cinegraph.Movies.Movie, slug: "parasite")
IO.inspect MovieScoring.explain_people_quality(movie.id)
# Should show director + lead actors with high PQS

# B-movie or no-credits film — expect 0.0
movie2 = Cinegraph.Repo.get_by(Cinegraph.Movies.Movie, slug: "SOME-OBSCURE-FILM")
IO.inspect MovieScoring.explain_people_quality(movie2.id)
```

### 4d. Distribution check

```elixir
results = Cinegraph.Predictions.HistoricalValidator.validate_decade("2010s")
scores = Enum.map(results.movies, & &1.criteria.auteur_recognition)

IO.puts("At 0.0:   #{Enum.count(scores, &(&1 == 0.0))}")
IO.puts("At 20.0:  #{Enum.count(scores, &(&1 == 20.0))}")   # should be 0 after fix
IO.puts("At 60.0:  #{Enum.count(scores, &(&1 == 60.0))}")
IO.puts("At 80.0:  #{Enum.count(scores, &(&1 == 80.0))}")
IO.puts("At 100.0: #{Enum.count(scores, &(&1 == 100.0))}")
```

**Healthy distribution after fix:** Large cluster at 0.0 (most films), moderate cluster at 60.0
(directors with ≥1 prior 1001-list credit), small cluster at 100.0. No cluster at 20.0.

---

## 5. What Failure Looks Like

| Failure Mode | Observable Symptom | Root Cause |
|---|---|---|
| Fallback bug present | All non-auteur films score 20 instead of 0 | `true -> 20.0` in cond |
| Batch/individual mismatch | Consistency test in §4b produces MISMATCH lines | Bug 2 in batch path |
| Step function cliffs | Histogram shows sharp clusters at 60/80/100 with gaps between | By design; acceptable or not depends on decision in §10 |
| Director-only blindspot | Ensemble films (no standout director) score low despite A-list cast | Predictions path ignores cast PQS entirely |
| PQS data missing | `people_quality` scores 0 for many films | `person_metrics` not populated; run PQS worker |

---

## 6. How to Measure Quality

### Batch/individual consistency

```elixir
# Run §4b above. Zero MISMATCH lines = consistent.
```

### Auteur vs. quality correlation

```elixir
# Do high auteur_recognition films also have high people_quality?
# If yes: both lenses measure similar things and one may be redundant.
# If no: they capture genuinely different signals.

movies = Cinegraph.Repo.all(from m in Cinegraph.Movies.Movie, limit: 200)

pairs = Enum.map(movies, fn movie ->
  auteur = CriteriaScoring.score_auteur_recognition(movie)
  scores = MovieScoring.calculate_movie_scores(movie)
  pq = scores.components.people_quality
  {movie.slug, auteur, pq}
end)

# Inspect high auteur / low people_quality outliers — debut directors of acclaimed films
# Inspect low auteur / high people_quality outliers — franchise films with A-list cast
```

### SQL: director 1001-list coverage

```sql
-- What fraction of movies in the 1001-list have a director
-- who has at least 1 other 1001-list credit?
SELECT
  COUNT(DISTINCT m.id) as total,
  COUNT(DISTINCT m.id) FILTER (WHERE director_1001_count.cnt > 0) as has_auteur_director,
  ROUND(
    100.0 * COUNT(DISTINCT m.id) FILTER (WHERE director_1001_count.cnt > 0) /
    COUNT(DISTINCT m.id), 1
  ) as pct
FROM movies m
WHERE (m.canonical_sources)::jsonb ? '1001_movies'
LEFT JOIN LATERAL (
  SELECT COUNT(DISTINCT m2.id) as cnt
  FROM movie_credits mc
  JOIN movie_credits mc2 ON mc2.person_id = mc.person_id
  JOIN movies m2 ON m2.id = mc2.movie_id
  WHERE mc.movie_id = m.id
    AND mc.department = 'Directing'
    AND (m2.canonical_sources)::jsonb ? '1001_movies'
    AND m2.id != m.id
) director_1001_count ON true;
```

---

## 7. What the Lens Is For

The predictions engine asks: **will the 1001 Movies editors add this film to future editions?**

The 1001 Movies list is strongly director-centric — it skews toward auteur cinema (Kubrick,
Bergman, Tarkovsky, Lynch, Coppola, etc.). A lens capturing director pedigree is appropriate
for this specific prediction task. The step function implementation is crude but directionally sound.

The display system asks: **how good is the talent involved in this film?** That is a broader
question where director-only coverage is insufficient. PQS across cast + crew is the right approach.

These are two distinct, legitimate questions. The lens should not be collapsed into one.
What needs fixing is:
1. The fallback bug (20 → 0)
2. The batch/individual inconsistency
3. Potentially: finer resolution in the step function for the predictions path

---

## 8. Data Missing

### Critical (directly affects scoring accuracy)
- **`person_metrics.quality_score` coverage** — `people_quality` in the display system depends
  entirely on PQS data. If the `PersonQualityScoreWorker` has not run for recent films, their
  `people_quality` will silently score 0.0. Run:
  ```elixir
  Cinegraph.Workers.PersonQualityScoreWorker.queue_missing()
  ```
  and verify with:
  ```sql
  SELECT COUNT(DISTINCT mc.person_id) as with_pqs,
         COUNT(DISTINCT mc.person_id) FILTER (WHERE pm.id IS NULL) as missing
  FROM movie_credits mc
  LEFT JOIN person_metrics pm ON pm.person_id = mc.person_id
    AND pm.metric_type = 'quality_score';
  ```

### Acceptable gaps
- Directors outside the 1001-list ecosystem (documentary, genre, TV) score 0 by design.
  This is correct — the predictions engine is about 1001 Movies affinity.
- Pre-1970 cast PQS may be sparse due to limited credit data. Acceptable.

---

## 9. Grade

| Dimension | Grade | Notes |
|---|---|---|
| Predictions algorithm | **C+** | Step function is coarse but directional; fallback bug inflates all non-auteur scores by 20 |
| Display algorithm | **A−** | Role-weighted PQS average is sound; limited by PQS data coverage |
| Concept clarity | **D** | Two completely different things share one lens slot; no documentation of the split |
| Batch consistency | **D** | Non-batch returns 0 for no-director films; batch returns 20 — clear bug |
| Test coverage | **D** | No unit tests for either path |
| Data coverage | **B** | PQS worker exists; coverage depends on how recently it ran |

**Overall: D+ (predictions path), B− (display path)**

The display `people_quality` is sound. The predictions `auteur_recognition` has two concrete
bugs and a design question that need resolution before this lens can be trusted.

---

## 10. Can We Move On?

**No.** The fallback bug is a correctness issue, not a data gap. Every predictions score
computed today for a non-auteur film is inflated by 20 points on a 0–100 criterion.
With 5% weight that is +1.0 to the weighted total — uniform but not acceptable for calibration.

### Must fix before moving on
1. **Change `true -> 20.0` to `true -> 0.0`** in both `score_auteur_recognition/1` (line 391)
   and `score_auteur_recognition_from_batch/1` (line 822). This is a 2-line change.
2. **Fix batch inconsistency:** `score_auteur_recognition_from_batch(0)` must match
   `score_auteur_recognition/1` for a film with no director credits. Both should return 0.0.

### Decisions needed
3. **What should this lens measure in the predictions path?**
   - Keep director-only step function (fix only the fallback)?
   - Add a continuous component using PQS for directors specifically?
   - Increase the step resolution (e.g., add a tier at ≥2 = 70)?
4. **Name the split explicitly:** rename predictions criterion to `director_pedigree` and
   display criterion to `people_quality` to avoid confusion in calibration UI.

### Nice-to-have
5. Add unit tests: `score_auteur_recognition_from_batch(0) == 0.0`,
   `score_auteur_recognition_from_batch(5) == 100.0`, etc.
6. Verify PQS worker has run for recent films (§8 SQL check).

---

## 11. Action Items

| # | Item | Priority | Effort |
|---|---|---|---|
| 1 | Fix `true -> 20.0` → `true -> 0.0` in both code paths | **CRITICAL** | 5 min |
| 2 | Fix batch/individual inconsistency for no-director films | **HIGH** | 30 min |
| 3 | Decide: director-only step function vs. continuous PQS for predictions | **HIGH** | Discussion |
| 4 | Rename predictions criterion `auteur_recognition` → `director_pedigree` | MEDIUM | ~30 min (touch weights maps + tests) |
| 5 | Add unit tests for both fallback and step-function values | MEDIUM | 1 hour |
| 6 | Verify PQS worker coverage (SQL in §8) | MEDIUM | 10 min |
| 7 | Document the split in module docs | LOW | 15 min |
