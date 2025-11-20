# Performance Optimization: Predictions Page Load Time Reduction

## Current Problem

The Movie Predictions page (`/predictions`) is extremely slow, taking approximately **10 seconds** to load. The target is to reduce this to **under 1 second** for real-time user experience.

### Current Performance Analysis

Based on query analysis, the main bottleneck is in `MoviePredictor.predict_2020s_movies/2`:

```
Prediction query took: 920ms (for first query)
Historical validation: ~4-10 seconds per decade
Total page load: ~10+ seconds
```

### Root Cause Analysis

The query in `ScoringService.apply_scoring/3` is extremely complex:

1. **6 LEFT OUTER JOINs** to `external_metrics` table
2. **Complex subqueries** for festival nominations aggregation
3. **Complex subqueries** for person quality aggregation
4. **Expensive SQL calculations** in SELECT clause with LOG functions
5. **No result caching** - every page load recalculates everything
6. **Historical validation** runs multiple expensive queries per decade
7. **Complex scoring fragments** executed for every movie

## Optimization Strategy: Multi-Layered Approach

### Phase 1: Immediate Wins (1-2 days)

#### 1.1 Implement Cachex for Results Caching
- **Library**: Cachex 4.0 (latest with 3x performance improvements)
- **Target**: Cache prediction results for 5-15 minutes
- **Impact**: 95% reduction in page load time for cached results

```elixir
# Add to application supervisor
{Cachex, name: :predictions_cache}

# Cache prediction results
def predict_2020s_movies(limit, profile) do
  cache_key = "predictions_#{profile.name}_#{limit}"
  
  case Cachex.get(:predictions_cache, cache_key) do
    {:ok, nil} ->
      result = compute_predictions(limit, profile)
      Cachex.put(:predictions_cache, cache_key, result, ttl: :timer.minutes(10))
      result
    {:ok, cached_result} ->
      cached_result
  end
end
```

#### 1.2 Background Processing with Oban
- **Pre-compute** popular profile combinations
- **Refresh cache** every 10-15 minutes via background jobs
- **Immediate response** from cache, async refresh

```elixir
defmodule Cinegraph.Workers.PredictionCacheWarmer do
  use Oban.Worker, queue: :predictions, max_attempts: 3
  
  def perform(%Oban.Job{}) do
    # Warm cache for all active profiles
    ScoringService.get_all_profiles()
    |> Enum.each(&warm_predictions_for_profile/1)
    
    :ok
  end
end
```

#### 1.3 Query Result Pagination
- **Limit initial load** to top 25-50 movies
- **Lazy load** remaining results on demand
- **LiveView streams** for infinite scroll

### Phase 2: Database Optimization (3-5 days)

#### 2.1 Materialized Views for Complex Calculations
Create pre-computed scoring views that refresh periodically:

```sql
-- Movie scoring materialized view
CREATE MATERIALIZED VIEW movie_scores AS
SELECT 
  m.id,
  m.title,
  m.release_date,
  -- Pre-computed popular opinion score
  (COALESCE(em_tmdb.value, 0) / 10.0 * 0.5 + COALESCE(em_imdb.value, 0) / 10.0 * 0.5) as popular_opinion_score,
  -- Pre-computed critical acclaim score  
  (COALESCE(em_meta.value, 0) / 100.0 * 0.5 + COALESCE(em_rt.value, 0) / 100.0 * 0.5) as critical_acclaim_score,
  -- Pre-computed industry recognition score
  LEAST(1.0, (COALESCE(f.wins, 0) * 0.2 + COALESCE(f.nominations, 0) * 0.05)) as industry_recognition_score,
  -- Pre-computed cultural impact score
  LEAST(1.0, COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(m.canonical_sources, '{}'::jsonb))), 0) * 0.1 + 
    CASE WHEN COALESCE(em_pop.value, 0) = 0 THEN 0 ELSE LN(COALESCE(em_pop.value, 0) + 1) / LN(1001) END) as cultural_impact_score,
  -- Pre-computed people quality score
  COALESCE(pq.avg_person_quality, 0) / 100.0 as people_quality_score
FROM movies m
LEFT JOIN external_metrics em_tmdb ON (em_tmdb.movie_id = m.id AND em_tmdb.source = 'tmdb' AND em_tmdb.metric_type = 'rating_average')
LEFT JOIN external_metrics em_imdb ON (em_imdb.movie_id = m.id AND em_imdb.source = 'imdb' AND em_imdb.metric_type = 'rating_average')
-- ... other joins
WHERE m.import_status = 'full';

CREATE UNIQUE INDEX ON movie_scores (id);
CREATE INDEX ON movie_scores (release_date) WHERE release_date >= '2020-01-01';
```

**Benefits**: 
- Reduces complex query to simple multiplication and addition
- Eliminates 6 LEFT JOINs and subqueries
- Can use expression indexes for sorting

#### 2.2 Dedicated Indexes for Prediction Queries

```sql
-- Composite index for 2020s movies predictions
CREATE INDEX idx_movies_2020s_predictions ON movies 
(release_date, import_status) 
WHERE release_date >= '2020-01-01' 
  AND import_status = 'full' 
  AND canonical_sources -> '1001_movies' IS NULL;

-- Index for external metrics lookups
CREATE INDEX idx_external_metrics_movie_source_type ON external_metrics 
(movie_id, source, metric_type);

-- Index for festival nominations aggregation
CREATE INDEX idx_festival_nominations_movie_won ON festival_nominations 
(movie_id, won);
```

#### 2.3 Query Optimization
- **Split complex query** into simpler parts
- **Use LATERAL joins** for better performance
- **Eliminate repeated calculations** in ORDER BY

### Phase 3: Advanced Caching Architecture (5-7 days)

#### 3.1 Nebulex Multi-Level Caching
- **Local ETS cache** for immediate access
- **Distributed cache** for shared results across instances
- **Cache partitioning** by profile and time periods

```elixir
defmodule Cinegraph.Cache do
  use Nebulex.Cache,
    otp_app: :cinegraph,
    adapter: Nebulex.Adapters.Dist
    
  defmodule Local do
    use Nebulex.Cache,
      otp_app: :cinegraph,
      adapter: Nebulex.Adapters.Local
  end
end

defmodule Cinegraph.Predictions.CachedPredictor do
  use Nebulex.Caching
  
  @decorate cacheable(cache: Cinegraph.Cache, key: {__MODULE__, profile.name, limit}, ttl: :timer.minutes(15))
  def predict_2020s_movies(limit, profile) do
    # Original computation
  end
  
  @decorate cache_evict(cache: Cinegraph.Cache, keys: [{__MODULE__, :_, :_}])
  def invalidate_all_predictions do
    :ok
  end
end
```

#### 3.2 Smart Cache Invalidation
- **Time-based expiration** (10-15 minutes)
- **Event-driven invalidation** when data changes
- **Gradual cache warming** to prevent thundering herd

#### 3.3 Pre-computed Score Tables
Create a dedicated `movie_discovery_scores` table:

```elixir
defmodule Cinegraph.Metrics.MovieDiscoveryScore do
  use Ecto.Schema
  
  schema "movie_discovery_scores" do
    belongs_to :movie, Cinegraph.Movies.Movie
    field :popular_opinion_score, :decimal
    field :critical_acclaim_score, :decimal  
    field :industry_recognition_score, :decimal
    field :cultural_impact_score, :decimal
    field :people_quality_score, :decimal
    field :computed_at, :utc_datetime
  end
end
```

**Benefits**:
- **Instant score retrieval** with simple SELECT
- **Background refresh** via Oban workers
- **Incremental updates** for new movies only

### Phase 4: Real-time Architecture (1-2 weeks)

#### 4.1 Streaming Updates with LiveView
- **Initial fast load** with cached top 25 results
- **Stream remaining** results as they compute
- **Progressive enhancement** of user experience

```elixir
def mount(_params, _session, socket) do
  # Fast initial load from cache
  cached_predictions = get_cached_predictions_fast(25)
  
  socket = 
    socket
    |> assign(:loading_more, true)
    |> stream(:predictions, cached_predictions)
  
  # Start background loading for full results
  send(self(), :load_full_predictions)
  
  {:ok, socket}
end

def handle_info(:load_full_predictions, socket) do
  # Load remaining predictions in background
  Task.start_link(fn ->
    full_predictions = compute_full_predictions()
    send(self(), {:predictions_ready, full_predictions})
  end)
  
  {:noreply, socket}
end
```

#### 4.2 Incremental Score Updates
- **Track data changes** with database triggers
- **Queue incremental updates** for affected movies
- **Real-time cache updates** via Phoenix PubSub

### Phase 5: System Architecture Optimization (2-3 weeks)

#### 5.1 Read Replicas for Analytics
- **Separate read replica** for prediction queries
- **Reduced load** on primary database
- **Dedicated analytics tuning**

#### 5.2 In-Memory Data Structures
- **ETS tables** for frequently accessed data (genres, countries, profiles)
- **Agent-based caching** for computation-heavy operations
- **Process dictionary** for request-scoped caching

```elixir
defmodule Cinegraph.Cache.ProfileWeights do
  use Agent
  
  def start_link(_) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end
  
  def get_weights(profile_name) do
    Agent.get(__MODULE__, fn cache ->
      case Map.get(cache, profile_name) do
        nil ->
          weights = ScoringService.profile_to_discovery_weights(profile_name)
          Agent.update(__MODULE__, &Map.put(&1, profile_name, weights))
          weights
        cached_weights ->
          cached_weights
      end
    end)
  end
end
```

## Implementation Timeline

### Week 1: Quick Wins
- [ ] Implement Cachex caching
- [ ] Add Oban background cache warming
- [ ] Optimize initial query with LIMIT
- [ ] Add query pagination

**Expected Impact**: 70-80% reduction in load time

### Week 2: Database Optimization
- [ ] Create materialized views
- [ ] Add optimized indexes
- [ ] Implement query splitting
- [ ] Add result pagination

**Expected Impact**: 90-95% reduction in load time

### Week 3-4: Advanced Caching
- [ ] Implement Nebulex caching
- [ ] Create pre-computed score tables
- [ ] Add smart cache invalidation
- [ ] Implement streaming updates

**Expected Impact**: Sub-second response times

### Week 5-6: System Architecture
- [ ] Set up read replicas
- [ ] Implement ETS caching
- [ ] Add real-time updates
- [ ] Performance monitoring

**Expected Impact**: Consistent sub-500ms response times

## Performance Monitoring

### Key Metrics to Track
- **Query execution time** (target: <100ms)
- **Cache hit ratio** (target: >90%)
- **Page load time** (target: <500ms)
- **Memory usage** for caches
- **Database connection pool** utilization

### Tools
- **Phoenix LiveDashboard** for real-time monitoring
- **Telemetry** for custom metrics
- **Ecto.Telemetry** for query analysis
- **Cachex telemetry** for cache performance

## Risk Mitigation

### Cache Coherency
- **Short TTL values** initially (5-10 minutes)
- **Gradual increase** as confidence builds
- **Manual invalidation** capabilities

### Memory Management
- **Cache size limits** to prevent OOM
- **LRU eviction** policies
- **Memory monitoring** and alerts

### Failover Strategy
- **Graceful degradation** when cache is unavailable
- **Circuit breaker** pattern for cache failures
- **Fallback to direct queries** with increased timeouts

## Success Criteria

1. **Page load time**: <1 second (from ~10 seconds)
2. **Cache hit ratio**: >90% for common profiles
3. **Database load**: 50% reduction in query volume
4. **User experience**: Immediate response with progressive loading
5. **Scalability**: Support 10x more concurrent users

## Libraries to Add

```elixir
# mix.exs
defp deps do
  [
    # High-performance caching
    {:cachex, "~> 4.0"},
    
    # Advanced distributed caching (alternative to Cachex)
    {:nebulex, "~> 2.6"},
    {:shards, "~> 1.1"},    # For Nebulex partitioned adapter
    {:decorator, "~> 1.4"}, # For Nebulex decorators
    
    # Background job enhancements  
    {:oban, "~> 2.17"},
    {:oban_pro, "~> 1.4"}, # For advanced scheduling (if budget allows)
    
    # Performance monitoring
    {:telemetry_metrics, "~> 1.0"},
    {:telemetry_poller, "~> 1.0"},
    {:phoenix_live_dashboard, "~> 0.8"}
  ]
end
```

## Additional Considerations

### Development vs Production
- **Development**: Use simple Cachex with short TTL
- **Production**: Full Nebulex distributed setup with materialized views

### Data Freshness vs Performance
- **Real-time data**: 5-minute cache TTL
- **Historical data**: 1-hour cache TTL
- **Profile changes**: Immediate invalidation

### Monitoring and Alerting
- **Cache miss spikes** indicating cache issues
- **Query time increases** suggesting database problems
- **Memory usage growth** indicating cache bloat

This multi-phase approach provides both immediate wins and long-term scalability while maintaining data accuracy and system reliability.