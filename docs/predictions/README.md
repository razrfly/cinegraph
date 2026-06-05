# Prediction System — architecture & CLI reference

How CineGraph predicts whether a film belongs on a curated/canonical list (1001 Movies, Criterion,
AFI, Sight & Sound, …), how to run and iterate on it from the CLI, and the invariants that keep the
numbers honest. **Read this before touching the prediction pipeline.** Tracking issue: **#1070**
(supersedes #1068/#1067 findings). Durable experiment reports live in
[`docs/scoring/reports/`](../scoring/reports/).

---

## 1. The mental model

The task is **needle-in-haystack ranking**: rank the full pool of ~900k films so the ~0.1% that
belong on a given list surface in the top-K. The headline metric is **objective recall@K** (K = number
of list members) over the full era pool — computed on **objective_only** features so it can't be gamed
by "appears on other lists" circularity.

### Layered substrate (data points → lenses → models → serving)

| Layer | Where | Role |
|---|---|---|
| **L1 raw metrics** | `external_metrics` → `metric_values_view` | normalized 0–1 feature values per (movie, metric_code) |
| **Catalog** | `Cinegraph.Metrics.CatalogSeed` (`metric_definitions`) | the registry of feature codes; `is_available` gates a code into the default feature set |
| **Derived features** | `Cinegraph.Scoring.DerivedFeatures` | computed features (canon/auteur/ROI/festival, missingness indicators, categorical one-hot/multi-hot, **hashed-TF-IDF text**) — leakage-stripped, train/serve-symmetric |
| **Assembly** | `Cinegraph.Scoring.DataPointFeatures.load_for/3` | the single shared per-movie vector used by **both** training and serving (the symmetry invariant) |
| **The Bus** | `Cinegraph.Scoring.Bus` | `Σ wᵢ·featureᵢ` — one scorer for every weight-map model |
| **Model registry** | `Cinegraph.Predictions.ModelRegistry` | pluggable `ModelClass` behaviour; only `:active`-lifecycle classes can serve. Today: `linear_logreg` (active), `pooled_linear` (experimental) |
| **Trainer** | `Cinegraph.Predictions.Trainer` | fits weights per list; `run_experiment` (holdout-free iteration), `evaluate_temporal`/`evaluate_static` (sacred holdout), `evaluate_cell` (the sole ledger writer) |
| **Ledger** | `prediction_experiments` | every run's weights + class + strategy + feature_bucket + metrics + grade + provenance |
| **Promote/serve** | `prediction_models` + `movie_lists.active_prediction_model_id` | the served winner per list (+ `trained_weights` read-cache) |
| **Honesty stack** | `Credibility` / `Reliability` / `ProbabilityCalibration` | PR-AUC/recall, Wilson-95 grade, Platt calibration — applied uniformly across classes |

### Backtest strategies
- **temporal** — sacred holdout = the latest decade; honest but power-limited (some lists have <10 latest-decade positives → `Trainer.temporal_underpowered?/1`).
- **static** — seeded member-holdout ranked against the full member-decade pool (#1055 era-stratified random negatives — fixes the gameable vote-gated universe).

### Feature buckets
`objective_only` (no circular "other-list membership" codes — the honest headline), `canon_overlap`
(only the circular codes — ablation, **never served**), `all`, `raw`, `derived`.
`Trainer.data_point_codes/1` = catalogued `is_available:true` raw (non-`custom`-normalized) + available
derived, minus the target's own code (leakage strip). `canon_overlap_codes/1` = every other list's code
+ the 3 canon-derived codes.

---

## 2. The honest iteration protocol

The whole point: a change can only "win" by adding **real independent signal**, measured against a
frozen baseline, and the integrity guard refuses untrustworthy models. One lever per trip.

```
1. PRE-REGISTER  hypothesis + expected Δ + falsification threshold (before any holdout spend)
2. BUILD         add feature(s)/model class behind a candidate group — gated is_available:false
3. RUN (cheap)   mix predictions.eval_features [--sample N]  → Δ PR-AUC vs base (holdout-free)
4. KEEP/KILL     keep iff Δ ≥ noise band on ≥ N lists AND circularity not increased
5. PROMOTE TO    flip is_available (migration) → code enters objective_only → mix predictions.matrix
   SERVED METRIC    → read Δ objective recall@K vs B₀ → mix predictions.promote --commit (guard gates)
6. LOG           record per-list Δ + keep/kill + lesson (issue #1070 + docs/scoring/reports/)
```

**B₀ (baseline):** the frozen honest scoreboard read from the ledger (see #1070). Every Δ is measured
against it on the identical metric/pool/seed.

**Critical caveat — separability ≠ served-metric lift.** A feature that separates members from matched
non-members (a spike AUC) does **not** necessarily lift recall@K on the full pool, where existing
metrics already do most of the separating. Always confirm against the real metric (step 5), not just a
spike. (Text features are the cautionary example: ~0.65 spike separability, ~0 PR-AUC lift on top of
metrics — see #1070.)

---

## 3. CLI reference (`mix predictions.*`)

All tasks are read-mostly and safe to run in `iex`/dev; only `--commit` paths spend the sacred holdout
or change the served board.

### Run / iterate
| Command | What it does |
|---|---|
| `mix predictions.matrix [--plan] [--only L1,L2] [--sample N]` | Sweep lists × classes × strategies × buckets → ledger. `--plan` prints a pool-weighted ETA (needs `duration_ms` history to estimate). `--sample` collapses the pool for speed. |
| `mix predictions.leaderboard [--by-class]` | Rank ledger rows on the honest objective full-pool metric — "which model wins which list." |
| `mix predictions.eval_features [--sample N] [--min-lists K] [--threshold T] [--json]` | **The keep/kill gate.** Holdout-free A/B of candidate feature groups (lang/genre/rating/cat/**text**) vs the objective base, on Δ PR-AUC. `--sample` ⇒ minutes not 30m+. `--json` ⇒ learning-log artifact. |
| `mix predictions.eval_indicators` | Same gate for the missingness-indicator family (#1051 A4). |
| `mix predictions.experiment` / `predictions.train` | Single-cell / single-list training entry points. |
| `mix predictions.ablation` | objective vs canon-overlap vs full recall ablation per list. |

### Promote / serve
| Command | What it does |
|---|---|
| `mix predictions.promote [--only …] [--commit]` | Ledger-driven: per list pick the best **servable** row (grade-first; `canon_overlap` excluded; underpowered-temporal → static fallback), train it exact on the sacred holdout (spent once), activate. Dry-run unless `--commit`. |
| `mix predictions.demote --list L [--clear|--to ID] [--commit]` | Deactivate / repoint a list's served model. `--clear` nulls both the active pointer and `trained_weights`. |
| `mix predictions.reliability [--all]` | The live served scoreboard: each list's grade (Wilson-95 LB of objective recall@K), lift vs popularity, circularity. |
| `mix predictions.seed_flagships [--commit]` | Legacy per-list strategy auto-pick + honest re-promotion. |

### Diagnostics & feature de-risk (measurement only — no DB writes, no holdout)
| Command | What it answers |
|---|---|
| `mix predictions.pu_diagnostic [--source-key L] [--json]` | Is this a Positive-Unlabeled/SAR problem (is canon *under*-covered vs the pool)? Decides whether PU reweighting (Lever C) applies. **Verdict: NOT-SAR** — canon is *better*-covered. |
| `mix predictions.text_spike [--source-key L] [--json]` | Does plot text separate canon from coverage/era-matched non-canon? (TF-IDF bag-of-words, lower bound on embeddings.) |
| `mix predictions.embed_spike [--head centroid|logistic] [--json]` | Same task with real MiniLM embeddings (needs Bumblebee). **Finding: embeddings ≈ TF-IDF** → ship TF-IDF, defer the embedding pipeline. |
| `mix predictions.build_text_vocab [--sample N]` | One-time precompute of the overview IDF map → `priv/scoring/text_idf.json` (the hashed-TF-IDF `txt_NNN` features). |
| `mix predictions.audit_coverage` / `audit_festivals` / `candidates` / `backfill_universe` | Coverage/universe audits + candidate-pool tooling. |

### Observability (#1065)
- `mix predictions.matrix --plan` — pool-weighted ETA per cell (`duration_ms ≈ k·n_evaluated + b`).
  **Currently reports "estimate unavailable"** until one instrumented matrix run seeds `duration_ms`
  (the pre-#1065 ledger rows are null).
- `/admin/predictions/runs` — live run progress + cell grid + timing history (`prediction_runs` table,
  `RunReporter`). Matrix/promote only; the `eval_*`/spike sweeps don't yet emit the progress line.

---

## 4. Adding a new feature (the standard recipe)

1. **Emit it** in `DerivedFeatures` (add to `@supported` + a loader; emit pre-normalized 0–1, leakage-safe). The categorical (`lang_*`/`genre_*`/`content_rating_age`) and text (`txt_000..txt_511`) families are templates.
2. **Catalog it** in `CatalogSeed` as `kind: "derived", is_available: false` (gated off serving).
3. **Gate it** via `mix predictions.eval_features` (Δ PR-AUC). Keep only if it clears the noise band on ≥ N lists.
4. **Promote survivors:** a migration flips `is_available: true` → the code auto-enters `objective_only` → re-run the matrix → confirm Δ recall@K vs B₀ → `promote --commit`.
5. **Log** the result (issue #1070 + a `docs/scoring/reports/` entry), including null results.

**Adding a new model class:** implement the `ModelClass` behaviour, register it (`:model_classes` config), set its lifecycle. The honesty stack/ledger/serving apply unchanged (the registry was proven extensible by `pooled_linear`).

---

## 5. Invariants you must not break

- **Leakage strip** — a model predicting list `L` must never see membership in `L`. `data_point_codes/1` removes the target code; derived target-aware features are stripped per target.
- **Train/serve symmetry** — features come from the single `DataPointFeatures.load_for/3` assembly so a movie's vector is identical at fit and inference. Precomputed artifacts (e.g. `text_idf.json`) must be fixed, not recomputed per batch.
- **Honest grading** — grades may only rise via objective signal; `canon_overlap` is for ablation, **never served**; circularity is always disclosed.
- **Spend the sacred holdout once** — only `promote --commit` / `seed_flagships --commit` touch it, via a fresh pre-registration.
- **Document nulls** — "this lever doesn't help / this list isn't predictable" is a valid, valuable result. Never move the keep-criterion to manufacture a win.

---

## 6. What's been learned (pointer)

The honest finding so far (#1070): most lists are **weakly predictable from objective signal**; the
binding constraint is signal availability, not the algorithm or model class. Categorical features (null),
PU reweighting (refuted), and text features (separable but ~0 served-metric lift) have each been measured
and recorded. The standing goal and full lever-by-lever scorecard live in **issue #1070**; per-experiment
detail in [`docs/scoring/reports/`](../scoring/reports/).
