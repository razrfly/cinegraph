# Stage B — Model-Class Comparison on the Honest Full-Pool Metric

**Date:** 2026-06-03 · **Epic:** #1051 (get all lists to high surface, honestly) · **Decision record**

## TL;DR

On the **honest full-pool metric** (#1055), no model class beats the plain linear `:simplex`
model on *objective* (non-canon-overlap) signal:

- **EXGBoost (gradient-boosted trees): loses on all four lists tested** (−16 % to −40 % relative
  recall@K). **Decision: NO-GO — drop the dependency.**
- **L2 regularization (`alpha`) sweep: marginal** — best at `alpha=0.1` (+1 held-out hit on
  `tspdt_1000`, within noise); heavier regularization does nothing. **Keep the default.**
- **Conclusion:** the linear `:simplex` model is the right serving model. The bottleneck is
  **signal availability, not model class** — a finding for the #1051 Stage 2 disclosure, not a
  modeling fix.

## Why this metric

Earlier comparisons ranked candidates against a *curated* negative universe, which any flexible
model can game (the `:signed` "dilution fix" hit recall 1.0 on that universe and **0.0** on the
full pool). #1055 made evaluation honest: every model ranks members against the **full decade
pool** (`Credibility.evaluate` over the validation decades, base rate ~1e-4). All numbers below
use that denominator. Models train on the train decades and are scored on the **held-out future
decade** (the sacred holdout is never touched). Features are the **objective-only** bucket
(`data_point_codes − canon_overlap_codes`) — the independent signal, with the strong-but-circular
canon-overlap features excluded.

## EXGBoost vs linear (objective-only, full-pool recall@K)

`mix predictions.tree_spike --source-key <list>` — fit `EXGBoost.train` on the undersampled
train matrix (5:1), predict the full validation-decade pool in chunks, `recall_precision_at_k`.
Compared against `Trainer.run_experiment(features: :objective_only, weight_normalize: :simplex)`.

| list                     | n_pos | n_eval  | linear `:simplex` | EXGBoost | tree vs linear |
|--------------------------|------:|--------:|------------------:|---------:|---------------:|
| `tspdt_1000`             |    33 | 223,673 |        **0.1515** |   0.1212 |        −20 %   |
| `criterion`              |    67 | 223,673 |        **0.0746** |   0.0448 |        −40 %   |
| `1001_movies`            |   114 | 223,673 |        **0.5263** |   0.4298 |        −18 %   |
| `national_film_registry` |    78 | 162,149 |        **0.3205** |   0.2692 |        −16 %   |

Trees (`max_depth: 6, eta: 0.1, 100 rounds`, binary:logistic) fit the train decades fine but
generalize **worse** on the held-out future decade — the classic signature of overfitting a
modest, mostly-linear signal. A flexible model cannot conjure signal that is not there.

## Alpha (L2) sweep — `tspdt_1000`, objective-only, `:simplex`

| alpha | recall@K   | PR-AUC |
|------:|-----------:|-------:|
| 0.1   | **0.1818** | 0.1587 |
| 1 (default) | 0.1515 | 0.1538 |
| 10    | 0.1515     | 0.1537 |
| 100   | 0.1515     | 0.1527 |

The best alpha (0.1, least regularization) buys exactly **one extra hit out of 33** on a single
validation decade — noise-level, not a material lever. Heavier regularization is inert. The
linear model already captures essentially all of the available objective signal; tuning the
penalty does not move the metric.

## Interaction features (B0) and list-as-feature pooling (B2) — deferred

Both linear-stack levers were scoped but **not built**. Rationale: two independent flexible
approaches (a depth-6 tree and an under-regularized linear model) both fail to extract more than
the `:simplex` baseline from the objective bucket. That is strong evidence the objective signal is
genuinely low and already linearly captured, so engineered interactions or cross-list pooling are
unlikely to find headroom the tree could not. They remain available as `is_available:false`
plug-ins (same pattern as the missingness indicators) if a future surface-area gain (#1051
Stage A) changes the signal picture. Deferred ≠ silently skipped.

## Decisions

1. **Serving model: linear `:simplex`** at the default `alpha`. No change to `Bus`/`Model`/serving.
2. **EXGBoost: dropped.** The dependency (`exgboost` + its transitive `kino`/`vega_lite`/native
   XGBoost build) is removed; the `mix predictions.tree_spike` task is deleted. The negative result
   lives here. (To reproduce: re-add `{:exgboost, "~> 0.5"}`, recreate the spike per the method
   above.)
3. **Static-list grades are now honest** (#1055 `evaluate_static` rewrite, Part 2): a broad list is
   scored once via a seeded member holdout against the full member-decade pool — no curated
   negatives. Expect several static grades to drop toward the temporal range; that is correct.
4. **Hand off to #1051 Stage 2 (disclosure)** with these honest numbers. The headline is not "all
   lists high" — it is that objective predictability is modest and bounded by signal availability,
   and the canon-overlap signal that drives the high raw numbers is circular and must be disclosed
   as such.

## Honest scoreboard caveat

The full objective / canon / full ablation across all ten lists (`mix predictions.ablation`, now
full-pool) is the authoritative scoreboard but is **slow** (≈30 full-pool scorings; minutes each).
Run it in the background / off-hours to refresh the disclosure table. The four lists above are a
representative spot-check, not the full board.
