# Issue #157: Restore Modular Task Architecture for Oscar Import

## Executive Summary

The Oscar import functionality has been successfully migrated to use the new unified `festival_*` tables, but we lost the modular task architecture in the process. Previously, the system spawned separate workers for different stages (discovery, movie creation, enrichment). Now it runs as one long task, reducing visibility and scalability.

## Current State (After Our Changes)

### ✅ What's Working
1. **Data Import**: Successfully imports Oscar data into new `festival_*` tables
2. **Direct Scraping**: Fetches directly from OscarScraper, bypassing old tables
3. **IMDb Enhancement**: Enriches data with IMDb IDs
4. **Database Population**: Creates 80 nominations across 15 categories for 23 movies (2024 ceremony)
5. **Dashboard Display**: Correctly queries from unified tables

### ❌ What We Lost: Modularization

**Previous Architecture (main branch):**
```
OscarImportWorker 
  ↓ (queues)
OscarDiscoveryWorker (per ceremony)
  ↓ (queues multiple)
TMDbDetailsWorker (per movie)
  ↓ (queues)
OMDbEnrichmentWorker (per movie)
  ↓ (queues)
CollaborationWorker (for credits)
```

**Current Architecture (our changes):**
```
OscarImportWorker
  ↓ (direct call)
Cultural.import_oscar_year()
  ↓ (direct call)
UnifiedOscarImporter.import_from_scraped_data()
  ↓ (synchronous loop)
  Process all categories
  Process all nominees
  Create all movies
  Create all nominations
  (one long-running task)
```

## Why Modularization Matters

1. **Visibility**: Each task appears separately in the job queue
2. **Parallelization**: Multiple movies can be processed simultaneously
3. **Failure Isolation**: One failed movie doesn't stop the entire import
4. **Progress Tracking**: Can see exactly which stage is running
5. **Resource Management**: Better memory usage with smaller tasks
6. **Retry Logic**: Failed tasks can be retried individually

## The Original Modular Flow (Detailed)

### Stage 1: Import Worker
- **File**: `lib/cinegraph/workers/oscar_import_worker.ex`
- **Purpose**: Entry point from UI
- **Action**: Queues OscarDiscoveryWorker

### Stage 2: Discovery Worker
- **File**: `lib/cinegraph/workers/oscar_discovery_worker.ex` 
- **Purpose**: Process ceremony and identify movies
- **Actions**:
  - Fetches ceremony data
  - Enhances with IMDb IDs
  - For each nominee, checks if movie exists
  - Queues TMDbDetailsWorker for missing movies
  - Creates nomination records

### Stage 3: TMDb Details Worker
- **File**: `lib/cinegraph/workers/tmdb_details_worker.ex`
- **Purpose**: Create movie records from TMDb
- **Actions**:
  - Looks up movie by IMDb ID
  - Fetches full TMDb details
  - Creates movie record
  - Queues OMDbEnrichmentWorker
  - Queues CollaborationWorker for credits

### Stage 4: Enrichment Workers
- **OMDbEnrichmentWorker**: Adds OMDb ratings and metadata
- **CollaborationWorker**: Processes cast/crew relationships

## What Changed in Our Implementation

1. **Removed OscarDiscoveryWorker**: Now handled inline in UnifiedOscarImporter
2. **No TMDbDetailsWorker Queuing**: Movies created synchronously in import loop
3. **No Enrichment Queuing**: OMDb enrichment not triggered
4. **No Collaboration Processing**: Credits not being processed

## Data Verification

### Current Import Results (2024 Ceremony)
```sql
-- From our test import
SELECT COUNT(*) FROM festival_nominations WHERE ceremony_id = 1;
-- Result: 80 nominations

SELECT COUNT(DISTINCT category_id) FROM festival_nominations WHERE ceremony_id = 1;
-- Result: 15 categories

SELECT COUNT(DISTINCT movie_id) FROM festival_nominations WHERE ceremony_id = 1;
-- Result: 23 movies
```

This matches expected data, so the import logic is correct, just not modular.

## Restoration Plan

### Option 1: Full Restoration (Recommended)
Restore the complete worker chain but using new tables:

1. **Update OscarDiscoveryWorker**:
   - Work with `FestivalCeremony` instead of `OscarCeremony`
   - Create `FestivalNomination` records
   - Queue TMDbDetailsWorker as before

2. **Keep TMDbDetailsWorker As-Is**:
   - Already handles IMDb ID lookups
   - Already queues enrichment workers

3. **Update Import Flow**:
   ```elixir
   def import_oscar_year(year, options) do
     # Create ceremony in festival tables
     {:ok, ceremony} = create_festival_ceremony(year)
     
     # Queue discovery worker
     OscarDiscoveryWorker.new(%{
       "ceremony_id" => ceremony.id,
       "options" => options
     }) |> Oban.insert()
   end
   ```

### Option 2: Hybrid Approach
Keep synchronous ceremony processing but modularize movie creation:

1. Process ceremony and nominations synchronously
2. Queue TMDbDetailsWorker for each unique movie
3. Let existing worker chain handle enrichment

### Option 3: New Modular Architecture
Design new workers specifically for unified tables:

1. `FestivalImportWorker` - Entry point
2. `FestivalDiscoveryWorker` - Process ceremonies
3. `FestivalMovieWorker` - Create/update movies
4. Keep existing enrichment workers

## Implementation Steps

### Phase 1: Restore Discovery Worker
1. Copy `OscarDiscoveryWorker` to `FestivalDiscoveryWorker`
2. Update to use `festival_*` tables
3. Modify `Cultural.import_oscar_year` to queue this worker

### Phase 2: Update Worker Chain
1. Ensure TMDbDetailsWorker is queued for new movies
2. Verify enrichment workers are triggered
3. Test end-to-end flow

### Phase 3: Testing
1. Import single year and verify all workers spawn
2. Check job queue shows individual tasks
3. Verify parallel processing works
4. Test failure recovery

## Code Changes Required

### 1. `lib/cinegraph/cultural.ex`
```elixir
def import_oscar_year(year, options \\ []) do
  # Create ceremony
  {:ok, ceremony} = ensure_festival_ceremony(year)
  
  # Queue discovery worker (restore modular approach)
  job_args = %{
    "ceremony_id" => ceremony.id,
    "organization" => "AMPAS",
    "options" => Enum.into(options, %{})
  }
  
  case FestivalDiscoveryWorker.new(job_args) |> Oban.insert() do
    {:ok, job} ->
      {:ok, %{
        ceremony_id: ceremony.id,
        year: year,
        job_id: job.id,
        status: :queued
      }}
    {:error, reason} ->
      {:error, reason}
  end
end
```

### 2. Create `lib/cinegraph/workers/festival_discovery_worker.ex`
Based on OscarDiscoveryWorker but using unified tables.

### 3. Update `lib/cinegraph/festivals/unified_oscar_importer.ex`
Split the monolithic import into queueable chunks.

## Benefits of Restoration

1. **Visibility**: See individual tasks in Oban dashboard
2. **Parallelization**: Process multiple movies simultaneously  
3. **Failure Recovery**: Retry individual failed tasks
4. **Memory Efficiency**: Smaller task memory footprint
5. **Progress Tracking**: Clear visibility of import stages
6. **Scalability**: Can process larger ceremonies efficiently

## Timeline

- **Phase 1**: 2-3 hours (Create FestivalDiscoveryWorker)
- **Phase 2**: 1-2 hours (Update worker chain)
- **Phase 3**: 1-2 hours (Testing and verification)
- **Total**: 4-7 hours

## Success Criteria

1. ✅ Import spawns multiple worker tasks (not one long task)
2. ✅ Each movie creation is a separate job
3. ✅ Enrichment workers are queued automatically
4. ✅ Failed tasks can be retried individually
5. ✅ Oban dashboard shows task hierarchy
6. ✅ Data integrity maintained (same import results)

## Risk Assessment

- **Low Risk**: Using proven worker architecture
- **Medium Complexity**: Need to adapt existing workers
- **High Value**: Restores scalability and visibility

## Decision Required

Which approach should we take?
1. **Full Restoration** - Complete worker chain (recommended)
2. **Hybrid** - Partial modularization
3. **New Architecture** - Fresh design for unified tables

## References

- Original Issue #100: Festival Tables Migration
- Issue #152: Migration Strategy
- PR context: Moving from `oscar_*` to `festival_*` tables
- Current branch: `08-05-people`