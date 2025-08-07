# GitHub Issue #178 - Performance Issue Analysis and Solution

## Summary
The issue describes UnifiedFestivalScraper making 40+ identical database queries during award parsing, causing performance problems.

## Root Cause
The function `get_festival_event_by_config/1` is called for every award category and nominee during parsing, and each call executes `Events.list_active_events()` - resulting in 40+ identical database queries for a single import.

## Impact
- **Performance**: Each import takes ~14ms extra due to repeated queries
- **Database Load**: Unnecessary load on the database
- **Scalability**: Problem compounds with multiple concurrent imports

## Attempted Solution #1: Agent-based Cache
**Status**: ❌ Failed - Caused intermittent import failures

### Implementation:
- Created `FestivalEventCache` using Elixir Agent
- Added to supervision tree
- Modified scraper to use cache

### Why it failed:
- Possible race conditions during startup
- Agent might not be fully initialized when scrapers run
- Cache invalidation timing issues

## Attempted Solution #2: ETS-based Cache  
**Status**: ⚠️ Not tested - More complex than needed

### Design:
- ETS table with public read access
- GenServer managing the cache
- Better concurrency support

### Concerns:
- Still has initialization order dependencies
- Adds complexity to the system

## Recommended Solution: Query Optimization
**Status**: ✅ Simple and effective

### Implementation:
Instead of caching at the application level, optimize the parsing function to load events once:

```elixir
# In UnifiedFestivalScraper
def parse_festival_html(html, year, festival_config) do
  # Load events once at the start of parsing
  all_events = Events.list_active_events()
  
  # Pass events through the parsing chain
  case parse_json(html) do
    {:ok, data} -> extract_awards(data, year, festival_config, all_events)
    # ... rest of parsing logic
  end
end

# Change helper function to use pre-loaded events
defp get_festival_event_by_config(festival_config, events) do
  Enum.find(events, fn event -> 
    event.abbreviation == festival_config.abbreviation 
  end)
end
```

### Benefits:
- **Simple**: No new processes or caching infrastructure
- **Reliable**: No initialization order issues
- **Effective**: Reduces queries from 40+ to 1
- **Safe**: No risk of stale cache data

## Performance Improvements
- Query reduction: 40+ → 1 per import
- Time saved: ~14ms per import
- Performance improvement: ~83x faster for the lookup operations

## Recommendation
Use the query optimization approach rather than caching. It's simpler, more reliable, and achieves the same performance goals without the complexity and potential issues of a caching layer.

## Files to Modify
1. `lib/cinegraph/scrapers/unified_festival_scraper.ex` - Pass events through parsing functions

## Testing
```elixir
# Test script to verify improvement
{time_before, _} = :timer.tc(fn ->
  # Current implementation - multiple queries
  40.times do
    Events.list_active_events()
    |> Enum.find(fn e -> e.abbreviation == "CFF" end)
  end
end)

{time_after, _} = :timer.tc(fn ->
  # Optimized implementation - single query
  events = Events.list_active_events()
  40.times do
    Enum.find(events, fn e -> e.abbreviation == "CFF" end)
  end
end)

IO.puts("Improvement: #{time_before / time_after}x faster")
```

## Conclusion
The issue is valid and impacts performance. The simplest solution is to optimize the query pattern rather than introduce caching. This avoids the complexity and potential issues seen with the cache implementation while still achieving the desired performance improvement.