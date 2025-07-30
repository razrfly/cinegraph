# Collaboration System Fixes

## Problem: Exponential Data Explosion

With movies having 1000+ credits (including all crew members), we're creating an unsustainable number of collaboration records. Avatar alone would create 553,878 collaboration pairs!

## Solution 1: Filter to Key Roles Only (Recommended)

Limit collaborations to meaningful creative relationships:

```sql
-- Only track collaborations between key creative roles
CREATE OR REPLACE VIEW key_collaborations AS
SELECT DISTINCT
  LEAST(mc1.person_id, mc2.person_id) as person_a_id,
  GREATEST(mc1.person_id, mc2.person_id) as person_b_id,
  mc1.movie_id
FROM movie_credits mc1
JOIN movie_credits mc2 ON mc1.movie_id = mc2.movie_id
WHERE mc1.person_id != mc2.person_id
  AND (
    -- Actor to Actor
    (mc1.credit_type = 'cast' AND mc2.credit_type = 'cast' AND mc1.cast_order <= 10 AND mc2.cast_order <= 10)
    OR
    -- Actor to Director
    (mc1.credit_type = 'cast' AND mc1.cast_order <= 20 AND mc2.job = 'Director')
    OR
    (mc1.job = 'Director' AND mc2.credit_type = 'cast' AND mc2.cast_order <= 20)
    OR
    -- Director to Key Crew
    (mc1.job = 'Director' AND mc2.job IN ('Producer', 'Executive Producer', 'Screenplay', 'Director of Photography', 'Original Music Composer'))
    OR
    (mc1.job IN ('Producer', 'Executive Producer', 'Screenplay', 'Director of Photography', 'Original Music Composer') AND mc2.job = 'Director')
    OR
    -- Key Crew to Key Crew
    (mc1.job IN ('Producer', 'Screenplay') AND mc2.job IN ('Producer', 'Screenplay') AND mc1.job != mc2.job)
  );
```

## Solution 2: Repopulate with Filtered Data

```elixir
defmodule Cinegraph.Collaborations do
  def populate_key_collaborations_only do
    # Clear existing data
    Repo.delete_all(CollaborationDetail)
    Repo.delete_all(Collaboration)
    
    # Define key roles we care about
    key_crew_jobs = ["Director", "Producer", "Executive Producer", "Screenplay", 
                     "Director of Photography", "Original Music Composer", "Editor"]
    
    # Only process actor-actor (top 10), actor-director, and key crew collaborations
    query = """
    WITH key_person_pairs AS (
      SELECT DISTINCT
        LEAST(mc1.person_id, mc2.person_id) as person_a_id,
        GREATEST(mc1.person_id, mc2.person_id) as person_b_id,
        mc1.movie_id,
        m.release_date,
        m.vote_average,
        m.revenue,
        EXTRACT(YEAR FROM m.release_date)::INTEGER as year,
        CASE 
          WHEN mc1.credit_type = 'cast' AND mc2.credit_type = 'cast' THEN 'actor-actor'
          WHEN (mc1.credit_type = 'cast' AND mc2.job = 'Director') OR 
               (mc1.job = 'Director' AND mc2.credit_type = 'cast') THEN 'actor-director'
          WHEN mc1.job = 'Director' AND mc2.job = 'Director' THEN 'director-director'
          WHEN mc1.job IN ($1) AND mc2.job IN ($1) THEN 'key-crew'
          ELSE 'other-key'
        END as collaboration_type
      FROM movie_credits mc1
      JOIN movie_credits mc2 ON mc1.movie_id = mc2.movie_id
      JOIN movies m ON mc1.movie_id = m.id
      WHERE mc1.person_id != mc2.person_id
        AND m.release_date IS NOT NULL
        AND (
          -- Top 10 actors only
          (mc1.credit_type = 'cast' AND mc2.credit_type = 'cast' 
           AND mc1.cast_order <= 10 AND mc2.cast_order <= 10)
          OR
          -- Actor (top 20) to Director
          (mc1.credit_type = 'cast' AND mc1.cast_order <= 20 AND mc2.job = 'Director')
          OR
          (mc1.job = 'Director' AND mc2.credit_type = 'cast' AND mc2.cast_order <= 20)
          OR
          -- Key crew only
          (mc1.job IN ($1) AND mc2.job IN ($1))
        )
    )
    SELECT * FROM key_person_pairs
    """
    
    # Process with the key crew jobs parameter
    # ... rest of implementation
  end
end
```

## Solution 3: Archive Current Data and Start Fresh

```bash
# 1. Backup current tables
pg_dump -h 127.0.0.1 -p 54332 -U postgres -t collaborations -t collaboration_details > collaborations_backup.sql

# 2. Truncate tables
psql -c "TRUNCATE collaborations, collaboration_details CASCADE;"

# 3. Run new filtered population
mix run -e "Cinegraph.Collaborations.populate_key_collaborations_only()"
```

## Expected Results After Filtering

Instead of 283,638 collaborations, we should have approximately:
- ~50-100 collaborations per movie (vs current 1,400)
- ~10,000-20,000 total collaborations (vs 283,638)
- Much faster query performance
- More meaningful collaboration data

## Additional Optimizations

1. **Add collaboration importance score**:
```sql
ALTER TABLE collaborations ADD COLUMN importance_score DECIMAL(3,2);

-- Higher scores for director-actor, lower for actor #9 - actor #10
UPDATE collaborations c
SET importance_score = 
  CASE 
    WHEN EXISTS (
      SELECT 1 FROM collaboration_details cd 
      WHERE cd.collaboration_id = c.id 
      AND cd.collaboration_type = 'actor-director'
    ) THEN 1.0
    WHEN c.collaboration_count > 3 THEN 0.9
    WHEN c.avg_movie_rating > 7.5 THEN 0.8
    ELSE 0.5
  END;
```

2. **Create filtered indexes**:
```sql
CREATE INDEX idx_important_collaborations ON collaborations(importance_score DESC) 
WHERE importance_score > 0.7;

CREATE INDEX idx_key_collaborations ON collaboration_details(collaboration_type) 
WHERE collaboration_type IN ('actor-director', 'director-director');
```

## Performance Impact

After implementing these fixes:
- Six Degrees queries will run in milliseconds instead of timing out
- Materialized view creation will complete in seconds
- UI will be responsive for all collaboration features
- Database size will be reasonable and maintainable