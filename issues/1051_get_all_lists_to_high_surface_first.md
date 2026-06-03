# #1051 — Get all 10 prediction lists to "high": fix the surface area first, then the models, then iterate

**Goal:** get all 10 canonical-list prediction models *passing* and as *high* as the data honestly allows. **Replaces #1047 and #1050** (those were measurement/hygiene plans that never looked at the thing that actually gates accuracy: the feature surface).

**The order is deliberate and non-negotiable: fix the surface area FIRST.** Our models can only be as good as the data they train on, and right now the data is thin, lopsided, and quietly confounded. Tuning algorithms on this surface is rearranging deck chairs.

---

## How to execute this (parent epic → sub-issues)

This is a **parent epic.** Each stage becomes its own implementation sub-issue when it starts — keep this issue as the north star, don't implement it as one PR.

| Sub-issue | Ready to start? |
|---|---|
| **0** — Hygiene / baseline trust | ✅ ready |
| **A1** — Enrich `predictions.audit_coverage` (by-code / by-universe / by-list) | ✅ ready |
| **A2** — Candidate-universe backfill (OMDb/TMDb sweepers, members-first) | ✅ ready |
| **A3+A4** — Festival densification + missingness indicators (w/ strict keep-criterion) | ✅ ready (A4 measured against A1) |
| **B** — Model-architecture spike + ADR (interaction features → pooling → EXGBoost) | ⏳ **after Stage A green** (it's a design spike; EXGBoost not yet a dep) |
| **C** — Ablation + iterate + disclose | ⏳ after A (and B's decision) |

**Are we ready?** Yes for **Stage 0 and all of Stage A** — those are fully specified and use existing machinery. **Stage B is a design spike, not yet implementable** (no GBM in Scholar; EXGBoost would be a new dependency). Stage C follows A. Net: we can start immediately and correctly; we just shouldn't pretend B is shovel-ready.

---

## Where we are (live evidence, dev DB)

### 1. The surface area is the binding constraint — and it's bad

Coverage of the feature codes over the **914,274** `import_status='full'` movies (61 distinct codes in `metric_values_view`; `Trainer.data_point_codes/1` yields ~62 *trainable* per list = raw-available-non-custom + 5 derived − the target's own code):

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

- The only model type in the codebase is `Scholar.Linear.LogisticRegression` (deps: `nx`/`exla`/`scholar`). **Scholar 0.4 itself has no supervised tree/GBM/ensemble** (only linear, KNN, naive-bayes; its "forest" modules are KNN structures). So a nonlinear model means **adding a new dependency** (e.g. `EXGBoost`) — *not currently in `mix.exs`/`mix.lock`*. This makes Stage B a feasibility spike, not a config change.
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

- [ ] **A1 — Enrich the EXISTING coverage task, don't fork one.** `mix predictions.audit_coverage` already exists (per-decade; imdb/RT/metacritic/festival; `--json`). **Extend that task** (don't create a separate `predictions.coverage`) to also report per-`metric_code` coverage over (a) full population, (b) the candidate universe, and (c) per-list members — the three lenses we need to track densification progress and define "done." Keep the decade view; add the by-code/by-universe modes.
- [ ] **A2 — Backfill the candidate universe** using the project's existing machinery — **do not write a new fetch path:**
  - Use `Cinegraph.ApiProcessors.OMDb` via the existing OMDb backfill **maintenance module + sweeper** pattern (CLAUDE.md §4), scoped to the ~5K candidate universe, **members first** (the confounded, under-covered side). Targets: metacritic, rotten_tomatoes, budget, revenue (OMDb carries metacritic/RT; budget/revenue come from TMDb via `ApiProcessors.TMDb`).
  - Assumptions to confirm in the ticket: `OMDB_API_KEY` (Basic = 100k/day) and `TMDB_API_KEY` present; respect the Oban `omdb`/`tmdb` queue limits (concurrency 5, ~250ms spacing) — a one-off run over ~5K movies is well within a day's quota.
  - **Record source-absent with the existing `fetch_attempt` marker** (an `external_metrics` `fetch_attempt` row = "tried, API returned nothing", 90-day cooldown). That is how we distinguish *not-yet-fetched* from *genuinely-absent* — no new convention needed.
- [ ] **A3 — Densify festival/award coverage** where source data exists (only 46% of candidates have a nomination row) — via the existing festival import flow.
- [ ] **A4 — Handle irreducible absence honestly, with a strict keep-criterion.** Old/foreign/arthouse films genuinely lack budget/metacritic at source. Add explicit **missingness-indicator features** (`has_metacritic`, `has_budget`, …) so absence is a *declared* feature, not a hidden confound. **Acceptance criterion (strict): an indicator is kept ONLY IF it raises objective-only lift on a held-out split AND the gain survives a coverage-matched control** (e.g. evaluated within the densified/coverage-balanced subsample) — i.e. it must add real signal, not merely re-learn "missing data ⇒ canon." Indicators that only encode the confound are dropped.

**Exit gate:** the enriched `audit_coverage` shows the candidate universe's *fetchable* gaps closed (member coverage of metacritic/RT/budget/revenue materially up, with the remainder marked `fetch_attempt`/source-absent); median candidate feature density rises from ~17/61; the absence-confound is either removed (by backfill) or made explicit (by indicators) **and shown to pass A4's keep-criterion**. **Re-run the scoreboard — expect movement here before any algorithm change.**

---

## Stage B — Decide the model architecture ("combine the models")

With a denser surface, decide — explicitly, with measurement — whether linear-one-per-list is still right. **This stage is a design spike + ADR, not directly implementable yet** (see the dependency reality below); it produces a recorded decision, then its own implementation sub-issue.

Options, cheapest-first:
- [ ] **B0 — Interaction/polynomial features (no new dep, no new serving path).** The cheapest way to capture nonlinearity is to feed *interaction* and binned features to the **existing linear model** — the bus stays `Σ w·feature`, the honesty/calibration machinery is untouched. Try this first; it may close much of the gap for free.
- [ ] **B1 — Nonlinear-model headroom test.** Scholar 0.4 has **no** supervised GBM/tree, so this requires adding **`EXGBoost`** (a new hex dep with native xgboost) — feasibility-check the build on the M3/CI first. Then prototype it in the experiment harness vs logistic regression on the densified universe and measure the PR-AUC/lift gap. Only worth the dependency + new serving path if the gap is material AND B0 didn't already capture it.
- [ ] **B2 — Pool the weak lists.** Prototype a **multi-task / pooled model** (all lists, list-as-feature) to rescue tiny-positive lists (NFR, 1001) that can't train standalone. Compare against per-list. (Doable with the existing linear stack — list-as-feature in one logistic regression — so no new dep.)
- [ ] **B3 — Decide and record (ADR).** Whatever wins, document the serving contract: the bus currently *cannot* hold a nonlinear model, so adopting EXGBoost means a new serving path that `Reliability`/`ProbabilityCalibration` must still apply to. B0 and B2 keep the existing contract.

**Exit gate:** an ADR recorded, backed by B0/B1/B2 measurements on the densified surface; if a new dep or serving path is adopted, a follow-up implementation sub-issue is filed with the contract spelled out. **Do not start Stage B until Stage A's exit gate is green** — a headroom test on the thin surface would mismeasure.

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

---

*Review pass applied (2026-06-03): reframed as a parent epic with a sub-issue breakdown; reconciled A1 with the existing `mix predictions.audit_coverage` (extend, don't fork); corrected the feature-code count (61 view codes vs ~62 trainable/list); added Stage A operational detail (OMDb/TMDb sweepers, `fetch_attempt` as the source-absent marker, quota/rate assumptions); tightened A4's missingness keep-criterion (must beat a coverage-matched control); corrected Stage B's dependency reality (Scholar has no GBM; EXGBoost is a new dep) and added the no-new-dep options (interaction features, list-as-feature pooling), reframing B as a spike+ADR gated on Stage A.*

