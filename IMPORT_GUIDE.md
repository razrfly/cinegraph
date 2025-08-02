# 🎬 CineGraph Import Guide

This guide provides comprehensive instructions for importing movie data into CineGraph using the Oban-based import system.

## Table of Contents
- [Prerequisites](#prerequisites)
- [Environment Setup](#environment-setup)
- [Import System Overview](#import-system-overview)
- [Import Methods](#import-methods)
- [Monitoring Progress](#monitoring-progress)
- [Troubleshooting](#troubleshooting)
- [API Rate Limits](#api-rate-limits)
- [Best Practices](#best-practices)

## Prerequisites

1. **API Keys Required**:
   - **TMDb API Key**: Get it free from [TMDb API Settings](https://www.themoviedb.org/settings/api)
   - **OMDb API Key** (Optional): Get it from [OMDb API](http://www.omdbapi.com/apikey.aspx)

2. **Database Setup**:
   - PostgreSQL running (locally via Supabase or remote)
   - Database migrations applied: `mix ecto.migrate`

3. **Dependencies Installed**:
   - Run `mix deps.get` to install all Elixir dependencies

## Environment Setup

1. **Copy the environment template**:
   ```bash
   cp .env.example .env
   ```

2. **Edit `.env` and add your API keys**:
   ```bash
   # For local Supabase development
   SUPABASE_URL=http://127.0.0.1:54321
   SUPABASE_ANON_KEY=your_supabase_anon_key_here
   SUPABASE_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres

   # Required API Keys
   TMDB_API_KEY=your_tmdb_api_key_here
   OMDB_API_KEY=your_omdb_api_key_here  # Optional
   ```

3. **Start the Phoenix server**:
   ```bash
   mix phx.server
   # Or use the start script if available
   ./start.sh
   ```

## Import System Overview

CineGraph uses an **Oban-based background job system** that provides:

- ✅ **Rate-limited API calls** (40 requests per 10 seconds for TMDb)
- ✅ **Resumable imports** that survive server restarts
- ✅ **Progress tracking** with real-time updates
- ✅ **Duplicate detection** to avoid re-importing movies
- ✅ **Automatic retries** for failed requests
- ✅ **Queue management** with priority levels

### Import Workflow

1. **Discovery Worker** (`TMDbDiscoveryWorker`):
   - Fetches pages of movies from TMDb's discover endpoint
   - Queues individual movie detail jobs
   - Updates import progress

2. **Details Worker** (`TMDbDetailsWorker`):
   - Fetches complete movie details, cast, crew, keywords
   - Stores data in PostgreSQL
   - Optionally queues OMDb enrichment

3. **OMDb Enrichment Worker** (`OMDbEnrichmentWorker`):
   - Fetches additional data from OMDb (awards, box office)
   - Enriches existing movie records

## Import Methods

### 1. Web UI Import (Recommended)

Navigate to the import dashboard:
```
http://localhost:4001/imports
```

Available import options:

#### Popular Movies Import
- Imports top-rated movies with significant vote counts
- Quick way to populate database with quality content
- ~2,000 movies, takes ~20 minutes

```elixir
# Triggered via UI or programmatically:
Cinegraph.Imports.TMDbImporter.start_popular_import(max_pages: 100)
```

#### Daily Updates
- Imports movies from the last 7 days
- Great for keeping database current
- ~50-200 movies, takes ~5 minutes

```elixir
Cinegraph.Imports.TMDbImporter.start_daily_update()
```

#### Import by Decade
- Import movies from specific decades (1950s-2020s)
- Useful for historical coverage
- ~2,000-5,000 movies per decade

```elixir
Cinegraph.Imports.TMDbImporter.start_decade_import(2020)
```

#### Full Catalog Import
- Imports entire TMDb catalog
- **WARNING**: Takes 5-7 days due to rate limits
- ~900,000+ movies

```elixir
Cinegraph.Imports.TMDbImporter.start_full_import()
```

### 2. Programmatic Import

Use IEx console or scripts:

```elixir
# Start a custom import with filters
Cinegraph.Imports.TMDbImporter.start_import("custom", %{
  max_pages: 50,
  sort_by: "vote_average.desc",
  "vote_count.gte" => 1000,
  "primary_release_date.gte" => "2020-01-01",
  "primary_release_date.lte" => "2023-12-31"
})
```

### 3. Test Import Script

Run a small test import to verify setup:

```bash
mix run test_import.exs
```

This will:
- Test rate limiting
- Import 1 page (20 movies)
- Show progress updates
- Verify database writes

## Monitoring Progress

### 1. Import Dashboard UI

Visit `http://localhost:4001/imports` to see:
- Current import status
- Movies imported vs. found
- Queue depths for each worker
- Estimated completion time
- Rate of import (movies/minute)

### 2. Oban Web Dashboard

Visit `http://localhost:4001/dev/oban` to see:
- Individual job status
- Failed jobs with error details
- Queue performance metrics
- Job history

### 3. Database Queries

Check import progress directly:

```elixir
# Total movies in database
Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count)

# Movies with TMDb data
import Ecto.Query
Cinegraph.Repo.aggregate(
  from(m in Cinegraph.Movies.Movie, where: not is_nil(m.tmdb_data)), 
  :count
)

# Recent import status
Cinegraph.Imports.TMDbImporter.get_import_status()
```

### 4. Logs

Monitor server logs for detailed information:
```bash
tail -f log/dev.log  # If file logging is enabled
# Or just watch the console output
```

## Troubleshooting

### Common Issues

#### 1. "Missing API Key" Error
**Symptom**: Jobs fail with `{:error, :missing_api_key}`

**Solution**:
- Ensure `.env` file exists with valid API keys
- Restart the Phoenix server after adding keys
- Verify with: `Application.get_env(:cinegraph, Cinegraph.Services.TMDb.Client)`

#### 2. Rate Limiting
**Symptom**: 429 errors or slow imports

**Solution**:
- The system automatically handles rate limits
- Default: 40 requests per 10 seconds
- Adjust in `config/config.exs` if needed

#### 3. Duplicate Movies
**Symptom**: Same movie appears multiple times

**Solution**:
- System checks for duplicates by TMDb ID
- Run deduplication: `Cinegraph.Movies.deduplicate()`

#### 4. Failed Jobs
**Symptom**: Jobs in "retryable" or "discarded" state

**Solution**:
```elixir
# Retry all failed jobs
Oban.retry_all_jobs(queue: :tmdb_details)

# Or retry specific job from Oban Web UI
```

#### 5. Import Stuck
**Symptom**: No progress for extended period

**Solution**:
1. Check Oban Web for failed jobs
2. Check rate limiter: `Cinegraph.RateLimiter.status(:tmdb)`
3. Restart import if needed:
   ```elixir
   # Cancel current import
   Cinegraph.Imports.TMDbImporter.cancel_import(import_id)
   
   # Start fresh
   Cinegraph.Imports.TMDbImporter.start_popular_import()
   ```

## API Rate Limits

### TMDb Limits
- **40 requests per 10 seconds**
- Automatically managed by rate limiter
- Burst capacity allows fast initial requests

### OMDb Limits
- **1,000 requests per day** (free tier)
- **100,000 requests per day** (paid tier)
- Set appropriate delay in worker config

### Adjusting Rate Limits

In `lib/cinegraph/rate_limiter.ex`:
```elixir
@bucket_configs %{
  tmdb: %{
    capacity: 40,        # Max tokens
    refill_amount: 40,   # Tokens added each interval
    refill_interval: 10  # Seconds
  }
}
```

## Best Practices

### 1. Start Small
- Begin with popular movies import
- Test with 1-2 pages first
- Gradually increase scope

### 2. Monitor Resources
- Watch database size
- Monitor memory usage
- Check disk space for logs

### 3. Schedule Imports
- Run large imports during off-hours
- Use daily updates to stay current
- Implement incremental imports

### 4. Data Quality
- Verify critical data after import
- Check for missing fields
- Validate relationships (cast, crew)

### 5. Backup Strategy
- Backup database before large imports
- Keep import logs for debugging
- Document custom import parameters

### 6. Performance Tips
- Increase Oban concurrency for faster imports:
  ```elixir
  # In config/config.exs
  config :cinegraph, Oban,
    queues: [
      tmdb_discovery: 10,
      tmdb_details: 50,    # Increase for faster imports
      omdb_enrichment: 5
    ]
  ```
- Use database indexes for better query performance
- Consider partitioning for very large datasets

## Example Import Scenarios

### Scenario 1: Fresh Installation
```bash
# 1. Setup environment
cp .env.example .env
# Edit .env with your API keys

# 2. Start server
mix phx.server

# 3. Import popular movies first
# Visit http://localhost:4001/imports
# Click "Import Popular Movies"

# 4. Monitor progress
# Refresh the page to see updates
```

### Scenario 2: Daily Maintenance
```elixir
# Run in IEx console
Cinegraph.Imports.TMDbImporter.start_daily_update()

# Or schedule with cron/systemd
```

### Scenario 3: Research Project
```elixir
# Import specific criteria for research
Cinegraph.Imports.TMDbImporter.start_import("research_2020s_drama", %{
  max_pages: 200,
  with_genres: "18",  # Drama genre ID
  "primary_release_date.gte" => "2020-01-01",
  "vote_count.gte" => 50,
  sort_by: "vote_average.desc"
})
```

## Next Steps

After successful import:
1. Explore the movie data at `/movies`
2. Use the search functionality
3. Build custom queries for analysis
4. Set up regular import schedules
5. Contribute improvements back to the project!

---

For additional help, check the [main README](README.md) or open an issue on GitHub.