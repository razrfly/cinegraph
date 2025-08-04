# Remove Redundant Import Tracking Tables

## Summary
We have two redundant tables (`failed_imdb_lookups` and `skipped_imports`) that duplicate functionality and should be removed. These tables store temporary debugging information that belongs in Oban job metadata.

## Background

### Current Tables

1. **`failed_imdb_lookups`** (added Aug 4, 2025)
   - Tracks IMDb IDs that couldn't be found in TMDb
   - Created by `TMDbDetailsWorker` when canonical import can't find a movie
   - Fields: imdb_id, title, year, source, reason, metadata, retry_count

2. **`skipped_imports`** (added Aug 3, 2025)
   - Tracks movies that didn't meet quality criteria for full import
   - Created by `TMDbDetailsWorker` during quality filtering
   - Fields: tmdb_id, title, reason, criteria_failed

## Problems

1. **Redundancy**: Both tables track "failed" imports with overlapping purposes
2. **Poor Design**: This is debug/monitoring data, not core application data
3. **Maintenance Burden**: Extra schemas, migrations, and code to maintain
4. **No Clear Value**: This data is only useful for debugging import jobs

## Usage Analysis

### `failed_imdb_lookups`
- Only written by: `TMDbDetailsWorker` line 360
- Only read by: Debug scripts (`check_canonical_import_status.exs`, `test_1001_movies_import.exs`)

### `skipped_imports`
- Only written by: `TMDbDetailsWorker` line 173
- Only read by: Test scripts (`test_quality_import.exs`, `test_strict_quality_import.exs`)

## Proposed Solution

### 1. Remove Both Tables
```elixir
# New migration
defmodule Cinegraph.Repo.Migrations.RemoveRedundantImportTables do
  use Ecto.Migration

  def change do
    drop table(:failed_imdb_lookups)
    drop table(:skipped_imports)
  end
end
```

### 2. Use Oban Job Meta Instead
Oban jobs already have a `meta` JSONB field perfect for this:

```elixir
# When creating the job
%{movie_id: movie_id, source: "canonical_import"}
|> Oban.Job.new(
  worker: "TMDbDetailsWorker",
  meta: %{
    "import_type" => "canonical",
    "source_list" => "1001_movies"
  }
)

# When job fails
def handle_error(job, error) do
  updated_meta = Map.merge(job.meta || %{}, %{
    "failure_reason" => "no_tmdb_match",
    "imdb_id" => imdb_id,
    "title" => title,
    "quality_criteria_failed" => criteria
  })
  
  # Oban automatically stores this in the job record
  {:error, updated_meta}
end
```

### 3. Query Failed Jobs
```elixir
# Find all failed canonical imports
from j in Oban.Job,
  where: j.worker == "Cinegraph.Workers.TMDbDetailsWorker",
  where: j.state == "discarded",
  where: fragment("? ->> 'failure_reason' = ?", j.meta, "no_tmdb_match")

# Find quality-filtered imports
from j in Oban.Job,
  where: j.worker == "Cinegraph.Workers.TMDbDetailsWorker",
  where: j.state == "completed",
  where: fragment("? ->> 'import_type' = ?", j.meta, "soft")
```

## Benefits

1. **Simpler Schema**: Remove 2 unnecessary tables
2. **Better Design**: Debug data stays with job execution context
3. **Existing Infrastructure**: Oban already handles job metadata, querying, and retention
4. **No Lost Functionality**: All the same information available via Oban Web or queries

## Migration Plan

1. Update `TMDbDetailsWorker` to use job meta instead of creating records
2. Deploy and verify new tracking works
3. Export any critical data from existing tables (if needed)
4. Remove tables and associated schemas
5. Update any debug scripts to query Oban jobs instead

## Alternative Approach

If we absolutely need persistent tracking beyond Oban's retention:

1. Create a single `import_audit_log` table with:
   - `import_type` (failed_lookup, quality_skip, etc.)
   - `details` JSONB field for all metadata
   - Proper indexes for common queries

But honestly, Oban job history should be sufficient for debugging import issues.