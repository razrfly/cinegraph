# CRI System Redesign - Proper Architecture

## Problems with Previous Implementation
1. **Data Duplication**: Created a `metrics` table that just duplicated data from `external_metrics`, `festival_nominations`, and `canonical_sources`
2. **Poor Naming**: Tables weren't prefixed consistently (e.g., `weight_profiles` instead of `metric_weight_profiles`)
3. **Not Seedable**: No seed files for database resets
4. **Wasteful**: Storing normalized values that could be calculated on the fly

## New Architecture

### Core Principle: DON'T DUPLICATE DATA
- Use **VIEWS** to aggregate existing metric data
- Only store CRI-specific data in new tables

### Tables Needed (all prefixed with `metric_`):

1. **metric_definitions**
   - Defines how to interpret and normalize each metric type
   - Maps metric sources to CRI dimensions
   - Stores normalization strategies
   - This is METADATA only, no actual metric values

2. **metric_weight_profiles**  
   - User-created weight profiles for scoring
   - Dimension weights (timelessness, cultural_penetration, etc.)
   - Metric-level weight adjustments
   - Backtest results against canonical lists

3. **metric_cri_scores**
   - Calculated CRI scores for movie/profile combinations
   - Caches the calculated scores (since calculation is expensive)
   - Stores dimension breakdowns for analysis

### Views Needed:

1. **metric_values_view**
   - Aggregates data from:
     - `external_metrics` (IMDb, TMDb, Metacritic, RT ratings)
     - `festival_nominations` (awards and nominations)
     - `movies.canonical_sources` (1001 Movies, AFI, etc.)
   - Provides unified interface for all metric data
   - NO data duplication, just a view!

### Implementation Steps:

1. Create migration with proper table names (all `metric_` prefixed)
2. Create the view to aggregate existing metric data
3. Create seed files for:
   - metric_definitions (the 29 metric types)
   - metric_weight_profiles (the 7 initial profiles)
4. Update CRI module to:
   - Read from the view instead of a duplicated table
   - Calculate normalizations on the fly
   - Only store final CRI scores

### Benefits:
- No data duplication
- Single source of truth for each metric
- Consistent naming (`metric_*`)
- Fully seedable for database resets
- More maintainable

## Migration Structure

```sql
-- Create metric_definitions table
CREATE TABLE metric_definitions (
  -- metadata about each metric type
);

-- Create metric_weight_profiles table  
CREATE TABLE metric_weight_profiles (
  -- weight configurations
);

-- Create metric_cri_scores table
CREATE TABLE metric_cri_scores (
  -- calculated scores only
);

-- Create view for metric values
CREATE VIEW metric_values_view AS
  SELECT ... FROM external_metrics
  UNION ALL
  SELECT ... FROM festival_nominations
  UNION ALL  
  SELECT ... FROM movies (canonical_sources);
```

## Seed Structure

```
priv/repo/seeds/
  metric_definitions.exs    # 29 metric type definitions
  metric_weight_profiles.exs # 7 initial profiles
```

These get called from seeds.exs for easy database reset.