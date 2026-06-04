# ADR — Prediction model-class registry, lifecycle, and serving contract (#1061 Session 2)

**Date:** 2026-06-03 · **Status:** accepted · **Supersedes:** the implicit "one linear model, hardwired" state audited in #1060.

## Context

The audit (#1060) found the prediction system had exactly one model class (linear logistic
regression), hardwired at the serving layer, with every comparison run discarded. #1061 made model
classes first-class: Session 1 built the substrate (behaviour + registry + experiment ledger);
Session 2 closes the loop (matrix → ledger → promote → explain) and proves extensibility with a
second class. This ADR records the contracts so a future class can be added safely.

## Decision

### 1. Serving contract: `:weight_map` vs `:opaque`

Every `Cinegraph.Predictions.ModelClass` declares a `serving_kind/0`:

- **`:weight_map`** — the fitted artifact serializes to a `%{feature_code => weight}` map and is
  served by the existing `Cinegraph.Scoring.Bus` `Σ wᵢ·featureᵢ` path **with no new serving code**.
  Weights stay inspectable, so the honesty/calibration/ablation machinery and
  `Explanation.for_list/1` work unchanged. `linear_logreg` and `pooled_linear` are both weight-map.
- **`:opaque`** — a serialized model blob scored via `score/3`; forfeits per-feature weights and
  **must be disclosed as such** in any explanation. **Out of scope for Session 2 / not yet built**
  (Phase 4, gated on ledger evidence). `Bus` has no opaque clause yet; since promotion only ever
  activates `linear_logreg`, no opaque artifact can become a live serving model.

### 2. Fit scope: `:per_cell` vs `:pooled`

`ModelRegistry.fit_scope/1` (via an optional `fit_scope/0` on the class) distinguishes:

- **`:per_cell`** (default) — fits one list at a time through `Trainer.fit_weights`, dispatched by
  `model_class`. `linear_logreg`.
- **`:pooled`** — fits once across all lists (`fit_pooled/2`), then projects to a per-target weight
  map. `pooled_linear` uses the target-list one-hot as an additive feature; the projected map is the
  shared objective weights (the per-list one-hot weight is a bias, rank-invariant within a list, so
  it need not be represented in the weight-map contract). `Trainer.run_matrix` routes pooled classes
  to the fit-once / project-many path and records them through the same sole ledger writer
  (`evaluate_cell` with `:precomputed_weights`).

### 3. Honesty caveat (non-negotiable)

Grades and the leaderboard rank on **objective full-pool recall** (#1055), never the gameable
curated universe. The per-cell objective ablation is **always** the `linear_logreg` baseline so the
honesty grade is class-comparable. `pooled_linear` trains on **objective-only** features
(`data_point_codes − canon_overlap_codes`), so it **structurally cannot smuggle canon-overlap**
circularity. Model class is not treated as an accuracy lever — Stage B (#1051) measured that
EXGBoost lost to linear; `pooled_linear` exists to prove *extensibility*, not to raise numbers.

### 4. Lifecycle (config-only)

`config :cinegraph, :model_class_lifecycle` maps a class key to a status. It is **config, not a
callback**, so a retired class dropped from `:model_classes` still resolves for the
leaderboard/explanation, and its ledger rows persist.

| status | runs in matrix? | promotable? | served? |
|---|---|---|---|
| `:experimental` | yes (ledger-only) | no | no |
| `:active` | yes | yes (S2: only `linear_logreg` is *activated*) | yes |
| `:deprecated` | no new runs | no | still served if already active |
| `:retired` | dropped from `:model_classes` | no | ledger rows persist as the record |

Default for an unlisted key is `:experimental`.

## Add a model class (checklist)

1. Implement `Cinegraph.Predictions.ModelClass` (`key/0`, `label/0`, `serving_kind/0`, `fit/4`,
   `score/3`, `serialize/1`, `load/1`, `explain/1`).
2. Add the module to `config :cinegraph, :model_classes` and a `:model_class_lifecycle` entry.
3. If **weight-map + per-cell** over the existing feature matrix → **done**: it flows through
   fit → matrix → ledger → leaderboard → promote → explain with no core edits.
4. If **pooled** → also add `fit_scope/0 => :pooled` + `fit_pooled/2`; `run_matrix` routes it.
5. If **opaque** → Phase 4: add a `Bus.score` opaque clause + serving path; disclose "no per-feature
   weights"; gate activation on evidence. Not config-only.

A class needing new feature preparation, a new dependency, its own hyperparameter grid, or different
scoring semantics is **not** config-only — it is incremental work, flagged here.

## Consequences / known residuals

- **Promotion activates `linear_logreg` only** (Session 2). Other classes are recorded and
  comparable in the ledger but never serve until a separate, evidence-gated decision.
- **`run_cells` timeout residual:** `evaluate_cell` records a `failed` ledger row on any exception,
  but an OS-level worker **timeout/kill** (`Task.async_stream` `{:exit}`) cannot be attributed to a
  cell and is logged-only. Acceptable: the holdout-free matrix can be re-run; the sacred-holdout
  promotion path never uses `run_cells`.
- **Byte-stability:** routing the fit through the registry kept `linear_logreg` weights identical to
  the pre-#1061 path (pinned by a regression test) — the live promotion path is unchanged.
