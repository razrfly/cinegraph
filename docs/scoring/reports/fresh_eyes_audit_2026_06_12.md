# Fresh-Eyes Audit of the Entire Prediction System — 2026-06-12 (#1113)

**Method:** 31-agent multi-perspective audit. Six independent auditors (evaluation/grading, feature & data surface, model class & training, problem formulation, Phase B/C plan, external research), every critical/major finding adversarially re-derived from primary sources (code, read-only psql on the prod-parity DB, git archaeology, recomputed statistics), then a completeness critic over the assembled record. Findings below are marked **[VERIFIED]** (survived independent refutation attempts at high confidence), **[REFUTED]** (original claim corrected), or unmarked (single-auditor, plausible, not independently verified).

---

## Grade card

| Component | Grade | One-line verdict |
|---|---|---|
| Honesty/integrity machinery (prereg, sacred holdouts, objective split, ledger) | **A−** | Genuinely above industry standard; the culture is the system's best asset |
| Evaluation & reliability grading | **C+** | No computational bug, but the scoreboard mislabels its own failures and parts of it are unwinnable by design |
| Feature & data surface | **C+** | Discipline excellent; but the baseline lost its one validated win, the objective bucket is contaminated, and the people channel is half-empty |
| Model class & training pipeline | **C+** | Linear serving is defensible, but two of the season's model-class kills were artifacts of a broken eval path |
| Problem formulation | **D+** | The deepest problem: for most lists, the measured quantity corresponds to no real future event, and the actual product goal has no training labels |
| Phase B/C content plan | **C+** | Right bet, near-certain false win as staged (coverage circularity + model-memory leakage + thin inputs) |
| Overall approach vs. state of the art | **B** | Measurement discipline above standard; measurement *validity* and architecture below it |

**The one-paragraph diagnosis:** The program concluded it hit a "metadata ceiling" and that grades are "power-bound." Both conclusions are substantially wrong. The board is gated by a mislabeled lift cap, computed on a quantized/clamped scoring path, over an objective bucket containing a canon leak, on a baseline missing its only validated metadata win, against a task that for 5–7 of 10 lists measures a fiction. The ceiling, where it exists, has not yet been honestly measured. That is bad news about the season's conclusions and good news about the headroom.

---

## Part 1 — Verified integrity defects: the board is not measuring what we think

### 1.1 The "insufficient" grades are lift-gate failures, not power failures [VERIFIED ×2]
`Reliability` has exactly two caps that can produce `:insufficient`: `n_pos < 10`, and the popularity-lift gate (`margin ≥ 0.05 AND ratio ≥ 1.5`, `reliability.ex:40-41,165-168,183-196`). All four insufficient temporal B₀ lists have n_pos ≥ 33, so the power cap *cannot* be the cause:

| List | obj recall | n_pos | pop baseline | why insufficient | absent the gate |
|---|--:|--:|--:|---|---|
| 1001_movies | 0.526 | 114 | 0.368 | ratio 1.429 < 1.5 (misses by 0.56 SE) | **MODERATE** (Wilson LB 0.435) |
| national_film_registry | 0.282 | 78 | 0.231 | ratio 1.22 | LOW (LB 0.194) |
| ebert_great_movies | 0.217 | 60 | — | margin 0.017 < 0.05 | LOW (LB 0.131) |
| letterboxd_top_250 | 0.151 | 33 | — | margin 0.0 | LOW (LB 0.067) |

`phase0_fresh_rebuild_2026_06_12.md` line 28 ("small temporal holdouts → power-bound") is a misdiagnosis for these four; the CLI legend ("INSUF = too little evidence") is wrong for them too. The gate compares two noisy point estimates from the same holdout with no uncertainty treatment, becomes *mathematically unsatisfiable* when the baseline exceeds 2/3 (observed up to 0.63 on static), and the fresh data pull silently raised the bar by strengthening the popularity baseline (1001: 0.061 → 0.368). Note the honest flip side: ebert/letterboxd genuinely show ~no lift over popularity — that's real, and the gate is correctly flagging it; the defect is the *label* and the knife-edge, not the existence of a lift requirement.

### 1.2 The evaluation path quantizes scores and the `:signed`/pooled kills were artifacts [VERIFIED]
`Bus.score` applies `Float.round(min(max(sum*100, 0), 100), 1)` (`bus.ex:63`) **inside the evaluation path**, and ties break by movie-id via stable sort (`credibility.ex:186`). Consequences, all reproduced in controlled read-only reruns:
- Scores take only 1,001 possible values over pools of 200–850k → quantization loss + tie lottery. tspdt's headline 0.242 is **0.273** with exact scores.
- `:signed` L2-normalized weights saturate the 100.0 clamp (criterion: 11,143-way tie at 100.0 holding 64/69 members; tspdt: all 33 members inside a 10,088-way tie → recall 0.0). Git archaeology confirms the clamp predates the `:signed` capability, so **the recorded ":signed = 0.0 on full pool" verdict measured the clamp, not the model**. With exact scoring, signed ties simplex on criterion and beats it on tspdt (0.273 vs 0.242).
- `PooledLinear` (E4, "loses 5/6") used `:signed` extraction through the same saturating clamp — tspdt pooled scored exactly 0.000, the saturation signature. **The naive-pooling kill is unsafe.**

### 1.3 B₀ contains zero box-office signal — the season's one metadata win is absent [VERIFIED ×2]
Migration `20260608140000` flipped the 4 raw box-office codes to `is_available=false` and tried to enable the band rows — but band rows are created only by `CatalogSeed.seed!`, which never ran on prod after #1087. Its `update_all` matched 0 rows (silent no-op). The prod-parity DB has **629 metric_definitions rows and 0 band rows**. Every model fitted since — including the entire 2026-06-12 B₀ board — trained with no box-office features, raw or banded. The #1087 clean-holdout wins (ss_critics 0.04→0.16, tspdt 0.076→0.121, criterion 0.156→0.188, …) are not in the baseline.

### 1.4 `person_quality_score` is a canon leak inside the objective bucket [VERIFIED]
`person_quality_score.ex`: canonical-list membership (1001/criterion/NFR/ss_critics) is weighted ×10 — the second-highest per-unit weight — counted across **all** of a person's films **including the target film itself**, with no time cutoff and `calculated_at = now`. `canon_overlap_codes` does not strip it. Every "objective" model carries it; the objective grades on the 4 counted lists are partially circular and temporally leaky. (Effect size unmeasured — the log-normalization may dampen it — but it must be measured, not assumed.)

### 1.5 The people/credits channel is half-empty, with member-skew [VERIFIED]
18.6% of canon films (673/3,615) have **zero `movie_credits` rows**; 45.7% of 1001_movies members lack any Directing credit (1950s: 34% coverage; 1990s: 91%) — the raw `tmdb_data` blobs contain the credits, they were never materialized. Downstream: PQS/auteur/collab features are zeroed exactly where the lists live, and the Phase C export is 55% director-less (83% of its 2010s rows), with sharp member/non-member asymmetry (director present: members 58% vs exported negatives 12%).

### 1.6 The award surface is broken in three places [VERIFIED]
- `oscar_wins` (1,375) / `oscar_nominations` (5,203) are catalogued `normalization_type='custom'`, which `trainer.ex:1599` rejects — **Oscar signal never enters any model** except diluted inside `festival_prestige` (where one win saturates the cap), while NHIFF (85 noms) has dedicated boolean features.
- `cannes_palme_dor` / `berlin_golden_bear` are permanently dead: the view CASE keys on `CANNES`/`BERLINALE`; the orgs are `CFF`/`BIFF`.
- `venice_golden_lion` matches `VIFF` and fires on **all** 2,295 Venice wins of any category (~28× the actual Golden Lions).

### 1.7 Smaller verified/strong items
- Pool asymmetry: ~34% of the 2010s eval pool (75k films) has NULL imdb_id and is structurally unable to ever be labeled positive (all 10 lists match by IMDb id); ~32% is sub-40-minute shorts. A symmetric observability+feature-length gate shrinks 223,670 → 90,578 (2.5× base-rate lift) **losing zero 1001 members**.
- `letterboxd_top_250` holds 280 positives for a 250-slot list — 12% stale ex-members graded as positives (critic finding).
- `HistoricalValidator` silently drops pre-1920 decades — 73 NFR members (8%) can never appear in any split, while the real NFR actively inducts early cinema.
- `bfi_top_100` is catalogued, available, and *not* in `canon_overlap_codes` — a dormant objective-bucket leak that activates the day the BFI list is imported.
- The temporal save path's negative undersampling never seeds `:rand` — committed model weights are not reproducible.
- B₀ provenance: `b0_2026_06_12.json`, the Phase 0 report, the export task, and the export itself are **untracked files**; the prior season's experiment ledger did not survive the prod pull. The "frozen baseline" is currently uncommitted bytes on one laptop.

---

## Part 2 — Verified formulation problems: for most lists, the task measures a fiction

### 2.1 No addition-event ground truth exists [VERIFIED]
The DB records only current-union membership with scrape timestamps. No edition diffs, no NFR induction years (`scraped_year` is the *release* year), 1001 = 1,257 films (all-editions union, including removed films) all stamped edition "2024". **"Predict the next edition's additions" — the actual product goal — currently has no training labels and no evaluation events for any list.**

### 2.2 Five lists have no future addition event of the modeled kind [VERIFIED]
afi_100 (one-off 1998; the 2007 revision isn't even in the DB), ebert (author died 2013), cult_movies_400 (static), both Sight & Sound polls (next event 2032). Their "temporal" B₀ numbers are leave-period-out **reconstruction** (AFI: trained pre-1960, scored on its 1960s–80s members) presented on the same "prediction trust" board as real forecasts. Nothing in the live code distinguishes the two.

### 2.3 Release-decade holdouts can't see retrospective additions
NFR inducts 25/year, mostly decades-old films; Criterion's slate is restorations; TSPDT/S&S re-canonize older films. A holdout of "films *released* in the latest decade" measures none of this — the dominant real addition mode for 4 lists is structurally invisible.

### 2.4 Temporal label censoring biases the honest number downward [VERIFIED]
Future members are counted as training negatives and as evaluation misses. The 1001 2020s pool contains ~20% films released after the 2024 edition's cutoff (impossible negatives occupying top-K slots); NFR's holdout decades are labeled at roughly half their steady-state induction rate. The objective recall on the worst-graded lists is biased **down** by an unknown but plausibly large amount. (The companion SAR-PU claim was [REFUTED]: the PU diagnostic itself concluded Elkan–Noto roughly holds; propensity weighting is a cheap experiment, not a established fix.)

### 2.5 The sacred-holdout endgame is broken in both directions
- Temporal sacred = single latest decade with **<10 positives for 7/10 lists** (tspdt/ebert/cult = 1 each, ssd 3, ssc 4, nfr 5, afi 8) → the n_pos<10 cap forces INSUFFICIENT regardless of model quality. [VERIFIED counts]
- The original claim "promotion is therefore impossible" was [REFUTED] — `promote` routes underpowered lists to the static instrument — **but the critic then found the rescue is hollow: the static "sacred" holdout is the same deterministic seed-1337 25% member split that every matrix run all season has scored.** It is informationally spent; spending it as a "one-shot confirmation" would be an adaptive re-measurement dressed as a one-shot, with no forbidden command ever run.
- Net: **holding the holdouts (the Phase 0 decision) was right, but the planned "promote once after Phase C" endgame cannot deliver honest grades for most lists without redesigning the instrument first.**

### 2.6 Power analysis: what MOD/HIGH actually require [VERIFIED]
At B₀ validation-tier n_pos, MOD (Wilson LB ≥ 0.30) needs point recall 0.386–0.485; HIGH (LB ≥ 0.50) needs **0.596–0.697**. At p̂=0.5, HIGH is unreachable at *any* n; at p̂=0.6 it needs n ≥ 97 (only 1001 qualifies today). The validation n_pos itself is an arbitrary config floor (`min_val_positives=30`) that grades tspdt on 33 of 992 members while no walk-forward/rolling-origin machinery exists to use the rest. **The north star (≥25% HIGH) is not achievable under the current evaluation design at currently observed recalls — by arithmetic, before any modeling question.**

---

## Part 3 — The Phase B/C content plan: right bet, broken execution [all four core findings VERIFIED]

1. **Coverage circularity (would have manufactured a false win):** the 4,952-film export covers 100% of members and ~0.4% of the honest eval pool (pre-1990 strata: 2,597 members vs 25 negatives). Features present only there become membership-presence indicators at full-pool eval — the vote-gated-negatives trap, rediscovered, landing directly in the objective bucket.
2. **Model-memory leakage with zero designed mitigation:** title+year alone identifies the film; the median synopsis is ~39 words of plot with no formal/stylistic content, so informative `auteur_signature`/`formal_ambition` scores must come disproportionately from the model's memorized critical consensus — informative mainly for famous (member) films, inflating every backtest and degrading on genuinely-future films (the deployment case).
3. **Input quality below the judgments requested, asymmetrically:** 55% no director, 57% no genres, 25% no cast, 41% of overviews <200 chars — and the gaps are class-correlated (substrate gap from §1.5, not an export bug).
4. **Scope drift + a keep gate below the noise floor:** the staged artifact contradicts the issue's own pre-registered tier ("members + candidate universe + eval-decade pool, $300–1.5k" vs 4,952 films/$30, silently re-baselined); the +1pt-on-≥2-lists keep gate is below the recall quantum (1/n_pos = 0.9–3.0pt) and far inside the ±4–8pt noise band — a pure-noise feature has a high chance of passing — while the issue-level win condition needs +22–27pt. Gate and goal are mismatched by an order of magnitude.
5. **The $0 measurement was skipped:** hashed TF-IDF text features (txt_000–511) are fully wired with ~86% pool coverage, and have never been gated on recall@K. Phases B and C are being priced without knowing whether the content channel moves the honest metric at all.

---

## Part 4 — What the research scan adds (grade: our approach B vs SOTA)

- **Two-stage retrieve-then-rerank** is the standard architecture for 1e-4 base-rate ranking at 1M scale. Because Cinegraph scores offline in batch, the linear-serving constraint is not real: an arbitrarily expensive reranker (GBT/embeddings/LLM) on a 5–50k shortlist can be stacked as one feature on the linear bus or distilled into it. The EXGBoost kill tested a tree as a *full-pool single-stage* model — the wrong role.
- **Hierarchical partial pooling** (shrinkage toward a cross-list or cluster mean) is the textbook answer for 10 related tasks at n_pos 33–114 and was never tried; the E4 kill was naive complete pooling, through the broken clamp (§1.2).
- **Rolling-origin pooled evaluation** is the standard remedy for tiny-n temporal grading: pool binomial counts across strictly-prior-trained origins before the Wilson bound. (Caveat from verification: pooling raises *power*, not point estimates — lists with recall < 0.30 stay LOW; and it must not be applied to closed lists, see contradictions.)
- **Collaborator-network prestige** (Fraiberger et al., *Science* 2018: network centrality predicts art-world success) is the strongest published non-circular analog feature class; computable from existing credits tables, must be time-sliced.
- **Award-prediction literature** is dominated by precursor-award features (our circular bucket, correctly stripped) — confirming that some of the canon is intrinsically hard to predict from objective signal, and a tranche (sleeping beauties) is unpredictable in principle. Expectations should stay calibrated.

---

## Part 5 — The roadmap to MOD/HIGH

### Step 1 — One bundled, pre-registered **B1 freeze** (integrity corrections; days)
The critic's bundling rule is binding: sequential fixes let us stop at the most favorable intermediate board (band reseed raises it, PQS quarantine lowers it). So: log directional predictions per fix first, apply **all** of them, mint **B1** (B₀ archived, never overwritten, both committed to git), publish no grade from any partial combination.
1. Exact (unrounded, unclamped) scoring in the eval path + seeded tie randomization.
2. `CatalogSeed.seed!` — restore the 66 band rows (dev *and* prod).
3. Quarantine `person_quality_score` from objective_only (rebuild canon-free/time-safe later); derive `canon_overlap_codes` from the catalog (closes the bfi hole).
4. Admit Oscar codes; fix CANNES/BERLINALE/Venice mappings.
5. Grade taxonomy: split **NO_LIFT** from **INSUFFICIENT**; replace the 1.5× point-estimate gate with an uncertainty-aware lift test. Export the binding cap reason on every board row.
6. Symmetric eligibility charters per list (imdb-observability; feature-length where the list never includes shorts) — derived from external list rules, frozen before any recomputation (never tuned while watching gate margins).
7. Label hygiene: letterboxd 280→250; seed the undersampling draw; archive ledger snapshots with reports.

*Expected B1 board (directional, logged here as the prereg requires): 1001 → MODERATE (gate fix alone); tspdt +3pp (exact scoring, measured) +bands (+3–12pp per the #1087 clean holdout, re-verify under fixed eval); criterion/ss_critics/ebert/cult + bands; PQS removal pulls 1001/criterion/NFR/ss_critics down by an unmeasured amount; eligibility gates add modest points everywhere. Net: plausibly 2–4 lists MOD, honestly labeled.*

### Step 2 — Re-open the falsely-killed model levers on the fixed eval (days; holdout-free)
- `:signed`/unnormalized extraction (already ties/beats simplex in controlled reruns).
- Hierarchical shrinkage across lists (target: the n_pos≤50 lists — cult, ssc, tspdt, letterboxd).
- Two-stage: linear bus as retriever → offline reranker on top-K shortlist (hard negatives = the canon look-alikes the PU diagnostic identified) → reranker score stacked as one bus feature. This is the highest-upside modeling lever remaining.
- One joint pre-registered family for the label machinery: undersampling ratio × full-pool/hard-negative training × censoring-aware masking of recent eligible cohorts (they interact; attribution requires joint design).

### Step 3 — Fix the formulation (1–2 weeks; the D+ → B move)
1. **Build `list_membership_events`**: NFR induction years (public record), 1001 edition diffs (published), TSPDT annual archives, Criterion spine/release dates. Converts "predict additions" from unmeasurable to measurable on ~5 lists; NFR alone yields ~25 labeled positives/year.
2. **Split the board**: forward-prediction lists (1001, NFR, criterion, tspdt, letterboxd) vs **reconstruction benchmarks** (afi, ebert, cult, S&S-until-2032), explicitly labeled. The north-star denominator becomes lists where the grade means something.
3. **Next-cohort evaluation** with per-list eligibility frontiers; rolling-origin pooled grading for power — on real-event lists only.
4. Delete the pre-1920 filter; stop labeling post-frontier films as negatives.

### Step 4 — Content channel, redesigned (the surviving #1113 bet)
1. **First, the $0 gate**: run TF-IDF text features through `eval_features` → matrix on the fixed eval. If text moves recall@K on criterion/tspdt, B/C have a real baseline; if not, recalibrate the whole bet before spending.
2. **Fix the substrate symmetrically**: materialize credits from `tmdb_data` blobs and fetch OMDb full plots for members *and* eval-decade pools alike (coverage parity reported as a gate — asymmetric backfill recreates the circularity one level down).
3. **Memorization audit before any feature spend** (~$10–20 on the existing export): direct membership-recovery probe (can the model name canon status from title+year?) + blinded-vs-unblinded arms on famous/obscure matched pairs. LLM features default to the **canon_overlap** bucket unless the blinded audit clears them.
4. **Coverage must be label-blind**: extraction scope = a frozen, pre-registered retriever score (or full pool), never a member-enriched set. Re-spec the keep gate to clear the noise band (pooled across rolling origins, threshold ≥ the refit-variance envelope).

### Step 5 — The prospective pivot (the critic's top reframe — adopt it)
The scarcest resource is uncontaminated evaluation information; the only inexhaustible, leakage-proof source is **the future**. Before Phase C: freeze and publish (commit hash + ledger row) top-K forecasts for every list with a real upcoming event — **NFR December 2026** (first scoring event, ~6 months out), TSPDT's annual re-rank, Letterboxd's rolling 250, Criterion's monthly slate, the next 1001 edition — and grade on what is actually added. One move simultaneously: dissolves LLM pretraining leakage (post-cutoff additions can't be memorized), escapes the spent static holdout and the over-fingered validation tier, makes the closed-list fiction moot, legitimizes cross-list membership as observable-at-forecast-time signal (Criterion membership IS honest signal for NFR induction — the permanent objective-only ratchet conflates "circular with the target" with "uses any canon information"), and converts cinegraph.org's honesty claim into externally verifiable prediction — which is the product's actual promise. Power accrues every cycle; the north star becomes reachable by *waiting and being right* instead of re-engineering the scoreboard.

### Honest end-state expectations
- **MOD on ≥50% of forward-prediction lists: realistic** after Steps 1–3 (1001 near-immediately; afi already there as a labeled reconstruction; NFR/tspdt/criterion via bands + model levers + censoring-corrected cohort eval).
- **HIGH on ≥25%: only via pooled/prospective power.** HIGH needs LB ≥ 0.50, i.e. point recall ≥ ~0.56 at pooled n ≥ 300. Rolling-origin pooling plus accruing addition-cohorts make that *mathematically* reachable; whether recall gets there is the real remaining bet, and the content channel + reranker are the only identified paths. A documented "this list caps at MOD" remains an acceptable honest outcome — saying so is the product.

---

## Part 6 — Protocol guardrails for executing this (from the completeness critic)
1. **Bundle or nothing**: all integrity fixes in one versioned B1 freeze with directional predictions logged first; cross-version grade comparisons forbidden.
2. **The static sacred holdout is spent.** Mint fresh-seed member splits (never touched by any ledger row) or use prospective events for any confirmation spend.
3. **The validation tier is an unmetered adaptive budget** (a full season + these audits all scored the same 2010s/seed-1337 slice). Treat fixed-eval reruns as exploratory; confirmations need fresh splits or future data.
4. **Eligibility charters from external list rules only**, frozen before recomputation — the 1001 lift gate (1.43 vs 1.50) can be flipped by pool pruning; never tune while watching the margin.
5. **Backfills must be coverage-symmetric** (member-targeted enrichment = circularity one level down).
6. **Commit the artifacts.** B₀/B1 json, reports, export task, and export are currently untracked; the append-only ledger didn't survive the prod pull. The honesty protocol is presently enforced by uncommitted files on one laptop.
7. **Serving divergence**: the public /algorithms page currently shows objective chips including PQS (verified contaminated), prediction-labeled grades for frozen lists, and prod models whose feature codes the trainer can no longer reproduce (serving has no `is_available` filtering). The catalog reseed will silently change served public scores — plan the prod transition deliberately, not as a side effect.
