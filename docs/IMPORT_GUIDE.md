# 🎬 CineGraph Import Guide

A comprehensive guide to importing movie data into CineGraph using the Oban-based background job system.

## Table of Contents
- [Quick Start](#quick-start)
- [Environment Setup](#environment-setup)
- [Import Dashboard](#import-dashboard)
- [Import Methods](#import-methods)
- [Import Process Flow](#import-process-flow)
- [Monitoring Progress](#monitoring-progress)
- [Troubleshooting](#troubleshooting)
- [API Rate Limits](#api-rate-limits)
- [Advanced Usage](#advanced-usage)

## Quick Start

The fastest way to populate your database with movies:

```bash
# 1. Ensure your .env file has API keys configured
cp .env.example .env
# Edit .env and add your TMDB_API_KEY and OMDB_API_KEY

# 2. Start the Phoenix server
./start.sh

# 3. Visit the import dashboard
open http://localhost:4001/imports

# 4. Click "Import Popular Movies" to start with ~2,000 highly-rated films
```

## Environment Setup

### Required API Keys

1. **TMDb API Key**
   - Get it free from: https://www.themoviedb.org/settings/api
   - Add to `.env`: `TMDB_API_KEY=your_key_here`

2. **OMDb API Key** (Optional but recommended)
   - Get it free from: http://www.omdbapi.com/apikey.aspx
   - Add to `.env`: `OMDB_API_KEY=your_key_here`

### Starting the Server

Always use the start script to ensure environment variables are loaded:

```bash
./start.sh  # Loads .env and starts Phoenix server
```

## Import Dashboard

Visit http://localhost:4001/imports to access the import dashboard, which provides:

- **Real-time Statistics**: Total movies, import progress, queue status
- **Import Controls**: Start different types of imports with one click
- **Progress Monitoring**: Live updates on running imports
- **Database Stats**: Current movie counts and data coverage

## Import Methods

### 1. Popular Movies Import (Recommended for First Run)
- **Movies**: ~2,000 highly-rated films
- **Time**: 20-30 minutes
- **Best for**: Initial database population

```elixir
# Via dashboard: Click "Import Popular Movies"
# Via console:
Cinegraph.Imports.TMDbImporter.start_popular_import(max_pages: 100)
```

### 2. Daily Update Import
- **Movies**: 50-200 recent releases
- **Time**: 5-10 minutes
- **Best for**: Keeping database current

```elixir
# Via dashboard: Click "Run Daily Update"
# Via console:
Cinegraph.Imports.TMDbImporter.start_daily_update()
```

### 3. Decade Import
- **Movies**: 2,000-5,000 per decade
- **Time**: 2-4 hours
- **Best for**: Historical coverage

```elixir
# Via console:
Cinegraph.Imports.TMDbImporter.start_decade_import(1990)  # 1990s movies
Cinegraph.Imports.TMDbImporter.start_decade_import(2000)  # 2000s movies
```

### 4. Full Catalog Import
- **Movies**: 900,000+ (entire TMDb database)
- **Time**: 5-7 days
- **Best for**: Complete coverage

```elixir
# Via console (use with caution):
Cinegraph.Imports.TMDbImporter.start_full_import(max_pages: 500)
```

## Import Process Flow

The import system uses a sophisticated pipeline:

```
1. Import Initiated
   └─> ImportProgress record created
   
2. TMDbDiscoveryWorker
   ├─> Fetches movie lists from TMDb API (20 movies/page)
   ├─> Queues TMDbDetailsWorker jobs for each movie
   └─> Updates ImportProgress with movies_found count
   
3. TMDbDetailsWorker (per movie)
   ├─> Checks if movie already exists (by tmdb_id)
   ├─> Fetches detailed movie data from TMDb
   ├─> Creates/updates movie record
   ├─> Queues enrichment workers
   └─> Updates ImportProgress with movies_imported count
   
4. Enrichment Workers (parallel)
   ├─> CastCrewWorker: Fetches cast and crew
   ├─> KeywordsWorker: Fetches keywords and tags
   ├─> VideosWorker: Fetches trailers and clips
   └─> ProductionWorker: Fetches production companies
   
5. OMDb Enrichment (if API key configured)
   └─> Adds IMDb ratings, Rotten Tomatoes scores, box office data
```

## Monitoring Progress

### Live Dashboard Metrics
The import dashboard shows:
- **Current Page**: Progress through TMDb pages
- **Movies Found**: Total discovered in TMDb
- **Movies Imported**: Successfully added to database
- **Import Rate**: Movies per minute
- **Queue Status**: Pending vs completed jobs

### Database Queries

```elixir
# Check import progress
Cinegraph.Imports.ImportProgress.get_running()

# Get specific import status
progress = Cinegraph.Imports.ImportProgress.get(import_id)

# Check movie count
Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count)

# Check movies with TMDb data
Cinegraph.Movies.Movie
|> where([m], not is_nil(m.tmdb_data))
|> Cinegraph.Repo.aggregate(:count)
```

### Oban Dashboard

Visit http://localhost:4001/dev/oban to see:
- All queued, executing, and completed jobs
- Job performance metrics
- Failed jobs with stack traces
- Queue throughput statistics

## Troubleshooting

### Common Issues

#### 1. "missing_api_key" Error
**Problem**: Jobs failing with `{:error, :missing_api_key}`

**Solution**:
```bash
# 1. Verify .env file has keys
cat .env | grep API_KEY

# 2. Restart server with ./start.sh (not mix phx.server)
./start.sh

# 3. Verify in console
source .env && iex -S mix
iex> Application.get_env(:cinegraph, Cinegraph.Services.TMDb.Client)[:api_key]
```

#### 2. Import Not Increasing Movie Count
**Problem**: Jobs running but movie count stays the same

**Possible Causes**:
- Importing movies that already exist (duplicates)
- Jobs failing silently
- Rate limit exhaustion

**Debugging Steps**:
```elixir
# Check for duplicate attempts
Oban.Job
|> where([j], j.worker == "Cinegraph.Workers.TMDbDetailsWorker")
|> where([j], j.state == "completed")
|> limit(10)
|> Cinegraph.Repo.all()
|> Enum.map(& &1.args)

# Check for failed jobs
Oban.Job
|> where([j], j.state in ["failed", "discarded"])
|> Cinegraph.Repo.all()
```

#### 3. Rate Limit Errors
**Problem**: TMDb API returning 429 errors

**Solution**: The system automatically handles rate limiting, but you can:
- Reduce concurrent workers in config
- Increase delays between requests
- Check rate limiter status in logs

#### 4. Stuck Imports
**Problem**: Import shows as "running" but no progress

**Solution**:
```elixir
# Find stuck imports
Cinegraph.Repo.query!("""
UPDATE import_progress 
SET status = 'failed' 
WHERE status = 'running' 
AND updated_at < NOW() - INTERVAL '1 hour'
""")

# Clear all Oban jobs and start fresh
Cinegraph.Repo.delete_all(Oban.Job)
```

## API Rate Limits

### TMDb
- **Limit**: 40 requests per 10 seconds
- **Handled by**: Built-in token bucket rate limiter
- **Logs**: Debug messages show token consumption

### OMDb
- **Free Tier**: 1,000 requests per day
- **Handled by**: 1-second delay between requests
- **Note**: May take longer for large imports

## Advanced Usage

### Custom Import Filters

```elixir
# Import movies from specific year
Cinegraph.Imports.TMDbImporter.start_full_import(
  year: 2023,
  max_pages: 50
)

# Import by genre (genre IDs from TMDb)
Cinegraph.Imports.TMDbImporter.start_full_import(
  genres: "28,12",  # Action and Adventure
  max_pages: 50
)

# Import by minimum vote count
Cinegraph.Imports.TMDbImporter.start_popular_import(
  min_vote_count: 500,
  max_pages: 200
)
```

### Pause and Resume Imports

```elixir
# Pause a running import
{:ok, _} = Cinegraph.Imports.TMDbImporter.pause_import(import_id)

# Resume a paused import
{:ok, _} = Cinegraph.Imports.TMDbImporter.resume_import(import_id)
```

### Direct Script Usage

For development and testing:

```bash
# Import specific movies by ID
./scripts/run_with_env.sh mix run -e 'Cinegraph.Workers.TMDbDetailsWorker.new(%{tmdb_id: 550}) |> Oban.insert()'

# Run a test import of older movies
./scripts/run_with_env.sh mix run scripts/import_tmdb.exs -- --decade 1980
```

### Monitoring Rate Limiter

```elixir
# Check rate limiter status
GenServer.call(Cinegraph.RateLimiter, {:check_tokens, :tmdb})
GenServer.call(Cinegraph.RateLimiter, {:check_tokens, :omdb})
```

## Best Practices

1. **Start Small**: Begin with popular movies import to verify setup
2. **Monitor Progress**: Use the dashboard to track imports
3. **Check Logs**: Look for rate limit warnings or API errors
4. **Incremental Imports**: Import by decade or genre to avoid overwhelming the system
5. **Daily Updates**: Set up scheduled daily imports to keep data fresh

## Example Import Scenarios

### New Installation
```bash
# 1. Import popular movies first (2,000 movies, 30 min)
# Via dashboard: Click "Import Popular Movies"

# 2. Add recent releases (200 movies, 10 min)
# Via dashboard: Click "Run Daily Update"

# 3. Fill in historical data by decade
# Via console:
Cinegraph.Imports.TMDbImporter.start_decade_import(2010)
Cinegraph.Imports.TMDbImporter.start_decade_import(2000)
```

### Development Testing
```bash
# Quick test with 40 movies
./scripts/import_with_env.sh --pages 2

# Medium test with 200 movies
./scripts/import_with_env.sh --pages 10

# Reset and import fresh
./scripts/import_with_env.sh --reset --pages 10
```

### Production Deployment
```elixir
# 1. Start with high-quality movies
Cinegraph.Imports.TMDbImporter.start_popular_import(
  min_vote_count: 100,
  max_pages: 200
)

# 2. Schedule daily updates (in config or cron)
Cinegraph.Imports.TMDbImporter.start_daily_update()

# 3. Gradually backfill by decade
Cinegraph.Imports.TMDbImporter.start_decade_import(2020)
# Wait for completion...
Cinegraph.Imports.TMDbImporter.start_decade_import(2010)
```

## Import Statistics

Typical import performance:
- **Discovery**: ~20 movies/page, 1-2 seconds per page
- **Details**: ~2-3 seconds per movie (with all associations)
- **Throughput**: ~15-20 movies/minute with default settings
- **Storage**: ~10-15 KB per movie (including all metadata)

With a full import:
- **Popular Movies** (2,000): ~2 hours, ~30 MB
- **Per Decade** (3,000-5,000): ~3-4 hours, ~50-75 MB
- **Full Catalog** (900,000+): ~5-7 days, ~10-15 GB