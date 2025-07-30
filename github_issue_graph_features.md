# Implement Graph-Based Movie Collaboration Features

## Overview
Add graph-based features to discover connections between actors, directors, and movies using the existing PostgreSQL database without adding graph database dependencies.

## Current State
We have a solid foundation:
- **Database Schema**: 
  - `movies`, `people`, and `movie_credits` tables with proper relationships
  - `credit_type` field distinguishes cast/crew roles
  - `job` field identifies directors, producers, etc.
- **Basic Queries**: 
  - `find_frequent_collaborators/2` in People context
  - Person show page displays collaborators
  - Basic movie recommendations via `external_recommendations` table

## Desired Features

### 1. Enhanced Recommendations
**Feature**: "If you liked movies with this actor-director pair..."
- Find movies with specific actor-director combinations
- Recommend other movies by the same collaborations

### 2. Discovery Features  
**Feature**: "Six degrees of separation" / "Kevin Bacon game"
- Find shortest path between any two actors through shared movies
- Interactive explorer to traverse connections

### 3. Career Analysis
**Feature**: "This director frequently works with these actors"
- Analyze collaboration patterns for directors
- Show collaboration frequency and success metrics

### 4. Trend Detection
**Feature**: "Emerging collaboration patterns in 2020s cinema"  
- Identify new actor-director pairs gaining popularity
- Track collaboration trends over time periods

## Implementation Steps

### Phase 1: Enhanced Query Functions (PostgreSQL CTEs)

#### Step 1.1: Actor-Director Collaboration Queries
```elixir
# In lib/cinegraph/collaborations.ex (new module)

def find_actor_director_movies(actor_id, director_id) do
  # Query movies where actor and director worked together
  # Using movie_credits table with proper joins
end

def find_similar_collaborations(actor_id, director_id) do
  # Find other actor-director pairs with similar genres/success
end
```

#### Step 1.2: Graph Traversal with Recursive CTEs
```elixir
def find_shortest_path(person1_id, person2_id, max_depth \\ 6) do
  # PostgreSQL recursive CTE to find connections
  # Returns path of people and movies between them
end
```

### Phase 2: Collaboration Analysis Module

#### Step 2.1: Create Collaborations Context
```elixir
# lib/cinegraph/collaborations.ex
defmodule Cinegraph.Collaborations do
  # Core functions for collaboration analysis
  
  def director_frequent_actors(director_id)
  def actor_frequent_directors(actor_id)  
  def collaboration_success_metrics(person1_id, person2_id)
  def trending_collaborations(date_range, limit \\ 20)
end
```

#### Step 2.2: Enhance Existing Contexts
- Add collaboration-aware functions to Movies and People contexts
- Extend recommendation logic to consider collaborations

### Phase 3: API/LiveView Integration

#### Step 3.1: LiveView Components
- Create `CollaborationGraphLive` for interactive exploration
- Add collaboration insights to existing movie/person pages
- Build "Six Degrees" game interface

#### Step 3.2: API Endpoints (if needed)
```elixir
# In router.ex
scope "/api", CinegraphWeb do
  get "/collaborations/:person1_id/:person2_id", CollaborationController, :show
  get "/six-degrees/:person1_id/:person2_id", SixDegreesController, :find_path
  get "/trends/collaborations", TrendsController, :collaborations
end
```

### Phase 4: Performance Optimization

#### Step 4.1: Database Indexes
```sql
-- Add composite indexes for collaboration queries
CREATE INDEX idx_credits_person_movie ON movie_credits(person_id, movie_id);
CREATE INDEX idx_credits_movie_type_job ON movie_credits(movie_id, credit_type, job);
```

#### Step 4.2: Materialized Views (Optional)
```sql
-- For expensive collaboration metrics
CREATE MATERIALIZED VIEW collaboration_pairs AS
SELECT ... -- Pre-calculate common collaborations
```

## Technical Approach

### PostgreSQL Features to Leverage:
1. **Recursive CTEs** for path finding
2. **Window Functions** for ranking and trends
3. **JSON Aggregation** for complex result sets
4. **Composite Indexes** for performance

### Query Examples:

**Find Actor-Director Movies:**
```sql
WITH actor_movies AS (
  SELECT movie_id FROM movie_credits 
  WHERE person_id = $1 AND credit_type = 'cast'
),
director_movies AS (
  SELECT movie_id FROM movie_credits 
  WHERE person_id = $2 AND job = 'Director'
)
SELECT m.* FROM movies m
JOIN actor_movies am ON m.id = am.movie_id
JOIN director_movies dm ON m.id = dm.movie_id;
```

**Six Degrees Path Finding:**
```sql
WITH RECURSIVE connections AS (
  -- Base case: direct connections
  SELECT ...
  UNION ALL
  -- Recursive case: connections through movies
  SELECT ...
)
SELECT * FROM connections WHERE target_reached LIMIT 1;
```

## Benefits of This Approach
1. **No new dependencies** - Uses existing PostgreSQL
2. **Leverages current schema** - Works with existing data model
3. **Incremental implementation** - Can build features progressively
4. **Performance** - PostgreSQL CTEs and indexes are highly optimized
5. **Maintainable** - Standard SQL queries, no graph database complexity

## Next Steps
1. Implement Phase 1 query functions
2. Test with existing movie data
3. Build simple UI to showcase features
4. Optimize based on real-world performance
5. Expand features based on user feedback

## Success Metrics
- Query performance < 100ms for common paths
- Support for paths up to 6 degrees
- Accurate collaboration recommendations
- Trending patterns updated daily