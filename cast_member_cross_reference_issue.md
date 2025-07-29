# Cast Member Cross-Reference Architecture for Cinegraph

## Overview

This issue examines how to enhance the existing cast member data structure to enable powerful cross-referencing capabilities between people and movies in our graph-based movie recommendation system.

## Current State Analysis

### Existing Structure
- **People Table**: Contains basic person information (name, tmdb_id, biography, etc.)
- **Movie_Credits Table**: Junction table linking people to movies with role information
- **Credit Types**: "cast" and "crew" with additional metadata (character, department, job)

### Current Limitations
1. Limited cross-referencing capabilities between people across movies
2. No efficient way to find collaboration patterns
3. Missing relationship strength indicators
4. No tracking of recurring partnerships

## Proposed Enhancements

### 1. Enhanced Person-to-Person Relationships

#### New Tables/Structures Needed:

**person_collaborations**
```sql
- id (primary key)
- person1_id (foreign key to people)
- person2_id (foreign key to people)
- collaboration_count (integer)
- first_collaboration_date (date)
- last_collaboration_date (date)
- collaboration_types (array) -- e.g., ["actor-actor", "actor-director"]
```

**collaboration_details**
```sql
- id (primary key)
- collaboration_id (foreign key to person_collaborations)
- movie_id (foreign key to movies)
- person1_role (string) -- their role in this specific movie
- person2_role (string)
- year (integer)
```

### 2. Graph-Oriented Features

#### Key Relationships to Track:
1. **Direct Collaborations**: People who worked together on the same movie
2. **Collaboration Frequency**: How often people work together
3. **Role Combinations**: Actor-Director pairs, Actor-Actor pairs, etc.
4. **Career Trajectories**: How people's collaborations evolve over time
5. **Network Effects**: Degrees of separation between people

#### Suggested Metrics:
- **Collaboration Score**: Weighted by number of movies, roles, and success metrics
- **Network Centrality**: How connected a person is within the industry
- **Genre Affinity**: Which people frequently work together in specific genres
- **Temporal Patterns**: Recurring collaborations over time periods

### 3. Implementation Strategies

#### Option A: PostgreSQL with Graph Extensions
- Use recursive CTEs for traversing relationships
- Create materialized views for common queries
- Implement custom functions for graph algorithms

#### Option B: Hybrid Approach
- Keep PostgreSQL for core data
- Add graph database (Neo4j) for relationship queries
- Sync data between systems

#### Option C: Enhanced Relational Model
- Optimize current structure with additional indexes
- Pre-compute common relationship patterns
- Use JSONB for flexible relationship metadata

### 4. Query Patterns to Support

```elixir
# Find all people who worked with a specific person
Movies.find_collaborators(person_id)

# Find shortest path between two people
Movies.find_connection_path(person1_id, person2_id)

# Find frequent collaborator pairs
Movies.find_frequent_collaborations(min_movies: 3)

# Find people who bridge different groups
Movies.find_network_bridges()

# Find collaboration patterns by genre
Movies.find_genre_collaborations(genre_id)
```

### 5. Data Migration Considerations

1. **Initial Population**: 
   - Process existing movie_credits to build collaboration data
   - Calculate historical metrics
   - Identify key relationships

2. **Ongoing Updates**:
   - Update collaborations when new movies are added
   - Recalculate metrics periodically
   - Handle person merges/updates

### 6. Performance Optimizations

- **Indexes**: 
  - Composite indexes on person pairs
  - Partial indexes for active collaborations
  - GIN indexes for array fields

- **Caching**:
  - Cache frequent collaboration queries
  - Pre-compute network metrics
  - Use materialized views for complex aggregations

### 7. Graph Visualization Considerations

For the UI/frontend integration:
- Node size based on person importance/centrality
- Edge thickness based on collaboration frequency
- Color coding for different role types
- Clustering for frequent collaborator groups

## Benefits for Recommendation System

1. **Enhanced Recommendations**: "If you liked movies with this actor-director pair..."
2. **Discovery Features**: "Explore the Kevin Bacon game" / "Six degrees of separation"
3. **Career Analysis**: "This director frequently works with these actors"
4. **Trend Detection**: "Emerging collaboration patterns in 2020s cinema"

## Technical Decisions Needed

1. **Storage Strategy**: Pure PostgreSQL vs. Hybrid with graph DB
2. **Update Frequency**: Real-time vs. batch processing
3. **Depth Limits**: How many degrees of separation to pre-compute
4. **Performance Targets**: Query response time requirements

## Next Steps

1. Benchmark query performance with current data volume
2. Prototype key relationship queries
3. Evaluate graph database integration options
4. Design API endpoints for cross-reference features
5. Plan UI components for visualization

## Questions for Discussion

1. What types of cross-references are most valuable for users?
2. Should we track crew-crew relationships or focus on cast?
3. How important is real-time relationship updates?
4. What's our target query performance for complex traversals?
5. Should we include TV shows in the collaboration network?

## Reference Examples

- **IMDb**: "Frequent Collaborators" section on person pages
- **Letterboxd**: Actor/Director partnership statistics  
- **The Movie Database**: "Known For" associations
- **Six Degrees of Kevin Bacon**: Classic movie connection game

## Conclusion

Implementing a robust cross-referencing system for cast and crew will significantly enhance Cinegraph's ability to discover patterns, make recommendations, and provide unique insights into the film industry's collaborative nature. The key is choosing the right balance between query flexibility, performance, and implementation complexity.