# Critical Issue: import_state Table Incorrectly Removed

## Problem Summary
The `import_state` table was incorrectly identified as unused and removed in migration `20250812065523_remove_unused_tables.exs`. This table was actively being used by the TMDbImporter module to track critical import metrics displayed on the Import Dashboard.

## Impact
- **TMDB total movies count no longer updates** - Always shows 0
- **Last page processed not tracked** - Import resume functionality broken
- **Sync timestamps lost** - Can't track when last full sync occurred
- **Import progress calculation broken** - Completion percentage incorrect

## Root Cause Analysis

### What import_state Was Used For
The `import_state` table was a key-value store that tracked:
1. **tmdb_total_movies** - Total number of movies available in TMDB
2. **last_page_processed** - Last page successfully imported (for resuming imports)
3. **last_full_sync** - Date of last complete synchronization
4. **last_update_check** - Date of last check for updates

### Where It Was Used
- `lib/cinegraph/imports/import_state.ex` - Core module for state management
- `lib/cinegraph/imports/tmdb_importer.ex` - Used for tracking import progress
- `lib/cinegraph_web/live/import_dashboard_live.ex` - Displayed metrics to users

### Why It Was Removed
- The table appeared empty during inspection
- No active import jobs were running at the time
- Assumed to be replaced by "TMDbImporterV2" (which doesn't exist)

## Current Broken State

### Stubbed TMDbImporter Methods
```elixir
def get_progress do
  our_total = count_our_movies()
  
  # Returns hardcoded values - NOT actual data!
  %{
    tmdb_total_movies: 0,      # Always 0
    our_total_movies: our_total,
    movies_remaining: 0,        # Always 0
    completion_percentage: 100.0, # Always 100%
    last_page_processed: 0,     # Always 0
    last_full_sync: nil,        # Never tracked
    last_update_check: nil      # Never tracked
  }
end
```

### Dashboard Shows Incorrect Data
- TMDB Total: 0 (should be ~900,000+)
- Movies Remaining: 0 (incorrect)
- Completion: 100% (false positive)
- Last Full Sync: Never (lost data)

## Solution

### Option 1: Restore the Table (Recommended)
Create a new migration to restore the import_state table:

```elixir
defmodule Cinegraph.Repo.Migrations.RestoreImportStateTable do
  use Ecto.Migration

  def change do
    create table(:import_state, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :text
      add :updated_at, :utc_datetime_usec, null: false
    end
  end
end
```

Then remove the stub methods from TMDbImporter and restore original functionality.

### Option 2: Implement Alternative Tracking
If we want to avoid restoring the table:
1. Use Oban job metadata to track progress
2. Store state in a configuration file
3. Use a different persistence mechanism

However, this would require significant refactoring.

## Verification Steps
1. Check if ImportState module references work: `ImportState.tmdb_total_movies()`
2. Verify dashboard shows correct TMDB total after clicking "Update TMDB Total"
3. Confirm import resume works with correct last_page_processed
4. Ensure sync timestamps are tracked properly

## Lessons Learned
- Always verify table usage across the entire codebase before removal
- Check for runtime dependencies, not just compile-time
- Test import functionality after database changes
- Document the purpose of infrastructure tables

## Priority
**HIGH** - Core import functionality is broken, affecting data accuracy and user experience.