# Phase 2: Systematic Import Testing

## Objective
Test the new import system with the first 10,000 movies to validate performance, data completeness, and system stability.

## Goals
1. Import approximately 10,000 movies (about 500 pages from TMDb)
2. Monitor system performance and rate limiting
3. Verify deduplication is working correctly
4. Check data completeness (genres, keywords, credits, etc.)
5. Validate OMDb enrichment for movies with IMDb IDs

## Monitoring Checklist

### Performance Metrics
- [ ] Import rate (movies per minute)
- [ ] Rate limit compliance (staying under 40 requests/10 seconds)
- [ ] Database query performance
- [ ] Memory usage
- [ ] Job processing times

### Data Quality
- [ ] Movies with complete TMDb data
- [ ] Movies with OMDb enrichment
- [ ] Genre associations
- [ ] Keyword associations
- [ ] Credit records (cast and crew)
- [ ] Production company associations

### System Health
- [ ] No failed jobs (or acceptable failure rate)
- [ ] Proper error handling for missing data
- [ ] State tracking accuracy
- [ ] Dashboard responsiveness

## Test Execution

### Step 1: Prepare for Testing
```elixir
# Clear any existing test data if needed
# Already done in previous step

# Verify system is ready
Cinegraph.Imports.TMDbImporter.get_progress()
```

### Step 2: Start Import
```elixir
# Start the full import (it will run to 10,000+ movies)
Cinegraph.Imports.TMDbImporter.start_full_import()
```

### Step 3: Monitor Progress
- Watch dashboard at http://localhost:4000/imports
- Check logs for any errors
- Monitor Oban queue status
- Track completion percentage

### Step 4: Validate Data
After reaching ~10,000 movies, run validation queries:

```elixir
# Check data completeness
Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count)
Cinegraph.Repo.aggregate(from(m in Cinegraph.Movies.Movie, where: not is_nil(m.tmdb_data)), :count)
Cinegraph.Repo.aggregate(from(m in Cinegraph.Movies.Movie, where: not is_nil(m.omdb_data)), :count)
```

## Success Criteria
- ✅ 10,000+ movies imported successfully
- ✅ Import rate stays consistent (no degradation)
- ✅ Less than 1% failure rate
- ✅ At least 50% of movies have OMDb data (those with IMDb IDs)
- ✅ All movies have genres and basic metadata
- ✅ System remains stable throughout import

## Notes
- The import will take several hours due to rate limiting
- Each page (20 movies) takes about 30-50 seconds with delays
- 500 pages × ~40 seconds = ~5.5 hours total
- Can be stopped and resumed using the last_page_processed state