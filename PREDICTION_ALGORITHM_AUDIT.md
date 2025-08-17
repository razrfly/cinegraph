# Prediction Algorithm Audit & Improvement Plan

## Current State Analysis

### Working Features ✅
1. **Basic Predictions**: Successfully predicting 2020s movies likely to be added to 1001 Movies list
2. **Historical Validation**: Shows accuracy across all decades (1920s-2020s)
3. **Caching System**: PredictionsCache module provides 15-minute caching for predictions
4. **Multiple Weight Profiles**: 5 profiles exist in database (Balanced, Award Winner, Critics Choice, Crowd Pleaser, Cult Classic)
5. **Dynamic Decade Detection**: System dynamically detects all decades with data

### Issues Found 🔴

#### 1. Tune Algorithm Feature Broken
**Problem**: When clicking "Tune Algorithm" and trying to switch profiles or adjust weights, it fails with "Invalid weight values. Please check your inputs"

**Root Cause Analysis**:
- In `index.ex:154-163`: The `update_weights` handler expects form params with string values like "popular_opinion"
- The form is sending integer values (0-50) but the conversion `String.to_float(params["popular_opinion"])` fails
- The params are coming through as strings but might be missing or have wrong keys

**Evidence**:
```elixir
# Line 158: This fails because params keys don't match expected format
new_weights = %{
  popular_opinion: String.to_float(params["popular_opinion"]) / 100,
  # ...
}
```

#### 2. Profile Switching Not Working
**Problem**: Selecting a different profile from dropdown doesn't recalculate predictions

**Root Cause**: 
- The profile selector sends profile name but the recalculation might be failing silently
- Cache key generation might not be differentiating between profiles properly

#### 3. No Comparative Analysis
**Problem**: Can't compare performance of different weight profiles side-by-side

**Current Limitation**:
- Only one profile can be tested at a time
- No way to see which profile performs best per decade
- Manual switching between profiles is tedious

### Performance Concerns ⚠️

1. **Recalculation Cost**: Running predictions for 100+ movies with complex scoring is expensive
2. **Database Load**: Each validation runs hundreds of queries
3. **Memory Usage**: Storing results for all 5 profiles × all decades could be memory-intensive
4. **User Experience**: Long wait times when switching profiles

## Proposed Improvements

### Phase 1: Fix Immediate Issues
1. **Fix Weight Tuner Form**
   - Correct parameter naming in form submission
   - Add validation for weight values
   - Ensure weights sum to 100%

2. **Fix Profile Switching**
   - Debug profile selection handler
   - Ensure cache keys are unique per profile
   - Add loading states and error handling

### Phase 2: Implement Comparative Analysis
1. **Pre-calculate All Profiles**
   - Run validation for all 5 profiles in background
   - Cache results for 1 hour (more stable than predictions)
   - Show loading progress

2. **Enhanced Validation View**
   - Add tabs or dropdown to switch between profile results
   - Show side-by-side comparison table
   - Highlight best-performing profile per decade

3. **Performance Metrics**
   - Overall accuracy per profile
   - Best profile per decade
   - Consistency score (low variance across decades)
   - Specific strengths (e.g., "Award Winner" better for 1950s-1970s)

### Phase 3: Advanced Features
1. **Hybrid Profiles**
   - Identify if different profiles work better for different eras
   - Create composite scoring based on decade

2. **Statistical Analysis**
   - Confidence intervals for accuracy
   - Statistical significance of profile differences
   - Trend analysis across decades

3. **Custom Weight Optimization**
   - Allow saving custom weight combinations
   - A/B testing framework for profiles
   - Machine learning to find optimal weights

## Implementation Strategy

### Quick Wins (1-2 hours)
1. Fix the weight tuner form parameter issue
2. Add proper error messages
3. Fix profile dropdown selection

### Medium Term (4-6 hours)
1. Implement background calculation for all profiles
2. Create comparison view in Historical Validation
3. Add comprehensive caching

### Long Term (1-2 days)
1. Build statistical analysis tools
2. Implement profile optimization
3. Create detailed performance dashboards

## Technical Recommendations

### Caching Strategy
```elixir
# Cache all profile validations for 1 hour
# Key: "validation:all_profiles:#{date}"
# This allows daily updates while preventing recalculation spam
```

### Database Optimization
- Add composite indexes for scoring queries
- Consider materialized views for decade aggregations
- Batch queries where possible

### UI/UX Improvements
- Show which profile is currently active
- Add tooltips explaining each profile's focus
- Provide visual indicators for performance differences
- Progressive loading for better perceived performance

## Risk Assessment

### High Priority Risks
1. **Data Accuracy**: Wrong calculations could undermine trust
2. **Performance**: Slow calculations frustrate users
3. **Cache Invalidation**: Stale data could mislead decisions

### Mitigation Strategies
1. Add comprehensive tests for scoring calculations
2. Implement background jobs for heavy calculations
3. Clear cache on data updates, add cache versioning

## Success Metrics

1. **Functionality**: All 5 profiles can be tested and compared
2. **Performance**: Results load in <3 seconds (from cache)
3. **Accuracy**: Clear winner emerges for best overall profile
4. **Insights**: Discover decade-specific profile advantages
5. **User Experience**: Smooth profile switching, clear visualizations

## Next Steps

1. Create GitHub issue with this audit
2. Fix the immediate form parameter bug
3. Implement profile comparison view
4. Add comprehensive caching layer
5. Deploy and monitor performance