# Multi-Source Movie Lookup System for Festival Imports

## Problem Statement

Festival imports are experiencing a **high failure rate** (~50-70%) when looking up movies in TMDb. Currently observing:

- **44+ retryable jobs** in Oban queue (mostly TMDbDetailsWorker)
- All failures have `failure_reason: "no_tmdb_match"`
- Many new/indie festival films don't exist in TMDb
- OMDb is only used AFTER successful TMDb movie creation (for enrichment)
- No fallback strategy when TMDb fails during initial movie creation

### Current Failure Examples
From Oban dashboard, recent failures include:
- "Sentimental Value" (tt27714581)
- "The Girls We Want" (tt36164712)
- "My Mom Jayne" (tt36464353)
- "Meteors" (tt33772384)
- "Alpha" (tt32275943)
- And 40+ more...

### Current Architecture Issues

```
Festival Import → IMDb ID → TMDb Lookup (6 fallback strategies) → ❌ FAILS
                                                                 ↓
                                                         Job marked as failed
                                                         Movie never created
```

**What doesn't happen:**
- OMDb fallback for initial movie creation
- IMDb scraping fallback (we have Zyte API available)
- Alternative data source attempts
- Any metrics on WHY lookups fail or which sources could help

## Proposed Solution Architecture

### 1. Multi-Source Lookup Strategy

Implement a **tiered fallback system** with configurable priority:

```
Festival Import → IMDb ID
                    ↓
     ┌──────────── Priority 1: TMDb (FREE) ────────────┐
     │   • 6 existing fallback strategies               │
     │   • Fast, comprehensive cast/crew data           │
     │   • Preferred for full imports                   │
     └────────────────────┬─────────────────────────────┘
                          │ ❌ Not Found
                          ↓
     ┌──────────── Priority 2: OMDb (PAID) ─────────────┐
     │   • Basic movie data by IMDb ID                   │
     │   • Ratings, awards, plot                         │
     │   • Create minimal movie record                   │
     │   • Cost: ~$0.001 per request                    │
     └────────────────────┬─────────────────────────────┘
                          │ ❌ Not Found
                          ↓
     ┌──────────── Priority 3: IMDb Scraping (PAID) ────┐
     │   • Direct IMDb page scraping via Zyte            │
     │   • Most authoritative but expensive              │
     │   • Cost: ~$0.01-0.05 per request                │
     │   • Fallback only, not primary                    │
     └────────────────────┬─────────────────────────────┘
                          │ ❌ Not Found
                          ↓
            Create "stub" record with IMDb ID only
            (Mark for manual review/future enhancement)
```

### 2. Dedicated Lookup Metrics Table

**Extend existing `api_lookup_metrics` table** to track comprehensive lookup flow:

```sql
-- Already exists, but enhance usage:
CREATE TABLE api_lookup_metrics (
  id UUID PRIMARY KEY,
  source TEXT NOT NULL,              -- 'tmdb', 'omdb', 'imdb_scrape', 'letterboxd'
  operation TEXT NOT NULL,            -- 'movie_lookup', 'fallback_search', etc.
  identifier TEXT,                    -- IMDb ID or title searched
  success BOOLEAN NOT NULL,
  response_time_ms INTEGER,
  error_message TEXT,
  metadata JSONB,                     -- Store strategy info, confidence, cost
  inserted_at TIMESTAMP
);

-- New tracking fields in metadata JSONB:
{
  "strategy": "tmdb_fallback_3" | "omdb_primary" | "imdb_scrape",
  "fallback_level": 1..4,           -- Which tier was used
  "confidence": 0.0..1.0,           -- Match confidence score
  "cost_usd": 0.001,                -- Estimated cost for paid APIs
  "movie_found": true|false,        -- Did we find movie data?
  "movie_created": true|false,      -- Did we create record?
  "import_type": "full"|"minimal"|"stub",
  "source_hierarchy": ["tmdb", "omdb", "imdb_scrape"],
  "festival": "cannes_2025",        -- Context for analysis
  "reason_for_fallback": "tmdb_not_found" | "tmdb_timeout"
}
```

### 3. Modular Data Source Architecture

Create a **behavior/protocol** for data sources:

```elixir
# Conceptual structure (not actual code):

defmodule Cinegraph.DataSources.Source do
  @callback lookup_by_imdb_id(imdb_id :: String.t()) ::
    {:ok, movie_data :: map()} | {:error, reason :: atom()}

  @callback lookup_by_title(title :: String.t(), year :: integer()) ::
    {:ok, movie_data :: map()} | {:error, reason :: atom()}

  @callback priority() :: integer()  # 1 = highest priority
  @callback cost_per_request() :: float()  # USD
  @callback rate_limit() :: {requests :: integer(), per :: :second | :minute | :day}
  @callback supports_full_import?() :: boolean()
end

# Implementations:
# - Cinegraph.DataSources.TMDb (priority: 1, cost: $0, full: true)
# - Cinegraph.DataSources.OMDb (priority: 2, cost: $0.001, full: false)
# - Cinegraph.DataSources.IMDbScraper (priority: 3, cost: $0.03, full: true)
# - Cinegraph.DataSources.Letterboxd (priority: 4, cost: $0, full: false) [future]
```

### 4. Import Type Classification

Define three types of movie imports:

1. **Full Import** (TMDb, IMDb Scraper)
   - Complete cast/crew data
   - Images, videos, metadata
   - Collaboration building enabled
   - CRI calculations enabled

2. **Minimal Import** (OMDb)
   - Basic movie info (title, year, plot, ratings)
   - Limited cast/crew (top billed only)
   - Marked for enhancement later
   - Festival nomination created

3. **Stub Import** (All sources failed)
   - IMDb ID + scraped title/year only
   - Marked as "needs_data_enrichment"
   - Festival nomination still created
   - Manual review queue

### 5. Worker Flow Enhancement

**Update TMDbDetailsWorker** to orchestrate multi-source lookup:

```
TMDbDetailsWorker.perform(%{imdb_id: "tt123", source: "festival"})
  ↓
  Check if movie exists by IMDb ID
  ↓ (Not found)
  Attempt multi-source lookup in priority order:

  1. Try TMDb (existing FallbackSearch logic)
     → Success: Full import
     → Failure: Continue to step 2

  2. Try OMDb (NEW - currently only used for enrichment)
     → Success: Minimal import, mark for future enhancement
     → Failure: Continue to step 3

  3. Try IMDb Scraping via Zyte (NEW - expensive, last resort)
     → Success: Full import (expensive but complete)
     → Failure: Continue to step 4

  4. Create stub record
     → Save IMDb ID, title, year
     → Mark as "needs_enrichment"
     → Create festival nomination anyway
     → Add to manual review queue

  All steps tracked in api_lookup_metrics
```

## Alternative Data Sources Analysis

### Currently Available
1. **TMDb** (The Movie Database) ✅ Already implemented
   - Pros: Free, comprehensive, good API
   - Cons: Missing many new/indie films
   - Coverage: ~1M movies

2. **OMDb** (Open Movie Database) ✅ Available but underutilized
   - Pros: Has IMDb data, reasonable cost
   - Cons: Limited compared to TMDb, $1/1000 requests
   - Coverage: ~500K movies
   - **Current issue: Only used for enrichment, not movie creation**

3. **IMDb Direct Scraping** ✅ Available via Zyte
   - Pros: Most authoritative, has everything
   - Cons: Expensive (~$0.03/request), slower, scraping fragility
   - Coverage: ~10M titles
   - Use case: Last resort for critical missing films

### Potential Future Sources

4. **Letterboxd** (via web scraping)
   - Pros: Strong festival film coverage, curated data
   - Cons: No official API, scraping needed
   - Coverage: ~800K films with strong indie/festival focus
   - **Note:** Letterboxd has unofficial API endpoints that could be explored

5. **Rotten Tomatoes**
   - Pros: Critical reviews, audience scores
   - Cons: No public API, expensive data licenses
   - Use case: Enrichment only, not primary source

6. **Metacritic**
   - Pros: Aggregated critic scores
   - Cons: No API, scraping needed
   - Use case: Enrichment only

7. **Film Festival APIs** (where available)
   - Cannes, Venice, Berlin, etc. may have official data
   - Use case: Direct import without IMDb middleman

### Recommended Initial Implementation
**Phase 1:** TMDb → OMDb → Stub (No IMDb scraping yet)
**Phase 2:** Add IMDb scraping for critical failures
**Phase 3:** Explore Letterboxd integration for festival films

## Success Metrics & Monitoring

### Key Performance Indicators

1. **Lookup Success Rate**
   ```sql
   -- Overall success rate by source
   SELECT
     source,
     COUNT(*) FILTER (WHERE success = true) * 100.0 / COUNT(*) as success_rate,
     COUNT(*) as total_attempts
   FROM api_lookup_metrics
   WHERE operation = 'movie_lookup'
   GROUP BY source
   ORDER BY success_rate DESC;
   ```

2. **Fallback Effectiveness**
   ```sql
   -- How often do fallbacks rescue failed TMDb lookups?
   SELECT
     metadata->>'fallback_level' as fallback_tier,
     metadata->>'source_hierarchy' as sources_tried,
     COUNT(*) as fallback_successes
   FROM api_lookup_metrics
   WHERE success = true
     AND metadata->>'fallback_level' > '0'
   GROUP BY fallback_tier, sources_tried;
   ```

3. **Cost Analysis**
   ```sql
   -- Total API costs by source
   SELECT
     source,
     SUM((metadata->>'cost_usd')::float) as total_cost,
     COUNT(*) as requests
   FROM api_lookup_metrics
   WHERE inserted_at > NOW() - INTERVAL '30 days'
   GROUP BY source;
   ```

4. **Festival Import Health**
   ```sql
   -- Success rates for festival imports specifically
   SELECT
     metadata->>'festival' as festival,
     COUNT(*) FILTER (WHERE metadata->>'movie_created' = 'true') as movies_created,
     COUNT(*) FILTER (WHERE metadata->>'import_type' = 'full') as full_imports,
     COUNT(*) FILTER (WHERE metadata->>'import_type' = 'minimal') as minimal_imports,
     COUNT(*) FILTER (WHERE metadata->>'import_type' = 'stub') as stub_imports,
     COUNT(*) as total_attempts
   FROM api_lookup_metrics
   WHERE metadata->>'festival' IS NOT NULL
   GROUP BY festival;
   ```

### Dashboard Metrics

Create monitoring dashboard showing:
- ✅ Successful lookups by source (TMDb, OMDb, IMDb)
- 📊 Fallback tier distribution (how often each tier is needed)
- 💰 Daily/monthly API costs
- 🎬 Festival import success rates
- ⏱️ Average lookup time by source
- 🚨 Failed lookups requiring manual review

## Implementation Strategy

### Phase 1: Foundation (Week 1-2)
1. ✅ Audit current api_lookup_metrics usage
2. Create `Cinegraph.DataSources.Source` behavior module
3. Refactor existing TMDb code to implement Source behavior
4. Implement OMDb as Source (with movie creation, not just enrichment)
5. Update TMDbDetailsWorker to attempt OMDb fallback

### Phase 2: Metrics & Monitoring (Week 2-3)
1. Enhance ApiTracker to record comprehensive lookup metadata
2. Create database views for common metric queries
3. Build simple LiveView dashboard for lookup metrics
4. Add alerts for high failure rates or costs

### Phase 3: IMDb Scraping (Week 3-4)
1. Implement IMDb scraper as Source using existing Zyte integration
2. Add cost controls (max daily spend, critical-only mode)
3. Add manual review queue for stub records
4. Backfill failed lookups using new sources

### Phase 4: Optimization (Ongoing)
1. Analyze metrics to tune fallback strategies
2. Evaluate Letterboxd as additional source
3. Implement caching for expensive lookups
4. Create enrichment jobs to upgrade minimal→full imports

## Cost Analysis

### Current Costs (Estimated)
- TMDb: $0 (unlimited free tier)
- OMDb: Currently minimal (~$1/month for enrichment only)
- Zyte: ~$50/month (used for festival scraping, not movie lookups)

### Projected Costs with Multi-Source Fallback

**Scenario: 1000 festival movies/year with 50% TMDb failures**

```
TMDb attempts:     1000 movies × $0        = $0
OMDb fallbacks:      500 movies × $0.001   = $0.50
IMDb fallbacks:       50 movies × $0.03    = $1.50 (10% of OMDb failures)
────────────────────────────────────────────────
Total annual cost:                          ≈$2

Monthly cost: ~$0.20
```

**Cost is negligible compared to value of complete festival data.**

### Cost Controls
- Set daily/monthly spend limits per source
- Implement "critical-only" mode for expensive sources
- Cache successful lookups to avoid duplicate costs
- Batch operations where possible

## Migration Path

### For Existing Failed Jobs

1. **Immediate:** Retry 44 failed jobs with OMDb fallback enabled
2. **Week 1:** Identify all movies with `needs_enrichment` flag
3. **Week 2:** Backfill failed festival movies using new multi-source system
4. **Week 3:** Create manual review workflow for remaining stubs

### Database Changes

```sql
-- Add to movies table:
ALTER TABLE movies ADD COLUMN import_type TEXT DEFAULT 'full'
  CHECK (import_type IN ('full', 'minimal', 'stub'));
ALTER TABLE movies ADD COLUMN needs_enrichment BOOLEAN DEFAULT false;
ALTER TABLE movies ADD COLUMN data_source_hierarchy TEXT[];
ALTER TABLE movies ADD COLUMN last_enrichment_attempt TIMESTAMP;

-- Index for finding movies needing enrichment:
CREATE INDEX idx_movies_needs_enrichment
  ON movies (needs_enrichment)
  WHERE needs_enrichment = true;
```

## Related Issues

- Issue #192: "Many festival films missing from database"
- Issue #235: "Credit-based person linking"
- Issue #236: "Person linking metrics"
- Oban dashboard: 44+ retryable TMDbDetailsWorker failures

## Success Criteria

1. ✅ Festival import failure rate < 10% (currently ~50%)
2. ✅ All festival nominations created even when full movie data unavailable
3. ✅ Comprehensive metrics showing lookup success by source
4. ✅ Cost per festival import < $0.01
5. ✅ Clear visibility into why lookups fail
6. ✅ Automated enrichment of minimal/stub records over time
7. ✅ No more "lost" festival films due to TMDb gaps

## Open Questions

1. Should we implement IMDb scraping immediately or wait for metrics?
   - **Recommendation:** Phase 2, after OMDb proves insufficient

2. How long should we keep stub records before manual review?
   - **Recommendation:** 30 days, then manual review queue

3. Should we cache OMDb/IMDb lookups to save costs?
   - **Recommendation:** Yes, cache successful lookups for 90 days

4. What confidence threshold triggers manual review?
   - **Recommendation:** confidence < 0.6 or all sources failed

5. Should Letterboxd integration be priority or nice-to-have?
   - **Recommendation:** Nice-to-have for Phase 4, focus on OMDb first

## References

- [TMDb API Docs](https://developers.themoviedb.org/3)
- [OMDb API Docs](http://www.omdbapi.com/)
- [Letterboxd Unofficial API Discussion](https://letterboxd.com/api-beta/)
- Current implementation: `lib/cinegraph/services/tmdb/fallback_search.ex`
- Current implementation: `lib/cinegraph/workers/tmdb_details_worker.ex`
- Metrics table: `priv/repo/migrations/20250812134727_create_api_lookup_metrics.exs`
