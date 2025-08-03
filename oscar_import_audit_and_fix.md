# Oscar Import System Audit & Fix Plan

## Current Issues

### 1. EnrichMovieWorker Jobs Not Processing
**Problem**: Jobs are being enqueued to `movie_enrichment` queue but not processing.
**Root Cause**: The `movie_enrichment` queue is not configured in `config/config.exs`.

### 2. Sequential Processing Instead of Parallel
**Problem**: `import_oscar_years` processes years sequentially instead of using job system.
**Impact**: Slow imports, no parallelization, no resilience to failures.

### 3. Missing Implementation from Issue Requirements

#### Issue #74 (Oscar Data Import Audit)
- ✅ Implemented: Basic data capture, IMDb enhancement
- ❌ Missing: Detailed ceremony metadata, validation, quality metrics

#### Issue #75 (Minimal Oscar Database)
- ✅ Implemented: oscar_categories, oscar_nominations tables
- ✅ Implemented: Person tracking for actor/director categories only
- ✅ Implemented: Database views for quick stats

#### Issue #76 (Oscar Import Mix Task)
- ✅ Implemented: Mix task with year/range/all options
- ❌ Missing: Job-based parallel processing
- ❌ Missing: Proper error handling and recovery

## Fix Plan

### 1. Fix Oban Queue Configuration

Add `movie_enrichment` queue to `config/config.exs`:

```elixir
config :cinegraph, Oban,
  repo: Cinegraph.Repo,
  queues: [
    tmdb_discovery: 10,
    tmdb_details: 20,
    omdb_enrichment: 5,
    media_processing: 10,
    collaboration: 5,
    movie_enrichment: 10  # Add this queue
  ],
```

### 2. Create Oscar Import Worker

Create `lib/cinegraph/workers/oscar_import_worker.ex`:

```elixir
defmodule Cinegraph.Workers.OscarImportWorker do
  use Oban.Worker,
    queue: :oscar_imports,
    max_attempts: 3
  
  def perform(%Oban.Job{args: %{"year" => year, "options" => options}}) do
    Cinegraph.Cultural.import_oscar_year(year, options)
  end
end
```

### 3. Update import_oscar_years to Use Jobs

```elixir
def import_oscar_years(start_year..end_year, options \\ []) do
  jobs = start_year..end_year
    |> Enum.map(fn year ->
      %{year: year, options: options}
      |> Cinegraph.Workers.OscarImportWorker.new()
    end)
  
  # Insert all jobs at once
  Oban.insert_all(jobs)
  
  # Return job references for monitoring
  {:ok, %{
    years: start_year..end_year,
    job_count: length(jobs),
    status: :queued
  }}
end
```

### 4. Add Progress Tracking

Create `lib/cinegraph/imports/oscar_import_progress.ex`:

```elixir
defmodule Cinegraph.Imports.OscarImportProgress do
  use Ecto.Schema
  import Ecto.Query
  
  schema "oscar_import_progress" do
    field :year, :integer
    field :status, :string
    field :movies_created, :integer, default: 0
    field :movies_updated, :integer, default: 0
    field :movies_skipped, :integer, default: 0
    field :error_message, :string
    timestamps()
  end
end
```

### 5. Update OscarImporter for Better Error Handling

- Add transaction support for atomic operations
- Better error messages and recovery
- Progress updates during import

### 6. Add Import Status Query

```elixir
def get_oscar_import_status do
  # Check running jobs
  running = Oban.Job
    |> where([j], j.worker == "Cinegraph.Workers.OscarImportWorker")
    |> where([j], j.state in ["available", "executing"])
    |> Repo.aggregate(:count)
  
  # Get progress
  progress = Repo.all(OscarImportProgress)
    |> Enum.group_by(& &1.status)
  
  %{
    running_jobs: running,
    completed: length(progress["completed"] || []),
    failed: length(progress["failed"] || []),
    progress: progress
  }
end
```

## Implementation Steps

1. **Fix Oban Configuration** (Immediate)
   - Add movie_enrichment queue
   - Add oscar_imports queue
   - Restart application

2. **Create Workers** (Phase 1)
   - OscarImportWorker for year-based imports
   - Update import methods to use jobs

3. **Add Progress Tracking** (Phase 2)
   - Create progress table
   - Update importer to track progress
   - Add status queries

4. **Improve Error Handling** (Phase 3)
   - Add transaction support
   - Better error recovery
   - Retry logic for failed movies

## Testing Plan

1. Test single year import with jobs
2. Test parallel year imports
3. Test error recovery (API failures)
4. Test progress tracking
5. Test idempotency (re-running same year)

## Benefits

1. **Parallel Processing**: Multiple years import simultaneously
2. **Resilience**: Failed years can be retried independently
3. **Progress Tracking**: Real-time visibility into import status
4. **Better UX**: Non-blocking imports with progress updates
5. **Scalability**: Can handle large date ranges efficiently