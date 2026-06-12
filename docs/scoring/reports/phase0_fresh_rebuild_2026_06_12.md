# Phase 0 — fresh-substrate rebuild + B₀ re-freeze (#1113)

**Date:** 2026-06-12 · **DB:** `cinegraph_dev` (refreshed to exact prod parity) · **Seed:** 1337

Prep phase for #1113 (use a frontier model as a new content data-class to break the prediction ceiling). Goal: pull the now-complete prod substrate local, re-freeze B₀ on it, preview a rebuilt board, and stage the content export — **before** spending anything on the model.

## What was done
1. **Delta measured (0a).** Catalog spine (movies/credits/people) was ~current on dev; the only material gap was **OMDb coverage** (dev 184,641 distinct vs prod 247,888).
2. **Full prod pull (0b).** `mix db.pull_production` → exact parity (movies 1,166,561 · people 686,089 · credits 4,620,046 · OMDb 247,888 · orphan metrics 0). All 3 matviews refreshed. (~26 min. A disk constraint forced an interim lean `external_metrics`-only refresh first; superseded by the full pull once ~32 GB was freed.)
3. **B₀ re-frozen (0c).** `mix predictions.matrix --buckets objective_only,all --classes linear_logreg --seed 1337` (40 cells; one accidental DB kill mid-run, resumed cleanly via the append-only ledger) → `docs/scoring/reports/b0_2026_06_12.json` (best objective_only `linear_logreg` per list).
4. **Content export staged (0e).** New task `mix predictions.export_content` → `priv/dumps/content_export_pool.jsonl` (4,952 leakage-safe films: title/year/country/language/runtime/overview/genres/director/cast; **no ratings/awards/membership**). The frontier model's input for Phase B/C.

## Result — recall up, grades still power-limited

| list | fresh obj@K | prod served | Δ | fresh grade |
|---|--:|--:|--:|---|
| afi_100 | 0.476 | 0.200 | +0.276 | moderate |
| national_film_registry | 0.282 | 0.085 | +0.197 | insufficient |
| tspdt_1000 | 0.242 | 0.112 | +0.130 | low |
| 1001_movies | 0.526 | 0.409 | +0.117 | insufficient |
| letterboxd_top_250 | 0.151 | 0.086 | +0.066 | insufficient |
| criterion | 0.145 | 0.156 | −0.011 | low |
| cult_movies_400 | 0.061 | unserved | NEW | low |
| ebert_great_movies | 0.217 | unserved | NEW | insufficient |
| sight_sound_critics_2022 | 0.114 | unserved | NEW | low |
| sight_sound_directors_2022 | 0.184 | unserved | NEW | low |

**Headline:** the complete substrate lifted objective **recall** materially on almost every list, but **did not lift the reliability grade** — `promote` dry-run shows only `criterion` would serving-clear; the rest grade insufficient/low (small temporal holdouts → power-bound, the #1070 ceiling). This is the #1113 thesis confirmed: **data completeness alone doesn't break the ceiling.**

## Decision
**Hold the holdout spend.** `promote --commit` would spend all 10 one-shot sacred holdouts to activate a single flat list. Reserve them for after the Phase C frontier-model content features, when grades may actually clear. Phase 0's durable deliverables — fresh substrate, frozen B₀ baseline, content export — are complete; no prod push.

## Next (#1113 Phase B/C)
B₀ (`b0_2026_06_12.json`) is the comparator. Phase B = stronger embeddings vs the MiniLM/TF-IDF ~0.65 tie; Phase C = frontier-LLM structured content features over `content_export_pool.jsonl` (~5k films ≈ $30 Opus-4.8 batch to gate). Promote once, on objective lift, after.
