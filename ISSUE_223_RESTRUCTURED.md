# Improve External API Resilience with Comprehensive Tracking System

## Problem Statement
We need better visibility into our external API and scraping operations across all data sources (TMDb, OMDb, IMDb scraping, festival data). Currently, we lack comprehensive tracking of success/failure rates and have no fallback strategies when primary lookups fail.

## Component 1: Improve TMDb Lookup Resilience

### Current Problem
- TMDb lookups fail silently when IMDb ID is missing or incorrect
- No fallback search strategy exists
- Lost data from festival/award imports

### Solution
Implement progressive fallback search with confidence scoring:

1. **Direct IMDb lookup** (confidence: 1.0)
2. **Exact title + year match** (confidence: 0.9)
3. **Normalized title match** (confidence: 0.8) - remove special chars, case-insensitive
4. **Year-tolerant match** (confidence: 0.7) - ±1 year tolerance
5. **Fuzzy title match** (confidence: 0.6) - Levenshtein distance
6. **Broad search** (confidence: 0.5) - title keywords only

Configuration via `config.exs`:
```elixir
config :cinegraph, :tmdb_search,
  max_fallback_level: 3,
  min_confidence: 0.7
```

## Component 2: Universal API/Scraping Tracking System

### New Table: `api_lookup_metrics`

```elixir
create table(:api_lookup_metrics) do
  add :source, :string, null: false         # "tmdb", "omdb", "imdb_scraper", "venice_scraper", etc.
  add :operation, :string, null: false      # "find_by_imdb", "search_movie", "fetch_ceremony", etc.
  add :target_identifier, :string           # IMDb ID, movie title, festival year, etc.
  add :success, :boolean, null: false
  add :confidence_score, :float             # For fuzzy matches
  add :fallback_level, :integer             # Which strategy succeeded (1-5)
  add :response_time_ms, :integer
  add :error_type, :string                  # "not_found", "rate_limit", "timeout", "parse_error"
  add :error_message, :text
  add :metadata, :map                       # Additional context (import source, job_id, etc.)
  
  timestamps()
end

create index(:api_lookup_metrics, [:source, :operation])
create index(:api_lookup_metrics, [:success])
create index(:api_lookup_metrics, [:inserted_at])
```

### Track All External Operations
- **TMDb API**: Direct lookups, searches, fallback attempts
- **OMDb API**: Movie enrichment calls
- **IMDb Scraping**: Canonical lists, Oscar data, festival pages
- **Festival Scrapers**: Venice, Cannes, Berlin data fetching
- **Any future external data sources**

## Component 3: Operations Dashboard

Add to `ImportDashboardLive` a new "API Health" tab showing:

### Real-time Metrics
```
Source          | Success Rate | Avg Response | Last 24h
----------------|--------------|--------------|----------
TMDb API        | 65.2%        | 245ms        | 1,234/1,892
OMDb API        | 99.8%        | 89ms         | 567/568  
IMDb Scraper    | 88.5%        | 1,234ms      | 234/264
Venice Scraper  | 92.1%        | 2,100ms      | 45/49
```

### Detailed Breakdowns
- TMDb fallback strategy effectiveness
- Error type distribution
- Response time trends
- Per-operation success rates

## Implementation Plan

### Phase 1: Create Tracking Infrastructure
- [ ] Create `api_lookup_metrics` table migration
- [ ] Create `Cinegraph.Metrics.ApiLookup` schema
- [ ] Create `Cinegraph.Metrics.ApiTracker` context module

### Phase 2: Instrument Existing Code
- [ ] Add tracking to `Cinegraph.Services.TMDb`
- [ ] Add tracking to `Cinegraph.Services.OMDb` 
- [ ] Add tracking to `Cinegraph.Scrapers.ImdbCanonicalScraper`
- [ ] Add tracking to festival scrapers (Venice, Cannes, Berlin)
- [ ] Use Telemetry events for consistency

### Phase 3: Implement TMDb Fallback Strategies
- [ ] Create `Cinegraph.Services.TMDb.FallbackSearch` module
- [ ] Implement confidence scoring
- [ ] Add configuration options
- [ ] Update `TMDbDetailsWorker` to use fallback strategies

### Phase 4: Build Dashboard Visualizations
- [ ] Add "API Health" tab to `ImportDashboardLive`
- [ ] Create real-time success rate calculations
- [ ] Add response time graphs
- [ ] Create error breakdown charts

## Benefits
- **Visibility**: Know exactly which external sources are reliable
- **Debugging**: Quickly identify failing integrations
- **Optimization**: Focus efforts on improving lowest-performing sources
- **Resilience**: Automatic fallbacks prevent data loss
- **Monitoring**: Proactive alerts when success rates drop

## Success Metrics
- TMDb lookup success rate increases from ~65% to >85%
- Zero lost movies from festival imports due to lookup failures
- <500ms average response time for all API operations
- Complete visibility into all external data source health

## Technical Notes

### Tracking Implementation Example
```elixir
defmodule Cinegraph.Metrics.ApiTracker do
  def track_lookup(source, operation, target, fun) do
    start_time = System.monotonic_time(:millisecond)
    
    result = 
      try do
        fun.()
      rescue
        error -> {:error, error}
      end
    
    end_time = System.monotonic_time(:millisecond)
    response_time = end_time - start_time
    
    attrs = %{
      source: source,
      operation: operation,
      target_identifier: target,
      success: match?({:ok, _}, result),
      response_time_ms: response_time,
      error_type: extract_error_type(result),
      error_message: extract_error_message(result),
      metadata: %{timestamp: DateTime.utc_now()}
    }
    
    Cinegraph.Metrics.create_api_lookup_metric(attrs)
    result
  end
end
```

### Usage in Services
```elixir
# In Cinegraph.Services.TMDb
def find_by_imdb_id(imdb_id) do
  ApiTracker.track_lookup("tmdb", "find_by_imdb", imdb_id, fn ->
    # Existing TMDb API call
    HTTPoison.get(...)
  end)
end
```

## Questions to Resolve
1. Should we use Telemetry for all tracking or direct database writes?
2. What retention policy for metrics? (30 days? 90 days?)
3. Should we add real-time alerting when success rates drop below thresholds?
4. Do we want to track individual user API keys separately?