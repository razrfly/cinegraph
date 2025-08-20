# Caching Implementation Audit & Improvements

## Current State Analysis

### What We Have Working ✅
1. **2020s Predictions Caching** - Successfully caches 1000 movies for 2020s decade
2. **Validation Calculations** - Individual decade validations run successfully
3. **Incremental Job System** - Split monolithic job into smaller pieces that don't timeout
4. **Database Persistence** - `prediction_cache` table stores results between restarts
5. **Memory Caching** - Cachex provides fast in-memory access

### What's Missing/Broken ❌

#### 1. **Only 2020s Predictions Are Cached**
**Problem**: The `MoviePredictor.predict_2020s_movies()` ONLY handles 2020s movies, but we need predictions for ALL decades.
- Current: Only stores `decade: 2020` in database
- Need: Store predictions for 1920s-2020s (11 decades total)
- Impact: Missing 10 decades of prediction data

#### 2. **Predictions vs Validation Confusion**
**Problem**: We're conflating two different concepts:
- **Predictions**: Which movies from a decade SHOULD be in 1001 Movies list
- **Validation**: How accurate our algorithm is at predicting what's ACTUALLY in the list

Current implementation only calculates validation (accuracy testing), not predictions for each decade.

#### 3. **No Decade-Based Movie Predictions**
The previous branch's `PredictionsCache.get_predictions()` could handle ANY decade, but our current implementation hardcodes 2020.

#### 4. **Profile Comparison Not Working**
- Aggregation job failed/was discarded
- No proper fallback when cache is missing
- Tuples in data causing JSON encoding errors

#### 5. **Missing Features from Previous Branch**
- **Decade Selector**: UI to switch between decades
- **Per-Decade Predictions**: Top movies from each decade that should be in 1001
- **Historical View**: See predictions for 1920s, 1930s, etc.
- **Cache Warmup**: Pre-populate cache for common queries

## Required Improvements

### 1. Create Decade-Aware Movie Predictor
```elixir
def predict_decade_movies(decade, limit \\ 100, profile) do
  start_date = Date.new!(decade, 1, 1)
  end_date = Date.new!(decade + 9, 12, 31)
  
  # Get movies from specific decade
  # Apply scoring
  # Return predictions
end
```

### 2. Cache Structure Changes
Instead of:
```elixir
PredictionCache.upsert_cache(%{
  decade: 2020,  # Only 2020s
  movie_scores: %{...}
})
```

Need:
```elixir
# Cache predictions for EACH decade
[1920, 1930, 1940, 1950, 1960, 1970, 1980, 1990, 2000, 2010, 2020]
|> Enum.each(fn decade ->
  PredictionCache.upsert_cache(%{
    decade: decade,
    movie_scores: predict_decade_movies(decade, ...),
    ...
  })
end)
```

### 3. Separate Jobs for Each Decade's Predictions
```elixir
# Current: Only one job for 2020s
%{action: "calculate_predictions", profile_id: profile_id}

# Need: One job per decade
%{action: "calculate_predictions", profile_id: profile_id, decade: 1920}
%{action: "calculate_predictions", profile_id: profile_id, decade: 1930}
# ... etc for all decades
```

### 4. Fix Data Structure Issues
- Convert ALL tuples to lists/maps before JSON encoding
- Handle nil values properly
- Ensure all MetricWeightProfile structs are converted to plain maps

### 5. Implement Proper Fallbacks
When cache is missing:
- Show loading indicator
- Offer manual refresh button
- NEVER auto-calculate expensive queries

## Implementation Plan

### Phase 1: Fix Core Prediction Logic
1. [ ] Update `MoviePredictor` to handle any decade, not just 2020s
2. [ ] Create `predict_decade_movies/3` function
3. [ ] Update database schema if needed to handle multiple decades

### Phase 2: Update Job System
1. [ ] Modify `PredictionsOrchestrator` to queue jobs for ALL decades
2. [ ] Update `PredictionsWorker` to handle decade parameter
3. [ ] Ensure each decade's predictions are saved separately

### Phase 3: Fix Caching Layer
1. [ ] Update `PredictionsCache` to handle decade queries
2. [ ] Fix profile comparison JSON encoding issues
3. [ ] Implement proper cache key structure for decades

### Phase 4: Restore UI Features
1. [ ] Add decade selector to predictions page
2. [ ] Display predictions for selected decade
3. [ ] Show validation accuracy per decade
4. [ ] Fix profile comparison display

### Phase 5: Testing & Optimization
1. [ ] Test all decades load correctly
2. [ ] Verify no timeouts occur
3. [ ] Ensure cache persistence works
4. [ ] Add monitoring for job failures

## Key Differences from Previous Branch

| Feature | Previous Branch (08-19-code_rabbit_audit) | Current Implementation | Needed |
|---------|-------------------------------------------|------------------------|--------|
| Decades Covered | 2020s only (but extensible) | 2020s only (hardcoded) | ALL decades (1920s-2020s) |
| Calculation Type | Real-time with memory cache | Background jobs with DB cache | ✅ Keep this |
| Predictions | Per-decade predictions possible | Only 2020s | Fix to support all decades |
| Validation | All decades validated | All decades validated | ✅ Working |
| Profile Comparison | Real-time calculation | Background job (broken) | Fix JSON encoding |
| Cache Storage | Memory only (Cachex) | Memory + Database | ✅ Better approach |
| Job System | None (synchronous) | Orchestrated jobs | ✅ Keep this |

## Recommended Architecture

```
PredictionsOrchestrator
├── Calculate Predictions (11 jobs - one per decade)
│   ├── 1920s predictions → cache
│   ├── 1930s predictions → cache
│   └── ... through 2020s
├── Calculate Validations (11 jobs - one per decade)
│   ├── 1920s validation → cache
│   ├── 1930s validation → cache
│   └── ... through 2020s
├── Aggregate Validation → cache
└── Calculate Comparison → cache
```

Total: 24 small jobs instead of 1 massive job

## Next Steps

1. **Immediate**: Fix the decade limitation in MoviePredictor
2. **Short-term**: Update job system to handle all decades
3. **Medium-term**: Fix JSON encoding issues
4. **Long-term**: Add UI features for decade selection

## Success Criteria

- [ ] All 11 decades (1920s-2020s) have cached predictions
- [ ] Each decade shows top 100-1000 movies that should be in 1001 list
- [ ] Validation shows accuracy for each decade
- [ ] Profile comparison works without JSON errors
- [ ] Page loads instantly from cache
- [ ] No jobs timeout (all complete in <60 seconds)
- [ ] Manual refresh available when cache is stale