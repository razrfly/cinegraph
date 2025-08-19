# Issue: Combine "Critical Acclaim" and "Popular Opinion" into Single Rating Category

## Problem Statement
Currently, the application treats "Critical Acclaim" (Metacritic/Rotten Tomatoes) and "Popular Opinion" (IMDb/TMDb) as separate categories. However, these actually represent the same type of data - aggregated user ratings - just from different platforms. The distinction is artificial and should be eliminated.

### Current State
- **Popular Opinion**: IMDb + TMDb ratings (50% each)
- **Critical Acclaim**: Metacritic + Rotten Tomatoes (50% each)
- Both use identical normalization (divide by max scale)
- Both represent mass audience opinions, not professional critics

### Proposed Change
Combine all four rating sources into a single "Popular Opinion" or "Audience Rating" category with equal weighting (25% each) or configurable weights.

## Affected Areas

### 1. Database/Seeds
- [ ] `/priv/repo/seeds/metric_definitions.exs` - Update metric category definitions
- [ ] `/priv/repo/seeds/metric_weight_profiles.exs` - Merge weight profiles for combined category

### 2. Discovery/Scoring System
- [ ] `/lib/cinegraph/movies/discovery_scoring.ex`
  - Remove `critical_acclaim` category
  - Update `calculate_popular_opinion` to include all 4 sources
  - Update scoring SQL queries
- [ ] `/lib/cinegraph/movies/discovery_scoring_simple.ex` - Similar updates
- [ ] `/lib/cinegraph/movies/discovery_common.ex` 
  - Update default weights
  - Update presets to remove critical_acclaim

### 3. Prediction System
- [ ] `/lib/cinegraph/predictions/criteria_scoring.ex`
  - Merge `score_critical_acclaim` logic into popular opinion
  - Update `normalize_critic_score` function name/logic
- [ ] `/lib/cinegraph/predictions/movie_predictor.ex` - Update weight references
- [ ] `/lib/cinegraph/predictions/historical_validator.ex` - Update validation logic

### 4. Movie Scoring/Filtering
- [ ] `/lib/cinegraph/movies/movie_scoring.ex` - Update scoring calculations
- [ ] `/lib/cinegraph/movies/filters.ex` - Update filter categories
- [ ] `/lib/cinegraph/movies/query/custom_filters.ex` - Merge filter logic
- [ ] `/lib/cinegraph/movies/query/custom_sorting.ex` - Update sort options
- [ ] `/lib/cinegraph/movies/query/params.ex` - Update parameter handling

### 5. Search System
- [ ] `/lib/cinegraph/movies.ex` - Update query builders
- [ ] `/lib/cinegraph/movies/search.ex` - Update search scoring

### 6. Metrics Service
- [ ] `/lib/cinegraph/metrics/scoring_service.ex` - Update metric calculations

### 7. UI Components

#### Metrics Page
- [ ] `/lib/cinegraph_web/live/metrics_live/index.html.heex`
  - Remove "Critical Acclaim" section
  - Combine all ratings under "Popular Opinion"
  - Update normalization table display
- [ ] `/lib/cinegraph_web/live/metrics_live/index.ex` - Update LiveView logic

#### Movie Pages
- [ ] `/lib/cinegraph_web/live/movie_live/show.html.heex` - Update score displays
- [ ] `/lib/cinegraph_web/live/movie_live/index.html.heex` - Update list view
- [ ] `/lib/cinegraph_web/live/movie_live/advanced_filters.ex` - Merge filter UI
- [ ] `/lib/cinegraph_web/live/movie_live/discovery_tuner.ex` - Remove critical acclaim slider

#### Predictions Page
- [ ] `/lib/cinegraph_web/live/predictions_live/index.html.heex` - Update UI
- [ ] `/lib/cinegraph_web/live/predictions_live/index.ex` - Update LiveView

### 8. Tests
- [ ] `/test/cinegraph/metrics/scoring_service_test.exs`
- [ ] `/test/cinegraph/predictions/criteria_scoring_test.exs`
- [ ] `/test/cinegraph/predictions/movie_predictor_test.exs`
- [ ] `/test/cinegraph/predictions/integration_test.exs`
- [ ] `/test/cinegraph_web/live/predictions_live_test.exs`

### 9. Documentation/Scripts
- [ ] Update any documentation mentioning the two categories
- [ ] `/priv/scripts/validate_predictions.exs` - Update validation logic
- [ ] Archive old test scripts that reference both categories

## Implementation Plan

### Step 1: Database/Configuration
1. Update seed files to merge categories
2. Create migration if needed for any stored configurations

### Step 2: Core Logic
1. Update discovery scoring modules
2. Update prediction scoring modules
3. Update filtering/sorting logic

### Step 3: UI Updates
1. Update LiveView templates
2. Update LiveView modules
3. Ensure consistent display across all pages

### Step 4: Testing
1. Update all affected tests
2. Add new tests for combined category
3. Verify no regressions in scoring accuracy

### Step 5: Migration/Deployment
1. Consider backward compatibility for saved user preferences
2. Update any cached scores if necessary
3. Document the change for users

## Benefits
- Simpler, more intuitive scoring system
- More accurate representation (all are user ratings)
- Easier to explain to users
- Reduces complexity in codebase
- Better weighting flexibility (4 sources instead of 2 categories)

## Considerations
- Users may have saved preferences with the old categories
- Some queries/reports may reference the old category names
- Need to ensure smooth migration without data loss