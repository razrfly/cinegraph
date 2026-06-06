# PU / SAR diagnostic — does Lever C (Positive-Unlabeled reweighting) apply? (#1070)

**Date:** 2026-06-04 · **DB:** `cinegraph_dev` · **Tool:** `mix predictions.pu_diagnostic`
**Verdict: NOT-SAR (inverted) on every list → skip Lever C, go to Lever E (text embeddings).**

## Why we ran this
Lever C's premise (from the literature + #1068): canon films are *under-covered* (fewer ratings/metrics, more foreign/old) than the popular films that dominate the unlabeled pool, so an "unlabeled = negative" learner mislabels canon → PU / coverage-aware reweighting would rescue it. Before building C (a real spike), we measured whether that confound actually exists — holdout-free, no DB writes.

**Decisive signal:** coverage→membership AUC (Mann-Whitney over objective-metric presence, 0..11). **< 0.5 ⇒ members under-covered (the SAR confound C targets); > 0.5 ⇒ members better-covered (the opposite).**

## Result — the confound runs the *opposite* way, on every list

| list | members | member cov (median) | pool cov (median) | coverage AUC | member non-Eng | pool non-Eng | verdict |
|---|--:|--:|--:|--:|--:|--:|---|
| criterion | 1768 | 7 | 4 | **0.94** | 52% | 55% | NOT-SAR |
| tspdt_1000 | 995 | 9 | 4 | **0.97** | 48% | 54% | NOT-SAR |
| sight_sound_critics_2022 | 99 | 9 | 4 | **0.98** | 61% | 54% | NOT-SAR |
| ebert_great_movies | 150 | 9 | 4 | **0.98** | 37% | 54% | NOT-SAR |
| 1001_movies | 1256 | 10 | 4 | **0.98** | 33% | 55% | NOT-SAR |
| afi_100 | 100 | 10 | 4 | **0.99** | 0% | 54% | NOT-SAR |
| cult_movies_400 | 399 | 10 | 4 | **0.99** | 9% | 55% | NOT-SAR |
| **ALL_LISTS (pooled)** | 3561 | 8 | 4 | **0.94** | 37% | 55% | NOT-SAR |

Pooled coverage histogram (% of group): members **42% at 9–11 / 57% at 6–8**; pool **67% at 3–5**. Canon is the *well-documented* set; the unlabeled pool is the obscure recent foreign long-tail with almost no metrics.

## Interpretation
- **The Lever-C rationale is false here.** Canon members are *better*-covered and *no more foreign* than the random pool — even the deep-arthouse lists. A binary learner is **not** biased against canon via coverage; coverage actually *helps* find canon. PU reweighting toward low-coverage positives would hurt, not help.
- **What's actually hard** (and where the weak lists fail) is distinguishing canon from **other well-documented, older, English-ish films** — the well-covered non-canon. Objective metrics can't separate those (they're similar). That is a **content / taste** distinction.
- **→ This points squarely at Lever E (text/plot embeddings)** — the one channel orthogonal to metrics, able to tell "great film" from "ordinary well-documented film." Not PU, not more metric coverage.

## Caveat (honest scope)
This rules out the **coverage/era/language SAR confound** — Lever C's dominant, cited rationale. It does **not** prove zero latent-positive contamination in the unlabeled set (some unlisted films are canon-worthy). But the specific, expensive PU mechanism we were about to build is **not indicated**; the Elkan-Noto SCAR shortcut roughly holds on the axes we can measure.

## Decision
- ❌ **Lever C (PU reweighting): dropped** — premise empirically false across all 10 lists.
- ✅ **Lever E (text embeddings): next** — the genuinely new channel that addresses the real gap (canon vs other well-covered films).
- Tool retained: `mix predictions.pu_diagnostic` (`--source-key`, `--json`) for re-checking if the pool composition changes.

## Reproduce
```shell
mix predictions.pu_diagnostic                      # pooled
mix predictions.pu_diagnostic --source-key criterion --json
```
