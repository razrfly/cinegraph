# #1047 — Reality check: does the prediction engine actually work, or are we tricking ourselves?

**Status:** audit / deep-dive + staged execution plan (§5). The diagnosis (§1–4, §6) is the finding; §5 is how we act on it without trying to swallow it in one PR.
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

The single most valuable next experiment is **the ablation harness** — Stage 1 of the plan in §5. It will tell us, in one number per list, how much of our accuracy is *real independent signal* versus *list overlap*. Until we run it, every headline % is unfalsified on the question that actually matters. **Start at §5 if you want the "what do we build" answer.**

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

The marketing hook is "we predict the 1001 list." The honest footnote today is "…mostly by checking whether it's already on 8 other best-films lists." We do not currently know how much **independent** predictive power exists from objective features (ratings, votes, box office, festival results, runtime, language). **We have never measured it.** (Fix: the ablation harness — §5 Stage 1.)

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

## 5. Staged execution plan

This issue is a **diagnosis + plan**, not a single PR. Below is the triage first (is anything actually broken?), then four stages in dependency order. Each stage is sized to be its own PR; do **not** implement them as one blob. Where another active issue already owns a piece, this plan defers to it rather than re-speccing it.

### Triage — the three questions, answered up front

> **Are there any big/major correctness problems?** **No.** Nothing is broken or producing wrong math. The integrity machinery is sound (§2), the train/serve symmetry holds (§1), and the leakage strips are verified. The "C+ on signal" is an *unproven-value* problem, not a *wrong-answer* problem.
>
> **Are there safety problems?** **One small one.** A failed model (`national_film_registry` id=11: recall 0, n=5, identity calibration) is still set **active**. Blast radius is low — `Reliability` already suppresses its headline on read and `predictions.candidates` suppresses the fake probability — but an `:insufficient` model should not silently be the active pointer. That's Stage 0.
>
> **Are there infrastructure problems?** **One real one, and it's already owned by #1045:** `metric_values_view` is a plain 4-way-UNION view recomputed on every train/eval pass. It is the binding constraint on the whole iteration loop, and #1047's core ask (run *many* ablations/sweeps) is gated by it. This plan does **not** re-spec materialization — it declares the dependency and asks #1045 to be the single speed plan (Stage 3).
>
> **Where do we start?** Stage 0 (minutes, safety + cleanup), then **Stage 1 is the real work** — the ablation harness. Stage 1 can run *once, slowly*, without waiting on #1045; #1045 is what turns it into a fast repeatable loop.

```
Stage 0  safety + cleanup        ─┐ (independent, do now)
Stage 1  measurement loop ◄───────┤ THE CORE TICKET. needs nothing but existing code.
Stage 2  honest disclosure ◄──────┘ consumes Stage 1's per-list deltas
Stage 3  sustained speed = #1045   (parallel; unblocks running Stage 1 at scale)
#1044  prior_collab_density        (parallel; feeds a new feature into Stage 1's buckets)
```

---

### Stage 0 — Triage & cleanup (quick wins, ~½ day, no dependencies)

The "is anything wrong right now" sweep. Small, safe, unblocks clean measurement.

- [ ] **Don't leave a failed model active.** Decide the policy: either refuse to set an `:insufficient` model as `active_prediction_model_id`, or keep the pointer but require the serving layer to treat `:insufficient` as "no prediction." `national_film_registry` (id=11) is the live offender.
- [ ] **Delete orphan model id=3** (`1001_movies`, superseded by id=6 — dead row).
- [ ] **Resolve `movie_lists.backtest_strategy`** — NULL on all 10 rows. Either backfill from the active model's strategy or drop the column; right now anything reading it gets `nil`.
- [ ] Log the edition-year disagreement (4 static lists) as a data-freshness task — investigate whether imported edition metadata is stale vs the newest member we hold. (Diagnose only; not a blocker.)

### Stage 1 — The measurement loop (THE core ticket; no new infra)

This is the work the whole audit points at. It answers "is the signal real?" with a number per list. `Trainer.run_experiment/2` already accepts an explicit code list via `resolve_codes/2` (`trainer.ex:153`), so this is feature-bucket plumbing + a report, not new ML.

**1.1 — Define and classify feature buckets.** Add a classifier so a run can select `:full`, `:objective_only`, or `:canon_overlap` (alongside the existing `all|raw|derived`). Proposed taxonomy (review the borderline rows before locking):

| Bucket | Codes |
|---|---|
| **canon_overlap** (the "already canonized" crutch) | `canonical_contribution`, `list_appearances`, every other list's membership boolean (the dynamic `list_codes`), `auteur_track_record` (counts the director's OTHER films *on the target list* → canon-derived) |
| **objective_only** (independent signal) | ratings (`imdb_rating`, `tmdb_rating`, `metacritic_metascore`, `rotten_tomatoes_tomatometer`), `imdb_rating_votes`, box office (`tmdb_budget`, `tmdb_revenue_worldwide`, `box_office_roi`), festival (`festival_prestige` + dynamic festival `*_win`/`*_nom` — juried, not canon-list), metadata (`runtime`, `original_language`, `production_country_count`, `has_official_trailer`, `collection_membership`, `release_year`), `person_quality_score` |
| **full** | objective_only ∪ canon_overlap (current behavior) |

Borderline calls to decide explicitly (not silently): `person_quality_score` (career quality — counted objective), `festival_prestige` (juried, but prestige correlates with canon — counted objective), and **`prior_collab_density` from #1044** (collaboration-network prestige — default objective *unless* we judge it canon-adjacent; this is the coordination point with #1044).

**1.2 — Expose the buckets in the CLI.** `predictions.experiment` currently only parses `all | raw | derived` (`predictions.experiment.ex:20`). Add `objective_only`, `canon_overlap`, and a `custom:code1,code2,...` form.

**1.3 — Add an ablation report.** A mode that runs `:full`, `:objective_only`, and `:canon_overlap` on the **same seed and split** and prints, per list: PR-AUC, recall@K, and lift for each bucket, plus the **`full − objective_only` delta**. That delta is the honest measure of independent signal. Interpretation rule, stated in advance: if `objective_only` still clears the lift gate, we have a real product; if it collapses to baseline, our headline is "we know which films are already famous," and Stage 2 must say so.

**1.4 — Run it once across all 10 lists and record the table** (in this issue or a results doc). Slow is fine — it's one-time and does not need Stage 3.

### Stage 2 — Honest disclosure (consumes Stage 1's output)

Once we know the real signal, stop the two ways the product would mislead a user (§4.1, §4.2):

- [ ] **Show baseline + lift next to every headline**, never the raw recall alone ("36% vs 0.01% popularity" reads very differently from "58% vs 39%").
- [ ] **Lead with lift (skill over baseline), not raw recall@K** — it is the only figure comparable across temporal vs static strategies. Surface the strategy + difficulty (base rate / universe size) so a static list isn't visually ranked against a temporal one as if equal.
- [ ] **Surface the objective-vs-full split** from Stage 1 so we never imply "we understand greatness" when the number is mostly "it's already on other lists."
- [ ] State structural limits in copy: temporal lists are confidence-capped by holdout size; "accuracy" is recall-at-K-against-this-universe, not per-film probability (only `:platt` models have the latter).

### Stage 3 — Sustained iteration speed (**owned by #1045 — do not duplicate here**)

Stage 1 proves the signal once; making it a *fast repeatable loop* (many sweeps/ablations) needs the speed work. **The reframing matters: this workload does not need the M3's cores — it's 100% Postgres-IO-bound.** The logistic fit is tiny (≤~60 features × a few thousand undersampled rows; EXLA/Metal is overkill). So "use more cores" is the wrong optimization. The real levers, which **belong in #1045 as one speed plan, not two**:

1. **Materialize `metric_values_view`** (`priv/repo/migrations/20260602120700_complete_metric_values_view.exs`) + concurrent refresh — the single biggest speedup, and the prerequisite for running Stage 1 at scale.
2. **Commit the ephemeral PG tuning to VCS.** `work_mem`/`effective_cache_size`/`jit`/`shared_buffers` were set via `ALTER SYSTEM` and live *only in the running instance* — nothing in version control, `shared_buffers→16GB` restart still pending. One reinstall loses it.
3. **Set `config :nx, default_backend: EXLA.Backend` in prod** (set in dev/test, not prod) — one line, prevents a silent BinaryBackend fallback.
4. Raising `max_concurrency` (hardcoded 4 in `trainer.ex:235`, `weight_optimizer.ex:160/338/425`, ~25% core use) is **last** — given the IO-bound reality it matters far less than materialization. Only worth it after #1 lands.

---

## 6. So — does it work?

**Yes, the machinery works, and no, we are not tricking ourselves — *yet*.** The integrity scaffolding is genuinely excellent and is actively catching our own failures (two `:insufficient` grades prove it). The substrate is clean and the train/serve symmetry is real.

**But we have not yet proven the engine has independent predictive value.** We've proven it beats "rank by popularity" on 8/10 lists — which it does largely by exploiting the fact that prestige lists overlap. The honest grade for the *signal* is C+ until the Stage 1 ablation (§5) tells us what's left when we take the canon-overlap crutch away.

The two ways the *finished product* would most plausibly mislead a user are both fixable disclosure problems, not modeling bugs:
1. presenting temporal and static headline %s as if they're comparable (§4.1), and
2. implying our accuracy is "understanding what makes a film great" when it's mostly "this film is already on other lists" (§4.2).

Fix the disclosure, run the ablation, and this goes from "rigorous but unproven" to "rigorous and honest about exactly how good it is" — which was the entire marketing thesis (#1027: *"we tell you exactly how accurate we are"*). We're closer to living up to that than most teams ever get; the last mile is measuring and disclosing the circularity, not building more machinery.

---

## 7. How this coordinates with the active follow-ups

This issue is the **measurement + disclosure** layer; the other two open tickets are signal and speed. They are complementary, not competing:

- **#1044 (`prior_collab_density`)** — adds one more (independent-ish) signal to the feature surface. When it lands, classify it into Stage 1's buckets: **objective_only by default**, unless we decide collaboration-network prestige is canon-adjacent. It should be live before the "final" ablation so we measure the real surface.
- **#1045 (experiment speed)** — *is* Stage 3. Materialization + pinned universe + PG-tuning-to-VCS should be **one speed plan there**, not re-specced here. #1047's many-ablations recommendation is gated on it.
- **#1047 (this issue)** — proves whether the signal is real (Stage 1) and stops the product from misleading users (Stage 2). It does not add signal (#1044) or speed (#1045); it adds the missing *measurement loop and honest reporting*.

**Sequencing:** Stage 0 now → Stage 1 once (slow, no deps) to get the existential answer → Stage 2 to disclose it. #1044 and #1045 proceed in parallel; re-run Stage 1 fast (via #1045) once #1044's signal is in. Only then is the claim "these models are as good as we can currently make them, and here's exactly how good" actually defensible (the #1027 thesis).

### Checklist (by stage — kept in this issue; peel into PRs as you go, don't pre-spawn sub-issues)
- [ ] **Stage 0** — deactivate/guard insufficient models; delete model id=3; resolve `backtest_strategy` column; log edition-year freshness
- [ ] **Stage 1** — feature-bucket classifier (`objective_only`/`canon_overlap`/`custom`) → CLI → ablation report → one full run across 10 lists
- [ ] **Stage 2** — baseline+lift-forward, strategy/difficulty-aware, objective-vs-full disclosure in reliability/candidate output + copy
- [ ] **Stage 3** — defer to **#1045** (materialize view, commit PG tuning, prod Nx backend, then concurrency)
- [ ] **Coordinate** — #1044 feeds Stage 1's objective bucket; re-run the ablation once it lands
