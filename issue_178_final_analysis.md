# Issue #178: UnifiedFestivalScraper Performance Issue - Final Analysis

## Executive Summary

The UnifiedFestivalScraper makes 40+ identical database queries during festival import due to repeated calls to `Events.list_active_events()` in the `get_festival_event_by_config/1` helper function. Two attempted cache implementations both **broke data imports** for Venice and New Horizons festivals while appearing to work in isolated tests.

## Current State
- **Main branch**: Reverted to original code with performance issue intact
- **Failed attempts**: Saved in `broken-caching` and `broken-caching2` branches
- **Impact**: 40+ identical queries per import, but data imports correctly

## Root Cause Analysis

### The Performance Issue

The issue occurs in these helper functions that are called repeatedly during award parsing:
- `get_festival_event_by_config/1` - Called for EVERY nominee
- `apply_festival_mappings/2` - Called for EVERY category 
- `get_festival_key/1` - Called multiple times
- `get_default_category/1` - Called multiple times

Each calls `Events.list_active_events()` which queries ALL festival events from the database.

### Why Both Cache Implementations Failed

#### Attempt 1: Agent-based Cache (`broken-caching` branch)
- **Implementation**: Created `FestivalEventCache` using Agent with 5-minute TTL
- **Symptom**: Venice and New Horizons returned 0 or minimal nominations
- **Root Cause**: The cache lookups by abbreviation (`find_by_abbreviation`) were failing intermittently, likely due to:
  - Race conditions during cache initialization
  - Agent process not being ready when scraper runs
  - Possible abbreviation mismatches

#### Attempt 2: Pre-loading Events (`broken-caching2` branch)
- **Implementation**: Load `all_events` once and pass through all parsing functions
- **Symptom**: Venice returned 0 nominations, New Horizons returned only 1
- **Root Cause**: 
  1. **The critical issue**: When we pass `all_events` as a parameter through the parsing chain, it changes the function signatures
  2. **Function arity mismatch**: The `parse_awards/2` function calls `parse_award_category/2` but after our change it became `parse_award_category/3`
  3. **Silent failures**: Some parsing paths fail silently when the extra parameter causes pattern matching issues

### The Hidden Bug We Discovered

Looking at the code flow:
```elixir
# Original (working but slow):
parse_awards(awards, festival_config) 
  |> Enum.flat_map(&parse_award_category(&1, festival_config))

# Our change (broken):
parse_awards(awards, festival_config, all_events)
  |> Enum.flat_map(&parse_award_category(&1, festival_config, all_events))
```

The problem is that `Enum.flat_map` with the capture operator `&` doesn't properly handle the extra parameter. This causes:
- Cannes to work (uses one parsing path)
- Venice to fail completely (uses different JSON structure)
- New Horizons to partially fail (hybrid parsing)

## Why This Is Particularly Insidious

1. **Tests pass**: Isolated tests show the functions return data
2. **Some festivals work**: Cannes appears to work fine
3. **Silent failures**: No errors are raised, just empty or minimal data
4. **Different code paths**: Each festival uses slightly different parsing logic based on their IMDb page structure

## Severity Assessment

### Performance Impact
- **Severity**: MEDIUM
- **40+ queries** takes ~100-150ms total
- **Not user-facing**: Imports run in background workers
- **Scale**: Only affects admin-triggered imports

### Risk of Fix
- **Severity**: HIGH
- **Two attempts** both broke production data imports
- **Silent failures** make it hard to detect issues
- **Different festivals** affected differently

## Recommendation

**DO NOT FIX THIS ISSUE** unless:

1. Performance becomes a real bottleneck (currently it's not)
2. We have comprehensive integration tests for ALL festivals
3. We can verify actual database import results, not just function returns

## Alternative Solutions (If We Must Fix)

### Option 1: Query-Level Optimization (Safest)
Instead of caching, optimize the query:
```elixir
# Add a function to get a specific event by abbreviation
def get_event_by_abbreviation(abbreviation) do
  Repo.one(
    from e in FestivalEvent,
    where: e.abbreviation == ^abbreviation and e.active == true
  )
end
```

### Option 2: Module Attribute (Compile-time)
Load events at compile time into module attributes (only works if events rarely change).

### Option 3: ETS with Proper Error Handling
Implement ETS cache with comprehensive fallback to database queries on any cache miss.

### Option 4: Memoization Within Request
Use `Process.put/get` to memoize within a single import process.

## Testing Requirements for Any Fix

Before attempting another fix, we need:

1. **Integration tests** that actually import festivals and check database results
2. **All festival coverage**: Tests for Cannes, Venice, Berlin, New Horizons, BAFTA
3. **Verification of**:
   - Total nominations count
   - Categories count  
   - Winners vs nominees
   - Person vs film nominations

## Lessons Learned

1. **Performance optimizations in parsing code are dangerous** - Different data structures can cause silent failures
2. **Function arity changes break capturing** - The `&function/2` syntax is fragile with parameter changes
3. **Test the actual outcome** - Don't just test that functions return data, test what gets saved to database
4. **Different festivals = different code paths** - IMDb returns different JSON structures per festival

## Current Workaround

None needed. The 40+ queries execute in ~150ms total, which is acceptable for a background job that runs infrequently.

## Branches for Reference

- `broken-caching`: Agent-based cache attempt (FAILED)
- `broken-caching2`: Pre-loading optimization attempt (FAILED)
- `main`: Current working code with performance issue

---

**Status**: Issue identified but NOT FIXED due to high risk of breaking imports
**Recommendation**: Close as "Won't Fix" or keep open as "Low Priority"
**Risk Level**: HIGH - Multiple attempts to fix have broken production imports