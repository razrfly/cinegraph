# Design Modular Oban-Based Movie Data Synchronization System

## Overview
Design and implement a modular, job-based system using Oban for continuous movie data synchronization from TMDB and OMDB. This system should support both initial bulk imports and incremental updates.

## Goals

1. **Modular Architecture**: Separate jobs for different data sources and update types
2. **Scalable Import**: Ability to import entire TMDB catalog (millions of movies)
3. **Incremental Updates**: Keep existing movie data fresh
4. **Rate Limit Compliance**: Respect API limits for both TMDB and OMDB
5. **Fault Tolerance**: Handle failures gracefully with retries
6. **Monitoring**: Track sync status and performance

## Proposed Architecture

### 1. Job Types

#### A. Discovery Jobs
```elixir
defmodule Cinegraph.Jobs.DiscoverMovies do
  use Oban.Worker, queue: :discovery, max_attempts: 3
  
  @impl true
  def perform(%Job{args: %{"source" => "popular", "page" => page}}) do
    # Fetch page of popular movies
    # For each movie, enqueue DetailedImportJob
  end
  
  def perform(%Job{args: %{"source" => "all", "start_id" => start_id}}) do
    # Fetch batch of ALL movies by ID range
    # TMDB has ~1M+ movies
  end
end
```

#### B. Import Jobs
```elixir
defmodule Cinegraph.Jobs.ImportMovie do
  use Oban.Worker, queue: :imports, max_attempts: 5
  
  @impl true
  def perform(%Job{args: %{"tmdb_id" => tmdb_id, "source" => source}}) do
    case source do
      "tmdb" -> import_tmdb_data(tmdb_id)
      "omdb" -> import_omdb_data(tmdb_id)
      "all" -> import_all_sources(tmdb_id)
    end
  end
end
```

#### C. Update Jobs
```elixir
defmodule Cinegraph.Jobs.UpdateMovie do
  use Oban.Worker, queue: :updates, max_attempts: 3
  
  @impl true
  def perform(%Job{args: %{"movie_id" => movie_id, "fields" => fields}}) do
    # Update specific fields for existing movie
    # fields: ["ratings", "revenue", "status", "videos"]
  end
end
```

#### D. Enrichment Jobs
```elixir
defmodule Cinegraph.Jobs.EnrichMovie do
  use Oban.Worker, queue: :enrichment, max_attempts: 3
  
  @impl true
  def perform(%Job{args: %{"movie_id" => movie_id, "enrichment" => type}}) do
    case type do
      "cultural_lists" -> add_to_cultural_lists(movie_id)
      "cri_score" -> calculate_cri_score(movie_id)
      "recommendations" -> generate_recommendations(movie_id)
    end
  end
end
```

### 2. Queue Configuration

```elixir
config :cinegraph, Oban,
  repo: Cinegraph.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}, # 7 days
    {Oban.Plugins.Cron,
      crontab: [
        {"0 2 * * *", Cinegraph.Jobs.DailySync},      # Daily at 2 AM
        {"0 * * * *", Cinegraph.Jobs.HourlyUpdates},  # Every hour
        {"*/15 * * * *", Cinegraph.Jobs.NewReleases}, # Every 15 min
      ]
    }
  ],
  queues: [
    discovery: [limit: 2],      # Find new movies
    imports: [limit: 5],        # TMDB allows higher concurrency
    omdb: [limit: 1],          # OMDB free tier: sequential only
    updates: [limit: 3],        # Update existing movies
    enrichment: [limit: 10],    # Internal processing
  ]
```

### 3. Sync Strategies

#### A. Initial Bulk Import
```elixir
defmodule Cinegraph.Sync.BulkImport do
  def import_all_movies do
    # Start with popular/top-rated for immediate value
    import_popular_movies(pages: 100)    # 2,000 movies
    import_top_rated_movies(pages: 100)  # 2,000 movies
    
    # Then background import ALL movies
    import_entire_catalog()
  end
  
  def import_entire_catalog do
    # TMDB movies have sequential IDs
    # Import in batches to avoid overwhelming system
    max_id = 1_000_000
    batch_size = 1000
    
    for start_id <- 1..max_id//batch_size do
      %{start_id: start_id, end_id: start_id + batch_size - 1}
      |> Cinegraph.Jobs.DiscoverMovies.new(schedule_in: {start_id, :seconds})
      |> Oban.insert()
    end
  end
end
```

#### B. Incremental Updates
```elixir
defmodule Cinegraph.Sync.IncrementalUpdate do
  def update_existing_movies do
    # Update movies based on criteria
    update_recently_released()    # Released in last 6 months
    update_popular_movies()       # High popularity score
    update_stale_movies()        # Not updated in 30+ days
  end
  
  def update_recently_released do
    Movies.recently_released(months: 6)
    |> Enum.each(fn movie ->
      %{movie_id: movie.id, fields: ["revenue", "ratings", "status"]}
      |> Cinegraph.Jobs.UpdateMovie.new()
      |> Oban.insert()
    end)
  end
end
```

#### C. Real-time Monitoring
```elixir
defmodule Cinegraph.Sync.Monitor do
  def check_new_releases do
    # Check TMDB "now playing" and "upcoming"
    # Run every 15 minutes for latest releases
  end
  
  def check_trending do
    # Update trending/popular movies more frequently
    # These change daily
  end
end
```

### 4. Rate Limit Management

```elixir
defmodule Cinegraph.RateLimit do
  use GenServer
  
  # TMDB: 50 requests per second
  # OMDB: 1,000 per day (free tier)
  
  def check_rate_limit(service) do
    case service do
      :tmdb -> check_tmdb_limit()    # Token bucket algorithm
      :omdb -> check_omdb_limit()    # Daily quota tracking
    end
  end
end
```

### 5. Progress Tracking

```elixir
defmodule Cinegraph.Sync.Progress do
  defstruct [
    :total_movies,
    :imported_movies,
    :failed_movies,
    :last_sync_at,
    :next_sync_at,
    :status
  ]
  
  def get_sync_status do
    %{
      discovery: Oban.queue_state(:discovery),
      imports: Oban.queue_state(:imports),
      updates: Oban.queue_state(:updates),
      stats: calculate_stats()
    }
  end
end
```

### 6. Failure Handling

```elixir
defmodule Cinegraph.Jobs.ImportMovie do
  def perform(%Job{args: args, attempt: attempt}) do
    case import_movie_data(args) do
      {:ok, movie} -> 
        :ok
        
      {:error, :rate_limited} ->
        # Exponential backoff
        {:snooze, :timer.minutes(attempt * 5)}
        
      {:error, :not_found} ->
        # Don't retry
        {:discard, :not_found}
        
      {:error, reason} ->
        # Retry with backoff
        {:error, reason}
    end
  end
end
```

## Implementation Phases

### Phase 1: Foundation (Week 1-2)
1. Add Oban dependency and basic configuration
2. Create job modules for TMDB and OMDB
3. Implement rate limiting
4. Basic import jobs

### Phase 2: Bulk Import (Week 3-4)
1. Discovery jobs for finding movies
2. Parallel import system
3. Progress tracking
4. Error handling

### Phase 3: Updates System (Week 5-6)
1. Update job types
2. Scheduled cron jobs
3. Freshness tracking
4. Selective updates

### Phase 4: Monitoring (Week 7-8)
1. Admin dashboard
2. Sync status API
3. Alerts for failures
4. Performance metrics

## Benefits

1. **Scalability**: Can handle millions of movies
2. **Reliability**: Automatic retries and error handling
3. **Efficiency**: Parallel processing where allowed
4. **Flexibility**: Easy to add new data sources
5. **Maintainability**: Modular job design
6. **Observability**: Built-in job tracking

## Configuration Examples

### Development (Small Scale)
```elixir
# config/dev.exs
config :cinegraph, :sync,
  max_concurrent_imports: 2,
  omdb_daily_limit: 1000,
  update_interval_days: 7,
  import_batch_size: 20
```

### Production (Full Scale)
```elixir
# config/prod.exs
config :cinegraph, :sync,
  max_concurrent_imports: 10,
  omdb_daily_limit: 100_000,  # Paid tier
  update_interval_days: 1,
  import_batch_size: 1000
```

## Future Enhancements

1. **Additional Sources**: Rotten Tomatoes, Metacritic, Letterboxd
2. **Smart Scheduling**: ML-based prediction of update needs
3. **Distributed Processing**: Multi-node Oban for scale
4. **Webhooks**: Real-time updates from TMDB
5. **Data Validation**: Ensure data quality before import

## Migration Path

1. Keep current Mix task for development
2. Add Oban jobs alongside existing code
3. Gradually move to job-based system
4. Deprecate old import methods
5. Full Oban-based synchronization

## Success Metrics

- Import speed: 1000+ movies/hour
- Update latency: <1 hour for popular movies
- Success rate: >99% successful imports
- API efficiency: <80% of rate limits
- Data freshness: 95% updated within 7 days