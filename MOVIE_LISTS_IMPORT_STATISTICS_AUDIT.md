# Audit: Movie Lists Import Statistics Not Being Updated

## Issue Summary

The movie lists import statistics tracking is not functioning correctly. All database movie lists show:
- `last_import_at`: Never (NULL)
- `last_movie_count`: 0 
- `last_import_status`: None (NULL)
- `total_imports`: 0

This indicates that the `MovieLists.update_import_stats/3` function is not being called during import operations.

## Database Schema Analysis

### Implemented Columns in `movie_lists` Table

✅ **Currently Used Columns:**
- `source_key` - Used as primary identifier
- `name` - Display name in UI
- `description` - Optional description text
- `source_type` - Always "imdb" currently
- `source_url` - Source URL for scraping
- `source_id` - Extracted list ID (e.g., "ls024863935")
- `category` - Classification (awards, critics, curated, registry)
- `active` - Enable/disable toggle
- `tracks_awards` - Boolean flag for award tracking
- `award_types` - Array of award types
- `metadata` - JSON metadata storage

❌ **Unused/Not Updated Columns:**
- `last_import_at` - Should track when list was last imported
- `last_import_status` - Should track import result ("success", "error", "partial")
- `last_movie_count` - Should track number of movies found in last import
- `total_imports` - Should increment with each import attempt

## Import Flow Analysis

### Current Import Flow

1. **UI Trigger**: User clicks import button in `/import` dashboard
2. **Worker Dispatch**: `CanonicalImportWorker.perform/1` is called
3. **List Retrieval**: Uses `CanonicalLists.get/1` (hardcoded fallback)
4. **Import Execution**: `CanonicalImporter.import_canonical_list/5` processes the list
5. **Result Broadcasting**: Progress is broadcast to UI via PubSub
6. **Completion**: Worker completes, UI shows success message

### Missing Integration Points

The import flow **never** calls `MovieLists.update_import_stats/3`. The function exists but is not integrated into the actual import process.

## Root Cause Analysis

### Problem 1: Wrong List Source
```elixir
# In CanonicalImportWorker.perform/1
case CanonicalLists.get(list_key) do  # ❌ Uses hardcoded lists
```

Should use:
```elixir
case MovieLists.get_active_by_source_key(list_key) do  # ✅ Uses database lists
```

### Problem 2: Missing Statistics Update
The worker completes successfully but never updates the database list statistics:

```elixir
# Current flow - missing update
result = CanonicalImporter.import_canonical_list(...)
broadcast_progress(list_key, :completed, result)
:ok  # ❌ No statistics update
```

Should be:
```elixir
# Fixed flow - with statistics update
result = CanonicalImporter.import_canonical_list(...)

# Update database list statistics
case MovieLists.get_active_by_source_key(list_key) do
  %MovieList{} = movie_list ->
    status = if result.error, do: "error", else: "success"
    MovieLists.update_import_stats(movie_list, status, result.total_movies)
  nil ->
    Logger.warn("Movie list not found in database: #{list_key}")
end

broadcast_progress(list_key, :completed, result)
:ok
```

### Problem 3: Inconsistent List Management
The system has two list sources:
1. **Database lists** (`MovieLists`) - Used by UI for display
2. **Hardcoded lists** (`CanonicalLists`) - Used by import worker

This creates a disconnect where UI shows database lists but imports use hardcoded configurations.

## Issue #121 Implementation Status

From `ISSUE_121_COMPLETION_SUMMARY.md`, the following were implemented:

✅ **Completed Features:**
- Database schema with import tracking fields
- CRUD UI for list management
- Backward compatibility with hardcoded lists
- Seeding system for migrating hardcoded lists
- Import system integration (claimed but not working correctly)

❌ **Not Fully Implemented:**
- **Import statistics tracking** - Core functionality missing
- **Proper database integration** - Worker still uses hardcoded lists
- **Statistics display** - UI shows 0 values because stats aren't updated

## Proposed Solutions

### Solution 1: Fix Import Worker Integration

**File:** `/lib/cinegraph/workers/canonical_import_worker.ex`

```elixir
defmodule Cinegraph.Workers.CanonicalImportWorker do
  # ... existing code ...
  
  alias Cinegraph.Movies.{MovieLists, MovieList}  # Add this
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "import_canonical_list", "list_key" => list_key}}) do
    Logger.info("Starting canonical import for #{list_key}")
    
    # Use database list first, fallback to hardcoded
    {movie_list, list_config} = case MovieLists.get_active_by_source_key(list_key) do
      %MovieList{} = ml ->
        config = MovieList.to_config(ml)
        {ml, config}
      nil ->
        # Fallback during transition period
        case CanonicalLists.get(list_key) do
          {:ok, config} -> {nil, config}
          {:error, reason} -> 
            Logger.error("List not found: #{list_key}")
            return {:error, reason}
        end
    end
    
    # Broadcast start
    broadcast_progress(list_key, :started, %{
      list_name: list_config.name,
      status: "Starting import..."
    })
    
    # Perform import
    result = CanonicalImporter.import_canonical_list(
      list_config.list_id,
      list_config.source_key,
      list_config.name,
      [create_movies: true],
      list_config.metadata
    )
    
    # Update database statistics if we have a database list
    if movie_list do
      import_status = cond do
        result[:error] -> "error"
        result.movies_created + result.movies_queued > 0 -> "success"
        true -> "partial"
      end
      
      case MovieLists.update_import_stats(movie_list, import_status, result.total_movies) do
        {:ok, _updated_list} ->
          Logger.info("Updated import statistics for #{list_key}")
        {:error, changeset} ->
          Logger.error("Failed to update import statistics: #{inspect(changeset.errors)}")
      end
    end
    
    # Broadcast completion
    broadcast_progress(list_key, :completed, %{
      list_name: list_config.name,
      movies_created: result.movies_created,
      movies_updated: result.movies_updated,
      movies_queued: result.movies_queued,
      movies_skipped: result.movies_skipped,
      total_movies: result.total_movies
    })
    
    Logger.info("Completed canonical import for #{list_key}: #{result.total_movies} movies processed")
    :ok
  end
end
```

### Solution 2: Add Statistics Display to UI

**File:** `/lib/cinegraph_web/live/import_dashboard_live.html.heex`

The UI template already shows statistics correctly:
```html
<%= format_number(list.last_movie_count) %>
<%= if list.last_import_at do %>
  <%= Calendar.strftime(list.last_import_at, "%b %d, %Y") %>
<% else %>
  <span class="text-gray-500">Never</span>
<% end %>
```

This will automatically work once statistics are being updated.

### Solution 3: Fix Available Lists Function

**File:** `/lib/cinegraph/workers/canonical_import_worker.ex`

```elixir
# Replace hardcoded function
def available_lists do
  # Use database lists with fallback to hardcoded
  db_lists = MovieLists.all_as_config()
  hardcoded_lists = CanonicalLists.all()
  
  # Merge with database taking precedence
  Map.merge(hardcoded_lists, db_lists)
end
```

### Solution 4: Add Validation and Error Handling

Enhance `MovieLists.update_import_stats/3` with better validation:

```elixir
def update_import_stats(%MovieList{} = movie_list, status, movie_count) do
  # Validate status values
  valid_statuses = ["success", "error", "partial", "cancelled"]
  status = if status in valid_statuses, do: status, else: "error"
  
  # Ensure movie_count is non-negative
  movie_count = max(movie_count || 0, 0)
  
  attrs = %{
    last_import_at: DateTime.utc_now(),
    last_import_status: status,
    last_movie_count: movie_count,
    total_imports: movie_list.total_imports + 1
  }
  
  movie_list
  |> MovieList.import_stats_changeset(attrs)
  |> Repo.update()
end
```

## Testing Plan

### Manual Testing Steps

1. **Check Current State:**
   ```bash
   mix run -e "
   lists = Cinegraph.Movies.MovieLists.list_all_movie_lists()
   Enum.each(lists, fn l -> 
     IO.puts \"#{l.source_key}: imports=#{l.total_imports}, last_count=#{l.last_movie_count}\"
   end)
   "
   ```

2. **Trigger Import:**
   - Go to `/import` dashboard
   - Click import button for any list
   - Wait for completion

3. **Verify Statistics Updated:**
   - Re-run step 1 query
   - Check UI shows correct values
   - Verify `last_import_at` is recent timestamp

### Automated Tests

Add to test suite:

```elixir
defmodule Cinegraph.Workers.CanonicalImportWorkerTest do
  test "updates import statistics after successful import" do
    # Create test movie list
    {:ok, movie_list} = MovieLists.create_movie_list(%{
      source_key: "test_list",
      name: "Test List",
      source_url: "https://www.imdb.com/list/ls123456/",
      source_type: "imdb"
    })
    
    # Mock successful import
    # ... test setup ...
    
    # Perform import
    {:ok, _job} = perform_job(CanonicalImportWorker, %{
      "action" => "import_canonical_list",
      "list_key" => "test_list"
    })
    
    # Verify statistics updated
    updated_list = MovieLists.get_movie_list!(movie_list.id)
    assert updated_list.total_imports == 1
    assert updated_list.last_import_status == "success"
    assert updated_list.last_movie_count > 0
    assert updated_list.last_import_at != nil
  end
end
```

## Expected Outcomes

After implementing these fixes:

1. **Statistics Tracking**: All import operations will update database statistics
2. **UI Consistency**: Dashboard will show accurate import history and movie counts
3. **System Integration**: Database lists and import system will be properly connected
4. **Error Handling**: Failed imports will be tracked with appropriate status
5. **Historical Data**: Users can see when lists were last updated and how many movies were found

## Priority Assessment

**Priority: HIGH** - This affects core functionality that was supposed to be implemented in Issue #121. The feature appears complete in the UI but is fundamentally broken due to missing integration between the import system and database statistics tracking.

## Implementation Effort

- **Time Estimate**: 2-4 hours
- **Risk Level**: Low (isolated changes, existing tests provide safety net)
- **Testing Required**: Manual verification + automated tests
- **Breaking Changes**: None (purely additive functionality)