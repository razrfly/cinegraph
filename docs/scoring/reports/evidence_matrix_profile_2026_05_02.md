# CineGraph Evidence Matrix Profile - 2026-05-02

This report profiles the Phase 1 research evidence matrix built from the restored
production snapshot documented in `production_snapshot_2026_05_02.md`.

This is not a scoring-model recommendation. It verifies that the matrix can support
Phase 2 validation-set design and later model bake-offs.

## Artifact Summary

| Artifact | Value |
|---|---:|
| SQL definition | `priv/repo/scoring_evidence_matrix.sql` |
| Local relation | `scoring_evidence_matrix` materialized view |
| Rows | 1,144,666 |
| Distinct `movie_id` values | 1,144,666 |
| Columns | 94 |
| Materialized view size | 888 MB total / 841 MB data |
| Indexes | `movie_id`, `release_decade`, `tmdb_popularity_bucket`, `evidence_regime` |
| Creation time | approximately 5m 23s on local Mac Studio |

The matrix intentionally has one row per movie, including movies without cached scores.
This is different from `movie_score_caches`, which currently covers 902,490 movies.

## Row Parity

| Source | Rows |
|---|---:|
| `movies` | 1,144,666 |
| `movie_score_caches` | 902,490 |
| `scoring_evidence_matrix` | 1,144,666 |
| distinct matrix `movie_id` | 1,144,666 |

Result: row parity with `movies` is correct, and `movie_id` is unique.

## Major Source Coverage

| Field | Non-null / Present Count | Percent of Movies |
|---|---:|---:|
| IMDb rating | 331,691 | 28.98% |
| IMDb votes | 386,372 | 33.75% |
| TMDb rating | 370,829 | 32.40% |
| TMDb votes | 843,827 | 73.72% |
| Rotten Tomatoes Tomatometer | 37,365 | 3.26% |
| Metacritic | 20,540 | 1.79% |
| TMDb popularity | 1,144,666 | 100.00% |
| Budget | 75,741 | 6.62% |
| Worldwide revenue | 25,872 | 2.26% |

Observation: audience-ish data is broad but uneven. Critic and financial data are sparse
relative to the full catalog.

## Canonical Source Distribution

| Canonical key | Movies |
|---|---:|
| `criterion` | 1,768 |
| `1001_movies` | 1,256 |
| `national_film_registry` | 900 |
| `sight_sound_critics_2022` | 99 |

The restored production schema does not contain `movie_list_entries`; Phase 1 confirms
that `movies.canonical_sources` is the usable canonical-list source for this research track.

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

| Present lenses | Movies | Percent | Avg legacy score | Avg evidence confidence |
|---:|---:|---:|---:|---:|
| 0 | 244,866 | 21.39% | 0.00 | 0.006 |
| 1 | 349,003 | 30.49% | 0.23 | 0.188 |
| 2 | 247,965 | 21.66% | 0.61 | 0.241 |
| 3 | 254,276 | 22.21% | 0.96 | 0.297 |
| 4 | 31,670 | 2.77% | 2.37 | 0.481 |
| 5 | 13,575 | 1.19% | 3.64 | 0.668 |
| 6 | 3,311 | 0.29% | 5.78 | 0.865 |

The matrix makes the core issue sharper than Phase 0: once all movies are included,
51.88% of the full catalog has zero or one present scoring lens.

## Evidence Regime Distribution

| Evidence regime | Movies | Percent | Avg legacy score | Avg evidence confidence |
|---|---:|---:|---:|---:|
| no_evidence | 244,866 | 21.39% | 0.00 | 0.006 |
| low_evidence | 349,003 | 30.49% | 0.23 | 0.188 |
| medium_evidence | 502,241 | 43.88% | 0.79 | 0.269 |
| high_evidence | 48,556 | 4.24% | 2.96 | 0.559 |

These evidence regimes are descriptive only. They are not final `rated` / `limited` /
`unscoreable` thresholds.

## Cohort Profiles

### Release Era

| Release era | Movies | Scored | Avg legacy score | Avg evidence confidence |
|---|---:|---:|---:|---:|
| pre-1950 | 76,222 | 57,145 | 0.84 | 0.204 |
| 1950s | 27,059 | 22,446 | 0.94 | 0.240 |
| 1960s | 41,657 | 33,694 | 0.82 | 0.226 |
| 1970s | 55,007 | 44,448 | 0.73 | 0.223 |
| 1980s | 63,338 | 51,829 | 0.74 | 0.228 |
| 1990s | 73,283 | 58,546 | 0.80 | 0.220 |
| 2000s | 127,418 | 102,478 | 0.88 | 0.213 |
| 2010s | 262,237 | 222,386 | 0.75 | 0.218 |
| 2020s | 286,617 | 249,579 | 0.50 | 0.208 |
| unknown | 131,828 | 59,939 | 0.39 | 0.087 |

### TMDb Popularity

| Popularity bucket | Movies | Scored | Avg legacy score | Avg evidence confidence | Avg present lenses |
|---|---:|---:|---:|---:|---:|
| 100+ | 36 | 36 | 2.50 | 0.511 | 4.03 |
| 50-100 | 50 | 50 | 2.80 | 0.511 | 4.16 |
| 10-50 | 1,274 | 1,274 | 3.10 | 0.550 | 4.24 |
| 1-10 | 255,192 | 255,191 | 1.07 | 0.304 | 2.62 |
| <1_or_unknown | 888,114 | 645,939 | 0.53 | 0.170 | 1.29 |

### Language

| Language bucket | Movies | Scored | Avg legacy score | Avg evidence confidence |
|---|---:|---:|---:|---:|
| non_english | 589,703 | 487,817 | 0.61 | 0.203 |
| english | 554,963 | 414,673 | 0.78 | 0.198 |

### Runtime

| Runtime bucket | Movies | Scored | Avg legacy score | Avg evidence confidence |
|---|---:|---:|---:|---:|
| short | 389,748 | 287,074 | 0.44 | 0.172 |
| feature | 485,454 | 437,503 | 0.92 | 0.262 |
| long_feature | 5,769 | 5,162 | 0.94 | 0.227 |
| unknown | 263,695 | 172,751 | 0.49 | 0.129 |

### Country

| Country bucket | Movies | Scored | Avg legacy score | Avg evidence confidence |
|---|---:|---:|---:|---:|
| single_country_non_us | 660,382 | 547,397 | 0.58 | 0.202 |
| us | 443,316 | 318,864 | 0.83 | 0.193 |
| multi_country_non_us | 37,930 | 34,469 | 0.94 | 0.279 |
| unknown | 3,038 | 1,760 | 0.58 | 0.109 |

### Budget

| Budget bucket | Movies | Scored | Avg legacy score | Avg evidence confidence |
|---|---:|---:|---:|---:|
| <1m | 59,173 | 51,304 | 0.58 | 0.352 |
| 1m-10m | 9,465 | 9,277 | 2.29 | 0.552 |
| 10m-50m | 5,375 | 5,329 | 3.25 | 0.659 |
| 50m-100m | 1,081 | 1,077 | 3.71 | 0.698 |
| 100m+ | 647 | 635 | 4.23 | 0.716 |
| unknown | 1,068,925 | 834,868 | 0.65 | 0.186 |

### Canonical / Festival Status

| Canonical data | Festival data | Movies | Scored | Avg legacy score | Avg evidence confidence |
|---|---|---:|---:|---:|---:|
| yes | yes | 1,536 | 1,536 | 6.37 | 0.871 |
| yes | no | 1,539 | 1,532 | 3.17 | 0.574 |
| no | yes | 18,340 | 17,736 | 3.18 | 0.543 |
| no | no | 1,123,251 | 881,686 | 0.62 | 0.194 |

## Validation Helpers

The matrix includes leakage-safe helper flags:

| Field | Count / Status |
|---|---:|
| `validation_target_canonical_any = true` | 3,075 |
| `validation_target_award_any = true` | 19,876 |
| `feature_mask_full` | true for all rows |
| `feature_mask_without_canonical` | true for all rows |
| `feature_mask_without_festival` | true for all rows |
| `feature_mask_without_critics` | true for all rows |
| `feature_mask_without_audience` | true for all rows |

The feature-mask booleans mean the row contains enough raw fields for those feature-exclusion
variants. The actual exclusion logic should live in Phase 3 model/evaluator code.

## Sample Row Inspection

The following known movies were inspected from the matrix:

| Movie | Year | Score | Lenses | Evidence | Canonical keys | Fest noms / wins | Notes |
|---|---:|---:|---:|---:|---|---:|---|
| The Godfather | 1972 | 9.2 | 6 | 1.000 | `1001_movies`, `national_film_registry`, `sight_sound_critics_2022` | 18 / 8 | high-evidence canonical classic |
| Parasite | 2019 | 9.2 | 6 | 1.000 | `1001_movies`, `criterion`, `sight_sound_critics_2022` | 23 / 11 | high-evidence international modern film |
| Moonlight | 2016 | 8.0 | 6 | 1.000 | `1001_movies`, `sight_sound_critics_2022` | 22 / 7 | high-evidence indie/awards film |
| Spirited Away | 2001 | 7.1 | 5 | 0.800 | `1001_movies`, `sight_sound_critics_2022` | 5 / 4 | high-evidence non-English animation |
| The Seventh Seal | 1957 | 6.5 | 5 | 0.800 | `1001_movies`, `criterion` | 2 / 1 | classic international film |
| Psycho | 1960 | 8.1 | 6 | 1.000 | `1001_movies`, `national_film_registry`, `sight_sound_critics_2022` | 4 / 1 | classic with full signal |
| 2001: A Space Odyssey | 1968 | 8.0 | 6 | 1.000 | `1001_movies`, `national_film_registry`, `sight_sound_critics_2022` | 7 / 3 | classic sci-fi |
| Your Name. | 2016 | 4.2 | 5 | 0.700 | none | 0 / 0 | useful non-canonical high-audience comparison |
| In the Mood for Love | 2000 | 8.3 | 6 | 1.000 | `1001_movies`, `criterion`, `sight_sound_critics_2022` | 7 / 4 | high-evidence international classic |
| La Dolce Vita | 1960 | 8.5 | 6 | 1.000 | `1001_movies`, `criterion`, `sight_sound_critics_2022` | 3 / 1 | high-evidence classic |
| Persona | 1966 | 5.7 | 4 | 0.700 | `1001_movies`, `criterion`, `sight_sound_critics_2022` | 0 / 0 | canonical but no festival signal |
| The Blair Witch Project | 1999 | 6.6 | 6 | 1.000 | `1001_movies` | 4 / 1 | small film with broad signal |
| Clerks | 1994 | 7.3 | 6 | 1.000 | `1001_movies`, `national_film_registry` | 4 / 2 | low-budget canonical example |
| Following | 1999 | 4.1 | 5 | 0.850 | `criterion` | 0 / 0 | low-budget auteur signal case |
| Tangerine | 2015 | 5.2 | 5 | 0.800 | `1001_movies` | 1 / 0 | low-budget independent case |
| Hoop Dreams | 1994 | 8.1 | 6 | 1.000 | `1001_movies`, `criterion`, `national_film_registry` | 2 / 2 | documentary with strong signal |
| Sherman's March | 1985 | 5.2 | 4 | 0.925 | `1001_movies`, `national_film_registry` | 1 / 0 | documentary with sparse critic values |
| Avatar | 2009 | 7.3 | 6 | 1.000 | `1001_movies` | 21 / 10 | blockbuster baseline |
| Avengers: Endgame | 2019 | 7.6 | 6 | 1.000 | `1001_movies` | 6 / 3 | blockbuster/franchise baseline |
| Oppenheimer | 2023 | 7.8 | 6 | 1.000 | `1001_movies` | 53 / 32 | modern high-evidence awards case |
| Barbie | 2023 | 7.5 | 6 | 1.000 | `1001_movies` | 37 / 7 | modern blockbuster/awards case |
| Nomadland | 2021 | 7.2 | 6 | 1.000 | `1001_movies` | 28 / 17 | festival/awards-heavy modern film |
| Drive My Car | 2021 | 7.8 | 6 | 1.000 | `1001_movies`, `criterion` | 13 / 7 | international awards case |
| The Act of Killing | 2012 | 5.8 | 5 | 0.800 | `1001_movies` | 7 / 2 | documentary/international case |

The sample rows are plausible enough for Phase 2 validation-set design. They also show why
leakage-safe validation is necessary: many validation targets are already visible in the current
scoring inputs.

## Findings

1. The matrix is feasible as a local materialized view.
   It builds on the restored production database and gives one row per movie.

2. A plain view is unlikely to be comfortable for repeated research queries.
   The materialized view is 888 MB and took several minutes to build, but profiling queries
   against it are fast once indexed.

3. The catalog is dominated by low-evidence movies.
   51.88% of all movies have zero or one present scoring lens.

4. Current scores are strongly tied to evidence availability.
   High-evidence rows average 2.96, while no-evidence rows average 0.00.

5. The matrix is already useful for leakage-safe validation design.
   It separates canonical, festival, critic, audience, financial, and people-quality signals.

6. `movies.canonical_sources` is the practical canonical-list source for the next phase.
   The known canonical keys are `criterion`, `1001_movies`, `national_film_registry`, and
   `sight_sound_critics_2022`.

## Recommendation

Keep `scoring_evidence_matrix` as a **local research materialized view** for Phase 2 and Phase 3.

Do not promote it to product schema yet.

Reasons:

- The matrix is wide and research-oriented.
- Some fields are exploratory, especially `evidence_confidence_baseline` and feature-mask helpers.
- Phase 2 still needs validation-set design.
- Phase 3 still needs model bake-offs before we know which fields deserve permanent cache support.

Likely future path:

1. Use this materialized view for validation-set design.
2. Use it as the source for model bake-off scripts.
3. After model selection, promote only the selected product fields into `movie_score_caches` or a dedicated production scoring cache.

## Reproducibility

Apply/rebuild the matrix locally:

```bash
psql -h localhost -U postgres -d cinegraph_dev -v ON_ERROR_STOP=1 -f priv/repo/scoring_evidence_matrix.sql
```

Validate row parity:

```sql
select
  (select count(*) from movies) as movies,
  (select count(*) from movie_score_caches) as score_caches,
  (select count(*) from scoring_evidence_matrix) as matrix_rows,
  (select count(distinct movie_id) from scoring_evidence_matrix) as distinct_movie_ids;
```

Profile evidence regimes:

```sql
select
  evidence_regime,
  count(*) movies,
  round(100.0 * count(*) / sum(count(*)) over (), 2) pct,
  round(avg(legacy_overall_score)::numeric, 2) avg_score,
  round(avg(evidence_confidence_baseline)::numeric, 3) avg_evidence_conf
from scoring_evidence_matrix
group by evidence_regime
order by min(present_lens_count);
```
