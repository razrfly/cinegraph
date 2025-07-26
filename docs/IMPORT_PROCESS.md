# Movie Import Process Documentation

This document describes the improved movie import process for Cinegraph.

## Quick Start

### Complete Reset and Import (Recommended)

```bash
# IMPORTANT: Load environment variables first!
source .env

# Reset database and import 200 movies
mix import_movies --reset --pages 10

# Or use the convenience script
elixir scripts/reset_and_populate.exs --pages 10
```

### Import Options

```bash
# Basic import (100 movies)
mix import_movies

# Import 200 movies
mix import_movies --pages 10

# Fresh data (clear existing, keep database)
mix import_movies --fresh --pages 10

# Complete reset (drop, create, migrate, import)
mix import_movies --reset --pages 10

# Import with progress tracking
mix import_movies --pages 10 --verbose

# Import specific movies
mix import_movies --ids 550,551,552

# Enrich existing movies with OMDB data
mix import_movies --enrich
```

## How It Works

### 1. Data Sources

- **TMDB (The Movie Database)**: Primary source for movie metadata
  - Comprehensive data: cast, crew, keywords, videos, release dates
  - Rate limit: 50 requests/second
  - No daily limit

- **OMDB (Open Movie Database)**: Secondary source for ratings
  - IMDb ratings, Rotten Tomatoes scores
  - Rate limit: 1000 requests/day (free tier)
  - 1 second delay between requests

### 2. Import Process

1. **Fetch Popular Movies**: Gets list of popular movies from TMDB
2. **Comprehensive Import**: For each movie:
   - Fetch full movie details
   - Fetch credits (cast & crew)
   - Fetch keywords
   - Fetch videos (trailers, etc.)
   - Fetch release dates
   - Fetch production companies
   - Store all data with associations
3. **OMDB Enrichment**: If movie has IMDB ID:
   - Fetch OMDB data
   - Store multiple rating types
   - Wait 1 second (rate limit)

### 3. Database Structure

The import populates these tables:
- `movies` - Core movie data
- `people` - Actors, directors, crew
- `movie_credits` - Cast and crew associations
- `keywords` - Movie keywords
- `movie_keywords` - Keyword associations
- `movie_videos` - Trailers and clips
- `movie_release_dates` - Release dates by country
- `production_companies` - Production companies
- `movie_production_companies` - Company associations
- `external_ratings` - TMDB and OMDB ratings
- `external_sources` - Rating source definitions

### 4. Time Estimates

- **100 movies** (5 pages): ~5-8 minutes
- **200 movies** (10 pages): ~10-15 minutes
- **500 movies** (25 pages): ~25-35 minutes

Time depends on:
- OMDB rate limiting (1 second per movie)
- Network speed
- Database performance

## Configuration

Edit `config/import.exs` to change defaults:

```elixir
config :cinegraph, :import,
  default_pages: 10,           # Default movie count
  tmdb_delay_ms: 100,         # TMDB request delay
  omdb_delay_ms: 1000,        # OMDB request delay (free tier)
  max_retry_attempts: 3,      # Retry failed imports
  show_progress: true         # Show progress updates
```

## Troubleshooting

### Common Issues

1. **"Movie ID not found"**
   - The database was reset, IDs changed
   - Use the movie list to find new IDs

2. **Import fails partway**
   - Check internet connection
   - May have hit API rate limits
   - Re-run with `--fresh` to start over

3. **OMDB data missing**
   - Movie might not have IMDB ID
   - OMDB free tier limit reached (1000/day)
   - Check logs for specific errors

### Checking Import Status

```elixir
# In IEx console
iex> Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count)
200

# Check specific movie
iex> Cinegraph.Movies.get_movie!(202)
```

## Development Workflow

### Daily Development

```bash
# Quick reset with 100 movies
mix import_movies --reset --pages 5
```

### Testing New Features

```bash
# Import just a few movies
mix import_movies --reset --pages 1

# Import specific test movies
mix import_movies --ids 550,551,552
```

### Production Preparation

```bash
# Full import with 500+ movies
mix import_movies --reset --pages 25 --verbose
```

## Future Improvements

Coming with Oban integration (#21):
- Parallel TMDB imports (5x faster)
- Incremental updates
- Background synchronization
- Better progress tracking
- Automatic retries
- Cultural data population

## Scripts and Tools

### Reset Script

```bash
# Complete reset with options
elixir scripts/reset_and_populate.exs --pages 10 --dry-run
```

Options:
- `--pages N`: Number of pages to import (default: 10)
- `--skip-drop`: Skip database drop/create
- `--dry-run`: Show what would be done

### Mix Task

The enhanced Mix task (`mix import_movies`) now supports:
- `--reset`: Complete database reset
- `--fresh`: Clear data only
- `--pages N`: Number of pages
- `--verbose`: Show progress
- `--ids`: Import specific movies
- `--enrich`: Add OMDB data to existing

## Best Practices

1. **Development**: Use `--reset` for clean slate
2. **Testing**: Import small batches with `--pages 1`
3. **Production**: Use larger imports with `--pages 25+`
4. **Updates**: Use `--enrich` to add OMDB data later
5. **Debugging**: Use `--verbose` to see progress

## API Keys

Currently using shared API keys (not recommended for production):
- TMDB: Set `TMDB_API_KEY` environment variable
- OMDB: Set `OMDB_API_KEY` environment variable

For production, obtain your own keys from:
- TMDB: https://www.themoviedb.org/settings/api
- OMDB: http://www.omdbapi.com/apikey.aspx