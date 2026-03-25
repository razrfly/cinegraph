# Six-Lens Master Plan — Definitive Architecture & Work Queue

**Supersedes:** #664 (original audit), #668 (taxonomy audit)
**Incorporates findings from:** #662, #665 (closed A+), #667, #670
**Date:** 2026-03-25
**Status:** Active — definitive reference for lens work

---

## The Decision: Six Lenses, Final Names

After the full audit chain (#664 → #668 → taxonomy discussion), we have a stable answer.

Six lenses. Same names in both systems. No seventh lens — the "Canonical Consensus" concept
belongs inside **The Time Machine**, not beside it.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  LENS              EMOJI  WHAT IT MEASURES                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│  The Mob             🔥   General audience consensus                        │
│  The Ivory Tower     🎭   Professional critic consensus                     │
│  The Inner Circle    🏆   Festival & awards circuit recognition             │
│  The Time Machine    ⏳   Canonical list presence — curatorial consensus    │
│                           that has persisted across time and institutions   │
│  The Auteurs         🎬   Talent quality — cast, crew, directors           │
│  The Box Office      💵   Commercial performance & cultural reach           │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Why The Time Machine is the right name for lens 4:**
It captures the "passed the test of time" nature of canonical list presence. A film on
Criterion, Sight & Sound, the 1001 Movies list, and the National Film Registry wasn't just
popular — it kept mattering. The name also visually distinguishes it from The Inner Circle
(institutional in the moment) vs. The Time Machine (institutional across decades).

---

## What Lives Under Each Lens

### 🔥 The Mob — Audience Voice

```
UMBRELLA: What did the general public think?

Display sources:
  ● IMDb rating        (0–10)    ~95% coverage    primary
  ● TMDb rating        (0–10)    ~90% coverage    secondary
  ● RT Audience Score  (0–100)   ~40% coverage    tertiary, sparse

Predictions sources (same, minus RT Audience until coverage confirmed):
  ● IMDb rating        (0–10)    ~95%
  ● TMDb rating        (0–10)    ~90%

Algorithm: null-aware average of available sources
Missing data: nil (not 0.0) — a film with no audience data is unknown, not hated
```

**Current grade: A-** | **Target: A**
One fix needed: return `nil` not `0.0` when no sources present (ML correctness).

---

### 🎭 The Ivory Tower — Critical Consensus

```
UMBRELLA: What did professional critics think?

Sources (same in both systems):
  ● RT Tomatometer    (0–100)   ~92% coverage    binary fresh/rotten aggregation
  ● Metacritic        (0–100)   ~35% coverage    weighted critic average

Algorithm: null-aware average, normalized to 0–10 (display) / 0–100 (predictions)
  Both sources absent → nil (not 0.0)
  One source absent → single-source score (documented, not penalized)

Missing data: nil (not 0.0) when both sources absent
Coverage gap: Metacritic ~35% — biggest remaining data gap in the system (#660)
```

**Current grade: B+** | **Target: A-**
One code fix: nil not 0.0. One data action: Metacritic fill via OMDb re-enrichment.

---

### 🏆 The Inner Circle — Festival & Awards Circuit

```
UMBRELLA: Did the film get institutional recognition from the awards circuit?

Sources:
  ● Festival nominations & wins from festival_nominations table
  ● Prestige scores stored in festival_organizations (win_score, nom_score)
  ● Prestige tiers: AMPAS(100/80) > Cannes(95/75) > Venice(90/70) ≈ Berlin(90/70) >
    BAFTA(85/65) > Globes(80/60) > Sundance(75/60) > Critics Choice(70/50) > Other(50/30)

Algorithm: sum of all nomination scores (prestige-weighted), capped at 100 (pred) / 10 (display)
  Category boost: +10/1 if category name contains "picture", "film", or "director"
  DB-backed tiers via festival_organizations.win_score / nom_score

Data imported: AMPAS 2016–2024 ✅ | Cannes partial ⚠️ | Venice winners only ⚠️ |
              Berlin partial ⚠️ | BAFTA NOT SEEDED ❌ | Pre-2016 back-catalog ❌
```

**Current grade: A+** | **Status: DONE ✅**

**Completed (2026-03-24/25):**
- [x] Fixed: `Enum.max` → `Enum.sum + cap` (multi-nomination films now score correctly)
- [x] Fixed: DB-backed prestige tiers (`festival_organizations.win_score/nom_score`)
- [x] Renamed: `industry_recognition` → `festival_recognition` across 38+ files
- [x] Migration: `add_prestige_scores_to_festival_organizations`
- [x] Migration: `rename_industry_recognition_score`
- [x] 25 pure-function tests passing

**Remaining (data, not code):**
- [ ] Import BAFTA into `festival_events` seeds — films scoring as "Other" tier today
- [ ] Import Oscar back-catalog pre-2016 — 1001-list skews heavily pre-2016
- [ ] Verify Cannes/Berlin/Venice nomination row counts (SQL integrity check)

---

### ⏳ The Time Machine — Canonical & Curatorial Consensus

```
UMBRELLA: Has this film stood the test of time across institutions?

Canonical lists in DB (9 total, all in movies.canonical_sources JSONB):

  List                        Category    Reliability  Coverage of 1001-list
  ──────────────────────────  ──────────  ───────────  ─────────────────────
  1001_movies                 curated     0.85         45% of all DB films
  criterion                   curated     0.90         ~34% of 1001-list
  letterboxd-top-250          curated     0.80         —
  national_film_registry      registry    0.95         ~28% of 1001-list
  afi_top_100                 critics     0.90         —
  sight_sound_critics_2022    critics     0.95         ~7% of 1001-list
  sight_sound_directors_2022  critics     0.95         —
  ebert_great_movies          critics     0.85         —
  tspdt_1000                  critics     0.85         —

Display algorithm (current — correct):
  Primary:   map_size(canonical_sources) × 2.0
  Secondary: log(tmdb_popularity + 1) / log(1000) × 5.0
  Cap at 10.0

Predictions algorithm (CURRENT — BROKEN):
  ROI (0–40) + IMDb critical mass step (0–30) + genre count (0–15) + international bonus (0–15)
  → ignores canonical_sources entirely
  → genre count is noise (length of genre tag list ≠ cultural significance)
  → international bonus double-counts festival_recognition data

Predictions algorithm (TARGET — after fix):
  Primary:    canonical_sources count score (replaces genre + international)
  Secondary:  box office ROI (0–30)
  Secondary:  IMDb critical mass (0–20) [smoothed, not step function]
  Minor:      technical craft wins (0–10) ← merged from Technical Innovation (Option C)
  Cap at 100

Technical Innovation decision (RESOLVED — Option C):
  Retire technical_innovation as a standalone lens.
  Merge technical craft wins into The Time Machine as a minor sub-component.
  Redistribute the 10% weight: +5% The Time Machine, +5% The Mob.
```

**Current grade: D (predictions) / B+ (display)** | **Target: B+ (both)**
This is the biggest remaining code fix. See Phase 3 in the work queue below.

---

### 🎬 The Auteurs — Talent Quality

```
UMBRELLA: Are great filmmakers involved in this film?

Display algorithm (people_quality — correct):
  Role-weighted average of person_metrics.quality_score
  Director 3.0× | Cast order 1–3: 2.0× | Cast order 4–10: 1.5× | Writer 1.5× | Other 1.0×
  Top 10 unique people by weighted score
  Result / 10 for 0–10 display scale

Predictions algorithm (auteur_recognition — narrower, intentionally):
  Measures director pedigree only: count of director's OTHER films on 1001-list
  ≥ 5 films → 100 | ≥ 3 → 80 | ≥ 1 → 60 | 0 → 20 (BUG: should be 0) | no credits → 0

The two formulas serve different purposes:
  Display: "Is the cast and crew strong?" — broad team question
  Predictions: "Is this an auteur director?" — specific 1001-list affinity question
  Both are valid. The split should be documented, not collapsed.

Data coverage:
  Display: depends on PersonQualityScoreWorker run coverage
  Predictions: 46% of films have no director credits in DB (Gap 3 from #660)
```

**Current grade: D+ (predictions) / B- (display)** | **Target: B+ (both)**
Two bugs to fix. See Phase 2 in the work queue below.

---

### 💵 The Box Office — Commercial Performance

```
UMBRELLA: How far did this film reach commercially?

Display algorithm (financial_performance — correct, display only):
  Revenue magnitude (60%): log(revenue + 1) / log(1B) × 10
  ROI (40%): log(revenue/budget + 1) / log(11) × 10
  Combined on 0–10 scale

Predictions: NOT a standalone lens.
  Revenue and ROI live as sub-components inside The Time Machine (above).
  Adding them here too would create correlated feature pair.

Data coverage:
  ~56% of films have usable revenue + budget (TMDb)
  Pre-1970 largely missing — structural gap, not fixable without new source
  No inflation adjustment — $10M in 1970 ≠ $10M in 2010 (low priority to fix)

Editorial weight: 5% (de-emphasized by design — commercial ≠ quality)
```

**Current grade: C+ (display) / N/A (predictions)** | **Status: Leave alone**
Sound formula. Rename display label to "The Box Office" from "Financial Performance" for
user clarity. No other changes needed.

---

## Work Queue — Ordered by Priority

### Phase 1: Auteurs bugs (do now — 2 lines, blocks calibration accuracy)

| # | Item | File | Effort |
|---|---|---|---|
| 1a | `true -> 20.0` → `true -> 0.0` (non-batch path) | `criteria_scoring.ex:391` | 1 min |
| 1b | `true -> 20.0` → `true -> 0.0` (batch path) | `criteria_scoring.ex:822` | 1 min |
| 1c | Fix batch/non-batch inconsistency for no-director films | `criteria_scoring.ex` batch path | 30 min |
| 1d | Unit tests: `score_auteur_recognition_from_batch(0) == 0.0`, etc. | test file | 1 hour |

**Why first:** The fallback bug adds +1.0 to every non-auteur film's total score. It is
corrupting every backtesting result today. 5-minute fix, high impact.

---

### Phase 2: Nil not zero (do now — 4 lines, ML correctness)

| # | Item | File | Effort |
|---|---|---|---|
| 2a | Return `nil` (not `0.0`) when Mob has no sources | `criteria_scoring.ex:~200` | 5 min |
| 2b | Return `nil` (not `0.0`) when Ivory Tower has no sources | `criteria_scoring.ex:~230` | 5 min |
| 2c | Verify display nil-handling in scoring_service.ex SQL | `scoring_service.ex:562–590` | 15 min |
| 2d | Remove dead RT Audience normalizer or wire it up | `criteria_scoring.ex:436–439` | 15 min |

**Why second:** `0.0` in a predictions feature means "audiences/critics rated this at the
floor" — which is false for films with no data. This misleads the ML model.

---

### Phase 3: The Time Machine — fix predictions formula (this sprint)

| # | Item | File | Effort |
|---|---|---|---|
| 3a | Replace `score_genre_cultural_impact` with canonical_sources count signal | `criteria_scoring.ex:496–499` | 1 hour |
| 3b | Remove `score_international_impact` (double-counts festival data) | `criteria_scoring.ex:502–518` | 30 min |
| 3c | Add technical craft wins as minor sub-component (Option C, TI merge) | `criteria_scoring.ex:316–349` | 1 hour |
| 3d | Redistribute TI's 10% weight: +5% cultural_impact, +5% mob | all weight profiles | 30 min |
| 3e | Remove `technical_innovation` from weight profiles and calibration UI | profiles + UI files | 1 hour |
| 3f | Smooth IMDb critical mass step function (thresholds → continuous) | `criteria_scoring.ex:296–299` | 1 hour |
| 3g | Add unit tests for new cultural_impact sub-scores | test file | 1 hour |
| 3h | Run distribution check: verify scores shift in expected direction | iex | 15 min |

**Why third:** Technical Innovation is holding 10% weight but returning 0 for 95% of films.
This dead weight distorts all backtesting. Fixing Cultural Impact aligns predictions with
the working display formula for the first time.

**Weight profile after Phase 3:**

```
Lens                  Default   Festival-heavy  Audience-first  Critics-choice  Auteur
────────────────────  ────────  ──────────────  ──────────────  ──────────────  ──────
The Mob               22.5%     12.5%           40%             12.5%           17.5%
The Ivory Tower       17.5%     10%             10%             35%             15%
The Inner Circle      30%       50%             20%             30%             25%
The Time Machine      25%       20%             20%             17.5%           22.5%
The Auteurs           5%        7.5%            10%             5%              20%
Total                 100%      100%            100%            100%            100%

Note: The Box Office is display-only and does not have a predictions weight.
TI's 10% redistributed: +5% The Mob, +5% The Time Machine.
```

---

### Phase 4: Metacritic data fill (this sprint, parallel to Phase 3)

| # | Item | Effort |
|---|---|---|
| 4a | Run OMDb re-enrichment for all films on 1001-list | ~half day |
| 4b | Target: Metacritic coverage from ~35% → ~80%+ for canonical films | — |
| 4c | Verify RT Audience Score actual coverage before raising its weight | 15 min |

**Why fourth:** The Ivory Tower's Metacritic gap is the biggest addressable data gap.
80%+ coverage on 1001-list films would push Ivory Tower from B+ to A.

---

### Phase 5: Inner Circle data backfill (next sprint)

| # | Item | Priority | Effort |
|---|---|---|---|
| 5a | Add BAFTA to `festival_events` seeds + import | HIGH | ~1 day |
| 5b | Import Oscar back-catalog pre-2016 | HIGH | ~half day |
| 5c | Run SQL integrity check: joined count = raw nomination count | HIGH | 10 min |
| 5d | Verify Cannes/Berlin/Venice nomination row counts | MEDIUM | 15 min |

---

### Phase 6: Auteurs design decision (next sprint, after Phase 1)

| # | Item | Effort |
|---|---|---|
| 6a | Decide: keep director-only step function OR add continuous PQS component for directors | Discussion |
| 6b | Rename predictions criterion `auteur_recognition` → `director_pedigree` (explicit split) | 1 hour |
| 6c | Fix Gap 3: import missing director credits (46% of films missing) | ~1 day |
| 6d | Verify PersonQualityScoreWorker coverage for display people_quality | 15 min |

---

### Phase 7: The Box Office cleanup (low priority)

| # | Item | Effort |
|---|---|---|
| 7a | Rename display label: "Financial Performance" → "The Box Office" | 15 min |
| 7b | Add "commercial data unavailable" state to display card | 30 min |
| 7c | Surface ROI and revenue separately in UI ("$180M worldwide · 4× budget") | 1 hour |

---

## Issues to Close After This Is Created

| Issue | Reason to close |
|---|---|
| #664 | Superseded by this issue |
| #662 | Signal quality findings fully incorporated here |
| #668 | Taxonomy audit incorporated here |
| #661 | "Canonical Consensus" resolved — signal belongs inside The Time Machine |
| #665 | Already closed A+ ✅ |
| #667 | Phases 1+3 above cover the scope |
| #670 | Phases 1+2+4 above cover the scope |

Issues to keep open (different scope):
- #660 — data quality gaps (Gap 1–4, structural)
- #663 — road to Phase 5B / ML
- #659 — ML benchmarking
- #655/#654 — 1001 Movies prediction accuracy goals

---

## Lens Status Summary

```
Lens               Code name(s)                          Grade  Status
─────────────────  ────────────────────────────────────  ─────  ───────────────────────
🔥 The Mob         mob / score_mob                       A-     Phase 2 (nil fix)
🎭 Ivory Tower     ivory_tower / score_ivory_tower       B+     Phase 2 (nil) + Phase 4 (data)
🏆 Inner Circle    festival_recognition (both systems)   A+     DONE ✅ + Phase 5 (data)
⏳ Time Machine    cultural_impact (both) +              D→B+   Phase 3 (biggest fix)
                   technical_innovation (retire)
🎬 The Auteurs     people_quality / auteur_recognition   D+→B   Phase 1 (now) + Phase 6
💵 Box Office      financial_performance (display only)  C+     Phase 7 (cosmetic)
```

---

## The Two-System Contract

After all phases complete, both systems should honor this contract:

| Lens | Predictions measures | Display measures | Difference |
|---|---|---|---|
| The Mob | avg(IMDb, TMDb) normalized 0–100 | avg(IMDb, TMDb, RT Audience) 0–10 | RT Audience included in display only (sparse) |
| Ivory Tower | avg(Metacritic, RT Tom) 0–100 | same, 0–10 | scale only |
| Inner Circle | prestige-weighted sum, 0–100 | same, 0–10 | scale only |
| Time Machine | canonical_sources + ROI + crit_mass + craft wins, 0–100 | canonical_count + popularity, 0–10 | predictions has more sub-signals for ML; display stays clean |
| The Auteurs | director pedigree (step fn), 0–100 | role-weighted PQS, 0–10 | intentional split — two valid questions |
| Box Office | N/A (sub-signals inside Time Machine) | revenue + ROI, 0–10 | predictions uses data, not standalone lens |
