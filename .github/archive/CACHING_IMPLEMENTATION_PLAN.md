# Correct Caching Implementation Plan

## Goal
Reduce prediction page load time from 3-4 seconds to <100ms by implementing proper database-backed caching with manual refresh.

## Current State (Working Branch: 08-19-code_rabbit_audit)
- **Performance**: 3.8 seconds for 100 predictions
- **In-memory caching**: Working via Cachex (15-minute TTL)
- **Problem**: Initial load and cache misses still slow

## Implementation Strategy

### Phase 1: Database Schema (Keep from failed attempt)
```elixir
# Migration: create_prediction_cache.exs
create table(:prediction_cache) do
  add :decade, :integer, null: false
  add :profile_id, references(:metric_weight_profiles), null: false
  add :movie_scores, :map  # Store full prediction data
  add :statistics, :map
  add :calculated_at, :utc_datetime
  add :metadata, :map
  timestamps()
end

create unique_index(:prediction_cache, [:decade, :profile_id])
```

### Phase 2: Core Cache Module
```elixir
defmodule Cinegraph.Predictions.PredictionCache do
  # Schema for database storage
  schema "prediction_cache" do
    field :decade, :integer
    belongs_to :profile, Metrics.MetricWeightProfile
    field :movie_scores, :map
    field :statistics, :map
    field :calculated_at, :utc_datetime
    field :metadata, :map
    timestamps()
  end
  
  def get_or_create_cache(decade, profile_id) do
    case get_cached_predictions(decade, profile_id) do
      nil -> {:error, :not_cached}
      cache -> {:ok, cache}
    end
  end
end
```

### Phase 3: Correct Worker Implementation
```elixir
defmodule Cinegraph.Workers.PredictionCalculator do
  use Oban.Worker, queue: :predictions, max_attempts: 3
  
  def perform(%{"decade" => decade, "profile_id" => profile_id}) do
    profile = Repo.get!(MetricWeightProfile, profile_id)
    
    # USE THE EXISTING WORKING LOGIC
    predictions = MoviePredictor.predict_2020s_movies(1000, profile)
    
    # Store in cache with correct format
    movie_scores = 
      Enum.reduce(predictions.predictions, %{}, fn pred, acc ->
        Map.put(acc, pred.id, %{
          "title" => pred.title,
          "score" => pred.prediction.likelihood_percentage, # Already 0-100
          "release_date" => pred.release_date,
          "canonical_sources" => pred.canonical_sources || %{}
        })
      end)
    
    PredictionCache.upsert_cache(%{
      decade: decade,
      profile_id: profile_id,
      movie_scores: movie_scores,
      statistics: calculate_stats(predictions.predictions),
      calculated_at: DateTime.utc_now()
    })
  end
end
```

### Phase 4: Modified PredictionsCache Module
```elixir
defmodule Cinegraph.Cache.PredictionsCache do
  # Modify get_predictions to check DB cache first
  def get_predictions(limit, profile) do
    # Try in-memory first (fast path)
    cache_key = predictions_cache_key(limit, profile)
    
    case Cachex.get(@cache_name, cache_key) do
      {:ok, nil} ->
        # Try database cache
        check_database_cache(limit, profile, cache_key)
      {:ok, cached} ->
        cached
      {:error, _} ->
        # Fallback to database cache
        check_database_cache(limit, profile, cache_key)
    end
  end
  
  defp check_database_cache(limit, profile, cache_key) do
    case PredictionCache.get_cached_predictions(2020, profile.id) do
      nil ->
        # DON'T calculate - return error for manual refresh
        {:error, :cache_missing}
      
      db_cache ->
        # Format and store in memory cache
        result = format_db_cache(db_cache, limit)
        Cachex.put(@cache_name, cache_key, result, ttl: :timer.minutes(15))
        result
    end
  end
end
```

### Phase 5: LiveView Updates
```elixir
def mount(_params, _session, socket) do
  profile = PredictionsCache.get_default_profile()
  
  case PredictionsCache.get_predictions(100, profile) do
    {:error, :cache_missing} ->
      # Show UI for manual refresh
      {:ok, assign(socket, 
        cache_missing: true,
        refresh_available: true,
        predictions_result: %{predictions: [], total_candidates: 0}
      )}
    
    predictions ->
      {:ok, assign(socket, 
        cache_missing: false,
        predictions_result: predictions
      )}
  end
end

def handle_event("refresh_cache", _, socket) do
  # Queue the job
  %{"decade" => 2020, "profile_id" => socket.assigns.current_profile.id}
  |> PredictionCalculator.new()
  |> Oban.insert()
  
  {:noreply, 
    socket
    |> put_flash(:info, "Refresh started. This will take a few minutes.")
    |> assign(:refresh_in_progress, true)}
end
```

### Phase 6: Import Dashboard Integration
Add to Import Dashboard for manual cache management:
```elixir
# Show cache status
cache_exists = PredictionCache.cache_exists?(2020, profile.id)
cache_age = PredictionCache.get_cache_age(2020, profile.id)

# Manual refresh button
def handle_event("refresh_predictions", %{"profile_id" => id}, socket) do
  RefreshManager.refresh_decade_profile(2020, id)
  {:noreply, put_flash(socket, :info, "Predictions refresh queued")}
end
```

## Validation Steps

1. **Create migration and run it**
2. **Implement PredictionCache schema**
3. **Create correct Worker using existing logic**
4. **Test worker output**:
   ```elixir
   # Manually run worker
   %{"decade" => 2020, "profile_id" => 46}
   |> Cinegraph.Workers.PredictionCalculator.perform()
   
   # Check cache
   cache = PredictionCache.get_cached_predictions(2020, 46)
   cache.movie_scores |> Map.values() |> List.first()
   # Should show score 0-100, not 0-2.5
   ```

5. **Update PredictionsCache module**
6. **Update LiveView**
7. **Test full flow**:
   - Load predictions page -> Should show "cache missing"
   - Click refresh -> Should queue job
   - Wait for job -> Check Oban dashboard
   - Reload page -> Should load instantly from cache

## Success Criteria

- [ ] Initial page load shows "cache missing" state
- [ ] Manual refresh queues Oban job
- [ ] Job completes in <1 minute
- [ ] Cached scores are 0-100 range
- [ ] Page loads from cache in <100ms
- [ ] No complex queries run when cache exists
- [ ] Validation data also cached properly

## Key Differences from Failed Attempt

1. **Use existing MoviePredictor** - Don't recreate scoring logic
2. **Scores already 0-100** - prediction.likelihood_percentage is correct
3. **Manual refresh only** - No automatic calculation on cache miss
4. **Proper error states** - Return {:error, :cache_missing} not nil
5. **Test incrementally** - Verify each step before integration