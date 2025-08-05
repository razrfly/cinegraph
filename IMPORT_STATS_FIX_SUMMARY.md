# Import Statistics Fix Summary

## Problem
The movie lists import statistics (`last_import_at`, `last_movie_count`, `last_import_status`, `total_imports`) were not being updated after imports completed, even though the import itself was successful.

## Root Causes
1. Import workers weren't calling the `MovieLists.update_import_stats` function
2. The UI wasn't refreshing the movie lists data after imports completed

## Solution Implemented

### 1. Updated CanonicalImportOrchestrator
- Added `update_import_started` to mark imports as "in_progress" when they begin
- Added `update_import_failed` to track failed imports with error reasons

### 2. Updated CanonicalPageWorker 
- Added `update_import_completed` to update statistics when the last page completes
- Enhanced error logging to track any update failures

### 3. Updated ImportDashboardLive
- Modified `load_data` to reload `all_movie_lists` on every refresh
- This ensures the UI shows updated statistics after imports complete

## Code Changes

### `/lib/cinegraph/workers/canonical_import_orchestrator.ex`
```elixir
# Added at start of import
update_import_started(list_key)

# Added helper functions
defp update_import_started(list_key) do
  case MovieLists.get_active_by_source_key(list_key) do
    nil -> :ok
    list -> MovieLists.update_import_stats(list, "in_progress", 0)
  end
end

defp update_import_failed(list_key, reason) do
  case MovieLists.get_active_by_source_key(list_key) do
    nil -> :ok
    list -> MovieLists.update_import_stats(list, "failed: #{reason}", 0)
  end
end
```

### `/lib/cinegraph/workers/canonical_page_worker.ex`
```elixir
# Added MovieLists alias
alias Cinegraph.Movies.MovieLists

# Modified check_completion to call update function
update_import_completed(list_key, count)

# Added helper function
defp update_import_completed(list_key, movie_count) do
  case MovieLists.get_active_by_source_key(list_key) do
    nil -> :ok
    list ->
      case MovieLists.update_import_stats(list, "success", movie_count) do
        {:ok, updated_list} ->
          Logger.info("Updated import stats for #{list_key}")
          :ok
        {:error, changeset} ->
          Logger.error("Failed to update import stats: #{inspect(changeset.errors)}")
          :error
      end
  end
end
```

### `/lib/cinegraph_web/live/import_dashboard_live.ex`
```elixir
# Modified load_data to refresh movie lists
defp load_data(socket) do
  # ... existing code ...
  socket
  |> assign(:progress, progress)
  |> assign(:stats, stats)
  |> assign(:canonical_stats, canonical_stats)
  |> assign(:oscar_stats, oscar_stats)
  |> assign(:queue_stats, queue_stats)
  |> assign(:import_rate, runtime_stats.movies_per_minute)
  |> assign(:all_movie_lists, MovieLists.list_all_movie_lists())  # Added
  |> assign(:canonical_lists, CanonicalImportOrchestrator.available_lists())  # Added
end
```

## Testing

Created test scripts to verify the fix:
- `test_import_stats.exs` - Tests import queueing
- `test_update_stats_directly.exs` - Tests direct stats update
- `verify_import_stats_fixed.exs` - Comprehensive verification

## Results

✅ Import statistics now correctly track:
- `last_import_at` - Timestamp of last import
- `last_movie_count` - Number of movies in the list
- `last_import_status` - "in_progress", "success", or "failed: reason"
- `total_imports` - Increments each time an import completes

✅ UI automatically refreshes to show updated statistics

## Future Improvements

1. Track more granular statistics (movies added vs updated)
2. Add import duration tracking
3. Store historical import data
4. Add email notifications for completed imports
5. Track per-page import progress in real-time