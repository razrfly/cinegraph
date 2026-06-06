# Text-signal feasibility spike — does Lever E (text embeddings) carry the signal metrics can't? (#1070)

**Date:** 2026-06-04 · **DB:** `cinegraph_dev` · **Tool:** `mix predictions.text_spike`
**Verdict: GREEN — build Lever E.** Plot text separates canon from coverage/era-matched non-canon on every list (AUC 0.57–0.69), **strongest exactly on the arthouse/auteur lists metrics fail on.**

## Why we ran this
The PU diagnostic showed the easy part (canon vs the obscure long-tail) is already solved by coverage; the *hard, unsolved* part is **canon vs other well-documented, similar-era films** — which look identical on metrics. The remaining question: does the **plot text** separate that hard pair? If yes, embeddings (Lever E) are the lever; if not, we're near a metadata ceiling.

## Method (a conservative lower bound on real embeddings)
- **Task:** classify canon members vs **non-members matched on (decade × coverage-bucket)** — so coverage/era (which we *know* already separate canon) are neutralized and **only the text can carry signal**.
- **Features:** TF-IDF of `movies.overview` (top-3000 terms) + nearest-centroid cosine, 5-fold CV AUC.
- **Why it's a lower bound:** bag-of-words ignores synonymy, paraphrase, and cross-lingual meaning that semantic embeddings capture. **Real embeddings will do at least as well.**
- No production training, no holdout, no DB writes.

## Result

| list | archetype | canon / matched-neg | **text AUC** | verdict | metric strength (B₀ obj recall) |
|---|---|--:|--:|---|--:|
| criterion | auteur | 1768 / 1427 | **0.69** | GREEN | 0.075 (metrics fail) |
| tspdt_1000 | auteur | 995 / 637 | **0.65** | GREEN | 0.152 |
| **ALL_LISTS (pooled)** | — | 3558 / 2375 | **0.65** | GREEN | — |
| sight_sound_critics_2022 | consensus | 99 / 76 | 0.63 | AMBER | 0.120 |
| cult_movies_400 | taste | 399 / 163 | 0.61 | AMBER | 0.030 (near-noise) |
| letterboxd_top_250 | taste | 280 / 230 | 0.60 | AMBER | 0.121 |
| 1001_movies | consensus | 1256 / 751 | 0.59 | AMBER | 0.526 |
| ebert_great_movies | auteur | 150 / 109 | 0.58 | AMBER | 0.094 |
| afi_100 | consensus | 100 / 40 | 0.57 | RED | 0.571 (metrics already strong) |

## Interpretation — the complementarity is ideal
- **Text is strongest where metrics are weakest.** Criterion (0.69) and tspdt (0.65) — the deep arthouse/critics canons that objective metrics *can't* crack — have the clearest text signal. afi (0.57, RED) is the one list metrics *already* solve (B₀ 0.57), and it has the smallest/noisiest sample (40 matched negatives). Embeddings help precisely the lists that need help.
- **Even the "unpredictable" taste lists show signal** (cult 0.61, letterboxd 0.60) — a mild upside vs the metrics-only near-noise, though on small samples.
- This is the **first positive lever** after two measured nulls (Phase 1 categorical, PU/Lever C). The content channel is real.

## Honest caveats
1. This is **separability AUC** (canon vs matched non-canon), **not recall@K** on the full 0.1%-base-rate pool. It proves the content channel *carries signal metrics lack*; it does **not** yet quantify the recall@K lift — that requires building embeddings as a feature and running the honest matrix.
2. **BoW is a lower bound;** real semantic embeddings should exceed these AUCs (esp. for foreign films, where overviews paraphrase across the corpus).
3. Small lists (afi 40, S&S 76 negatives) are noisy; treat their exact AUCs as indicative.
4. Overviews are predominantly English (TMDb default) → the signal is plot *content*, not language detection; era/coverage are matched out.

## Decision & next step
- ✅ **Build Lever E (text embeddings).** Greenlit by a positive lower bound, with the signal concentrated on the weak lists the 🎯 goal needs to lift to MODERATE.
- **Open sub-decision (needs input): embedding backend.**
  - **Local — Bumblebee + a sentence-transformer** (e.g. `multilingual-e5-small`) via the existing EXLA stack. No per-call cost, reproducible, handles foreign overviews. Adds `bumblebee`/`tokenizers` deps + a model download. *(Recommended — fits the local/honest infra.)*
  - **Hosted API** — OpenAI `text-embedding-3-small` / Cohere / Voyage. ~\$1 to embed the whole catalog, but adds an external dependency + key.
- **Then:** add a `pgvector` column, embed overviews, expose embeddings as a feature group, A/B via `eval_features` + the matrix, and measure the real Δ recall@K vs B₀ — kept only if it clears the band (same protocol).

## Follow-up: real embeddings vs TF-IDF — **embeddings do NOT beat bag-of-words**

To decide whether the *expensive* embedding pipeline (pgvector + model serving + embedding 900k movies) is justified over cheap TF-IDF, we stood up real embeddings (`Cinegraph.Embeddings`, Bumblebee + `all-MiniLM-L6-v2`, in-Elixir via EXLA — required bumping the Nx stack 0.11→0.12; the existing trainer suite stays green) and ran the **same matched task** (`mix predictions.embed_spike`).

| task | representation | head | AUC | BoW comparison |
|---|---|---|--:|---|
| pooled | MiniLM embeddings | centroid | 0.640 | ≈ BoW 0.65 |
| pooled | MiniLM embeddings | logistic | 0.638 | ≈ BoW 0.65 |
| criterion | MiniLM embeddings | logistic | 0.657 | < BoW 0.69 |
| tspdt_1000 | MiniLM embeddings | logistic | 0.676 | > BoW 0.65 |

**Embeddings and TF-IDF are interchangeable (~0.64–0.68), neither dominates, across pooled/per-list and both classifier heads.** MiniLM sentence embeddings do **not** outperform cheap bag-of-words on this task.

### Revised Lever E decision
- ✅ **Build Lever E with TF-IDF / hashed bag-of-words text features** — same content signal as embeddings, **far cheaper** (sparse, no model serving, no pgvector, no embedding of the catalog), and it fits the existing `DerivedFeatures` pattern (hash overview tokens into N dims → a feature group).
- ⏸️ **Defer the embedding pipeline.** MiniLM ties TF-IDF, so the heavy infra isn't justified *now*. Revisit only if (a) TF-IDF text features give real recall@K lift but plateau, **and** (b) a stronger model (e5-large, OpenAI `text-embedding-3-large`) is worth trialing — the `Cinegraph.Embeddings` + `embed_spike` scaffolding (and the Nx-0.12/Bumblebee deps) are kept in place for exactly that, and can be dropped if a lean tree is preferred.
- **Next real test:** integrate hashed-TF-IDF overview features as a feature group → A/B via `eval_features` + the matrix → measure the **real Δ recall@K vs B₀**, kept only if it clears the noise band (same honest protocol). *Separability AUC ≈0.65 is encouraging but is not yet a recall@K result.*

## Reproduce
```shell
mix predictions.text_spike                          # TF-IDF, pooled
mix predictions.text_spike --source-key criterion --json
mix predictions.embed_spike --head logistic --json  # real MiniLM embeddings (needs Bumblebee)
mix predictions.embed_spike --source-key tspdt_1000 --head logistic
```
