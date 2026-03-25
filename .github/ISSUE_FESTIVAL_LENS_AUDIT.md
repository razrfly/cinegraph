# ISSUE: Festival / Inner Circle Lens — Full Audit

**Date:** 2026-03-25
**Scope:** `criteria_scoring.ex` (festival_recognition), `movie_scoring.ex` (festival_recognition)
**Status:** A+ complete 2026-03-25. DB-backed prestige tiers, full rename, regression + pipeline tests.

---

## 1. Identity & Naming

The festival lens has a **single unified name** across both subsystems:

| System | Criterion Name | Scale | Weight | File |
|---|---|---|---|---|
| Predictions engine | `festival_recognition` | 0–100 | **30% default** | `criteria_scoring.ex` |
| Discovery/show UI | `festival_recognition` | 0–10 | 20% fixed | `movie_scoring.ex` |

Unified 2026-03-25: `industry_recognition` → `festival_recognition` across all 38+ files.
DB column `festival_recognition_score` (was `industry_recognition_score`).

---

## 2. What's Inside the Lens

For each festival nomination a movie has received:

1. Look up the festival abbreviation in the prestige tier map
2. Assign base score: win score or nomination score
3. Apply +10.0 / +1.0 boost if category name contains "picture", "film", or "director"
4. **Sum all nomination scores** (not max — fixed 2026-03-24)
5. Cap at 100 (predictions) or 10 (UI)

### Prestige Tier Map

| Festival | Abbrev | Win (pred/UI) | Nom (pred/UI) | Seeded? | Data imported? |
|---|---|---|---|---|---|
| Academy Awards | AMPAS | 100 / 10.0 | 80 / 8.0 | ✅ | ✅ 2016–2024 fully imported |
| Cannes | CFF | 95 / 9.5 | 75 / 7.5 | ✅ | ⚠️ Partial (IMDb scraper) |
| Venice | VIFF | 90 / 9.0 | 70 / 7.0 | ✅ | ⚠️ Winners only, partial |
| Berlin | BIFF | 90 / 9.0 | 70 / 7.0 | ✅ | ⚠️ Partial |
| BAFTA | BAFTA | 85 / 8.5 | 65 / 6.5 | ❌ NOT SEEDED | ❌ No data |
| Golden Globes | HFPA | 80 / 8.0 | 60 / 6.0 | ✅ (golden_globes) | ⚠️ Partial |
| Sundance | SFF | 75 / 7.5 | 60 / 6.0 | ✅ | ⚠️ Partial |
| Critics Choice | CCA | 70 / 7.0 | 50 / 5.0 | ❌ NOT SEEDED | ❌ No data |
| Other | _ | 50 / 5.0 | 30 / 3.0 | — | — |

**Critical gap:** BAFTA (Tier 4) and Critics Choice (Tier 7) are in the scoring map
but have zero `festival_events` entries and zero nomination data. Films with BAFTA
wins score as "Other" (50/30 instead of 85/65) — systematically underselling
British and European cinema.

### Named Profiles (predictions engine)

| Profile | festival_recognition weight |
|---|---|
| default | 30% |
| festival-heavy | 50% |
| audience-first | 20% |
| critics-choice | 30% |
| auteur | 25% |

---

## 3. Algorithm Status

### Before (bug, fixed 2026-03-24)
`Enum.max(scores)` — single highest nomination score.
A film with 1 Oscar win = a film with 1 Oscar win + 20 Cannes nominations.
Massive signal compression; multi-nominated films indistinguishable.

### After (current)
`min(Enum.sum(scores), 100.0)` — sum all scores, cap at ceiling.
- Cannes Palme d'Or (95) + Berlin nom (70) = 165 → capped at 100 ✓
- 5 minor festival noms (5 × 30 = 150) → capped at 100 ✓ (prevents noise inflation)
- Multi-Oscar films now score higher than single-win films ✓

**Algorithm correctness: sound.** The cap prevents minor-festival spam from
equaling prestige circuit recognition.

---

## 4. How to Test & Verify

### 4a. Pure function test (no DB)

```elixir
iex -S mix
alias Cinegraph.Movies.MovieScoring

# Oscar Best Picture win — should cap at 10.0 (base 10 + boost 1 = 11 → capped)
MovieScoring.calculate_festival_recognition([["AMPAS", "Best Picture", true]])
# => 10.0

# Two Oscar nominations — sum 9.0 + 9.0 = 18.0 → cap 10.0
MovieScoring.calculate_festival_recognition([
  ["AMPAS", "Best Picture", false],
  ["AMPAS", "Best Director", false]
])
# => 10.0

# Cannes win (non-major) → 9.5, Berlin nom (major) → 8.0, sum 17.5 → cap 10.0
MovieScoring.calculate_festival_recognition([
  ["CFF", "Best Score", true],
  ["BIFF", "Best Director", false]
])
# => 10.0

# Single minor festival win — no boost
MovieScoring.calculate_festival_recognition([["XYZ", "Best Short", true]])
# => 5.0

# Empty list
MovieScoring.calculate_festival_recognition([])
# => 0.0
```

### 4b. SQL integrity check (verify join doesn't drop rows)

```elixir
movie = Cinegraph.Repo.get_by(Cinegraph.Movies.Movie, slug: "KNOWN-OSCAR-FILM")

{:ok, %{rows: rows}} = Cinegraph.Repo.query("""
  SELECT fo.abbreviation, fc.name, fnom.won
  FROM festival_nominations fnom
  JOIN festival_categories fc ON fnom.category_id = fc.id
  JOIN festival_ceremonies fcer ON fnom.ceremony_id = fcer.id
  JOIN festival_organizations fo ON fcer.organization_id = fo.id
  WHERE fnom.movie_id = $1
""", [movie.id])

{:ok, %{rows: [[count]]}} = Cinegraph.Repo.query(
  "SELECT COUNT(*) FROM festival_nominations WHERE movie_id = $1",
  [movie.id]
)

IO.puts("Joined: #{length(rows)}, Raw: #{count}")
# These must match. Divergence = orphaned nominations (broken FK chain).
```

### 4c. End-to-end score check on known films

```elixir
alias Cinegraph.Predictions.CriteriaScoring

# Multi-Oscar winner (e.g., Parasite, Everything Everywhere) → expect 80–100
movie = Cinegraph.Repo.get_by(Cinegraph.Movies.Movie, slug: "parasite")
IO.inspect CriteriaScoring.score_festival_recognition(movie)

# Single Sundance Grand Jury only → expect 60–76
# Film with no nominations → expect 0.0
```

### 4d. Distribution check (bulk health)

```elixir
results = Cinegraph.Predictions.HistoricalValidator.validate_decade("2010s")
scores = Enum.map(results.movies, & &1.criteria.festival_recognition)

IO.puts("Min: #{Enum.min(scores)}")
IO.puts("Max: #{Enum.max(scores)}")
IO.puts("Mean: #{Float.round(Enum.sum(scores) / length(scores), 1)}")
IO.puts("At 0.0: #{Enum.count(scores, &(&1 == 0.0))}")
IO.puts("At 100.0: #{Enum.count(scores, &(&1 == 100.0))}")
```

**Healthy distribution:** 70–80% at 0.0 (no nominations), small cluster at 30–60
(minor festivals), small cluster at 75–100 (prestige circuit). No unexplained spike
at a single value.

---

## 5. What Failure Looks Like

| Failure Mode | Observable Symptom | Root Cause |
|---|---|---|
| Enum.max regression | Many films tied at identical score | Bug reintroduced |
| Orphaned nominations | Joined count < raw count | Broken FK chain (ceremony → org) |
| BAFTA/CCA scored as "Other" | British/award-circuit films underscored | Not seeded in festival_events |
| All films score 0 | festival_recognition = 0 universally | SQL returning empty; schema issue |
| Batch ≠ individual | Consistency test fails | Divergence between two code paths |
| Cap too low | Too many films at 100.0 | Prestige film pileup at ceiling |

---

## 6. How to Measure Quality

### Coverage metric

```sql
SELECT
  COUNT(DISTINCT m.id) FILTER (WHERE fn.id IS NOT NULL) as has_nominations,
  COUNT(DISTINCT m.id) as total,
  ROUND(100.0 * COUNT(DISTINCT m.id) FILTER (WHERE fn.id IS NOT NULL)
        / COUNT(DISTINCT m.id), 1) as coverage_pct
FROM movies m
JOIN movie_list_entries mle ON mle.movie_id = m.id
JOIN movie_lists ml ON ml.id = mle.movie_list_id AND ml.slug = '1001-movies'
LEFT JOIN festival_nominations fn ON fn.movie_id = m.id;
```

### Organization distribution

```sql
SELECT fo.abbreviation, fo.name,
       COUNT(*) as nominations,
       COUNT(*) FILTER (WHERE fn.won) as wins
FROM festival_nominations fn
JOIN festival_ceremonies fcer ON fn.ceremony_id = fcer.id
JOIN festival_organizations fo ON fcer.organization_id = fo.id
GROUP BY fo.abbreviation, fo.name
ORDER BY nominations DESC;
```

### Backtesting accuracy

```elixir
# If festival-heavy profile (50% weight) performs worse than default (30%),
# festival data coverage is too sparse to upweight.
Cinegraph.Predictions.HistoricalValidator.compare_profiles()
```

---

## 7. Festivals Represented

### Seeded in `festival_events` (8 total)

| Name | Abbrev | Tier | Data Status |
|---|---|---|---|
| Academy Awards | AMPAS | 1 | ✅ Fully imported 2016–2024 |
| Golden Globe Awards | HFPA | 2 | ⚠️ Partial |
| Cannes Film Festival | CFF | 2 | ⚠️ Partial (IMDb) |
| Venice Int'l Film Festival | VIFF | 3 | ⚠️ Winners only |
| Berlin Int'l Film Festival | BIFF | 3 | ⚠️ Partial |
| Sundance Film Festival | SFF | 4 | ⚠️ Partial |
| SXSW Film Festival | SXSW | "Other" | ⚠️ Partial |
| New Horizons | NHIFF | "Other" | ⚠️ Partial |

### In scoring code but NOT seeded (dead tiers)

| Name | Abbrev | Tier | Impact |
|---|---|---|---|
| BAFTA Film Awards | BAFTA | 4 (85/65) | British cinema systematically undersold |
| Critics Choice Awards | CCA | 7 (70/50) | US critics circuit invisible |

---

## 8. Data Missing

### Critical (directly affects scoring accuracy)
- **BAFTA** — Not seeded. Any BAFTA win scores as "Other" (50 instead of 85).
  Add to `festival_events` seeds + import. ~1 day of work.
- **Oscar back-catalog (pre-2016)** — The 1001-list spans 1902–2024.
  Current import only covers 2016–2024. Films from the 1960s–2000s have
  zero Oscar nomination data and will silently score 0.0.
- **Cannes/Berlin/Venice nomination completeness** — Unclear how many
  nomination rows actually exist. Run the distribution SQL above to verify.

### Important
- **Golden Globes back-catalog** — Same gap as Oscars for pre-2016 films.
- **Critics Choice Awards** — Not seeded, not imported. Lower priority than BAFTA.

### Acceptable gaps
- SXSW/NHIFF missing data — "Other" tier, negligible scoring impact.
- Pre-1970 festival data — Mostly doesn't exist digitally at scale.
- RT Audience Score — Dead code in `score_mob`, unrelated to festival lens.

---

## 9. Grade

| Dimension | Grade | Notes |
|---|---|---|
| Algorithm correctness | **A** | Enum.max fixed; sum+cap sound; regression test guards it |
| Prestige tier design | **A+** | DB-backed via `festival_organizations.win_score/nom_score`; no dual-maintenance |
| Data coverage | **B+** | Backfill tooling in place; full import pending |
| Test coverage | **A** | 25 pure-function tests: tier lookup, DB fallback, regression, pipeline |
| Architecture | **A+** | DB tiers, dead `rt_audience` removed, clean pipeline |
| Naming consistency | **A** | Single name `festival_recognition` across all 38+ files |

**Overall: A+**

Algorithm, architecture, naming, and tests are all complete. The remaining gap is
data coverage: Oscar back-catalog (pre-2016), BAFTA, and CCA imports are the last
milestone before calling this lens production-ready. Run `mix festivals.backfill`
and verify coverage SQL ≥ 40% on the 1001-list.

---

## 10. Can We Move On?

**Yes, conditionally.** Algorithm is correct. Architecture supports the full vision.
Blockers are data, not code.

### Before calling this lens "production-ready"
1. **Import BAFTA** — Add to seeds, run import. ~1 day. High impact.
2. **Import Oscar back-catalog (pre-2016)** — 1001-list skews heavily pre-2016.
   Without this, most of the list scores 0 on this lens.
3. **Verify Cannes/Berlin/Venice row counts** — Run the SQL integrity check.
   Confirm nominations are being imported, not just ceremonies.

### Nice-to-have
4. Add prestige tier unit tests: assert AMPAS win = 100, CFF nom = 75, etc.
5. Add Critics Choice to seeds.

### Not blocking
- CCA import (lower prestige signal)
- SXSW/NHIFF data (Other tier)
- Pre-1970 data (doesn't exist digitally)

---

## Action Items

| # | Item | Priority | Effort |
|---|---|---|---|
| 1 | Add BAFTA to `festival_events` seeds + import | HIGH | ~1 day |
| 2 | Import Oscar back-catalog (pre-2016) | HIGH | ~half day |
| 3 | Run SQL integrity check: joined = raw count | HIGH | 10 min |
| 4 | Add prestige tier unit tests | MEDIUM | 1 hour |
| 5 | Verify Cannes/Berlin/Venice nomination counts in DB | MEDIUM | 15 min |
| 6 | Add Critics Choice Awards to seeds | LOW | 30 min |

---

## 11. A+ Completion Checklist — 2026-03-25

All code-level items completed. Remaining items are data verification only.

### Completed ✅

- [x] Regression test: sum > max for multi-nomination film (`festival_prestige_test.exs:91`)
- [x] Pipeline tests: zero noms = 0.0, multi-Oscar > single-Sundance (`movie_scoring_test.exs`)
- [x] DB prestige tiers: `win_score`, `nom_score`, `prestige_tier` on `festival_organizations`
- [x] Migration: `add_prestige_scores_to_festival_organizations` (20260325000000)
- [x] Migration: `rename_industry_recognition_score` (20260325000001)
- [x] Seeds: prestige scores set for all 8 tiers via `Ecto.Changeset.change`
- [x] `FestivalPrestige.score_nomination/5` with DB fallback to `@tiers`
- [x] Festival SQL extended to `SELECT fo.win_score, fo.nom_score` in both code paths
- [x] Remove dead `rt_audience` from `calculate_mob_score` and `calculate_score_confidence`
- [x] Rename `industry_recognition` → `festival_recognition` in 38+ files
- [x] `calculation_version` bumped: `"3"` → `"4"`
- [x] 25 pure-function tests passing, 0 failures

### Data verification (pending import runs)

- [ ] Run `mix import_oscars --years 1970-2015`, verify Oban queue clears without mass failures
- [ ] Run `mix festivals.backfill --years 2000-2024`, verify BAFTA + CCA appear in org distribution SQL
- [ ] 1001-list coverage SQL shows ≥ 40% of films have at least one nomination
