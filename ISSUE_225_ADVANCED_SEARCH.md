# Issue #225: Advanced Search & Filtering Using New Metrics System

## Summary
Implement comprehensive search and filtering capabilities leveraging our new metrics system to enable granular discovery of movies through awards, ratings, and people relationships.

## Background
With our new unified metrics system (metric_definitions, metric_scores, metric_weight_profiles), we now have the foundation to build powerful search capabilities that go beyond basic genre/country/language filters. Users should be able to discover movies through:
- Award achievements (nominations and wins)
- Rating thresholds across different sources
- Specific people involvement (actors, directors, etc.)
- Combined metric-based criteria

## Requirements

### 1. Award-Based Filtering
Enable users to filter movies by award achievements with progressive specificity:

#### General Award Filters
- **Any Award Recognition**: Movies with any festival nomination or win
- **Award Winners Only**: Movies that have won at least one award
- **Award Nominees**: Movies nominated but not necessarily won

#### Specific Festival Filters
- **By Organization**: Filter by specific festival organizations (e.g., "Academy Awards", "Cannes", "Venice")
- **By Category**: Filter by category type (e.g., "Best Picture", "Best Director", "Acting Awards")
- **By Achievement Level**: Separate filters for nominations vs. wins
- **By Year Range**: Awards received within specific time periods

#### Implementation Approach
```elixir
# Leverage festival_nominations table with joins to:
# - festival_organizations (for festival names)
# - festival_categories (for category types)
# - festival_ceremonies (for year information)

# Example query structure:
from m in Movie,
  join: fn in assoc(m, :festival_nominations),
  join: fc in assoc(fn, :category),
  join: fo in assoc(fc, :organization),
  where: fo.name == ^festival_name and fn.won == true
```

### 2. Rating-Based Filtering
Enable filtering by ratings from different sources with configurable thresholds:

#### Rating Sources to Support
- **TMDb Rating**: User ratings from TMDb (0-10 scale)
- **IMDb Rating**: User ratings from IMDb (0-10 scale)
- **Metacritic Score**: Critic aggregate score (0-100 scale)
- **Rotten Tomatoes**: Both Tomatometer and Audience Score (0-100 scale)

#### Filter Options
- **Minimum Rating Threshold**: Set minimum rating for any selected source
- **Rating Range**: Filter movies within a specific rating range
- **Combined Ratings**: Option to require minimum ratings across multiple sources
- **Missing Ratings Handling**: Include/exclude movies without ratings from specific sources

#### Implementation Approach
```elixir
# Use external_metrics table with metric_type differentiation
# Support both simple and compound rating queries

# Example: Movies with IMDb >= 7.0 AND Metacritic >= 70
from m in Movie,
  join: em_imdb in ExternalMetric,
    on: em_imdb.movie_id == m.id and 
        em_imdb.source == "imdb" and 
        em_imdb.metric_type == "rating_average",
  join: em_meta in ExternalMetric,
    on: em_meta.movie_id == m.id and
        em_meta.source == "metacritic" and
        em_meta.metric_type == "metascore",
  where: em_imdb.value >= 7.0 and em_meta.value >= 70
```

### 3. People-Based Filtering
Enable discovery through specific cast and crew involvement:

#### Filter Types
- **By Actor**: Find movies featuring specific actors
- **By Director**: Find movies directed by specific directors
- **By Writer**: Find movies written by specific writers
- **By Composer**: Find movies with music by specific composers
- **By Cinematographer**: Find movies shot by specific cinematographers

#### Features
- **Autocomplete Search**: Type-ahead search for people names
- **Multiple Selection**: Select multiple people with AND/OR logic
- **Role Filtering**: Filter by specific roles (e.g., "Lead Actor" vs. "Supporting")
- **Collaboration Filters**: Find movies where specific people worked together

#### Implementation Approach
```elixir
# Use movie_credits table with person relationships
# Support both single and multiple person queries

# Example: Movies with both Actor A and Director B
from m in Movie,
  join: mc_actor in MovieCredit,
    on: mc_actor.movie_id == m.id and mc_actor.person_id == ^actor_id,
  join: mc_director in MovieCredit,
    on: mc_director.movie_id == m.id and 
        mc_director.person_id == ^director_id and
        mc_director.job == "Director"
```

### 4. Metric Score Filtering
Leverage our new composite metric scores for advanced filtering:

#### Score Dimensions
- **Popular Opinion**: Combined audience ratings
- **Critical Acclaim**: Combined critic scores
- **Industry Recognition**: Award achievements
- **Cultural Impact**: Canonical lists + popularity

#### Filter Options
- **Minimum Score Threshold**: Per dimension or overall
- **Score Ranges**: Filter within specific score ranges
- **Weight Profile Selection**: Apply different weight profiles for scoring
- **Percentile Filtering**: Top 10%, top 25%, etc.

### 5. Combined Advanced Filters
Enable powerful combined queries:

#### Examples
- "Oscar-winning films from the 1970s with IMDb rating > 8.0"
- "Cannes Palme d'Or winners directed by specific director"
- "Films with Metacritic > 80 featuring specific actor"
- "Top 10% cultural impact films that won major awards"

### 6. UI/UX Design

#### Filter Panel Organization
```
Advanced Filters
├── Awards & Recognition
│   ├── Quick Filters
│   │   ├── [ ] Any Award Nomination
│   │   ├── [ ] Award Winner
│   │   └── [ ] Multiple Awards
│   ├── Specific Festivals
│   │   ├── [Dropdown] Select Festival
│   │   ├── [Dropdown] Select Category
│   │   └── ( ) Nominated ( ) Won ( ) Either
│   └── Award Year Range
│       └── [Year From] - [Year To]
│
├── Ratings
│   ├── Source Selection
│   │   ├── [ ] TMDb (User Rating)
│   │   ├── [ ] IMDb (User Rating)
│   │   ├── [ ] Metacritic (Critic Score)
│   │   └── [ ] Rotten Tomatoes
│   └── For each selected:
│       └── [Slider or Input] Minimum: ___ Maximum: ___
│
├── People
│   ├── [Search Input] Search for person...
│   ├── Role Filter
│   │   └── [Dropdown] All Roles / Actor / Director / Writer
│   └── Selected People
│       └── [Chip] Person Name [x]
│
└── Discovery Scores
    ├── [ ] Popular Opinion > [Slider]
    ├── [ ] Critical Acclaim > [Slider]
    ├── [ ] Industry Recognition > [Slider]
    └── [ ] Cultural Impact > [Slider]
```

#### UI Features
- **Collapsible Sections**: Each filter category can be collapsed
- **Active Filter Pills**: Show active filters as removable pills
- **Filter Count Badge**: Show number of active filters
- **Quick Clear**: Clear all filters or clear by section
- **Save Filter Sets**: Save commonly used filter combinations
- **Filter Preview**: Show result count before applying

### 7. Performance Considerations

#### Query Optimization
- **Indexed Columns**: Ensure proper indexes on frequently filtered columns
- **Query Building**: Build dynamic queries only for active filters
- **Caching Strategy**: Cache common filter combinations
- **Pagination**: Maintain efficient pagination with complex filters

#### Suggested Indexes
```sql
-- Award filtering
CREATE INDEX idx_festival_nominations_movie_won ON festival_nominations(movie_id, won);
CREATE INDEX idx_festival_categories_org_type ON festival_categories(organization_id, category_type);

-- Rating filtering
CREATE INDEX idx_external_metrics_movie_source_type ON external_metrics(movie_id, source, metric_type);

-- People filtering
CREATE INDEX idx_movie_credits_person_job ON movie_credits(person_id, job);
CREATE INDEX idx_movie_credits_movie_person ON movie_credits(movie_id, person_id);

-- Metric scores
CREATE INDEX idx_metric_scores_movie_profile ON metric_scores(movie_id, profile_id);
```

### 8. Implementation Phases

#### Phase 1: Core Infrastructure
- Extend `Cinegraph.Movies.Filters` module with new filter functions
- Add query builders for award, rating, and people filters
- Implement filter parameter parsing and validation

#### Phase 2: Basic UI Integration
- Add award filter section with simple options
- Add rating filter section with source selection
- Implement people search autocomplete

#### Phase 3: Advanced Features
- Add metric score filtering
- Implement combined filter logic
- Add saved filter sets functionality

#### Phase 4: Optimization
- Add database indexes
- Implement caching layer
- Optimize complex query performance

### 9. Testing Requirements

#### Unit Tests
- Test each filter function individually
- Test filter combination logic
- Test parameter validation

#### Integration Tests
- Test complex multi-filter queries
- Test performance with large datasets
- Test filter result accuracy

#### UI Tests
- Test filter interaction and updates
- Test filter persistence across navigation
- Test responsive design

### 10. Success Metrics
- Filter query response time < 500ms for 95% of queries
- Support for 10+ simultaneous filter criteria
- Accurate result counts for all filter combinations
- User engagement with advanced filters > 30% of searches

## Technical Decisions

### Why Leverage the New Metrics System?
1. **Unified Data Model**: All metrics normalized through metric_definitions
2. **Flexible Scoring**: metric_weight_profiles allow different ranking strategies
3. **Cached Computations**: metric_scores provide pre-computed values
4. **Extensibility**: Easy to add new metric sources and filters

### Query Strategy
- Use Ecto's dynamic query building for flexible filter combinations
- Leverage PostgreSQL's JSONB operators for canonical_sources filtering
- Use CTEs for complex aggregations to maintain readability

### UI Framework
- LiveView for real-time filter updates
- Alpine.js for interactive filter components
- Tailwind CSS for consistent styling

## Open Questions
1. Should we support saved/shareable filter URLs?
2. How should we handle filters that return 0 results?
3. Should we implement filter suggestions based on current results?
4. Do we need filter combination validation (e.g., mutually exclusive filters)?
5. Should we add export functionality for filtered results?

## Related Issues
- #223: API lookup tracking and resilience
- #228: Universal API/scraping tracking system
- #230: Import state system using unified metrics

## Acceptance Criteria
- [ ] Users can filter movies by award nominations and wins
- [ ] Users can filter movies by ratings from multiple sources
- [ ] Users can search and filter by specific people
- [ ] Users can combine multiple filter types
- [ ] Filters maintain state during pagination
- [ ] Filter results are accurate and performant
- [ ] UI is intuitive and responsive
- [ ] All filters have appropriate test coverage