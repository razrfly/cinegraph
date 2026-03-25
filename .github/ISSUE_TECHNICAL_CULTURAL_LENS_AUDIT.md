# ISSUE: Technical Innovation + Cultural Impact Lens — Full Audit

**Date:** 2026-03-25
**Scope:** `criteria_scoring.ex` (`score_technical_innovation`, `score_cultural_impact`),
`movie_scoring.ex` (`calculate_cultural_impact`)
**Status:** Open — double-counting confirmed; formula misalignment documented; no code changes yet.

---

## 1. Identity & Naming

Two lenses, two different problems:

| Lens | System | Criterion | Scale | Weight | File |
|---|---|---|---|---|---|
| Technical Innovation | Predictions | `technical_innovation` | 0–100 | **10% default** | `criteria_scoring.ex:316` |
| Cultural Impact | Predictions | `cultural_impact` | 0–100 | **20% default** | `criteria_scoring.ex:263` |
| Cultural Impact | Display | `cultural_impact` | 0–10 | ~30% (editorial) | `movie_scoring.ex:234` |

Technical Innovation exists only in the predictions engine — there is no display counterpart.
Cultural Impact exists in both systems but with **completely different formulas**.

---

## 2. What's Inside Each Lens

### Technical Innovation — predictions only (criteria_scoring.ex:316–349)

Queries `festival_nominations` filtered to category names matching:
`%cinematography%`, `%sound%`, `%editing%`, `%visual%`, `%technical%`

Scoring:
- Win in a technical category: **+20 points**
- Nomination in a technical category: **+10 points**
- Cap at 100

Batch path (`score_technical_innovation_from_batch`, line 797–811): identical logic.

### Cultural Impact — predictions (criteria_scoring.ex:263–309)

Four sub-scores summed (0–100 total):

| Sub-score | Max pts | Logic |
|---|---|---|
| ROI (box office) | 40 | revenue/budget ratio: 10x→40, 5x→30, 2x→20, 1x→10, <1→0 |
| Critical mass | 30 | IMDb rating + vote count: ≥7.5/100k→30, ≥7.0/50k→20, ≥6.5/25k→10 |
| Genre diversity | 15 | `length(genres) / 4.0 * 15.0` — 4+ genres = 15 pts |
| International bonus | 15 | Non-English: 8 base + min(nom_count × 1.5, 7) additional |

### Cultural Impact — display (movie_scoring.ex:234–256)

Two sub-scores on a 0–10 scale:

| Sub-score | Formula |
|---|---|
| Canonical presence | `map_size(canonical_sources) × 2.0` |
| Popularity (log-scaled) | `log(popularity + 1) / log(1000) × 5.0` |

Combined: `min(10.0, canonical_count × 2.0 + popularity_score × 5.0)`

---

## 3. Algorithm Status

### Problem 1 — Technical Innovation double-counts festival nominations (confirmed)

The `festival_recognition` criterion already scores ALL nominations against ALL prestige
festival organizations. Technical Innovation queries the **same `festival_nominations` table**
and awards points for the subset of those nominations that match technical category names.

Concrete example — *Mad Max: Fury Road* (6 Oscar wins including cinematography, editing, VFX):
- `festival_recognition`: scores all 10 nominations → contributes to the 30% festival weight
- `technical_innovation`: scores the 6 technical wins again → contributes to the 10% tech weight

The same Oscar nomination row is counted twice. This is signal leakage between two separate
lens buckets that are supposed to be independent signals.

The 10% weight for Technical Innovation is not measuring something independent — it is
a partial shadow of the festival_recognition lens.

### Problem 2 — Technical Innovation returns 0 for most films

The category name matching depends on what strings are stored in `festival_categories.name`.
Current data in seeds (`priv/repo/seeds/metric_definitions.exs`) shows only one technical
festival category: `adobe_editing_award`. None of the common Oscar technical category names
("Best Cinematography", "Best Film Editing", "Best Visual Effects", "Best Sound Mixing")
appear to be stored with the lowercase keywords the LIKE query targets.

Result: the vast majority of films score 0 on a lens that holds **10% weight**. The 10%
weight is effectively dead for all but a tiny subset of films with unusually-named categories.

### Problem 3 — Cultural Impact formula divergence

The predictions Cultural Impact (ROI + critical mass + genre + international) and the display
Cultural Impact (canonical list count + popularity) measure different things and use different
signals:

| Signal | Predictions | Display |
|---|---|---|
| `canonical_sources` (list count) | ❌ Not used | ✅ Primary signal |
| Box office ROI | ✅ 40 pts | ❌ Not used |
| IMDb vote count ("critical mass") | ✅ 30 pts | ❌ Not used |
| Genre count (diversity bonus) | ✅ 15 pts | ❌ Not used |
| Non-English language bonus | ✅ 15 pts | ❌ Not used |
| TMDb popularity score | ❌ Not used | ✅ Secondary signal |

The display system uses `canonical_sources` as its primary signal — this is the number of
canonical "best of" lists (1001 Movies, Sight & Sound, TSPDT, AFI, etc.) that include the film.
This is arguably the single clearest proxy for cultural staying power. The predictions system
ignores it entirely.

### Problem 4 — Genre diversity is noise

`score_genre_cultural_impact` awards points for the raw count of TMDb genres attached to a
film. Films tagged with 4+ genres receive 15 points regardless of quality or actual cultural
reach. A mediocre action/comedy/thriller/drama gets the same genre bonus as *Pulp Fiction*.
Genre count is not a valid proxy for cultural impact.

### Problem 5 — International bonus double-counts festival nominations

`score_international_impact` adds 8 base points for non-English language, then adds up to 7
more points based on `nom_count` — the total number of festival nominations.

But festival nominations are already scored by `festival_recognition` (30% weight).
An international film with 10 nominations gets:
- 30%: full `festival_recognition` score based on those nominations
- 20%: `cultural_impact` gets an additional 15 points from the international bonus because of those same nominations

This is a second double-counting issue (separate from the Technical Innovation overlap).

---

## 4. How to Test & Verify

### 4a. Confirm Technical Innovation double-counting

```elixir
iex -S mix
alias Cinegraph.Predictions.CriteriaScoring

# Find a film with known technical Oscar wins (e.g., Mad Max: Fury Road)
movie = Cinegraph.Repo.get_by(Cinegraph.Movies.Movie, slug: "mad-max-fury-road")

fr_score = CriteriaScoring.score_festival_recognition(movie)
ti_score = CriteriaScoring.score_technical_innovation(movie)

IO.puts("Festival Recognition: #{fr_score}")
IO.puts("Technical Innovation: #{ti_score}")
# If TI > 0, the nominations contributing to TI also contributed to FR
```

### 4b. Confirm Technical Innovation returns 0 for most films

```elixir
# Check what technical category names actually exist in the DB
{:ok, %{rows: rows}} = Cinegraph.Repo.query("""
  SELECT DISTINCT LOWER(fc.name) as category_name
  FROM festival_categories fc
  JOIN festival_nominations fnom ON fnom.category_id = fc.id
  WHERE LOWER(fc.name) LIKE ANY(ARRAY['%cinematography%', '%sound%', '%editing%', '%visual%', '%technical%'])
  ORDER BY category_name
""")
IO.inspect rows, label: "Matching technical categories"
# Expect: very few or zero rows with current data
```

### 4c. Confirm Cultural Impact formula divergence

```elixir
# Find a highly canonical film (many list entries)
movie = Cinegraph.Repo.get_by(Cinegraph.Movies.Movie, slug: "citizen-kane")

# Display system cultural impact
scores = Cinegraph.Movies.MovieScoring.calculate_movie_scores(movie)
IO.puts("Display cultural_impact: #{scores.components.cultural_impact}")

# Predictions cultural impact
pred = CriteriaScoring.score_cultural_impact(movie)
IO.puts("Predictions cultural_impact: #{pred}")

# Also check canonical_sources count
IO.inspect map_size(movie.canonical_sources || %{}), label: "canonical_sources count"
# Expected: display score reflects canonical count; predictions ignores it
```

### 4d. Distribution check

```elixir
results = Cinegraph.Predictions.HistoricalValidator.validate_decade("2010s")

ti_scores = Enum.map(results.movies, & &1.criteria.technical_innovation)
ci_scores = Enum.map(results.movies, & &1.criteria.cultural_impact)

IO.puts("--- Technical Innovation ---")
IO.puts("At 0.0: #{Enum.count(ti_scores, &(&1 == 0.0))}")
IO.puts("Non-zero: #{Enum.count(ti_scores, &(&1 > 0.0))}")
IO.puts("Mean (non-zero): #{Float.round(Enum.sum(Enum.filter(ti_scores, &(&1 > 0))) / max(Enum.count(ti_scores, &(&1 > 0)), 1), 1)}")

IO.puts("--- Cultural Impact ---")
IO.puts("Min: #{Enum.min(ci_scores)}")
IO.puts("Max: #{Enum.max(ci_scores)}")
IO.puts("Mean: #{Float.round(Enum.sum(ci_scores) / length(ci_scores), 1)}")
IO.puts("At 0.0: #{Enum.count(ci_scores, &(&1 == 0.0))}")
```

**Unhealthy signal:** If 90%+ of `technical_innovation` scores are 0.0, the 10% weight
is dead weight distorting all other criterion contributions.

---

## 5. What Failure Looks Like

| Failure Mode | Observable Symptom | Root Cause |
|---|---|---|
| Technical double-count | Films with technical Oscars score higher than their cultural/artistic merit warrants | Same nomination counted in both FR and TI |
| Dead TI weight | 95%+ of films score 0 on TI; weight effectively redistributes to other criteria | No matching category names in DB |
| Cultural Impact mismatch | Predictions and display rank the same films very differently on cultural impact | Formula divergence — canonical_sources missing from predictions |
| Genre noise | Mid-tier genre films outscore niche masterpieces on cultural impact | Genre count ≠ cultural resonance |
| International double-count | Non-English prestige films overscore compared to English-language peers with identical festival records | Nominations counted in both FR and international bonus |

---

## 6. How to Measure Quality

### Technical Innovation: coverage check

```sql
-- How many nominations match technical category keywords?
SELECT
  COUNT(*) as matching_nominations,
  COUNT(DISTINCT fnom.movie_id) as movies_with_tech_nominations
FROM festival_nominations fnom
JOIN festival_categories fc ON fnom.category_id = fc.id
WHERE LOWER(fc.name) LIKE ANY(
  ARRAY['%cinematography%', '%sound%', '%editing%', '%visual%', '%technical%']
);
```

If `matching_nominations` is 0 or near-0: Technical Innovation is non-functional.

### Cultural Impact: canonical_sources correlation

```sql
-- Do high canonical_sources films score high on predictions cultural_impact?
-- If not, the predictions formula is missing the primary signal.
SELECT
  m.title,
  jsonb_array_length(
    COALESCE(
      (SELECT jsonb_agg(k) FROM jsonb_object_keys(m.canonical_sources) k),
      '[]'
    )
  ) as canonical_count
FROM movies m
WHERE m.canonical_sources IS NOT NULL
  AND m.canonical_sources != '{}'
ORDER BY canonical_count DESC
LIMIT 20;
```

Then run `CriteriaScoring.score_cultural_impact(movie)` on the top films and verify the
predictions score correlates with canonical_count. It currently will not.

---

## 7. What These Lenses Are For

**Technical Innovation** was designed to reward films that pushed cinematic craft forward —
the kind of work that defines a decade's visual language. This is a legitimate signal for
the 1001 Movies list, which does include craft-forward films (2001: A Space Odyssey,
Apocalypse Now, Blade Runner, etc.). The concept is sound; the implementation fails because:
(a) it draws from the same data as festival_recognition, and (b) the category data isn't there.

**Cultural Impact** was designed to reward films that entered the cultural conversation beyond
critics and festivals. The display system correctly identifies `canonical_sources` (how many
"must-see" lists include the film) as the clearest signal for this. The predictions system
ignores that signal entirely and substitutes box office ROI + genre count, which is a poor proxy.

---

## 8. Data Missing

### Critical
- **Technical category names in `festival_categories`** — If the LIKE patterns don't match
  any stored category names, Technical Innovation is dead. Verify with the SQL in §4b.
  The Oscar technical categories ("Best Cinematography", "Best Visual Effects", etc.) need
  to be imported with names that match the LIKE patterns, or the patterns need updating.

### Important
- **`canonical_sources` coverage** — The display Cultural Impact depends on `canonical_sources`
  being populated for most films. If it is sparse, the display score will cluster at 0.
  The predictions engine could use the same field once aligned.

### Acceptable gaps
- Box office budget/revenue data missing for many films — already returns 0 for those.
- Pre-1970 technical data nonexistent — expected.

---

## 9. Grade

### Technical Innovation

| Dimension | Grade | Notes |
|---|---|---|
| Concept | **B** | Craft-forward films are a real 1001-list signal |
| Implementation | **F** | Double-counts festival_recognition; returns 0 for ~95% of films |
| Data support | **F** | Category name matching finds no data with current imports |
| Test coverage | **F** | No unit tests |
| Weight justification | **D** | 10% weight allocated to a lens that is effectively 0 for most films |

**Technical Innovation overall: F**

### Cultural Impact (predictions)

| Dimension | Grade | Notes |
|---|---|---|
| Concept | **B** | Cultural resonance is a valid 1001-list predictor |
| Implementation | **D** | Ignores canonical_sources; genre diversity and international bonus add noise |
| Alignment with display | **D** | Completely different formulas; will produce conflicting signals in calibration UI |
| Test coverage | **D** | No unit tests for sub-scores |

**Cultural Impact (predictions) overall: D**

### Cultural Impact (display)

| Dimension | Grade | Notes |
|---|---|---|
| Concept | **A** | Canonical list count is the right primary signal for cultural staying power |
| Implementation | **B+** | Clean, minimal, directionally correct |
| Test coverage | **C** | Limited test coverage |

**Cultural Impact (display) overall: B+**

---

## 10. Can We Move On?

**No.** Technical Innovation is non-functional and double-counts festival_recognition.
Allocating 10% weight to a broken lens distorts all backtesting and calibration results.

### Decision required before any code changes

**Option A — Retire Technical Innovation**
- Remove `technical_innovation` from the predictions criteria
- Redistribute its 10% weight (e.g., +5% festival_recognition, +5% cultural_impact)
- Update all weight profiles, tests, calibration UI

**Option B — Restructure Technical Innovation (non-festival source)**
- Replace festival category matching with a different data source that does not overlap
  with `festival_nominations` (e.g., IMDb technical awards data, OMDb awards field parsing)
- Requires new data pipeline before the lens can be functional

**Option C — Merge into Cultural Impact**
- Absorb craft recognition into the Cultural Impact signal
- Treat technical category wins as one sub-component of cultural significance

**Recommendation:** Option A (retire) is the safest path with the current data.
Option B is the correct long-term answer but requires new data work first.

### Cultural Impact alignment (regardless of TI decision)

4. **Add `canonical_sources` count to predictions Cultural Impact** — this is the key
   alignment fix. It is what the display formula already uses as its primary signal.
5. **Remove genre diversity sub-score** — 4 genre tags ≠ cultural impact.
6. **Remove international nomination double-count** — fold non-English bonus to a flat
   base bonus only (e.g., 5 points) with no nomination multiplier.

---

## 11. Action Items

| # | Item | Priority | Effort |
|---|---|---|---|
| 1 | Decide: retire Technical Innovation or restructure it (see §10 options) | **CRITICAL** | Discussion |
| 2 | Verify technical category name matching returns any rows (SQL §4b) | **HIGH** | 10 min |
| 3 | Add `canonical_sources` count to predictions `score_cultural_impact` | **HIGH** | 1 hour |
| 4 | Remove genre diversity sub-score from Cultural Impact predictions | **HIGH** | 30 min |
| 5 | Replace international nomination multiplier with flat non-English base bonus | **HIGH** | 30 min |
| 6 | Update weight profiles if Technical Innovation is retired | HIGH | 1 hour |
| 7 | Add unit tests for Cultural Impact sub-scores | MEDIUM | 1 hour |
| 8 | Run distribution check (§4d) after fixes to verify score shift | MEDIUM | 15 min |
| 9 | Document the predictions vs. display formula split in module docs | LOW | 15 min |
