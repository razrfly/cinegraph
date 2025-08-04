## Additional Success Criteria - Update vs Create Test

### 6. Update vs Create Verification Test

To ensure the system correctly handles both new movie creation AND updating existing movies:

**Test Sequence:**
1. Start with empty database
2. Import ~1,000 movies from TMDb (e.g., 5 pages of popular movies)
3. Run canonical "1001 Movies" import
4. Run Oscar import (all years)
5. Verify both creation and update paths work correctly

**Expected Behavior:**

**A. Movies that exist in TMDb import AND canonical list:**
- Should be UPDATED with `canonical_sources` data
- Should NOT create duplicate movies
- Original TMDb data should remain intact
- Should add canonical metadata without overwriting existing fields

**B. Movies that exist in TMDb import AND Oscar nominations:**
- Should be UPDATED with Oscar nomination records
- Should NOT create duplicate movies
- Should properly link existing movie to nomination

**C. Movies that DON'T exist in TMDb import:**
- Should be CREATED via TMDbDetailsWorker
- Should have both TMDb data AND canonical/Oscar data

**Verification Queries:**
```sql
-- Count movies that were UPDATED (existed before canonical import)
SELECT COUNT(*) FROM movies 
WHERE canonical_sources ? '1001_movies'
AND created_at < (
  SELECT MIN(inserted_at) FROM oban_jobs 
  WHERE worker = 'Cinegraph.Workers.CanonicalImportWorker'
);

-- Count movies that were CREATED by canonical import
SELECT COUNT(*) FROM movies 
WHERE canonical_sources ? '1001_movies'
AND created_at >= (
  SELECT MIN(inserted_at) FROM oban_jobs 
  WHERE worker = 'Cinegraph.Workers.CanonicalImportWorker'
);

-- Verify no duplicates by title/year
SELECT title, release_date, COUNT(*) as count
FROM movies
GROUP BY title, release_date
HAVING COUNT(*) > 1;

-- Check overlap between TMDb popular and canonical
SELECT COUNT(*) FROM movies
WHERE vote_count > 1000  -- Popular TMDb movies
AND canonical_sources ? '1001_movies';

-- Verify Oscar nominations link to existing movies
SELECT COUNT(*) FROM oscar_nominations n
JOIN movies m ON n.movie_id = m.id
WHERE m.vote_count > 1000;  -- Popular TMDb movies with Oscar noms
```

**Success Metrics:**
- ✅ Zero duplicate movies created
- ✅ Updated movies retain all original TMDb data
- ✅ Updated movies gain canonical/Oscar metadata
- ✅ Created movies have complete data from all sources
- ✅ Total canonical count still equals 1,260
- ✅ Total Oscar nominations count remains consistent

**Example Overlap Cases:**
- "The Godfather" - Popular on TMDb + In 1001 list + Oscar winner
- "Parasite" - Popular on TMDb + In 1001 list + Oscar winner  
- "Oppenheimer" - Popular on TMDb + Oscar nominee

These movies should exist only ONCE in the database with data from all three sources.

**Final Verification:**
```sql
-- Super important: Total unique movies should be less than sum of all imports
SELECT 
  (SELECT COUNT(*) FROM movies) as total_unique_movies,
  (SELECT COUNT(*) FROM movies WHERE vote_count > 1000) as tmdb_popular,
  (SELECT COUNT(*) FROM movies WHERE canonical_sources ? '1001_movies') as canonical,
  (SELECT COUNT(DISTINCT movie_id) FROM oscar_nominations) as oscar_movies;

-- The total_unique_movies should be significantly less than 
-- tmdb_popular + canonical + oscar_movies due to overlaps
```