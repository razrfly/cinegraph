# Post-Mortem: Movie Prediction System Implementation Failure

## Issue Reference
- **Original Issue**: #322 - 2020s Movie Predictions: Which Films Will Make Future 1001 Movies Lists?
- **Branch**: `prediction-working` 
- **Status**: Complete system failure
- **Date**: August 17, 2025

## What Was Supposed to Work

### The Vision
A movie prediction system that would:
1. Show top 100 2020s movies with percentage likelihood of being added to future 1001 Movies lists
2. Use 5-criteria weighted algorithm (Critical Acclaim 35%, Festival Recognition 30%, Cultural Impact 20%, Technical Innovation 10%, Auteur Recognition 5%)
3. Provide historical validation showing 90%+ accuracy on past decades
4. Load quickly with good UI/UX

### Expected Output
```
Rank │ Movie                           │ Likelihood │ Status
─────┼─────────────────────────────────┼────────────┼────────
  1  │ Everything Everywhere All...    │    94%     │ 🔮 Future
  2  │ The Power of the Dog (2021)     │    89%     │ ✅ Added
  3  │ Drive My Car (2021)             │    87%     │ ✅ Added
```

## What Actually Happened

### Critical Failures

#### 1. **Calculation Logic Completely Broken**
- **Expected**: Movies showing meaningful percentages (60-95% for top candidates)
- **Actual**: ALL movies showing 0.0% likelihood despite having valid individual criterion scores
- **Root Cause**: Multiple variable shadowing and type conversion bugs in the weighted calculation

#### 2. **Performance Disaster**
- **Expected**: Sub-second loading for top 100 predictions
- **Actual**: 30+ second loading times, system essentially unusable
- **Root Cause**: N+1 query patterns executing 10+ database queries per movie

#### 3. **UI/UX Complete Failure**
- **Expected**: Clean, fast interface showing predictions
- **Actual**: Extremely slow loading, horrible visual design, unusable interface
- **Root Cause**: No materialized views, poor data loading strategy, minimal UI polish

## Technical Root Causes

### 1. **Database Architecture Mistakes**
```elixir
# WRONG: This creates N+1 queries (10+ per movie)
def score_critical_acclaim(movie) do
  query = from em in "external_metrics", where: em.movie_id == ^movie.id
  Repo.all(query)  # Executes for EVERY movie individually
end
```

**Problem**: No batch loading, no materialized views, no performance optimization

### 2. **Arithmetic Logic Bugs**
```elixir
# BUG: Variable shadowing overwrites the destructured variable
weighted_total = 
  Enum.reduce(scores, 0, fn {criterion, score}, acc ->
    score = score || 0.0  # ← This overwrites the destructured 'score'!
    weight = weights[criterion] || 0.0
    acc + (score * weight)  # Always uses 0.0
  end)
```

**Problem**: Fundamental arithmetic errors causing all calculations to return 0

### 3. **Type Conversion Disasters**
```elixir
# BUG: Passing array when function expects number
director_info[movie.id] || []  # Returns array
# But function signature expects: score_auteur_recognition_from_batch(director_1001_count)
```

**Problem**: Type mismatches throughout the system

### 4. **No Validation or Testing**
- No unit tests for calculation logic
- No integration tests for end-to-end flow
- No performance benchmarks
- No data validation

## Why This Failed So Spectacularly

### 1. **Over-Engineering Without Foundation**
- Built complex batch processing before verifying basic calculations worked
- Created elaborate UI before ensuring backend functioned
- Optimized for performance while core logic was fundamentally broken

### 2. **Poor Development Process**
- No incremental testing of calculation logic
- No validation against known good data
- No performance testing during development
- Multiple layers of abstraction hiding bugs

### 3. **Database Design Oversights**
- No materialized views for expensive calculations
- No pre-computed scoring metrics
- No batch processing architecture from the start
- Relying on real-time calculation for complex algorithms

### 4. **Calculation Logic Complexity**
- 5 different scoring algorithms with different data sources
- Complex weighted calculations prone to arithmetic errors
- Multiple nil handling patterns creating inconsistencies
- No intermediate result validation

## Lessons Learned

### 1. **Start Simple, Build Up**
- Implement basic calculation for ONE movie first
- Verify arithmetic logic with manual calculations
- Add complexity only after core logic is proven

### 2. **Database-First Approach Needed**
- Materialized views for pre-computed scores
- Batch-loading architecture from day 1
- Performance testing with realistic data volumes

### 3. **Test-Driven Development Required**
- Unit tests for every calculation function
- Integration tests for end-to-end flow
- Performance benchmarks as acceptance criteria

### 4. **Incremental Validation**
- Test with 1 movie, then 10, then 100
- Compare results against manual calculations
- Validate intermediate results at each step

## Recommended Restart Approach

### Phase 1: Foundation (Week 1)
1. **Create materialized view** with pre-computed criterion scores
2. **Build simple calculator** for ONE movie with manual validation
3. **Unit test every calculation** against known good data
4. **Verify arithmetic logic** produces expected results

### Phase 2: Scaling (Week 2)
1. **Batch processing architecture** using materialized views
2. **Performance optimization** targeting sub-second response
3. **Integration testing** with realistic data volumes
4. **Error handling and edge cases**

### Phase 3: Interface (Week 3)
1. **Clean, fast UI** focusing on performance
2. **Progressive loading** for better user experience
3. **Visual design improvements**
4. **Export and analysis features**

## Data Requirements for Restart

### Materialized View Needed
```sql
CREATE MATERIALIZED VIEW movie_prediction_scores AS
SELECT 
  m.id,
  m.title,
  m.release_date,
  -- Pre-computed criterion scores
  calculate_critical_acclaim(m.id) as critical_acclaim_score,
  calculate_festival_recognition(m.id) as festival_recognition_score,
  calculate_cultural_impact(m.id) as cultural_impact_score,
  calculate_technical_innovation(m.id) as technical_innovation_score,
  calculate_auteur_recognition(m.id) as auteur_recognition_score
FROM movies m
WHERE EXTRACT(YEAR FROM m.release_date) >= 2020;
```

### Success Metrics for Restart
- **Performance**: Sub-1-second loading for top 100 predictions
- **Accuracy**: Manual verification of calculation logic with sample movies
- **UI**: Clean, professional interface
- **Reliability**: No arithmetic errors, proper nil handling

## Conclusion

This was a complete system failure due to:
1. **Broken arithmetic logic** (variable shadowing, type mismatches)
2. **Terrible performance** (N+1 queries, no optimization)
3. **Poor UI/UX** (slow, ugly, unusable)

The restart should focus on **database-first architecture** with materialized views, **test-driven development** for calculation logic, and **incremental building** to avoid these mistakes.

**Status**: Marking issue #322 as blocked pending complete restart with lessons learned.