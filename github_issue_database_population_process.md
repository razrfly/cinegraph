# Database Population Process - Current State and Improvement Recommendations

## Problem Statement
We need a repeatable, reliable process to drop and repopulate the database with 200+ movies from TMDB and OMDB. This process will be run multiple times during development as we refine the data model and import logic.

## Current State Analysis

### 1. Multiple Import Methods Exist
- **Mix Task**: `mix import_movies` - The most comprehensive option
- **Standalone Scripts**: Various `fetch_*.exs` scripts with different approaches
- **No single unified process** that handles everything

### 2. Current Mix Task (`lib/mix/tasks/import_movies.ex`)
**Strengths:**
- Has `--fresh` flag to clear data first
- Supports custom page counts with `--pages`
- Integrates both TMDB and OMDB data
- Rate limits OMDB calls (1000ms delay)

**Weaknesses:**
- Default is only 100 movies (5 pages)
- Data clearing is incomplete (doesn't handle genres, external sources)
- No progress tracking for large imports
- No error recovery or retry logic
- Sequential processing is slow

### 3. Current Import Flow
1. Clear data (if `--fresh` flag)
2. Fetch popular movies from TMDB
3. For each movie:
   - Fetch comprehensive TMDB data (credits, keywords, videos, etc.)
   - Store in database
   - Fetch OMDB data (if IMDB ID exists)
   - Store ratings
4. No post-processing (cultural lists, CRI scores, etc.)

### 4. Performance Issues
- **Sequential Processing**: Each movie takes ~2-3 seconds minimum
- **200 movies = 400-600 seconds (6-10 minutes)**
- OMDB rate limiting adds significant time
- No parallelization

## Proposed Improvements

### 1. Single Entry Point Script
Create `scripts/reset_and_populate.exs` that:
```elixir
# Drop and recreate database
mix ecto.drop
mix ecto.create
mix ecto.migrate

# Import movies
mix import_movies --fresh --pages 10 --with-cultural-data
```

### 2. Enhanced Mix Task Features

#### A. Better Data Clearing
```elixir
defp clear_all_data do
  # Drop and recreate is cleaner than TRUNCATE
  Mix.Task.run("ecto.drop")
  Mix.Task.run("ecto.create") 
  Mix.Task.run("ecto.migrate")
  
  # Seed essential data
  seed_genres()
  seed_external_sources()
  seed_cultural_authorities()
end
```

#### B. Progress Tracking
```elixir
defp import_with_progress(total_pages) do
  progress = Progress.start(total: total_pages * 20)
  
  for page <- 1..total_pages do
    movies = fetch_tmdb_page(page)
    
    Enum.each(movies, fn movie ->
      import_movie_comprehensive(movie)
      Progress.increment(progress)
    end)
  end
  
  Progress.stop(progress)
end
```

#### C. Parallel Processing (with rate limiting)
```elixir
defp import_movies_parallel(movie_ids) do
  # TMDB allows higher rate limits
  tmdb_tasks = Task.async_stream(
    movie_ids,
    &fetch_tmdb_comprehensive/1,
    max_concurrency: 5,
    timeout: 30_000
  )
  
  # Process TMDB results and collect IMDB IDs
  movies_with_imdb = process_tmdb_results(tmdb_tasks)
  
  # OMDB requires sequential processing (free tier)
  Enum.each(movies_with_imdb, fn movie ->
    fetch_and_store_omdb_data(movie)
    Process.sleep(1000) # Rate limit
  end)
end
```

#### D. Post-Processing Pipeline
```elixir
defp post_process_movies do
  # Add movies to cultural lists
  populate_cultural_lists()
  
  # Calculate initial CRI scores
  calculate_all_cri_scores()
  
  # Generate recommendations
  generate_recommendations()
  
  # Create sample reviews
  create_sample_reviews()
end
```

### 3. Configuration Options
```elixir
# config/import.exs
config :cinegraph, :import,
  tmdb_pages: 10,           # 200 movies
  tmdb_concurrency: 5,      # Parallel requests
  omdb_delay_ms: 1000,      # Rate limiting
  include_cultural_data: true,
  include_sample_reviews: true,
  retry_failed: true,
  retry_attempts: 3
```

### 4. Error Handling and Recovery
```elixir
defp import_with_recovery(movie_id, attempts \\ 3) do
  case import_movie_comprehensive(movie_id) do
    {:ok, movie} -> 
      {:ok, movie}
    {:error, reason} when attempts > 1 ->
      Logger.warn("Retrying movie #{movie_id}, attempts left: #{attempts - 1}")
      Process.sleep(2000)
      import_with_recovery(movie_id, attempts - 1)
    {:error, reason} ->
      Logger.error("Failed to import movie #{movie_id}: #{inspect(reason)}")
      {:error, reason}
  end
end
```

### 5. Recommended Command Structure
```bash
# Basic reset and populate with 200 movies
mix import_movies --reset --pages 10

# With all features
mix import_movies --reset --pages 10 --with-cultural --with-reviews --parallel

# Resume failed imports
mix import_movies --resume-failed

# Just enrich with OMDB data
mix import_movies --enrich-omdb

# Import specific popular movie categories
mix import_movies --reset --top-rated --now-playing --upcoming --pages 3
```

## Implementation Priority

1. **Phase 1**: Create unified reset script
   - Combine ecto.drop/create/migrate
   - Add to Mix task as `--reset` flag

2. **Phase 2**: Improve performance
   - Add progress tracking
   - Implement parallel TMDB fetching
   - Better error handling

3. **Phase 3**: Enhanced features
   - Cultural data population
   - CRI score calculation
   - Sample data generation

4. **Phase 4**: Developer experience
   - Configuration file support
   - Resume capability
   - Import statistics

## Expected Outcomes

### Current Process (100 movies)
- Time: ~5-8 minutes
- Success rate: ~90%
- Manual steps required

### Improved Process (200 movies)
- Time: ~8-12 minutes
- Success rate: ~98%
- Single command
- Full data population
- Progress visibility
- Error recovery

## Next Steps

1. Create `scripts/reset_and_populate.exs`
2. Enhance Mix task with `--reset` flag
3. Add progress tracking
4. Implement parallel TMDB fetching
5. Add post-processing pipeline
6. Document the new process