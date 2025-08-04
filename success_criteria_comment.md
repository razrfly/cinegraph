## Success Criteria - Quantitative Verification

To ensure both import systems are working correctly, we will test with a clean database and verify exact counts:

### 1. Canonical Lists Import - "1001 Movies" Test

**Starting from empty database:**
- Run full "1001 Movies You Must See Before You Die" import
- **Expected Results:**
  - Total movies in `canonical_sources ? '1001_movies'`: **1,260** (exact count from IMDb list)
  - This includes all 6 pages × 250 movies/page + 10 on last page
  - Some movies may already exist if Oscar import was run first
  - All 1,260 entries should have `canonical_sources->>'1001_movies'->>'included' = 'true'`

**Verification Query:**
```sql
-- Should return exactly 1,260
SELECT COUNT(*) FROM movies 
WHERE canonical_sources ? '1001_movies' 
AND canonical_sources->>'1001_movies'->>'included' = 'true';

-- Verify positions are sequential 1-1260
SELECT COUNT(DISTINCT (canonical_sources->'1001_movies'->>'list_position')::int) 
FROM movies 
WHERE canonical_sources ? '1001_movies';
```

### 2. Oscar Import - Full Test

**Starting from empty database:**
- Run full Oscar import (2016-2024)
- **Expected Results by Year:**
  - 2024: ~50-60 unique nominated films
  - 2023: ~50-60 unique nominated films
  - 2022: ~50-60 unique nominated films
  - 2021: ~50-60 unique nominated films
  - 2020: ~50-60 unique nominated films
  - 2019: ~50-60 unique nominated films
  - 2018: ~50-60 unique nominated films
  - 2017: ~50-60 unique nominated films
  - 2016: ~50-60 unique nominated films
  - **Total unique films: ~450-540** (accounting for films nominated multiple years)

**Verification Queries:**
```sql
-- Count ceremonies (should be 9)
SELECT COUNT(*) FROM oscar_ceremonies WHERE year BETWEEN 2016 AND 2024;

-- Count total nominations (varies by year but ~200-250 per ceremony)
SELECT year, COUNT(*) as nominations 
FROM oscar_nominations n
JOIN oscar_ceremonies c ON n.ceremony_id = c.id
GROUP BY year ORDER BY year;

-- Count unique movies with Oscar nominations
SELECT COUNT(DISTINCT movie_id) FROM oscar_nominations;

-- Verify specific year (e.g., 2024)
SELECT COUNT(DISTINCT movie_id) 
FROM oscar_nominations n
JOIN oscar_ceremonies c ON n.ceremony_id = c.id
WHERE c.year = 2024;
```

### 3. Combined Import Test

**Test import order independence:**
1. **Test A**: Oscar first, then Canonical
   - Import all Oscars → Import 1001 Movies
   - Movies nominated for Oscars AND in 1001 list should have both markers
   
2. **Test B**: Canonical first, then Oscar  
   - Import 1001 Movies → Import all Oscars
   - Results should be identical to Test A

**Verification Query:**
```sql
-- Find movies that are both Oscar-nominated AND canonical
SELECT COUNT(*) FROM movies m
WHERE EXISTS (
  SELECT 1 FROM oscar_nominations WHERE movie_id = m.id
)
AND canonical_sources ? '1001_movies';
```

### 4. Single Year Oscar Test

**Import only 2024 Oscars:**
- Should create exactly 1 ceremony record for 2024
- Should create ~200-250 nomination records
- Should reference ~50-60 unique movies

```sql
-- Verify single year import
SELECT 
  (SELECT COUNT(*) FROM oscar_ceremonies WHERE year = 2024) as ceremonies,
  (SELECT COUNT(*) FROM oscar_nominations n 
   JOIN oscar_ceremonies c ON n.ceremony_id = c.id 
   WHERE c.year = 2024) as nominations,
  (SELECT COUNT(DISTINCT movie_id) FROM oscar_nominations n 
   JOIN oscar_ceremonies c ON n.ceremony_id = c.id 
   WHERE c.year = 2024) as unique_movies;
```

### 5. Idempotency Test

**Run same import twice:**
- Numbers should remain exactly the same
- No duplicates should be created
- Updates should be applied to existing records

### Pass/Fail Criteria

✅ **PASS** if:
- Canonical import creates exactly 1,260 tagged movies
- Oscar import creates expected number of ceremonies and nominations
- No duplicate records are created on re-import
- All movies have proper metadata (positions, years, etc.)

❌ **FAIL** if:
- Count is off by even 1 movie
- Duplicate records are created
- Metadata is missing or incorrect
- Import order affects final results