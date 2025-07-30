# Optimize PostgreSQL Tables for Graph Collaboration Features

## Overview
Based on PostgreSQL best practices review, we can improve the proposed table design for the collaboration graph features. This issue consolidates the recommendations and provides an optimized schema.

## Current Proposal Issues

### 1. **Table Redundancy**
The original 3-table design has significant overlap between `collaboration_summaries` and `collaboration_metrics`.

### 2. **Array Column Anti-patterns**
Using arrays for `movie_ids INTEGER[]` and `genres_worked TEXT[]` violates normalization principles and prevents referential integrity.

### 3. **Missing Bidirectional Lookups**
Current indexes don't support efficient lookups from both directions in person relationships.

### 4. **Data Type Issues**
- Using `FLOAT` for ratings instead of `NUMERIC`
- Using `TIMESTAMP` without timezone
- Missing constraints for data integrity

## Recommended Design (2 Tables + 1 Materialized View)

### 1. Main Collaborations Table (Consolidated)

```sql
-- Drop the old tables if they exist
DROP TABLE IF EXISTS collaboration_summaries CASCADE;
DROP TABLE IF EXISTS collaboration_metrics CASCADE;

-- Main collaboration summary table (consolidated)
CREATE TABLE collaborations (
  id SERIAL PRIMARY KEY,
  person_a_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  person_b_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  
  -- Core metrics
  collaboration_count INTEGER NOT NULL DEFAULT 0,
  first_collaboration_date DATE,
  latest_collaboration_date DATE,
  avg_movie_rating NUMERIC(3,1),
  total_revenue BIGINT DEFAULT 0,
  
  -- Yearly metrics (denormalized for performance)
  years_active INTEGER[],  -- Array of years they collaborated
  peak_year INTEGER,       -- Year with most collaborations
  
  -- Diversity metrics
  genre_diversity_score NUMERIC(3,2),
  role_diversity_score NUMERIC(3,2),
  
  -- Metadata
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  -- Constraints to prevent duplicates
  CONSTRAINT ordered_persons CHECK (person_a_id < person_b_id),
  CONSTRAINT unique_collaboration UNIQUE (person_a_id, person_b_id)
);

-- Detailed collaboration data (normalized)
CREATE TABLE collaboration_details (
  id SERIAL PRIMARY KEY,
  collaboration_id INTEGER NOT NULL REFERENCES collaborations(id) ON DELETE CASCADE,
  movie_id INTEGER NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
  collaboration_type TEXT NOT NULL, -- 'actor-actor', 'actor-director', etc.
  year INTEGER NOT NULL,
  
  -- Movie-specific data
  movie_rating NUMERIC(3,1),
  movie_revenue BIGINT,
  
  -- Ensure no duplicate entries
  UNIQUE(collaboration_id, movie_id, collaboration_type)
);

-- Essential indexes for performance
CREATE INDEX idx_collab_persons ON collaborations(person_a_id, person_b_id);
CREATE INDEX idx_collab_person_b ON collaborations(person_b_id, person_a_id);
CREATE INDEX idx_collab_count ON collaborations(collaboration_count DESC);
CREATE INDEX idx_collab_dates ON collaborations(first_collaboration_date, latest_collaboration_date);
CREATE INDEX idx_collab_revenue ON collaborations(total_revenue DESC) WHERE total_revenue > 0;

-- Covering index for common queries
CREATE INDEX idx_collab_summary_covering 
ON collaborations(person_a_id, person_b_id) 
INCLUDE (collaboration_count, first_collaboration_date, avg_movie_rating);

-- Indexes for details table
CREATE INDEX idx_collab_detail_collab ON collaboration_details(collaboration_id);
CREATE INDEX idx_collab_detail_movie ON collaboration_details(movie_id);
CREATE INDEX idx_collab_detail_year ON collaboration_details(year);
CREATE INDEX idx_collab_detail_type ON collaboration_details(collaboration_type);
```

### 2. Person Relationships Cache (Enhanced)

```sql
-- Person relationship cache for six degrees queries
CREATE TABLE person_relationships (
  id SERIAL PRIMARY KEY,
  from_person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  to_person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  degree INTEGER NOT NULL CHECK (degree BETWEEN 1 AND 6),
  path_count INTEGER DEFAULT 1,
  shortest_path INTEGER[] NOT NULL,
  
  -- Additional metrics
  strongest_connection_score NUMERIC(5,2), -- Based on collaboration count/quality
  calculated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  expires_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() + INTERVAL '7 days',
  
  -- Prevent duplicates
  CONSTRAINT unique_relationship UNIQUE (from_person_id, to_person_id)
);

-- Indexes for efficient lookups
CREATE INDEX idx_person_rel_lookup ON person_relationships(from_person_id, to_person_id);
CREATE INDEX idx_person_rel_degree ON person_relationships(degree, from_person_id);
CREATE INDEX idx_person_rel_expires ON person_relationships(expires_at);
```

### 3. Materialized View for Trends

```sql
-- Materialized view for yearly collaboration trends
CREATE MATERIALIZED VIEW person_collaboration_trends AS
SELECT 
  p.id as person_id,
  EXTRACT(YEAR FROM m.release_date)::INTEGER as year,
  COUNT(DISTINCT 
    CASE 
      WHEN c.person_a_id = p.id THEN c.person_b_id 
      ELSE c.person_a_id 
    END
  ) as unique_collaborators,
  COUNT(DISTINCT 
    CASE 
      WHEN EXTRACT(YEAR FROM c.first_collaboration_date) = EXTRACT(YEAR FROM m.release_date)
      THEN cd.collaboration_id 
    END
  ) as new_collaborators,
  COUNT(cd.id) as total_collaborations,
  AVG(cd.movie_rating) as avg_rating,
  SUM(cd.movie_revenue) as total_revenue,
  array_agg(DISTINCT mg.genre_id) as genre_ids
FROM people p
JOIN collaborations c ON (p.id = c.person_a_id OR p.id = c.person_b_id)
JOIN collaboration_details cd ON c.id = cd.collaboration_id
JOIN movies m ON cd.movie_id = m.id
LEFT JOIN movie_genres mg ON m.id = mg.movie_id
WHERE m.release_date IS NOT NULL
GROUP BY p.id, year;

-- Index for fast lookups
CREATE INDEX idx_trend_person_year ON person_collaboration_trends(person_id, year DESC);

-- Refresh strategy
CREATE OR REPLACE FUNCTION refresh_collaboration_trends()
RETURNS void AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY person_collaboration_trends;
END;
$$ LANGUAGE plpgsql;
```

## Helper Functions and Triggers

### 1. Automatic Timestamp Updates

```sql
CREATE OR REPLACE FUNCTION update_collaboration_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_collaboration_timestamp
BEFORE UPDATE ON collaborations
FOR EACH ROW
EXECUTE FUNCTION update_collaboration_timestamp();
```

### 2. Collaboration Ordering Function

```sql
-- Helper function to ensure consistent person ordering
CREATE OR REPLACE FUNCTION ensure_person_order(p1_id INTEGER, p2_id INTEGER)
RETURNS TABLE(person_a_id INTEGER, person_b_id INTEGER) AS $$
BEGIN
  IF p1_id < p2_id THEN
    RETURN QUERY SELECT p1_id, p2_id;
  ELSE
    RETURN QUERY SELECT p2_id, p1_id;
  END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;
```

### 3. Populate Collaborations Function

```sql
CREATE OR REPLACE FUNCTION populate_collaborations()
RETURNS void AS $$
DECLARE
  collab RECORD;
BEGIN
  -- Clear existing data
  TRUNCATE collaborations CASCADE;
  
  -- Find all unique collaborations
  FOR collab IN 
    WITH person_pairs AS (
      SELECT DISTINCT
        LEAST(mc1.person_id, mc2.person_id) as person_a_id,
        GREATEST(mc1.person_id, mc2.person_id) as person_b_id,
        mc1.movie_id,
        CASE 
          WHEN mc1.credit_type = 'cast' AND mc2.credit_type = 'cast' THEN 'actor-actor'
          WHEN mc1.credit_type = 'cast' AND mc2.job = 'Director' THEN 'actor-director'
          WHEN mc1.job = 'Director' AND mc2.credit_type = 'cast' THEN 'actor-director'
          WHEN mc1.job = 'Director' AND mc2.job = 'Director' THEN 'director-director'
          ELSE 'other'
        END as collaboration_type
      FROM movie_credits mc1
      JOIN movie_credits mc2 ON mc1.movie_id = mc2.movie_id
      WHERE mc1.person_id != mc2.person_id
    )
    SELECT 
      person_a_id,
      person_b_id,
      COUNT(DISTINCT movie_id) as collaboration_count,
      MIN(m.release_date) as first_collaboration_date,
      MAX(m.release_date) as latest_collaboration_date,
      AVG(m.vote_average)::NUMERIC(3,1) as avg_movie_rating,
      SUM(m.revenue) as total_revenue,
      array_agg(DISTINCT collaboration_type) as collaboration_types,
      array_agg(DISTINCT movie_id) as movie_ids
    FROM person_pairs pp
    JOIN movies m ON pp.movie_id = m.id
    GROUP BY person_a_id, person_b_id
  LOOP
    -- Insert main collaboration record
    INSERT INTO collaborations (
      person_a_id, person_b_id, collaboration_count,
      first_collaboration_date, latest_collaboration_date,
      avg_movie_rating, total_revenue
    ) VALUES (
      collab.person_a_id, collab.person_b_id, collab.collaboration_count,
      collab.first_collaboration_date, collab.latest_collaboration_date,
      collab.avg_movie_rating, collab.total_revenue
    );
    
    -- Insert details would go here...
  END LOOP;
END;
$$ LANGUAGE plpgsql;
```

## Migration Strategy

1. **Create new tables** with the improved schema
2. **Migrate data** from existing credits using the populate function
3. **Build materialized view** for trend analysis
4. **Set up refresh schedule** for materialized view (daily/weekly)
5. **Add table comments** for documentation

## Benefits of This Design

1. **Reduced from 3 to 2 tables** plus a materialized view
2. **Proper normalization** with junction table for movie details
3. **Referential integrity** maintained throughout
4. **Bidirectional indexes** for efficient queries from any direction
5. **Automatic cache expiration** for relationship paths
6. **Better data types** for precision and timezone handling
7. **Prevents duplicate entries** with proper constraints

## Performance Considerations

- The `collaborations` table acts as a pre-computed summary
- The `collaboration_details` table maintains the source of truth
- The materialized view handles complex trend queries without impacting real-time performance
- Cache expiration ensures fresh data for six degrees calculations
- Covering indexes reduce disk I/O for common queries

## Next Steps

1. Review and approve the schema design
2. Create migration scripts
3. Test with sample data
4. Benchmark query performance
5. Implement refresh strategies for cached data