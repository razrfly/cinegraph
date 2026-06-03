# #1051 — Get all 10 prediction lists to "high": fix the surface area first, then the models, then iterate

**Goal:** get all 10 canonical-list prediction models *passing* and as *high* as the data honestly allows. **Replaces #1047 and #1050** (those were measurement/hygiene plans that never looked at the thing that actually gates accuracy: the feature surface).

**The order is deliberate and non-negotiable: fix the surface area FIRST.** Our models can only be as good as the data they train on, and right now the data is thin, lopsided, and quietly confounded. Tuning algorithms on this surface is rearranging deck chairs.

---

## Where we are (live evidence, dev DB)

### 1. The surface area is the binding constraint — and it's bad

Coverage of the 61 feature codes over the **914,274** `import_status='full'` movies:

| feature | % populated | | feature | % populated |
|---|--:|---|---|--:|
| metacritic_metascore | **2.3%** | | imdb_rating | 36.3% |
| tmdb_revenue_worldwide | **2.7%** | | tmdb_rating | 40.6% |
| rotten_tomatoes_tomatometer | **4.1%** | | imdb_rating_votes | 42.3% |
| tmdb_budget | **7.5%** | | tmdb_rating_votes | 93.4% |
| has_official_trailer | 14.0% | | tmdb_popularity_score | 99.6% |
| ~40 festival/award codes | **<0.5% each** | | runtime / language | 100% |

- **~40 of 61 codes are populated on <0.5% of movies.** Models trained on the full population learn from near-constant, mostly-zero vectors.
- Even in the **curated candidate universe (4,952 movies)**, the **median movie has only 17 of 61 features (~28% density)**.
- **A real, inverted confound:** within the candidate universe, list *members* have **lower** metacritic/budget/revenue coverage than non-member candidates (canon skews arthouse/old/foreign, which lack that data). So a model can learn **"missing budget/metacritic → canon"** — predicting from *data absence*, not quality. That is self-deception the integrity machinery can't catch.
- Festival data: only **46%** of candidates have any nomination row.

**Verdict: surface area = D+.** This, not the algorithm, is why the lists are stuck.

### 2. The models — linear-only, 10 independent, architecturally locked

- The only model type in the codebase is `Scholar.Linear.LogisticRegression` (deps: `nx`/`exla`/`scholar` — no trees, no gradient boosting, no ensembles).
- **10 models = one per list.** The weak lists can't support that — `national_film_registry` has **5** positives; you cannot train a real model on 5 examples.
- **The serving architecture is committed to linear.** The "bus" *is* `Σ wᵢ·featureᵢ` (a weight vector). A nonlinear model cannot be expressed as a weight map, so adopting one is an **architectural fork**, not a flag.
- Honest read: on today's thin surface, logistic regression is *fine* — a fancier model won't find signal that isn't there. Model class only becomes a lever **after** the surface densifies. **Models = C.**

### 3. Postgres — fast enough to iterate; one dev speed bump

- The iteration loop is fast (the pinned candidate universe shipped in #1045). ✅
- **Speed bump:** `mix run` saturates the DB pool on boot (DashboardStats/AwardImportStats cache warmers, 15s checkout timeouts) — experiments have to bypass the app to run. Needs a dev-env fix.
- Materializing `metric_values_view` is optional — not the constraint. **Postgres = B+.**

### 4. The scoreboard (baseline we iterate to beat)

**0 high · 2 moderate · 6 low · 2 insufficient.**

| List | strat | recall@K | n_pos | grade | target |
|---|---|--:|--:|---|---|
| tspdt_1000 | static | 0.614 | 995 | moderate | high |
| cult_movies_400 | static | 0.664 | 399 | low\* | moderate+ |
| sight_sound_directors_2022 | static | 0.500 | 104 | moderate | high |
| criterion | static | 0.527 | 1768 | **insuf** | low+ |
| letterboxd_top_250 | static | 0.329 | 280 | low | moderate |
| afi_100 | static | 0.350 | 100 | low | moderate |
| ebert_great_movies | static | 0.320 | 150 | low | moderate |
| sight_sound_critics_2022 | static | 0.293 | 99 | low | moderate |
| 1001_movies | temporal | 0.364 | 22 | low | low (power-capped) |
| national_film_registry | temporal | 0.000 | 5 | **insuf** | gradeable (needs static) |

\* cult is band-HIGH, capped only by a stale frontier — a data fix, not a model fix.

> **The honesty rule (non-negotiable).** A grade may only rise via *legitimate* signal. Raising recall by leaning harder on **canon-overlap** features (other lists' membership, `canonical_contribution`, `list_appearances`) is **not** improvement — it deepens circularity. Every accepted gain must hold-or-raise **objective-only lift**. We track grade *and* objective-only lift; the second is the real score.

---

## Stage 0 — Hygiene (prerequisite, ~½ day, improves nothing)

Make the baseline trustworthy before measuring against it.

- [ ] Guard `MovieLists.set_active_prediction_model/3` against `:insufficient` models **and** null out the live offender `national_film_registry` (id=11: recall 0, n=5). Verify the `/predictions` path degrades to "no prediction available" on a nil active model.
- [ ] Delete orphan model id=3 (`1001_movies`, superseded by id=6).
- [ ] **Drop `movie_lists.backtest_strategy`** — dead column (written/read nowhere; authoritative copy is `prediction_models.backtest_strategy`). The only schema change in Stage 0.
- [ ] Refresh `cult_movies_400`'s frontier so its band-HIGH grade isn't staleness-capped.
- [ ] Fix the `mix run` pool-saturation bump (cache warmers vs experiment runs).

**Exit gate:** `mix predictions.reliability` shows no `:insufficient` model active; no orphans; column dropped; cult uncapped; experiments run without pool timeouts; suite green.

---

## Stage A — Densify the surface area (the highest-leverage work) 🔴

The candidate universe is only ~5K movies. Densifying *those* is tractable with the project's existing OMDb/TMDb backfill-sweeper pattern.

- [ ] **A1 — Repeatable coverage audit as a mix task** (`mix predictions.coverage`): per-feature coverage over (a) full population, (b) candidate universe, (c) per-list members. This is how we *track densification progress* and define "done."
- [ ] **A2 — Backfill the candidate universe.** Run OMDb/TMDb enrichment on the ~5K candidate movies, **prioritizing list members** (the confounded, under-covered side). Targets: metacritic, rotten_tomatoes, budget, revenue. Many are simply un-fetched, not truly absent.
- [ ] **A3 — Densify festival/award coverage** where source data exists (only 46% of candidates have a nomination row).
- [ ] **A4 — Handle irreducible absence honestly.** Old/foreign/arthouse films genuinely lack budget/metacritic at the source. Add explicit **missingness-indicator features** (`has_metacritic`, `has_budget`, …) so the model uses absence *as a declared feature*, not as a hidden confound — and measure objective-only lift with and without them to confirm we're not just re-learning the confound.

**Exit gate:** coverage audit shows the candidate universe's *fetchable* gaps closed (member coverage of metacritic/RT/budget/revenue materially up, or documented as source-absent); median candidate feature density rises from ~17/61; the absence-confound is either removed (by backfill) or made explicit (by indicators) and measured. **Re-run the scoreboard — expect movement here before any algorithm change.**

---

## Stage B — Decide the model architecture ("combine the models")

With a denser surface, decide — explicitly, with measurement — whether linear-one-per-list is still right.

- [ ] **B1 — Headroom test.** In the experiment harness, prototype a **nonlinear model** (e.g. EXGBoost / a Scholar tree) against logistic regression on the densified candidate universe. Measure the PR-AUC/lift gap. If a tree materially beats linear, that's the headroom interactions are leaving on the table.
- [ ] **B2 — Pool the weak lists.** Prototype a **multi-task / pooled model** (all lists, list-as-feature, or a shared representation) to rescue tiny-positive lists (NFR, 1001) that can't train standalone. Compare against per-list.
- [ ] **B3 — Decide and record.** Options: keep the linear bus (serving-simple, honesty-machinery intact); add a nonlinear model behind a **new serving path**; and/or adopt a pooled model for weak lists. Whatever wins, document the serving contract — the bus currently *cannot* hold a nonlinear model, so this is a real architectural decision, not a tweak.

**Exit gate:** a recorded decision backed by the B1/B2 measurements; if a nonlinear/pooled model is adopted, its serving path is specified (and the reliability/calibration machinery still applies to it).

---

## Stage C — Measure, iterate, disclose

The old #1047 content — now meaningful, because the surface (A) and model class (B) are settled.

- [ ] **C1 — Feature buckets + ablation.** Add `objective_only` / `canon_overlap` / `custom:` selectors to `run_experiment`/`predictions.experiment` (today only `all|raw|derived`). Ablation report: per list, `{full lift, objective_only lift, delta}` on the same seed/split.
- [ ] **C2 — Iterate to the scoreboard targets**, judged on objective-only lift (the honesty rule). Per-list strategy review (does NFR/1001 become gradeable under static?), noise pruning (`box_office_roi` barely contributes), tuning via `run_sweep`.
- [ ] **C3 — Honest disclosure.** Lead with lift + baseline + strategy/difficulty (never raw recall across mixed strategies); surface the objective-vs-full split; state structural limits (temporal lists are power-capped; "accuracy" is recall-at-K-against-this-universe, not per-film probability).

**Exit gate:** scoreboard targets met *legitimately* (both `:insufficient` lists rescued, ≥2 `:low`→`:moderate`, ≥1 `:high`); per list we can state how much is independent signal vs canon overlap; nothing in the UI is falsely comparable.

---

## Honest expectation

- **With Stage A done**, the probability of reaching the targets rises substantially — most of the current ceiling is missing data, not a weak algorithm.
- **Some ceilings are real:** `national_film_registry` (5 temporal positives) and `1001_movies` (22) are data-power-capped; they likely need a static strategy and/or pooling (Stage B) and may still cap at `:low`/`:moderate`. We will *disclose* those ceilings, not fake past them.
- **"As high as possible" is bounded by the signal that genuinely exists.** If after A+B the objective-only lift is still thin on a list, the honest product statement is "this list is hard to predict from objective features" — which is itself a true, valuable answer.

## Grades (current state)

| | grade |
|---|---|
| Surface area | **D+** (binding constraint) |
| Models (type + count) | **C** |
| Postgres readiness | **B+** |
| Old #1047 as a path to the goal | C− (great honesty, wrong primary axis) |

---

*Supersedes #1047 (audit + measurement plan) and #1050 (Stage-0 hygiene), both closed. The hygiene is folded in as Stage 0 above.*
