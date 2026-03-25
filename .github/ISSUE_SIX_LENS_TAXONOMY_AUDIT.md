# ISSUE: Six-Lens Taxonomy Audit — Do Our Categories Make Sense?

**Date:** 2026-03-25
**Scope:** All six lenses across both subsystems — `criteria_scoring.ex` (predictions engine)
and `movie_scoring.ex` (display/discovery engine)
**Status:** Open — evaluation only, no code changes. Decisions required before Phase 5B.

Related: #662 (signal quality), #661 (canonical list gap), #660 (data gaps)

---

## 1. The Triggering Question

Another agent recently attempted to create a seventh lens called "Canonical Consensus" based
on `canonical_sources` overlap across curated lists (1001 Movies, Criterion, Sight & Sound,
AFI, NFR, etc.). The PR was rejected — not because the concept is wrong, but because the
*framing* was wrong.

This issue examines why that happened, evaluates whether the instinct was correct, and
asks the harder question: **do our current six lens categories actually hold up?**

The criteria for a valid lens are:
1. **Human-legible** — a non-technical user can understand what the score means
2. **Algorithmically distinct** — it adds a signal not already captured by the other five
3. **Data-supported** — we have (or can have) real data behind it
4. **Predictively valid** — it correlates with the kind of films we're trying to surface

---

## 2. The Two Systems and Their Divergence

Both systems use a six-lens architecture, but they are NOT the same six lenses:

```
┌────────────────────────────────┬─────────────────────────────────────────┐
│  LENS NAME (display label)     │  PREDICTIONS          DISPLAY            │
├────────────────────────────────┼─────────────────────┬───────────────────┤
│  The Mob                       │  mob (17.5%)        │  mob              │
│  The Ivory Tower               │  ivory_tower (17.5%)│  ivory_tower      │
│  Inner Circle (Festivals)      │  festival_recog(30%)│  festival_recog   │
│  Cultural Impact               │  cultural_impact    │  cultural_impact  │
│                                │  (20%) ← diverges   │  ← diverges       │
│  "Auteurs" / People Quality    │  auteur_recog (5%)  │  people_quality   │
│                                │  ← DIFFERENT concept│  ← DIFFERENT      │
│  Financial / Technical         │  technical_innov(10)│  financial_perf   │
│                                │  ← BROKEN concept   │  ← working        │
└────────────────────────────────┴─────────────────────┴───────────────────┘
```

Lenses 1–3 are consistent across both systems. **Lenses 4–6 have diverged so much they
are measuring fundamentally different things while sharing the same display label.**

This is the root cause of the "Canonical Consensus" confusion: the display system's
Cultural Impact already uses `canonical_sources` as its primary signal, but the
predictions Cultural Impact ignores it entirely and uses ROI + genre count instead.
The other agent saw the gap and tried to add a seventh lens, when the right fix is
to align lens #4 across both systems.

---

## 3. Current Six Lenses: What's Actually Inside

### Lens 1: The Mob

**Concept:** What does the general audience think?
**Scale:** 0–10 (display) / 0–100 (predictions)

| Source | Metric | Weight within lens | Coverage |
|---|---|---|---|
| IMDb | rating_average (0–10) | ~50% | ~95% |
| TMDb | rating_average (0–10) | ~50% | ~90% |
| RT | audience_score (0–100) | defined but unused in predictions | ~40% |

**What's inside:**
```
╔══════════════════════════════════════════════════════╗
║  THE MOB                                             ║
║                                                      ║
║  Average of available sources:                       ║
║    IMDb (primary) + TMDb (secondary)                 ║
║                                                      ║
║  Predictions: average of normalized scores           ║
║  Display: simple average (0–10 scale)                ║
║                                                      ║
║  Note: RT Audience Score defined in metric_defs      ║
║  but not used in either scoring path                 ║
╚══════════════════════════════════════════════════════╝
```

**Grade:** A- (sound concept, RT Audience Score unused, TMDb somewhat redundant)
**Verdict: Keep.** The name is memorable and accurate.

---

### Lens 2: The Ivory Tower

**Concept:** What do professional critics think?
**Scale:** 0–10 (display) / 0–100 (predictions)

| Source | Metric | Weight within lens | Coverage |
|---|---|---|---|
| Metacritic | metascore (0–100) | ~50% | ~35% |
| Rotten Tomatoes | tomatometer (0–100) | ~50% | ~92% |

**What's inside:**
```
╔══════════════════════════════════════════════════════╗
║  THE IVORY TOWER                                     ║
║                                                      ║
║  Average of available critic sources:                ║
║    RT Tomatometer (% fresh) + Metacritic (0–100)     ║
║                                                      ║
║  Predictions: average of normalized scores           ║
║  Display: same (both normalized to 0–10)             ║
║                                                      ║
║  PROBLEM: Metacritic has only ~35% coverage.         ║
║  A film with only RT gets an average of just RT.     ║
║  A film with neither scores 0.0 — penalized for      ║
║  a data gap, not for being bad.                      ║
╚══════════════════════════════════════════════════════╝
```

**Grade:** B+ (concept is airtight; 65% Metacritic gap is the only issue, tracked in #660)
**Verdict: Keep.** Fix data gap separately.

---

### Lens 3: The Inner Circle (Festival Recognition)

**Concept:** Did the film circuit through prestige festivals and award shows?
**Scale:** 0–10 (display) / 0–100 (predictions)

| Source | Metric | Prestige tier | Coverage |
|---|---|---|---|
| Academy Awards (AMPAS) | nominations/wins | 100/80 (win/nom) | 2016–2024 ✅ |
| Cannes (CFF) | nominations/wins | 95/75 | Partial ⚠️ |
| Venice (VIFF) | nominations/wins | 90/70 | Winners only ⚠️ |
| Berlin (BIFF) | nominations/wins | 90/70 | Partial ⚠️ |
| Golden Globes (HFPA) | nominations/wins | 80/60 | Partial ⚠️ |
| Sundance (SFF) | nominations/wins | 75/60 | Partial ⚠️ |
| BAFTA | nominations/wins | 85/65 | NOT SEEDED ❌ |
| Critics Choice | nominations/wins | 70/50 | NOT SEEDED ❌ |

**What's inside:**
```
╔══════════════════════════════════════════════════════╗
║  INNER CIRCLE / FESTIVAL RECOGNITION                 ║
║                                                      ║
║  Sum of all nomination scores (prestige-weighted):   ║
║    • Win score from festival_organizations table     ║
║    • Nom score from festival_organizations table     ║
║    • +10% boost if category contains "picture",     ║
║      "film", or "director"                           ║
║    • Sum capped at 100 (predictions) / 10 (display)  ║
║                                                      ║
║  Same algorithm in both systems (A+ grade, #662)     ║
║  DB-backed prestige tiers, not hardcoded             ║
╚══════════════════════════════════════════════════════╝
```

**Grade:** A+ (algorithm complete; BAFTA + back-catalog import is the remaining work)
**Verdict: Keep.** Best-implemented lens in the system.

---

### Lens 4: Cultural Impact ← THE PROBLEM LENS

**Concept:** How much has this film penetrated culture?
**Scale:** 0–10 (display) / 0–100 (predictions)

This is where the two systems have completely diverged.

#### 4A. Predictions formula (what it DOES):

| Sub-signal | Max pts | Formula | Signal validity |
|---|---|---|---|
| Box office ROI | 40 | revenue/budget ratio tiers | ◑ Moderate |
| IMDb critical mass | 30 | rating ≥ 7.5 + votes ≥ 100k step fn | ◑ Moderate |
| Genre diversity | 15 | `length(genres) / 4.0 × 15` | ○ WEAK (genre count ≠ cultural impact) |
| International bonus | 15 | non-English base 8 + festival_noms×1.5 | ○ WEAK (double-counts festival data) |

```
╔══════════════════════════════════════════════════════╗
║  CULTURAL IMPACT (predictions — current broken form) ║
║                                                      ║
║  80% of this formula is defensible:                  ║
║    ROI → did people show up?                         ║
║    IMDb votes → did people engage long-term?         ║
║                                                      ║
║  20% is noise or double-counting:                    ║
║    Genre count → editorial tag, not cultural signal  ║
║    International bonus → reuses festival_noms data   ║
║      already counted in Inner Circle                 ║
║                                                      ║
║  CRITICAL OMISSION: canonical_sources not used       ║
║  The 9 curated lists in the DB (100% coverage,       ║
║  independently curated over decades) are invisible   ║
║  to the predictions engine on this lens.             ║
╚══════════════════════════════════════════════════════╝
```

#### 4B. Display formula (what it DOES):

| Sub-signal | Weight | Formula |
|---|---|---|
| Canonical list count | Primary | `map_size(canonical_sources) × 2.0` |
| TMDb popularity | Secondary | `log(popularity+1) / log(1000) × 5.0` |

```
╔══════════════════════════════════════════════════════╗
║  CULTURAL IMPACT (display — working form)            ║
║                                                      ║
║  Primary: canonical_sources count                    ║
║    How many of 9 curated lists include this film?    ║
║    (100% coverage, decades of curatorial consensus)  ║
║                                                      ║
║  Secondary: TMDb popularity (log-scaled)             ║
║    Current audience engagement proxy                 ║
║                                                      ║
║  This is correct. The display system accidentally    ║
║  found the right formula. The predictions system     ║
║  didn't, and they share a name.                      ║
╚══════════════════════════════════════════════════════╝
```

**Grade:** D (predictions) / B+ (display)
**Verdict: Keep the name, fix the predictions formula.** See §8 for details.

---

### Lens 5: The Talent (People Quality / Auteur Recognition)

**Concept:** Are great filmmakers involved?
**Scale:** 0–10 (display) / 0–100 (predictions)

These are not the same lens at all. They share a slot but measure different things:

#### 5A. Predictions: `auteur_recognition` (director only)

| Signal | Formula | Coverage |
|---|---|---|
| Director's prior 1001-list films | Step: ≥5→100, ≥3→80, ≥1→60, 0→20 (bug: should be 0) | ~54% |

```
╔══════════════════════════════════════════════════════╗
║  AUTEUR RECOGNITION (predictions)                    ║
║                                                      ║
║  "Is the director an established auteur?"            ║
║  Measures DIRECTOR PEDIGREE only                     ║
║                                                      ║
║  Uses 1001 Movies list as the benchmark —            ║
║  somewhat circular for a 1001-list predictor         ║
║                                                      ║
║  Known bugs:                                         ║
║    • Fallback → 20 (should be 0) [Audit issue]       ║
║    • Batch / individual inconsistency                ║
║    • 46% of films have no director credit in DB      ║
╚══════════════════════════════════════════════════════╝
```

#### 5B. Display: `people_quality` (full cast + crew)

| Signal | Formula | Coverage |
|---|---|---|
| person_metrics.quality_score | Role-weighted avg, top 10 people | PQS worker coverage |
| Director | 3.0× weight | — |
| Lead cast (order 1–3) | 2.0× weight | — |
| Supporting cast (4–10) | 1.5× weight | — |
| Writer / Producer | 1.5× / 1.0× | — |

```
╔══════════════════════════════════════════════════════╗
║  PEOPLE QUALITY (display)                            ║
║                                                      ║
║  "Is the TEAM good?"                                 ║
║  Measures ENTIRE CAST AND CREW quality               ║
║                                                      ║
║  Role-weighted average of PQS scores                 ║
║  Director weighted 3× (highest)                      ║
║  Down to 1× for supporting roles                     ║
║                                                      ║
║  Clean, sound formula. Limited by PQS data           ║
║  coverage from PersonQualityScoreWorker.             ║
╚══════════════════════════════════════════════════════╝
```

**Grade:** D+ (predictions — bugs, circular, narrow) / B- (display — sound, needs PQS coverage)
**Verdict:** The concept is valid. The implementations are serving two different (but both legitimate) purposes. See §8 for the decision framework.

---

### Lens 6: Technical Innovation (predictions) / Financial Performance (display)

These are two completely different things sharing a position in the six-lens taxonomy.

#### 6A. Predictions: `technical_innovation` (10%)

| Signal | Formula | Coverage |
|---|---|---|
| Festival nominations in technical categories | Sum of wins(20) + noms(10), capped at 100 | Near zero |

```
╔══════════════════════════════════════════════════════╗
║  TECHNICAL INNOVATION (predictions) — BROKEN         ║
║                                                      ║
║  Queries festival_nominations WHERE category name    ║
║  LIKE '%cinematography%' OR '%sound%' OR '%editing%' ║
║  OR '%visual%' OR '%technical%'                      ║
║                                                      ║
║  Problems:                                           ║
║    1. Double-counts festival_recognition (same table,║
║       same rows, subset view)                        ║
║    2. Returns 0 for ~95% of films because category   ║
║       names don't match LIKE patterns in current DB  ║
║    3. Holds 10% weight while contributing nothing    ║
║    4. No tests; no coverage verification             ║
╚══════════════════════════════════════════════════════╝
```

#### 6B. Display: `financial_performance`

| Signal | Formula | Coverage |
|---|---|---|
| Revenue magnitude | log(revenue) / log(1B) × 60% weight | ~56% |
| ROI | log(roi+1) / log(11) × 40% weight | ~56% when budget also present |

```
╔══════════════════════════════════════════════════════╗
║  FINANCIAL PERFORMANCE (display)                     ║
║                                                      ║
║  "How commercially successful was this film?"        ║
║    Revenue magnitude (60%): log-scaled to $1B        ║
║    ROI (40%): revenue/budget on log scale            ║
║                                                      ║
║  Sound formula. Limited by 44% data gap for          ║
║  pre-1970 films (tracked in #660).                   ║
║  Low weight (5%) in Editorial profile by design.     ║
╚══════════════════════════════════════════════════════╝
```

**Predictions grade:** F (double-counts, broken, dead weight)
**Display grade:** B (sound formula, data gap acceptable at 5% weight)
**Verdict:** Technical Innovation should be retired. Financial Performance should stay.

---

## 4. Why the "Canonical Consensus" Lens Was Wrong (But the Instinct Was Right)

The other agent saw that `canonical_sources` (9 curated lists, 100% DB coverage) was
not being used in the predictions engine and tried to add it as a new seventh lens.

**Why the PR was wrong:**
- We don't need 7 lenses — we need 6 that work correctly
- Adding a seventh creates an overfit-prone model (more features, same training data)
- The weight budget was already diluted (Technical Innovation at 10% was dead weight;
  adding another lens makes the dilution problem worse)
- "Canonical Consensus" as a name competes confusingly with "Cultural Impact"

**Why the instinct was right:**
- `canonical_sources` IS the best single unimplemented signal (★★★★★ in #662)
- It IS independent of all six current lenses
- It IS what the display Cultural Impact already uses as its primary signal
- The gap between predictions Cultural Impact and display Cultural Impact is real

**The correct fix:** Don't add a 7th lens. Fix lens #4 (Cultural Impact predictions) to
use `canonical_sources` as its primary signal — which the display system already does.
The canonical signal belongs INSIDE Cultural Impact, not beside it.

---

## 5. The Taxonomy: Is "Six" the Right Number?

Six lenses maps cleanly to three pairs of intuitive questions:

```
┌─────────────────────────────────────────────────────────────┐
│  "What do people THINK of it?"                              │
│    ① The Mob          Audience ratings (millions of votes)  │
│    ② The Ivory Tower  Critic consensus (professional review)│
├─────────────────────────────────────────────────────────────┤
│  "What did INSTITUTIONS recognize?"                         │
│    ③ Inner Circle     Festival circuit, major award bodies  │
│    ④ Cultural Impact  Canonical lists, curatorial consensus │
├─────────────────────────────────────────────────────────────┤
│  "Who MADE it and what did it DO?"                          │
│    ⑤ The Talent       Cast and crew quality                 │
│    ⑥ Cultural Reach   Box office, popularity, longevity     │
└─────────────────────────────────────────────────────────────┘
```

Six is the right number. The taxonomy above holds up. The current problem is that:
- Lenses ①–③ are implemented correctly
- Lens ④ has the right name but the wrong formula in predictions
- Lens ⑤ has two different formulas that are both valid but serve different purposes
- Lens ⑥ has a working display formula and a broken predictions formula that should be retired

---

## 6. UI/UX: What These Lenses Look Like to a User

### 6A. Movie show page — score breakdown display

```
┌─────────────────────────────────────────────────────────────────┐
│  PARASITE (2019)                                    Score: 9.2  │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Score Breakdown                                          │  │
│  │                                                          │  │
│  │  ① The Mob           ████████░░  8.4  IMDb 8.6, TMDb 8.3│  │
│  │  ② Ivory Tower       █████████░  9.1  MC 96, RT 99%     │  │
│  │  ③ Inner Circle      ██████████  10.0 4 Oscars + Cannes │  │
│  │  ④ Cultural Impact   ████████░░  8.0  1001+Criterion+S&S│  │
│  │  ⑤ The Talent        ████████░░  8.2  Bong Joon-ho ×3  │  │
│  │  ⑥ Cultural Reach    ██████░░░░  6.1  $266M / $11M      │  │
│  │                                                          │  │
│  │  Confidence: ████████░░  87%   (4/4 rating sources)     │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### 6B. Discovery / Filter panel — lens-based sorting

```
┌───────────────────────────────────────────────────────────┐
│  Sort by:   [Overall ▼]                                   │
│                                                           │
│  ○ Overall Score     ○ The Mob         ○ Ivory Tower      │
│  ○ Inner Circle      ● Cultural Impact ○ The Talent       │
│  ○ Cultural Reach                                         │
│                                                           │
│  ▸ Cultural Impact — what this means:                     │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  Films on multiple canonical "must-see" lists.      │  │
│  │  Criterion. 1001 Movies. Sight & Sound. AFI.        │  │
│  │  These lists are curated by critics and scholars    │  │
│  │  over decades — they represent time-tested          │  │
│  │  consensus about what matters in cinema.            │  │
│  └─────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────┘
```

### 6C. Predictions calibration — weight tuning UI

```
┌──────────────────────────────────────────────────────────────┐
│  CALIBRATION TUNER                    Profile: [Default ▼]   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Drag sliders to re-weight. Total must equal 100%.   │   │
│  │                                                      │   │
│  │  The Mob         ████░░░░░░  17.5%  ← [─────────] → │   │
│  │  Ivory Tower     ████░░░░░░  17.5%  ← [─────────] → │   │
│  │  Inner Circle    ████████░░  30.0%  ← [─────────] → │   │
│  │  Cultural Impact █████░░░░░  20.0%  ← [─────────] → │   │
│  │  The Talent      █░░░░░░░░░   5.0%  ← [─────────] → │   │
│  │  Cultural Reach  ██░░░░░░░░  10.0%  ← [─────────] → │   │  ← TI retired, replaced
│  │                                                      │   │
│  │  ✓ Total: 100%                                       │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  [Backtest against 2010s] [Reset to Default] [Save Profile] │
└──────────────────────────────────────────────────────────────┘
```

### 6D. Mobile / card view — compact display

```
┌──────────────────────────────┐
│  BLADE RUNNER (1982)         │
│  Score: 8.1                  │
│                              │
│  👥 Mob      7.9  ███████░░░ │
│  🎓 Critics  8.3  ████████░░ │
│  🏆 Awards   6.0  ██████░░░░ │
│  📚 Canon    9.0  █████████░ │
│  🎭 Talent   8.7  ████████░░ │
│  💰 Reach    7.2  ███████░░░ │
└──────────────────────────────┘
```

---

## 7. Per-Lens Data Signal Inventory

For each lens: what data points live under it, where they come from, and how reliable they are.

### Lens 1: The Mob

| Data Point | Source | DB Field | Reliability | Coverage |
|---|---|---|---|---|
| IMDb user rating (0–10) | IMDb scrape | `external_metrics` imdb/rating_average | 0.95 | ~95% |
| TMDb user rating (0–10) | TMDb API | `external_metrics` tmdb/rating_average | 0.90 | ~90% |
| IMDb vote count | IMDb scrape | `external_metrics` imdb/rating_votes | 0.95 | ~90% |
| TMDb vote count | TMDb API | `external_metrics` tmdb/rating_votes | 0.90 | ~90% |
| RT Audience Score (0–100) | RT scrape | `external_metrics` rotten_tomatoes/audience_score | 0.75 | ~40% |

Currently used in scoring: IMDb + TMDb rating only. RT Audience Score defined but unused.

### Lens 2: The Ivory Tower

| Data Point | Source | DB Field | Reliability | Coverage |
|---|---|---|---|---|
| Metacritic Metascore (0–100) | Metacritic scrape | `external_metrics` metacritic/metascore | 0.85 | ~35% |
| RT Tomatometer (0–100) | RT scrape | `external_metrics` rotten_tomatoes/tomatometer | 0.80 | ~92% |

### Lens 3: Inner Circle (Festival Recognition)

| Data Point | Source | DB Field | Reliability | Coverage |
|---|---|---|---|---|
| Oscar nominations/wins | import_oscars task | `festival_nominations` via AMPAS org | 1.0 | 2016–2024 ✅; pre-2016 ❌ |
| Cannes nominations/wins | IMDb scraper | `festival_nominations` via CFF org | 1.0 | Partial ⚠️ |
| Venice nominations/wins | IMDb scraper | `festival_nominations` via VIFF org | 1.0 | Winners only ⚠️ |
| Berlin nominations/wins | IMDb scraper | `festival_nominations` via BIFF org | 1.0 | Partial ⚠️ |
| Golden Globes | IMDb scraper | `festival_nominations` via HFPA org | 1.0 | Partial ⚠️ |
| BAFTA | NOT SEEDED | — | — | ❌ 0 rows |
| Sundance | IMDb scraper | `festival_nominations` via SFF org | 1.0 | Partial ⚠️ |

### Lens 4: Cultural Impact

**Display system (current/correct):**

| Data Point | Source | DB Field | Reliability | Coverage |
|---|---|---|---|---|
| 1001 Movies | Canonical import | `movies.canonical_sources['1001_movies']` | 0.85 | ~45% of DB |
| Criterion Collection | Canonical import | `movies.canonical_sources['criterion']` | 0.90 | ~34% of 1001-list |
| National Film Registry | Canonical import | `movies.canonical_sources['national_film_registry']` | 0.95 | ~28% of 1001-list |
| Sight & Sound 2022 | Canonical import | `movies.canonical_sources['sight_sound_critics_2022']` | 0.95 | ~7% of 1001-list |
| AFI Top 100 | Canonical import | `movies.canonical_sources['afi_top_100']` | 0.90 | — |
| BFI Top 100 | Canonical import | `movies.canonical_sources['bfi_top_100']` | 0.90 | — |
| Letterboxd Top 250 | Canonical import | `movies.canonical_sources['letterboxd-top-250']` | 0.80 | — |
| TSPDT 1000 | Canonical import | `movies.canonical_sources['tspdt-1000']` | 0.85 | — |
| Ebert Great Movies | Canonical import | `movies.canonical_sources['ebert-great-movies']` | 0.85 | — |
| TMDb popularity (secondary) | TMDb API | `external_metrics` tmdb/popularity_score | 0.70 | ~90% |

**Predictions system (current/wrong — uses instead):**

| Data Point | DB Field | Problem |
|---|---|---|
| Box office ROI | `tmdb_data['revenue'] / tmdb_data['budget']` | 44% data gap; commercial ≠ cultural |
| IMDb critical mass | `external_metrics` imdb/rating_average + votes | Step function; double-uses mob data |
| Genre diversity | `tmdb_data['genres']` | Genre count ≠ cultural signal |
| International bonus | `tmdb_data['original_language']` + nom count | Doubles festival data |

### Lens 5: The Talent

**Display system (`people_quality`):**

| Data Point | DB Field | Reliability | Coverage |
|---|---|---|---|
| Person quality scores (all roles) | `person_metrics` quality_score per person_id | 0.90 | PQS worker coverage |
| Role weights: Director 3×, Lead 2×, etc. | Applied in SQL | — | — |

**Predictions system (`auteur_recognition`):**

| Data Point | DB Field | Reliability | Coverage |
|---|---|---|---|
| Director's other films on 1001 list | `movie_credits` + `canonical_sources` join | 0.90 | ~54% (46% gap = no director credits) |

### Lens 6: Financial Performance / Technical Innovation

**Display (`financial_performance`):**

| Data Point | DB Field | Reliability | Coverage |
|---|---|---|---|
| Worldwide revenue | `external_metrics` tmdb/revenue_worldwide | 0.70 | ~56% |
| Budget | `external_metrics` tmdb/budget | 0.70 | ~56% |
| Domestic revenue | `external_metrics` omdb/revenue_domestic | 0.65 | ~35% |

**Predictions (`technical_innovation`) — broken:**

| Data Point | DB Field | Problem |
|---|---|---|
| Festival technical category nominations | `festival_nominations` + `festival_categories` LIKE match | ~0% match rate; double-counts festival_recognition |

---

## 8. Master Evaluation Table

```
Lens               Human label       Predictions     Display         Decision
─────────────────  ────────────────  ──────────────  ──────────────  ─────────────────────────
The Mob            The Mob           A-  sound        A-  sound       KEEP. Add RT Audience.
The Ivory Tower    The Ivory Tower   B+  data gap     B+  data gap    KEEP. Fix Metacritic gap.
Inner Circle       Inner Circle      A+  complete     A+  complete    KEEP. Import BAFTA.
Cultural Impact    Cultural Impact   D   broken        B+  correct    FIX predictions formula.
                                                                       Use canonical_sources.
The Talent         The Auteurs /     D+  bugs+narrow   B-  sound     CLARIFY the split.
                   People Quality                                       Rename pred→"talent_pedigree"
                                                                       Fix fallback bug.
Tech / Financial   —                 F   broken/dead   B   working   RETIRE technical_innovation.
                                                                       Keep financial_performance.
                                                                       Redistribute 10% weight.
```

---

## 9. What the "Canonical Consensus" Lens Would Have Done

If we had added it as a 7th lens, the weight budget would have looked like:

```
Before (current 6):
  mob              17.5%
  ivory_tower      17.5%
  festival_recog   30.0%
  cultural_impact  20.0%  ← already contains canonical data in display
  tech_innovation  10.0%  ← dead weight, returns 0 for 95% of films
  auteur_recog      5.0%

After (hypothetical 7 with canonical_consensus):
  mob              14.0%  (diluted)
  ivory_tower      14.0%  (diluted)
  festival_recog   25.0%  (diluted)
  cultural_impact  15.0%  (diluted AND now semantically overlapping)
  canonical_consns 15.0%  (new, overlaps with cultural_impact)
  tech_innovation   8.0%  (still dead weight)
  auteur_recog      9.0%  (slightly elevated but still broken)
```

The problem: adding a 7th lens would have created semantic overlap between "Cultural Impact"
and "Canonical Consensus" — both claiming to represent canonical list presence — while not
fixing the dead weight of `technical_innovation` and not fixing the predictions Cultural
Impact formula.

**The right fix:** retire `technical_innovation`, move its 10% into Cultural Impact, and
fix Cultural Impact's predictions formula to use `canonical_sources`. This preserves six
lenses and makes the canonical signal first-class inside the right umbrella.

---

## 10. Recommended Architecture: Six Harmonized Lenses

These six lenses should be conceptually stable across both subsystems:

```
┌─────────────────────────────────────────────────────────────────────┐
│  LENS                WHAT IT MEASURES           DATA SOURCES        │
├─────────────────────────────────────────────────────────────────────┤
│  ① The Mob           General audience consensus  IMDb, TMDb, RT Aud │
│                                                                     │
│  ② Ivory Tower       Professional critic         Metacritic,         │
│                      consensus                   RT Tomatometer      │
├─────────────────────────────────────────────────────────────────────┤
│  ③ Inner Circle      Institutional recognition   Festival awards,   │
│                      (awards circuit)             major ceremonies   │
│                                                                     │
│  ④ Cultural Impact   Time-tested curatorial       Canonical lists    │
│                      consensus + reach            (9 in DB) +        │
│                                                   TMDb popularity   │
├─────────────────────────────────────────────────────────────────────┤
│  ⑤ The Talent        Cast and crew quality        PQS (display)      │
│                                                   Director pedigree  │
│                                                   (predictions)      │
│                                                                     │
│  ⑥ Cultural Reach    Commercial/audience          Box office ROI,    │
│                      reach                        revenue, votes     │
│                      [display: Financial Perf]                      │
└─────────────────────────────────────────────────────────────────────┘
```

Note: Lens ⑥ currently has two identities — `financial_performance` (display) and
`technical_innovation` (predictions). After retiring TI, the predictions path for
lens ⑥ should adopt a formula similar to the display `financial_performance` plus
the IMDb "critical mass" component from current Cultural Impact (votes × rating step).

---

## 11. Decision Items

| # | Decision | Stakes | Recommendation |
|---|---|---|---|
| 1 | Retire `technical_innovation` from predictions? | **CRITICAL** — it holds 10% of the weight budget but contributes 0 discriminative power | **Yes. Retire immediately.** Redistribute weight. |
| 2 | Fix `cultural_impact` predictions formula to use `canonical_sources`? | **HIGH** — display system already does this; predictions ignores the best signal we have | **Yes.** Replace genre_diversity + international_bonus with canonical_sources count signal. |
| 3 | Fix `auteur_recognition` fallback bug (20 → 0)? | **HIGH** — uniform 1-point inflation on every non-auteur film; easy 2-line fix | **Yes, in parallel with any other predictions changes.** |
| 4 | Should lens 5 have unified "talent" formula across both systems? | MEDIUM — two formulas serve different purposes; display PQS is broader; predictions director-pedigree is more specific | **Document the split explicitly.** Rename pred criterion to `talent_pedigree`. |
| 5 | Should `financial_performance` appear in predictions? | MEDIUM — box office ROI is already inside Cultural Impact predictions; DRY issue | **Yes, eventually.** Low priority — at 5% display weight it barely moves scores. |
| 6 | What should the 10% weight from retired TI go to? | MEDIUM | **+5% Cultural Impact, +5% The Mob** (or discuss). |

---

## 12. Action Items

| # | Item | Priority | Effort |
|---|---|---|---|
| 1 | Retire `technical_innovation` from predictions engine | CRITICAL | 1 hour (remove function, redistribute weights, update tests) |
| 2 | Fix `cultural_impact` predictions: replace genre + international sub-signals with `canonical_sources` count | HIGH | 2 hours |
| 3 | Fix `auteur_recognition` fallback: `true -> 20.0` → `true -> 0.0` (both batch + non-batch) | HIGH | 5 min |
| 4 | Fix `auteur_recognition` batch/individual inconsistency for no-director films | HIGH | 30 min |
| 5 | Rename predictions criterion `auteur_recognition` → `talent_pedigree` (or `director_pedigree`) | MEDIUM | 1 hour (touch weight profiles + calibration UI) |
| 6 | Update weight profiles to remove `technical_innovation` key | MEDIUM | 30 min |
| 7 | Add unit tests for Cultural Impact sub-scores (predictions) | MEDIUM | 1 hour |
| 8 | Update calibration UI to reflect new 5-lens predictions layout | MEDIUM | 1 hour |
| 9 | Document the predictions vs. display formula split per lens in module docs | LOW | 1 hour |
| 10 | Evaluate adding RT Audience Score to The Mob (currently defined, never used) | LOW | 30 min |

---

## 13. Appendix: Canonical Lists in DB

```
Slug                       Category     Reliability  Notes
─────────────────────────  ───────────  ───────────  ─────────────────────────────────
1001_movies                curated      0.85         Primary prediction target
criterion                  curated      0.90         Editorial/art cinema focus
letterboxd-top-250         curated      0.80         Audience-driven modern canon
national_film_registry     registry     0.95         US preservation (Library of Congress)
afi_top_100                critics      0.90         US-centric, 1998
sight_sound_critics_2022   critics      0.95         Global critical poll, every 10 years
sight_sound_directors_2022 critics      0.95         Companion directors poll
ebert_great_movies         critics      0.85         Roger Ebert's curated canon (~400 films)
tspdt_1000                 critics      0.85         They Shoot Pictures, global critical consensus
```

All 9 are in `movies.canonical_sources` as JSONB keys.
`map_size(canonical_sources)` = count of lists the film appears on (0–9).
100% coverage — every movie row has the field (empty map if not on any list).
