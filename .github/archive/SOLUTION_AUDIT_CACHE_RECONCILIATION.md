# Solution: Cache System Reconciliation

## Problem Analysis

The 08-19-code_rabbit_audit branch works because:
1. It calls calculation functions inline when cache is empty
2. It returns proper data structure with `year` field
3. It works immediately without background jobs

Our current implementation:
1. Only checks database cache, never calculates inline
2. Requires manual refresh via background jobs
3. Has all the worker code but doesn't populate cache properly

## The Solution

### Phase 1: Fix Cache Data Structure
The cache needs to return data exactly like MoviePredictor does:
- Include `year` field (extracted from release_date)
- Match the exact structure MoviePredictor returns
- Keep likelihood_percentage properly calculated

### Phase 2: Pre-populate Cache via Background Jobs
Instead of inline calculations, we'll:
1. Run comprehensive cache population on app startup
2. Cache ALL decades (1920s-2020s), not just 2020s
3. Use the existing orchestrator to populate everything

### Phase 3: Hybrid Approach for Development
For development convenience:
1. Add a development-only flag to allow inline calculation
2. In production, NEVER calculate inline
3. Use environment variable to control this

## Implementation Steps

### Step 1: Fix Cache Extraction to Include Year
```elixir
# In check_database_for_predictions:
year = extract_year_from_date(Map.get(score_data, "release_date"))

%{
  id: movie_id,
  title: Map.get(score_data, "title", "Unknown"),
  year: year,  # Add this field
  release_date: Map.get(score_data, "release_date"),
  # ... rest of structure
}
```

### Step 2: Add Dev-Only Inline Calculation
```elixir
# In predictions_cache.ex
@allow_inline_calc Application.compile_env(:cinegraph, :allow_inline_calc, false)

def get_predictions(limit, profile) do
  case Cachex.get(@cache_name, cache_key) do
    {:ok, nil} ->
      # Try database cache first
      result = check_database_for_predictions(2020, profile, limit, cache_key)
      
      # In dev only, fall back to calculation if no cache
      if is_nil(result) && @allow_inline_calc do
        Logger.warning("DEV MODE: Calculating inline - this would not happen in production!")
        result = Cinegraph.Predictions.MoviePredictor.predict_2020s_movies(limit, profile)
        Cachex.put(@cache_name, cache_key, result, ttl: :timer.minutes(30))
        
        # Also queue background job to save to database
        Cinegraph.Workers.PredictionsOrchestrator.orchestrate_profile(profile)
        
        result
      else
        result
      end
  end
end
```

### Step 3: Ensure Orchestrator Populates All Decades
```elixir
# In PredictionsOrchestrator:
defp queue_decade_calculations(profile_id) do
  # Queue calculations for ALL decades
  decades = [1920, 1930, 1940, 1950, 1960, 1970, 1980, 1990, 2000, 2010, 2020]
  
  Enum.map(decades, fn decade ->
    %{
      action: "calculate_predictions",
      decade: decade,
      profile_id: profile_id
    }
    |> Oban.Job.new(queue: :predictions)
    |> Oban.insert()
  end)
end
```

### Step 4: Add Startup Cache Population
```elixir
# In application.ex startup:
def start(_type, _args) do
  children = [
    # ... other children
    {Task, fn -> 
      # Wait for app to fully start
      Process.sleep(5000)
      
      # Queue cache population for default profile
      Cinegraph.Workers.PredictionsOrchestrator.orchestrate_default_profile()
    end}
  ]
end
```

## Benefits of This Approach

1. **Production Safety**: Never calculates inline in production
2. **Development Convenience**: Can work immediately in dev
3. **Full Compatibility**: Works exactly like 08-19-code_rabbit_audit branch
4. **Background Processing**: All heavy work done in background
5. **Complete Coverage**: All decades cached, not just 2020s

## Configuration

Add to config/dev.exs:
```elixir
config :cinegraph,
  allow_inline_calc: true  # Allow inline calculation in dev only
```

Add to config/prod.exs:
```elixir
config :cinegraph,
  allow_inline_calc: false  # Never calculate inline in production
```

## Verification

1. Cache returns data with `year` field
2. All decades get cached via background jobs
3. Page loads instantly when cache is populated
4. Manual refresh button works
5. Development mode allows immediate results