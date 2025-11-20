# Postmortem: Failed Predictions Caching Implementation

## Issue #350: Predictions Caching Implementation Failure

### Summary
An attempt to implement database-backed caching for movie predictions to address performance issues (2-4 second load times) failed due to fundamental misunderstandings about the existing architecture and incorrect implementation of the caching layer.

### Timeline
- **Branch**: `08-19-caching_predictions` (failed)
- **Rollback to**: `08-19-code_rabbit_audit` (working)
- **Problem**: Predictions page still performs expensive queries despite cache existing

### Original Goal
Move expensive prediction calculations (2-4 second queries with multiple JOINs) to background Oban jobs and serve from cache to achieve sub-second response times.

### What Was Attempted

#### 1. Database Schema
✅ **WORKED**: Created `prediction_cache` table migration
```elixir
create table(:prediction_cache) do
  add :decade, :integer, null: false
  add :profile_id, references(:metric_weight_profiles)
  add :movie_scores, :map
  add :statistics, :map
  add :calculated_at, :utc_datetime
  timestamps()
end
```

#### 2. Cache Infrastructure
⚠️ **PARTIALLY WORKED**: 
- `PredictionCache` schema module - OK
- `RefreshManager` for manual refresh - OK
- `StalenessTracker` for tracking changes - OK

#### 3. Worker Implementation
❌ **FAILED COMPLETELY**: `PredictionCalculator` worker
- Used wrong scoring logic (recreated from scratch instead of using existing)
- Weight key mismatch: profile has `"awards", "cultural", "people"` but worker expected `"critical_acclaim", "audience_reception", "festival_recognition"`
- Produced scores in wrong range (0-2.5 instead of 0-1)
- Didn't use the existing `ScoringService.apply_scoring` query

#### 4. Cache Integration
❌ **FAILED**: Modified `PredictionsCache` module
- Changed from direct calculation to cache-only mode
- But cache lookup still triggered database queries
- Multiple database hits even when cache existed
- String vs atom key mismatches in cached data

#### 5. LiveView Integration
⚠️ **PARTIALLY FAILED**: 
- Added cache status handling
- Added refresh button
- But validation_result nil checks were missing
- Format_status missing clause for `:predicted`

### Root Causes of Failure

#### 1. Misunderstanding of Existing Architecture
The original system uses `ScoringService.apply_scoring` which is a complex Ecto query with:
- Multiple JOINs (external_metrics, festival_nominations, person_metrics)
- Database-side calculations using fragments
- Returns `discovery_score` field in results

The caching attempt tried to replicate this in Elixir code but got it completely wrong.

#### 2. Weight System Mismatch
```elixir
# What the profile actually has:
%{
  "awards" => 0.2,
  "cultural" => 0.2,
  "financial" => 0.0,
  "people" => 0.2,
  "popular_opinion" => 0.4
}

# What PredictionCalculator expected:
%{
  "critical_acclaim" => 0.2,
  "audience_reception" => 0.2,
  "festival_recognition" => 0.15,
  "cast_quality" => 0.15,
  "director_quality" => 0.15,
  "cultural_impact" => 0.15
}
```

#### 3. Cache Not Actually Being Used
Even when cache existed (verified in database), the predictions page still ran the expensive queries because:
- Cache lookup code path wasn't properly integrated
- LiveView was still calling the original calculation methods
- Cache data structure didn't match expected format

#### 4. Score Range Issues
- Original scores: 0-100 (percentages)
- Worker produced: 0-2.5 (due to weight accumulation)
- Display expected: 0-100
- Result: 250% likelihood scores

### What Actually Works (Salvageable)

1. ✅ Database migration for prediction_cache table
2. ✅ Basic cache schema module structure
3. ✅ RefreshManager concept (needs implementation fix)
4. ✅ Import Dashboard UI for manual refresh
5. ✅ Basic Cachex in-memory caching setup

### Correct Implementation Strategy

#### Step 1: Fix the Worker to Use Existing Logic
```elixir
defp calculate_predictions_for_decade(profile, decade) do
  # DON'T recreate the scoring logic
  # DO use the existing MoviePredictor
  
  predictions = MoviePredictor.predict_2020s_movies(1000, profile)
  
  # Transform to cache format
  Enum.reduce(predictions.predictions, %{}, fn pred, acc ->
    Map.put(acc, pred.id, %{
      title: pred.title,
      score: pred.prediction.likelihood_percentage, # Already 0-100
      release_date: pred.release_date,
      canonical_sources: pred.canonical_sources
    })
  end)
end
```

#### Step 2: Fix Cache Integration
```elixir
def get_predictions(limit, profile) do
  # Check database cache first
  case PredictionCache.get_cached_predictions(2020, profile.id) do
    nil -> 
      # Return cache missing error, don't calculate
      {:error, :cache_missing}
    
    cache ->
      # Use cached data directly
      format_cached_predictions(cache, limit)
  end
end
```

#### Step 3: Fix LiveView to Handle Cache States
```elixir
def mount(_params, _session, socket) do
  case PredictionsCache.get_predictions(100, profile) do
    {:error, :cache_missing} ->
      # Show cache missing UI with refresh button
      assign(socket, cache_status: :missing)
    
    predictions ->
      # Use cached predictions
      assign(socket, predictions_result: predictions)
  end
end
```

### Lessons Learned

1. **Don't recreate existing logic** - Use the working `MoviePredictor` and `ScoringService`
2. **Understand data flow** - The scoring happens in the database via complex queries
3. **Test incrementally** - Should have tested worker output before integration
4. **Match data structures** - Ensure cache format matches what consumers expect
5. **Preserve working code** - The original in-memory caching was working, just slow

### Action Items

1. **Revert to working branch** (`08-19-code_rabbit_audit`)
2. **Keep salvageable parts**:
   - Migration for prediction_cache table
   - Basic structure of RefreshManager
   - Import Dashboard UI elements
3. **Reimplement correctly**:
   - Worker uses `MoviePredictor.predict_2020s_movies`
   - Cache stores results in correct format
   - LiveView properly handles cache states
   - Manual refresh only (no automatic calculation)
4. **Test thoroughly**:
   - Verify cache is actually used (no DB queries)
   - Check score ranges are correct (0-100%)
   - Ensure all UI states work (missing, loading, ready)

### Verification Checklist

- [ ] Cache refresh creates entries with scores 0-100
- [ ] Predictions page loads without running complex queries
- [ ] Refresh button triggers background job
- [ ] Cache missing state shows appropriate UI
- [ ] Validation results handle nil properly
- [ ] No duplicate database queries when cache exists
- [ ] Scores display as reasonable percentages

### References
- Original Issue: #223 (Performance optimization)
- Failed PR: #349 (Caching implementation)
- Working branch: `08-19-code_rabbit_audit`
- Failed branches: `08-19-caching_predictions`, `08-19-broken`