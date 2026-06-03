# #1046 — Reality check: does the prediction engine actually work, or are we tricking ourselves?

**Status:** audit / deep-dive (no code changes in this issue — findings + prioritized follow-ups)
**Date:** 2026-06-03
**Scope:** everything built in #1027 → #1030 → #1036 → #1039 → #1040 (the Tunable Algorithm Engine: 3-layer substrate, the bus, the credibility/reliability engines, and the iteration loop).
**Audited against:** the live dev DB (11 trained models, 10 active lists), the algorithm source, and the hardware posture.

---

## TL;DR — the grade

**Overall: B+.**

The thing we built to *stop ourselves from lying* is the best part of this system, and it is genuinely rare. The integrity protocol (pre-registration → sacred holdout → spent-once → Wilson lower bound → dumb baselines → grade caps) is A-grade engineering that most production ML never bothers with. **We are not, today, tricking ourselves in the obvious ways** — the live grades read mostly `:low`/`:insufficient`, which is the *honest* answer for the data we have.

The weakness is not the machinery, it's the **substance of the signal**: most of our predictive power is *circular* (canon predicts canon), our temporal holdouts are *severely underpowered* (n = 5–22 positives), and our headline accuracy numbers are **not comparable across lists** because two different backtest strategies measure two different-difficulty tasks. None of these are fatal; all are fixable; the most important one is a disclosure/comparability problem, not a math bug.

| Dimension | Grade | One-liner |
|---|---|---|
| Anti-self-deception machinery (integrity protocol) | **A** | Pre-reg + sacred holdout + Wilson + baselines + caps. Rare and correct. |
| Architecture / schema (3 layers, bus, train==serve) | **A−** | Clean, documented, the train/serve symmetry invariant is real. |
| Honesty of reporting | **A** | Nothing hidden; failures are recorded, not buried; grades read LOW. |
| **Statistical validity (does the signal exist?)** | **C+** | Real lift over baselines on 8/10 lists — but circular, underpowered, and not cross-comparable. |
| Resource utilization (M3 Studio) | **B−** | Compute is trivial (EXLA is overkill); the real lever is materialization + the ephemeral PG tuning. Cores mostly idle. |

The single most valuable next experiment is **one ablation run** (§5.1). It will tell us, in one number per list, how much of our accuracy is *real independent signal* versus *list overlap*. Until we run it, every headline % is unfalsified on the question that actually matters.

---

## 1. What we actually built (the three layers, verified against the code)

Confirmed the architecture in the memory note matches the code on disk:

- **Layer 0 — data points.** `metric_definitions` catalog (raw + derived) → `metric_values_view` normalized feed. `Cinegraph.Scoring.DataPointFeatures.load_for/3` is the single assembly path. Derived target-aware features (`canonical_contribution`, `auteur_track_record`, `box_office_roi`, `festival_prestige`) come from `Cinegraph.Scoring.DerivedFeatures`, which reuses `FeatureResolver` and is **leakage-stripped per target** (verified: `feature_resolver.ex:240` deletes `source_key` before counting; `:320` subtracts the film's own contribution to its directors' counts).
- **Layer 1 — lenses.** 6 lenses, versioned in code (`@lens_version`), computed from Layer 0 in one place.
- **Layer 2 — the bus.** `Cinegraph.Scoring.Bus.score/3` — one `Σ wᵢ·featureᵢ` contract dispatched on `feature_set.granularity`. **The same `DataPointFeatures.load_for/3` feeds both training and serving** (`bus.ex:55` and `trainer.ex:558`), so the train/serve symmetry invariant is structurally enforced, not just hoped for. This is the most important correctness property in the whole system and it is real.

**Verdict on the substrate: it works and it's clean.** Adding a data point is (close to) a one-row catalog change. The two-formula debt (Elixir vs SQL) is gone. No notes here beyond "keep it."

---

## 2. The integrity machinery — this is the good part

Every guard the protocol promises is actually in the code path, not aspirational:

- **Pre-registration required to save** — `train(save: true)` with no prereg → `{:error, :prereg_required}` (`trainer.ex:65`). DB-enforced: `prediction_models.prereg_id` is `NOT NULL`.
- **Sacred holdout, spent once** — latest decade reserved, scored once, `holdout_spent_at` stamped; re-running the same prereg → `{:error, :holdout_already_spent}` (`trainer.ex:68,80`).
- **Holdout-free iteration sandbox** — `run_experiment/2` fits on train, evaluates on *validation*, never touches the holdout (`trainer.ex:153`). This is exactly right: it lets us tune without burning the sacred set.
- **Conservative headline** — `Reliability` reports the **Wilson 95% lower bound** of recall@K, never the point estimate (`reliability.ex:88,219`). 8/22 ≈ 36% point becomes a 19.7% headline.
- **Dumb baselines, scored identically** — popularity / random / prior-rate, scored through the same bus (`credibility.ex:189`).
- **Grade caps, never inflation** — identity calibration, stale frontier, edition disagreement, failed prereg can each only *lower* the grade, and each records its reason (`reliability.ex:128`).

**This is the answer to "how do we not trick ourselves."** It is working: see §4, where two live models are correctly graded `:insufficient` precisely because they *failed* their honesty checks. A system that lets a 52.7%-recall model self-report as "insufficient" because it only beat popularity by 1.35× is not flattering itself.

---

## 3. The live state of the engine (evidence)

Queried directly from the dev DB. 11 model rows, 10 active lists (model id=3 is an orphaned earlier `1001_movies` — dead row, should be deleted).

| id | list | strategy | recall@K | n_pos | n_eval | grade | band | headline | lift margin | passes lift? |
|----|------|----------|---------:|------:|-------:|-------|------|---------:|-----:|:--:|
| 6 | 1001_movies | temporal | 0.364 | **22** | 255,033 | low | low | 19.7% | 0.364 | ✅ |
| 5 | cult_movies_400 | static | 0.664 | 399 | 2,109 | low | high | 61.6% | 0.564 | ✅ |
| 7 | afi_100 | static | 0.350 | 100 | 1,852 | low | low | 26.4% | 0.31 | ✅ |
| 8 | criterion | static | 0.527 | 1,768 | 3,423 | **insuf** | high | — | 0.136 | ❌ (1.35×) |
| 9 | ebert_great_movies | static | 0.320 | 150 | 1,920 | low | low | 25.1% | 0.28 | ✅ |
| 10 | letterboxd_top_250 | static | 0.329 | 280 | 1,989 | low | low | 27.6% | 0.161 | ✅ |
| 11 | national_film_registry | temporal | **0.0** | **5** | 223,673 | **insuf** | low | — | 0.0 | ❌ |
| 12 | sight_sound_critics_2022 | static | 0.293 | 99 | 1,869 | low | low | 21.2% | 0.263 | ✅ |
| 13 | sight_sound_directors_2022 | static | 0.500 | 104 | 1,869 | moderate | moderate | 40.6% | 0.481 | ✅ |
| 14 | tspdt_1000 | static | 0.614 | 995 | 2,596 | moderate | high | 58.3% | 0.329 | ✅ |

**Reading this honestly:**
- **8 of 10 lists beat the popularity baseline** (lift gate passes). That is genuine, measured evidence of *some* skill. It is not nothing.
- **No list grades `:high`.** Best is `:moderate`. That is the correct, sober answer given the data.
- **The two `:insufficient` verdicts are the system working as designed:** `criterion` looks great (52.7%) but the list is so popularity-predictable that the model barely adds 1.35×; `national_film_registry` is a genuine failure (recall 0, n=5, identity calibration) that is *still set active* but correctly refuses to state a headline.

---

## 4. Where we ARE at risk of tricking ourselves (ranked)

### 4.1 🔴 Headline accuracy is NOT comparable across lists (the #1 disclosure risk)

Two backtest strategies measure **two completely different-difficulty tasks**, but both emit a number called "recall@K → headline %":

- **temporal** (1001_movies, national_film_registry): K members ranked against the **entire decade** — 255,033 movies, base rate ~0.0001. A 36% recall here is finding 8 of 22 needles in a quarter-million haystack.
- **static** (everything else): K members ranked against a **pinned ~2,000-film universe** of members + most-voted non-members, base rate 0.05–0.52. A 58% recall here is a far, far easier task.

So `tspdt_1000` (58.3%, static) reads as ~3× more reliable than `1001_movies` (19.7%, temporal), when the temporal task is roughly **1,000× harder by base rate**. A user comparing two lists on the public `/predictions` page would be badly misled. The Reliability lift-gate *partially* compensates (it grades skill relative to each list's own popularity baseline), but the **headline number itself carries no difficulty normalization**.

**This is the most likely way the finished product lies to a user — not by overstating one list, but by making lists falsely comparable.** Fix options in §5.2.

### 4.2 🔴 The signal is largely circular: canon predicts canon

Look at the dominant learned weights (top features, live):

- `afi_100`: **canonical_contribution** (0.11), then `hfpa_win`, `festival_prestige`, `list_appearances`…
- `ebert_great_movies`: **canonical_contribution** (0.14), `list_appearances` (0.11)…
- `sight_sound_critics_2022`: **canonical_contribution** (0.22), `list_appearances` (0.10)…
- `sight_sound_directors_2022`: top feature is **`sight_sound_critics_2022`** (0.16) — the sister list from the *same poll* — then `canonical_contribution` (0.15).
- `tspdt_1000`, `letterboxd_top_250`, `criterion`: all led by `canonical_contribution` + `list_appearances`.

The feature set includes **every other canonical list's membership boolean** plus the aggregate `canonical_contribution` count. The target's own code is stripped (no direct leakage — verified), **but the model is overwhelmingly learning "films that critics have already canonized on the other 9 lists tend to be on this one too."** That is true, and it's not strictly leakage, but it is *circular signal*: predicting canon from canon. The `sight_sound_directors ← sight_sound_critics` case is nearly tautological (two cuts of one 2022 poll).

The marketing hook is "we predict the 1001 list." The honest footnote today is "…mostly by checking whether it's already on 8 other best-films lists." We do not currently know how much **independent** predictive power exists from objective features (ratings, votes, box office, festival results, runtime, language). **We have never measured it.** (Fix: the ablation, §5.1 — the single most important next run.)

### 4.3 🟠 Temporal holdouts are severely underpowered

`1001_movies` n_pos = 22 (CI {19.7%, 57.0%} — a 37-point-wide interval). `national_film_registry` n_pos = 5. You cannot make a confident accuracy claim from 5–22 positives, and the Wilson bound correctly refuses to pretend otherwise. This isn't a bug — it's a *data ceiling*. The temporal design reserves the latest decade, and recent decades simply don't contain many new canon entries yet. Implication: **temporal lists will essentially never earn a `:high` grade** under this design. That's honest, but worth stating as a known structural limit rather than something more sweeps will fix (cf. #1040's honest finding that the 22-positive holdout couldn't resolve the +derived gain).

### 4.4 🟠 `log_loss` during experiments is computed on an in-sample Platt fit

`run_experiment` fits Platt on the validation pairs and then scores log-loss on those same pairs (`trainer.ex:194`). The code is honest about it ("in-sample, but computed identically across experiments, so it is a consistent relative metric"). It's fine for *ranking* variants, but it is **not** a valid absolute calibration metric and must never be surfaced as one. Low risk as long as it stays an internal tuning signal. PR-AUC (rank-based, no calibration) is the trustworthy comparator and is correctly the sort key.

### 4.5 🟡 Minor leakage seams (low severity, worth noting)

- `director_avg_imdb` (`feature_resolver.ex:350`) averages a director's films' IMDb ratings **including the film being scored** — not stripped. It's a rating, not a label, so it's a weak feature-leak, not target-leak. Acceptable, but document it.
- `box_office_roi` uses revenue/budget from catalogued external metrics — fine, but coverage is low and ROI is notoriously noisy; it barely appears in any top-5. Probably contributing noise, not signal.

### 4.6 🟡 Wiring/cleanup debts

- `movie_lists.backtest_strategy` is **NULL on all 10 rows** — the strategy lives only on the model artifact. Anything reading the list column gets nil. Either backfill it or drop the column.
- Orphan model id=3 (`1001_movies`, superseded by id=6) should be deleted.
- The systemic **"edition year disagrees with newest member"** warning fires on 4 static lists (afi_100, both sight_sound, tspdt_1000). That's a real data-freshness signal worth chasing — it suggests the imported edition metadata is out of sync with the newest member we actually hold.

---

## 5. Recommendations (prioritized)

### 5.1 🥇 Run the ablation. This is the experiment that answers the user's question.

For each list, run `run_experiment` twice on identical splits:
- **Full** feature set (current).
- **Objective-only**: drop `canonical_contribution`, `list_appearances`, every per-list membership boolean, and `auteur_track_record` — keep ratings, votes, box office, festival, runtime, language, certifications.

Report `pr_auc_full` vs `pr_auc_objective` per list. The delta is, finally, the honest measure of **independent predictive signal**. If objective-only still beats baseline, we have a real product. If it collapses to baseline, our headline is "we know which films are already famous," and we should say so. `Trainer.run_experiment(features: ...)` already accepts an explicit code list (`trainer.ex:261`), so this is a mix-task wiring job, not new infrastructure. **Do this first.**

### 5.2 🥈 Make headline numbers comparable, or stop presenting them side-by-side.

Options, cheapest first:
1. **Always show the baseline next to the headline** ("36% vs 0.01% popularity" vs "58% vs 39% popularity") so the difficulty is visible. Lowest effort, high honesty.
2. **Lead with the lift, not the raw recall** — a difficulty-normalized "skill over baseline" figure is comparable across strategies in a way raw recall is not.
3. **Pick one strategy per public claim.** If `/predictions` compares lists, either backtest them all the same way or visually segregate temporal from static. Never sort a single leaderboard by raw headline across mixed strategies.

### 5.3 🥉 State the structural limits in the product copy.
- Temporal lists are capped at low confidence by holdout size — say it.
- "Accuracy" is recall-at-K-against-this-universe, not "probability we're right about any one film" — the calibrated per-film probability is the latter and only `:platt` models have it.

### 5.4 Housekeeping
- Delete orphan model id=3; backfill or drop `movie_lists.backtest_strategy`.
- Investigate the edition-year-disagreement on the 4 static lists (data freshness).
- Document the `director_avg_imdb` self-inclusion seam (or strip it).

### 5.5 Resources (M3 Studio) — important reframing
**The honest finding: this workload does not need the M3's muscle, and "use the cores better" is the wrong optimization.** The logistic regression is tiny (≤~60 features × a few thousand undersampled rows) — EXLA/Metal is overkill and the fit is microseconds. The bottleneck is 100% **Postgres feature-loading**, and the real levers are:
1. **Materialize `metric_values_view`.** It is a regular 4-way-UNION VIEW recomputed from base tables on every training/eval pass (`priv/repo/migrations/20260602120700_complete_metric_values_view.exs`). A materialized view + concurrent refresh is the single biggest speedup. This is already flagged as #1045's "pinned candidate universe ~45×" direction — make it concrete.
2. **The PG tuning is ephemeral.** `work_mem`/`effective_cache_size`/`jit`/`shared_buffers` were set via `ALTER SYSTEM` but exist *only in the running instance* — **nothing in version control**, and the `shared_buffers→16GB` restart is still pending. One reinstall and it's gone. Commit a `postgresql.tuning.conf` (or document the `ALTER SYSTEM` in a repo doc) so it survives.
3. **`config :nx, default_backend: EXLA.Backend` is set in dev/test but NOT prod** — if any prod path ever fits a model it silently falls to the BinaryBackend. Low impact today (training is dev-side) but a one-line fix.
4. Parallelism is hardcoded to `max_concurrency: 4` in the sweep/CV paths (`trainer.ex:235`, `weight_optimizer.ex:160/338/425`) — ~25% core use. But given the I/O-bound reality, **raising this matters far less than materializing the view.** Only worth touching after #5.5.1.

---

## 6. So — does it work?

**Yes, the machinery works, and no, we are not tricking ourselves — *yet*.** The integrity scaffolding is genuinely excellent and is actively catching our own failures (two `:insufficient` grades prove it). The substrate is clean and the train/serve symmetry is real.

**But we have not yet proven the engine has independent predictive value.** We've proven it beats "rank by popularity" on 8/10 lists — which it does largely by exploiting the fact that prestige lists overlap. The honest grade for the *signal* is C+ until the §5.1 ablation tells us what's left when we take the canon-overlap crutch away.

The two ways the *finished product* would most plausibly mislead a user are both fixable disclosure problems, not modeling bugs:
1. presenting temporal and static headline %s as if they're comparable (§4.1), and
2. implying our accuracy is "understanding what makes a film great" when it's mostly "this film is already on other lists" (§4.2).

Fix the disclosure, run the ablation, and this goes from "rigorous but unproven" to "rigorous and honest about exactly how good it is" — which was the entire marketing thesis (#1027: *"we tell you exactly how accurate we are"*). We're closer to living up to that than most teams ever get; the last mile is measuring and disclosing the circularity, not building more machinery.

---

### Follow-ups this issue spawns
- [ ] **#1046a** — objective-vs-full ablation harness + per-list deltas (§5.1) **← do first**
- [ ] **#1046b** — comparable headline presentation / lift-forward UI (§5.2–5.3)
- [ ] **#1046c** — materialize `metric_values_view` + commit PG tuning to VCS (§5.5.1–2)
- [ ] **#1046d** — housekeeping: delete model id=3, fix `backtest_strategy` column, edition-year data freshness (§4.6)
- [ ] relates to #1044 (prior_collab_density), #1045 (experiment speed)
