# 1053 — Backfill OMDb completely, as fast as possible (and stop the gap from silently reopening)

**Goal:** drive OMDb coverage to *complete* across the eligible catalog — every movie with an IMDb ID reaches a **terminal state** (we have its stored OMDb response **or** a `fetch_attempt` source-absent marker) — and do it in days, not months. Then fix the root cause so the gap can't quietly re-open.

**TL;DR of the audit (prod, 2026-06-03):** the OMDb pipeline is **not broken and not throughput-limited.** Two distinct things are wrong:
1. **A materialization gap (~339k movies):** they were already fetched from OMDb — the raw blob sits in `movies.omdb_data` — but their derived `external_metrics` rows were never written (or only partially). The downstream app reads `external_metrics`, so they *look* missing while the bytes are on disk. **Closeable with zero API calls.**
2. **A genuine fetch backlog (~85k movies):** no blob at all, never fetched. **Needs API — <1 day at our demonstrated rate.**

> ⚠️ **Predicate correction (must read before implementing).** Everything below hinges on defining "terminal" correctly. `ExternalMetric.from_omdb/2` writes OMDb-derived rows under **four** sources — `imdb`, `metacritic`, `rotten_tomatoes`, **and** `omdb` (external_metric.ex:196+). A sparse OMDb response that only yields an `imdbRating` produces an `imdb` row and **no `source='omdb'` row at all** — and that's the *common* case (of the 339k blob-present movies, 156,330 have an `imdbRating` but only **290** have a `Metascore`). So **"has a `source='omdb'` row" is the wrong terminal test.** It is currently used in two places that this issue must fix (`BackfillOmdb` and `OMDb.should_skip_processing?`), and using it would (a) re-fetch ~339k movies we already have and (b) re-fetch IMDb-only movies forever. The correct terminal test keys on **"did we fetch & store a response"** (`omdb_data` present) **or** **"we tried and got nothing"** (`fetch_attempt`). See *Terminal-state predicate* below.

---

## Terminal-state predicate (define this first — it's load-bearing)

A movie's OMDb state is exactly one of:

| State | Definition | Action |
|---|---|---|
| **Fetched** | `omdb_data IS NOT NULL` (we stored OMDb's response) | Derive whatever metrics the blob supports, **idempotently**. No API. Done. |
| **Source-absent** | an `omdb` / `fetch_attempt` row within the 90-day cooldown | Tried; OMDb had nothing. Done (re-try after cooldown). |
| **Needs fetch** *(the only true backlog)* | `imdb_id` present **AND** `omdb_data IS NULL` **AND** no recent `fetch_attempt` | OMDb API call. |
| **Needs materialization** *(debt, not backlog)* | `omdb_data IS NOT NULL` but derivable rows are missing | Re-derive locally from the blob. **No API.** |

Key consequences:
- **Do not** decide "needs fetch" by the absence of a `source='omdb'` row. A valid response may legitimately produce only an `imdb`/`metacritic`/`rotten_tomatoes` row, or — for a truly sparse record — *no* row under any source. The blob's presence is the proof we fetched.
- "Materialization complete" is **not** "a `source='omdb'` row exists." It is measured **per metric** via the `backfill_from_jsonb --dry-run` parity report (source-field count vs `external_metrics` dest count), which already covers all five OMDb-derived metric families.

---

## Live production baseline (2026-06-03, via `ProdRpc`)

### Catalog
| metric | count |
|---|--:|
| Total movies | **1,161,694** |
| `import_status='full'` | 912,951 |
| `import_status='soft'` | 248,743 |
| **With `imdb_id` (OMDb-eligible)** | **654,217** |
| Without `imdb_id` (OMDb-*ineligible*, ~44%) | 507,477 |

OMDb requires an IMDb ID and has no fallback identifier, so the **507,477 movies with no `imdb_id` can never get OMDb data.** "Complete OMDb" is bounded to the **654,217 eligible** movies. (Recovering more IMDb IDs from TMDb — `ImdbIdRepairSweeper` — is a separate lever; see *Out of scope*.)

### Eligible movies by terminal state
| state | count | how measured | work |
|---|--:|---|---|
| **Needs fetch** (no blob, no `fetch_attempt`) | **84,660** | `imdb_id` ∧ `omdb_data IS NULL` ∧ no `omdb` row | **API** (~85k calls) |
| Source-absent (`fetch_attempt`, no real metrics) | 13,320 | `omdb`/`fetch_attempt` row | done |
| Fetched — blob present | **~556k** | `omdb_data IS NOT NULL` | done fetching; *some* need (re)materialization |
| — of those, has a `source='omdb'` row today | 217,068 | | already materialized (≥1 omdb-namespaced row) |
| — of those, blob present but **no** `source='omdb'` row | **339,169** | `Response=True`, no `omdb` row | **materialization debt** (no API) |

> The widely-quoted "423,829 backlog" = `84,660 + 339,169` — i.e. **"movies with no `source='omdb'` row."** That number conflates *needs-fetch* (85k) with *materialization-debt* (339k), and 339k of it is **not** fetch work. The true API backlog is **~85k**.

- Of the 339,169 materialization-debt movies: **156,330 carry an `imdbRating`** (→ an `imdb/rating_average` row on re-derive), only 290 carry a `Metascore`. Metascore/RT are genuinely sparse in OMDb — that's source-absence, not our bug, and exactly why many of these will never produce an `omdb`-namespaced row even when fully materialized.

### Canonical (prediction-relevant) movies are basically fine
| metric | count |
|---|--:|
| Canonical movies (`canonical_sources <> '{}'`) | 3,615 |
| …with a `source='omdb'` row | 3,395 (94%) |
| …with no `omdb` row | 219 (mostly materialization debt) |

So the prediction surface (#1051 Stage A2) is **not** materially gated by this — but completing OMDb removes a whole class of "missing data" confusion.

---

## Is the sweeper working? Is it slow?

**It's healthy, and fast when it fires — but materialization never happens and one predicate is wrong.**

- Oban `:omdb` queue: **315,084 completed, 0 retryable, 0 discarded, 0 available.** No stuck/failed jobs. No rate-limit wall.
- API success last 24h: **104,934 succeeded / 72 errored (99.93%)**, zero `rate_limit` errors → our OMDb plan ceiling is **≥~105k/day** (consistent with the Basic 100k/day plan, not hard-throttled).
- Daily completions, last 7 days: `105009, 47, 4, 0, 20, 104998, 105006` → it only **fires on ~3 of 7 days** (~45k/day effective), and when it fires it maxes out cleanly.

**What's actually wrong:**
1. **Materialization is never reconciled.** `RatingsRefreshWorker`'s fetch predicate (`omdb_data IS NULL` + 90-day cooldown) is *correct for deciding what to fetch* — there's almost nothing left to fetch (its visible fetch-backlog is ~43), so it correctly spends most of its budget on Phase B "stale refresh." Nothing, however, ever re-derives metrics from blobs that were stored but never materialized. That's the 339k.
2. **The root cause of the orphaned blobs:** `ApiProcessors.OMDb.store_omdb_data/2` (omdb.ex:142) commits the raw blob and the derived `external_metrics` in **two separate, un-transactioned steps**. Any error/crash/deploy between them leaves a committed blob with no metrics — precisely the 339k state. (#913 parity gap, re-opened.)
3. **A latent quota bug from the wrong predicate.** `OMDb.should_skip_processing?` (omdb.ex:103) skips only when `has_json AND exists(source='omdb' row)`. A blob whose response held only an `imdbRating` has no `omdb` row, so the guard never trips → it **re-fetches that movie from the API every pass, forever.** `BackfillOmdb`'s selection query (backfill_omdb.ex:64) shares the same `source='omdb'` predicate, so it keeps re-enqueuing those movies. Today this is capped at 5k/day; **it becomes a real waste the moment we raise the cap for Phase 2** (it would re-download the 339k instead of fetching the 85k).

---

## Plan — fastest path to complete

### Phase 1 — Materialize from existing blobs (no API, hours) 🟢 biggest win
Use the existing, idempotent tool — **do not write a new path**:

```bash
mix cinegraph.metrics.backfill_from_jsonb --source=omdb --dry-run   # per-metric parity report
mix cinegraph.metrics.backfill_from_jsonb --source=omdb             # enqueues DataRepairWorker on :maintenance
```

Re-runs `ExternalMetric.from_omdb/2` against every movie with a populated `omdb_data` blob and inserts missing rows (skips existing via the `(movie_id, source, metric_type)` unique index). **Zero OMDb quota.** Closes the entire 339k materialization debt — but note **success is measured by the per-metric parity gaps reaching 0, not by a `source='omdb'`-row count** (many of these blobs legitimately materialize only an `imdb` row).

> Prod invocation goes through `bin/cinegraph eval` / `DataRepairWorker.start_external_metrics_backfill(:omdb, ...)` on the `:maintenance` queue.

### Phase 2 — Fetch the ~85k genuinely-missing (API, <1 day)
These have no blob; they need a real OMDb call. At the **demonstrated ~100k/day clean throughput**, the remainder fits in **one day's quota**.

- **Hard prerequisite:** the predicate fix (Phase 4.1) and the snooze fix (Phase 4.2) must be deployed **first**. Without 4.1, `BackfillOmdb` at a raised cap selects the 339k blob-present movies (wrong) and re-downloads data we already have; without 4.2, an over-enqueue past the daily ceiling discards jobs.
- Then: raise `OmdbBackfillSweeper @per_run_limit` 5,000 → 100,000 for the duration, **or** one-shot `Cinegraph.Maintenance.BackfillOmdb.run(limit: 100_000)` (with 4.1's corrected predicate, this now targets exactly the ~85k needs-fetch set).

### Phase 3 — Verify completion
`mix cinegraph.metrics.backfill_from_jsonb --source=omdb --dry-run` exits 0 when all per-metric gaps are closed; plus the verification queries below. Target end state:
- materialization debt = 0 (all dry-run gaps 0);
- needs-fetch ≈ 0 (remainder became `fetch_attempt`);
- every eligible movie is **fetched (blob present) or source-absent (`fetch_attempt`)** ≈ 654,217.

### Phase 4 — Durability fixes (so it never silently reopens)

**4.0 is the root cause; 4.1 fixes the wrong predicate at every site; 4.2 makes the push safe; 4.3 monitors.**

0. **🔴 Make the blob+metrics write atomic.** Wrap `OMDb.store_omdb_data/2` (omdb.ex:142) — the `update_movie` (blob) + `Metrics.store_omdb_metrics` (rows) pair — in a single `Repo.transaction/1` so they commit together or not at all. Stops new orphaned blobs at the source. Without it, Phases 1–3 are a cleanup the non-atomic write slowly re-dirties.
1. **🔴 Fix the terminal predicate everywhere it's wrong.**
   - **`OMDb.should_skip_processing?`** (omdb.ex:103): skip when `omdb_data` is present (we already fetched) unless `force_refresh`. **Drop the `exists(source='omdb')` gate** — it causes infinite re-fetch of IMDb-only responses.
   - **`BackfillOmdb`** (backfill_omdb.ex:54-64): change the selection predicate from *"no `source='omdb'` row"* to the **needs-fetch** predicate — `imdb_id` present ∧ `omdb_data IS NULL` ∧ no recent `fetch_attempt`. Now it targets the real ~85k, not the 339k.
   - **Do NOT** repoint `RatingsRefreshWorker`'s fetch predicate at `external_metrics` — its `omdb_data IS NULL` + cooldown is already the correct *fetch* test; widening it would mass re-fetch the 339k.
2. **Snooze, don't discard, on quota exhaustion.** The OMDb client returns the *string* `"Request limit reached!"`, which currently falls through `OMDbEnrichmentWorker` to `{:error, reason}` → retried → **discarded**. Map it (in `ApiProcessors.OMDb` or the worker) to `{:snooze, 3600}`. Prerequisite for safely enqueuing the whole backlog at once.
3. **Parity watchdog (required, cheap).** A `Health.Drift` check that runs the per-metric source-vs-dest parity (the dry-run logic) and flags when any gap grows. Surfaces a re-opening orphan problem before it becomes the next 339k.

**Why this fixes the long term:** 4.0 removes the only known cause of orphaned blobs at the source; 4.1's predicate fix stops the quota waste and the infinite re-fetch; 4.3 detects any regression. If orphans ever *do* reappear, the fix is already a one-liner — re-run Phase 1's `backfill_from_jsonb --source=omdb` (no API). We deliberately **do not** add an always-on auto-healer (see *Deferred*): prevention + detection + a one-command manual fix is sufficient, and keeping a human in the loop preserves the signal about *why* orphans recurred instead of silently masking an upstream regression.

---

## Execution / rollout sequence (code vs ops)

Part **code** (merge + deploy), part **ops** (prod commands after deploy). Order matters — Phase 2 depends on 4.1 **and** 4.2 being live.

### A. Code — implement → merge → deploy (one PR)
1. **4.0** — atomic blob+metrics write (`Repo.transaction`).
2. **4.1** — predicate fix in `should_skip_processing?` + `BackfillOmdb`. *(Leave `RatingsRefreshWorker`'s fetch predicate alone; no new sweeper.)*
3. **4.2** — snooze on `"Request limit reached!"`. *(prerequisite for Phase 2)*
4. **4.3** — parity watchdog.
5. *(optional)* raise `OmdbBackfillSweeper @per_run_limit` 5,000 → 100,000 — or drive Phase 2 with the one-shot eval.
6. **Tests** (see *Acceptance & tests*) green in CI.

→ **Then: merge → deploy to prod via Kamal.** *(You own all git/deploy; nothing here runs git for you.)*

### B. Ops — run in prod after deploy (existing tools, via `kamal app exec` / `bin/cinegraph eval`)
7. **Baseline** — run the verification queries + `--dry-run`; record the starting numbers.
8. **Phase 1 — materialize (no API):** `backfill_from_jsonb --source=omdb` → closes the 339k debt in hours, zero quota.
9. **Phase 2 — fetch (API):** `BackfillOmdb.run(limit: 100_000)` → drains the ~85k (now correctly targeted by 4.1, safely snoozable by 4.2).
10. **Phase 3 — verify:** `backfill_from_jsonb --source=omdb --dry-run` → exit 0; queries below at target.
11. **Soak 24h**, re-measure, repeat 9–10 for stragglers / newly-imported movies.
12. **Revert** the sweeper cap to 5,000/day once needs-fetch ≈ 0.

> Phase 1 & verify use tools **already in production**, so they *could* run pre-deploy to materialize early — but the clean path is **deploy-first**, so every fetch lands in the corrected (atomic, right-predicate, snooze-safe) pipeline. Do **not** run Phase 2 pre-deploy: the old predicate would re-download the 339k.

## Expectations & the soak/iterate loop

Realistically **~1–2 days of real work**; budget a week for soak + edge cases.

| When | Action | Expected state afterward |
|---|---|---|
| **Day 0** (deploy + kick off) | Deploy code (4.0–4.3). Baseline, then Phase 1, then first Phase-2 batch. | Materialization debt 339k → ~0 within hours; per-metric dry-run gaps collapse. API begins chipping the ~85k. |
| **Day 1** | Re-measure. | Materialization complete. Needs-fetch ≈ 0 (85k < one day's 100k quota). **Most of the job done.** |
| **Days 2–4** | Mop-up + soak. Confirm `--dry-run` green; watch new imports. | Remainder = genuine source-absent (`fetch_attempt`) + churn. |
| **Days 5–7** | Lock in. Revert cap to 5k/day. Confirm watchdog stays green. | OMDb "complete"; durability fixes prevent recurrence. |

**Honest definition of "done":** of the 654,217 eligible movies, every one is fetched (blob present, metrics materialized to the extent the response allows) or marked `fetch_attempt`. The ~507k without an IMDb ID stay OMDb-ineligible — a separate IMDb-ID-recovery problem.

---

## Recovery scorecard — before → after (how we prove it worked)

Recovery must be *measured*. Capture the **before** snapshot (step B-7) immediately before kicking off; re-run after each phase.

| Metric (eligible = `imdb_id` present) | **Before** (2026-06-03) | After Phase 1 (materialize, no API) | After Phase 2 (API) — target |
|---|--:|--:|--:|
| **Needs-fetch** (no blob, no `fetch_attempt`) | **84,660** | 84,660 | **~0** |
| Materialization debt (blob present, derivable rows missing) | **339,169**\* | **0** | 0 |
| `imdb/rating_average` rows (`--dry-run` dest) | baseline | **+~156,330** | + new fetches |
| Movies with a `source='omdb'` row | 217,068 | rises (Awards/Rated/BoxOffice/RT blobs) | + new fetches |
| `fetch_attempt` (source-absent) | 13,320 | 13,320 | ~14k–85k† |
| Eligible reaching terminal (blob **or** `fetch_attempt`) | ~569,557 | ~569,557 | **≈ 654,217** |

\* Proxy = "blob present, no `source='omdb'` row." The *precise* debt is the sum of per-metric dry-run gaps; track that, not the proxy.
† The needs-fetch ~85k are ultra-long-tail (only ~456 of the no-omdb-row set have ≥100 TMDb votes), so a **meaningfully higher share returns "Movie not found!"** than the 99.93% we saw on popular titles. Expected — they become terminal `fetch_attempt`, not backlog.

### The pass/fail gate (the invariant that proves recovery)
Done-ness is **zero movies left unresolved** (un-fetched *and* un-materialized) — independent of the data-vs-absent split:

```
materialization:  `backfill_from_jsonb --source=omdb --dry-run` exits 0   (all per-metric gaps == 0)
AND needs_fetch:  count(imdb_id ∧ omdb_data IS NULL ∧ no recent fetch_attempt) ≈ 0
AND terminal:     count(blob present OR omdb/fetch_attempt) ≈ 654,217
```

If a later check shows the materialization gap **>0 and rising**, the atomic write (4.0) regressed or another path is orphaning blobs — that's the watchdog's (4.3) job to catch.

## Verification queries (re-run each morning)

Run via `ProdRpc.eval_json` / `bin/cinegraph eval`. **These use the corrected terminal predicate** (blob / fetch_attempt), not `source='omdb'` presence:

```sql
-- True fetch backlog vs materialization debt
SELECT
  count(*) FILTER (
    WHERE m.omdb_data IS NULL
      AND NOT EXISTS (SELECT 1 FROM external_metrics em
                      WHERE em.movie_id=m.id AND em.source='omdb' AND em.metric_type='fetch_attempt')
  ) AS needs_fetch,
  count(*) FILTER (WHERE m.omdb_data IS NOT NULL) AS fetched_blob_present
FROM movies m
WHERE m.imdb_id IS NOT NULL AND m.imdb_id <> '';

-- Terminal coverage (should approach 654,217)
SELECT count(*) FROM movies m
WHERE m.imdb_id IS NOT NULL AND m.imdb_id <> ''
  AND (m.omdb_data IS NOT NULL
       OR EXISTS (SELECT 1 FROM external_metrics em
                  WHERE em.movie_id=m.id AND em.source='omdb' AND em.metric_type='fetch_attempt'));
```

Materialization debt is authoritatively the `--dry-run` per-metric gap table.

---

## Acceptance & tests (tighten before merge)

The fixes are predicate-sensitive, so each gets a test:

- **`from_omdb/2` — sparse response.** A blob with only `imdbRating` (no Awards/Rated/BoxOffice/RT/Metascore) yields exactly one `imdb/rating_average` row and **no `source='omdb'` row** — and is classified **fetched/terminal**, not backlog.
- **Atomic write (4.0).** Stub `Metrics.store_omdb_metrics` to fail → assert `omdb_data` is **not** committed (transaction rolled back), so no orphaned blob is created.
- **Skip guard (4.1).** Movie with `omdb_data` present + only `imdb` rows → `should_skip_processing?` returns true (no API call). With `force_refresh: true` → false.
- **`BackfillOmdb` predicate (4.1).** Blob-present-IMDb-only movie is **not** enqueued; blob-null no-`fetch_attempt` movie **is**; movie within `fetch_attempt` cooldown is not.
- **Snooze (4.2).** OMDb client returns `"Request limit reached!"` → worker returns `{:snooze, _}`, job not discarded.
- **Watchdog (4.3).** Synthetic orphan → parity check reports a non-zero gap.

**Exit gate:** all tests green; `mix format`; on prod the invariant above holds and `--dry-run` exits 0.

---

## Risks & safety
- **Wrong predicate wastes the whole push.** If Phase 4.1 isn't deployed before Phase 2, raising the cap makes `BackfillOmdb` re-download the 339k blob-present movies instead of fetching the 85k. **4.1 is a hard gate on Phase 2.**
- **Over-enqueue burns jobs.** Until 4.2 ships, don't dump >~100k API jobs at once — excess discards. Phase 1 (no API) is risk-free here.
- **Shared, untuned Postgres** (16GB Mac Mini, no pooler — see project memory). The reconcile/`DataRepairWorker` batches at 200 with a 500ms throttle on `:maintenance` (concurrency 1); keep it there. Avoid heavy verification counts during the 5:30–7:30 UTC sweeper window.
- **`load_in_query: false`** — `omdb_data`/`tmdb_data` are excluded from default queries; the materialization task and `ApiProcessors.OMDb` already `select_merge` them. Any new query touching the blob must opt in (CLAUDE.md §1).

## Deferred (build only if the trigger fires)
- **Always-on materialization reconcile sweeper.** A recurring `:maintenance` job that auto-re-derives orphaned blobs (no API). **Not built now** — 4.0 prevents new orphans, 4.3 detects regressions, and the fix is already a one-command re-run of Phase 1. **Trigger to build it:** the 4.3 watchdog shows orphans recurring from a path 4.0 doesn't cover *and* manual re-runs become frequent enough to be a chore. Until then it's speculative machinery that would also mask the "why did this recur" signal.

## Out of scope (note, don't do here)
- **IMDb-ID recovery** for the 507,477 ineligible movies (`ImdbIdRepairSweeper`, TMDb→IMDb). Would *grow* the eligible set; track separately.
- **TMDb budget/revenue** densification (#1051 Stage A2) — same `backfill_from_jsonb --source=tmdb` machinery, different ticket.

---

*Audit performed live against production 2026-06-03 via `Cinegraph.ProdRpc`. All counts are prod. Root cause: **non-atomic blob+metrics write** in `OMDb.store_omdb_data/2` (omdb.ex:142) orphans blobs (#913 reopened); compounded by a **`source='omdb'`-row terminal predicate** in `should_skip_processing?` (omdb.ex:103) and `BackfillOmdb` (backfill_omdb.ex:64) that misclassifies IMDb-only responses as never-fetched. Fix: atomic write (4.0) + correct terminal predicate / local reconcile (4.1) + snooze (4.2) + parity watchdog (4.3).*
