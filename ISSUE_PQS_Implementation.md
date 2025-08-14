# Person Quality Scores (PQS) - MVP Implementation Complete

## Summary

Successfully implemented a minimal viable Person Quality Score system that adds **"People"** as the fifth metric category alongside Ratings, Awards, Cultural, and Financial metrics. This creates a new dimension for discovering high-quality films based on the talent involved.

## What's Implemented ✅

### 1. Core Infrastructure
- **New table**: `person_metrics` for storing person quality scores
- **Schema**: `PersonMetric` with support for multiple score types
- **Module**: `PersonQualityScore` with calculation and storage functions

### 2. Director Quality Scoring (MVP)
- **Algorithm**: Simple but effective scoring based on:
  - Film count (20+ films = maximum points)
  - Average TMDb rating of their directed films
- **Scoring range**: 0-100 with famous directors getting high scores:
  - Akira Kurosawa: 87.4
  - Martin Scorsese: 86.55  
  - Ingmar Bergman: 86.11
  - Stan Brakhage: 77.62

### 3. Background Processing
- **Oban Worker**: `PersonQualityScoreWorker` for batch calculations
- **Individual scoring**: Calculate single person scores
- **Batch processing**: Calculate all directors at once
- **Scheduling**: Manual and automatic job scheduling

### 4. Data Storage Integration
- **Unified metrics**: Person scores stored in dedicated table
- **Version tracking**: Algorithm versioning for future improvements
- **Caching**: Weekly refresh cycle with expiration dates
- **Components tracking**: Detailed breakdown of score calculations

## Technical Implementation

### Database Schema
```sql
CREATE TABLE person_metrics (
  id SERIAL PRIMARY KEY,
  person_id BIGINT REFERENCES people(id),
  metric_type VARCHAR(255) NOT NULL, -- 'director_quality', 'actor_quality', etc.
  score FLOAT,
  components JSONB DEFAULT '{}',
  metadata JSONB DEFAULT '{}',
  calculated_at TIMESTAMP NOT NULL,
  valid_until TIMESTAMP,
  inserted_at TIMESTAMP,
  updated_at TIMESTAMP,
  UNIQUE(person_id, metric_type)
);
```

### Core Functions
- `PersonQualityScore.calculate_director_score/1` - Calculate score for individual director
- `PersonQualityScore.store_person_score/4` - Store score with components
- `PersonQualityScore.calculate_all_director_scores/0` - Batch process all directors  
- `PersonQualityScore.get_top_directors/1` - Query top-rated directors

### Background Jobs
```elixir
# Calculate single person
PersonQualityScoreWorker.schedule_person(person_id)

# Calculate all directors
PersonQualityScoreWorker.schedule_all_directors()
```

## Next Steps - Adding to Metrics Dashboard 🎯

### 1. Add "People" as Fifth Category
Current categories: **Ratings**, **Awards**, **Cultural**, **Financial**  
**New category**: **People** (directors, actors, writers, producers)

### 2. Dashboard Integration Needed:
- [ ] Add People category card to metrics overview section
- [ ] Update category stats calculation to include person metrics
- [ ] Add People filter button to metric definitions table  
- [ ] Update weight profiles to include "people" category
- [ ] Add People color scheme (suggest: orange `bg-orange-100 text-orange-800`)

### 3. Metric Definitions Integration:
- [ ] Add person quality metrics to `metric_definitions` table
- [ ] Create metric codes: `director_quality_score`, `actor_quality_score`, etc.
- [ ] Update coverage stats to include person metrics
- [ ] Add normalization rules for person scores (0-100 → 0-1)

### 4. Weight Profiles Enhancement:
- [ ] Update existing weight profiles to include "people" category
- [ ] Ensure all profile category weights sum to 100% (currently 4 categories, will be 5)
- [ ] Add person metrics to movie scoring algorithm

## Testing Results

Successfully calculated scores for top directors:
```
Director ID 677610 (Stan Brakhage): 77.62
Director ID 661617 (Ingmar Bergman): 86.11  
Director ID 661367 (Akira Kurosawa): 87.4
Director ID 653345 (Martin Scorsese): 86.55
Director ID 677424 (Hollis Frampton): 74.24
```

## Why This Matters

Person Quality Scores create a new dimension for movie discovery:
- **Ratings** tell you what people think
- **Awards** tell you what industry thinks  
- **Cultural** tells you what critics/historians think
- **Financial** tells you commercial success
- **People** tells you the talent level involved

This helps users discover films by following acclaimed directors, actors, and other talent - a proven way to find quality cinema.

## Future Enhancements (Post-MVP)

1. **Actor Quality Scores**: Similar algorithm for actors based on film quality
2. **Writer/Producer Scores**: Expand to other key roles
3. **Collaboration Scores**: Factor in working with other high-scored people  
4. **Genre Specialization**: Directors who excel in specific genres
5. **Career Trajectory**: Account for career phases and evolution
6. **Festival Integration**: Use festival awards when person linking is improved

## Files Created/Modified

### New Files:
- `lib/cinegraph/metrics/person_quality_score.ex`
- `lib/cinegraph/metrics/person_metric.ex` 
- `lib/cinegraph/workers/person_quality_score_worker.ex`
- `priv/repo/migrations/20250814091411_create_person_metrics.exs`

### Ready for Dashboard Integration:
- `lib/cinegraph_web/live/metrics_live/index.ex` (needs People category)
- `lib/cinegraph_web/live/metrics_live/index.html.heex` (needs People card)

## Impact

This implementation provides:
1. **Immediate value**: Can identify quality directors right now
2. **Foundation for growth**: Easy to extend to actors, writers, etc.
3. **Integration ready**: Fits into existing metrics infrastructure
4. **Performance optimized**: Background processing with caching
5. **Extensible design**: Version tracking and component breakdown for future algorithms

The next step is integrating this as the fifth metric category in the dashboard to make it visible and usable for movie discovery.