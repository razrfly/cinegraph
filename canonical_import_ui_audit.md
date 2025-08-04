# GitHub Issue: Add Canonical Lists and Oscar Imports to Import Dashboard UI

## Overview

We need to add UI controls to the import dashboard (`http://localhost:4001/imports`) for importing canonical movie lists from IMDb and Oscar ceremony data. This will provide a complete interface for all our import types alongside the existing TMDb import controls.

## Current State Audit

### What We Have Working

1. **Backend Infrastructure** ✅
   - **Canonical Lists Import**
     - `ImdbCanonicalScraper` - Fetches IMDb user lists page by page
     - `CanonicalImporter` - Processes movies following Oscar pattern
     - `TMDbDetailsWorker` - Creates missing movies with canonical marking
     - Mix task: `mix import_canonical --list 1001_movies`
   
   - **Oscar Import**
     - `OscarScraper` - Fetches ceremony data from oscars.org
     - `OscarImporter` - Processes nominees and winners
     - `TMDbDetailsWorker` - Creates missing movies with Oscar nominations
     - Mix task: `mix import_oscars --year 2024` or `--all`

2. **Data Model** ✅
   - Movies have `canonical_sources` JSONB field for multiple lists
   - Oscar ceremonies, categories, and nominations tables
   - Both systems use the same modular pattern

3. **Import Patterns** ✅
   - Both follow the same workflow:
     1. Fetch data from source
     2. For existing movies: Update with metadata
     3. For missing movies: Queue TMDbDetailsWorker job
     4. Worker creates movie and applies post-processing

### What's Missing - UI Integration

1. **No UI for Canonical Lists Import**
   - Need dropdown to select from available lists
   - Currently only accessible via mix task

2. **No UI for Oscar Import**  
   - Need controls to import specific years or all years
   - Currently only accessible via mix task

3. **No Progress Monitoring**
   - Need to show import status and progress
   - Need to display results (movies created/updated)

## Implementation Plan

### 1. Add Canonical Lists Import to UI

**UI Components Needed:**
```elixir
# In imports_live.html.heex
<div class="canonical-import-section">
  <h3>Import Canonical Movie Lists</h3>
  <form phx-submit="import_canonical_list">
    <select name="list_key" required>
      <option value="">Select a list...</option>
      <option value="1001_movies">1001 Movies You Must See Before You Die</option>
      <!-- Future lists will be added here -->
    </select>
    <button type="submit" class="btn-primary">
      Import/Update List
    </button>
  </form>
  
  <!-- Progress indicator -->
  <div :if={@canonical_import_running}>
    <.spinner /> Importing canonical list...
    <div>Progress: <%= @canonical_import_progress %></div>
  </div>
</div>
```

**Backend Handler:**
```elixir
# In imports_live.ex
def handle_event("import_canonical_list", %{"list_key" => list_key}, socket) do
  # Queue an Oban job to run the import
  %{
    "action" => "import_canonical_list",
    "list_key" => list_key
  }
  |> CanonicalImportWorker.new()
  |> Oban.insert()
  
  {:noreply, assign(socket, canonical_import_running: true)}
end
```

**New Worker:**
```elixir
defmodule Cinegraph.Workers.CanonicalImportWorker do
  use Oban.Worker, queue: :imports, max_attempts: 3
  
  @lists %{
    "1001_movies" => %{
      list_id: "ls024863935",
      source_key: "1001_movies", 
      name: "1001 Movies You Must See Before You Die",
      metadata: %{"edition" => "2024"}
    }
  }
  
  def perform(%{args: %{"list_key" => list_key}}) do
    list_config = @lists[list_key]
    
    Cinegraph.Cultural.CanonicalImporter.import_canonical_list(
      list_config.list_id,
      list_config.source_key,
      list_config.name,
      [create_movies: true],
      list_config.metadata
    )
  end
end
```

### 2. Add Oscar Import to UI

**UI Components Needed:**
```elixir
# In imports_live.html.heex
<div class="oscar-import-section">
  <h3>Import Academy Awards Data</h3>
  <form phx-submit="import_oscars">
    <select name="year_range" required>
      <option value="">Select years...</option>
      <option value="2024">2024 Only</option>
      <option value="2023">2023 Only</option>
      <option value="2020-2024">2020-2024</option>
      <option value="all">All Years (2016-2024)</option>
    </select>
    <button type="submit" class="btn-primary">
      Import Oscar Data
    </button>
  </form>
  
  <!-- Progress indicator -->
  <div :if={@oscar_import_running}>
    <.spinner /> Importing Oscar ceremonies...
    <div>Progress: <%= @oscar_import_progress %></div>
  </div>
</div>
```

**Backend Handler:**
```elixir
def handle_event("import_oscars", %{"year_range" => year_range}, socket) do
  # Queue job based on selection
  job_args = case year_range do
    "all" -> %{"action" => "import_all_years"}
    year when is_binary(year) and String.contains?(year, "-") ->
      [start_year, end_year] = String.split(year, "-")
      %{"action" => "import_range", "start_year" => start_year, "end_year" => end_year}
    year ->
      %{"action" => "import_single", "year" => String.to_integer(year)}
  end
  
  job_args
  |> OscarImportWorker.new()
  |> Oban.insert()
  
  {:noreply, assign(socket, oscar_import_running: true)}
end
```

### 3. Progress Monitoring

**Phoenix PubSub Integration:**
```elixir
# Workers publish progress updates
Phoenix.PubSub.broadcast(
  Cinegraph.PubSub,
  "import_progress",
  {:canonical_progress, %{
    list_key: "1001_movies",
    current_page: 3,
    total_pages: 6,
    movies_processed: 750,
    movies_created: 45,
    movies_updated: 705
  }}
)

# LiveView subscribes and updates UI
def mount(_params, _session, socket) do
  Phoenix.PubSub.subscribe(Cinegraph.PubSub, "import_progress")
  {:ok, socket}
end

def handle_info({:canonical_progress, progress}, socket) do
  {:noreply, assign(socket, canonical_import_progress: format_progress(progress))}
end
```

## Testing Plan

### 1. Canonical Lists Import Test
1. Navigate to `/imports`
2. Select "1001 Movies You Must See Before You Die" from dropdown
3. Click "Import/Update List"
4. Verify:
   - Oban job is created
   - Progress updates appear
   - Movies are created/updated
   - Canonical sources are set correctly

### 2. Oscar Import Test
1. Navigate to `/imports`
2. Select "2024 Only" from Oscar dropdown
3. Click "Import Oscar Data"
4. Verify:
   - Oban job is created
   - Ceremony data is fetched
   - Nominations are created
   - Missing movies are queued

### 3. Database Verification
```sql
-- Check canonical movies
SELECT COUNT(*) FROM movies WHERE canonical_sources ? '1001_movies';

-- Check Oscar nominations
SELECT COUNT(*) FROM oscar_nominations WHERE ceremony_id IN (
  SELECT id FROM oscar_ceremonies WHERE year = 2024
);

-- Check Oban jobs
SELECT worker, state, COUNT(*) FROM oban_jobs 
GROUP BY worker, state 
ORDER BY worker;
```

## UI Layout Mockup

```
Import Dashboard
================

TMDb Import
-----------
[Existing TMDb controls]

Canonical Movie Lists                    Academy Awards
---------------------                    ---------------
Select a list:                          Select years:
[1001 Movies You Must...  v]            [All Years (2016-2024) v]
[Import/Update List]                    [Import Oscar Data]

Progress: Importing page 3/6...         Progress: Importing 2024...
```

## Success Criteria

1. **UI Integration** ✅
   - Both import types visible on dashboard
   - Controls are intuitive and match existing patterns
   - Progress feedback during imports

2. **Functionality** ✅
   - Clicking buttons creates appropriate Oban jobs
   - Imports run without timeouts
   - Progress updates in real-time
   - Error handling for failures

3. **Data Integrity** ✅
   - Canonical sources properly set on movies
   - Oscar nominations correctly linked
   - No duplicate imports
   - Existing data updated, not overwritten

## Future Enhancements

1. **More Canonical Lists**
   - Add Sight & Sound, Criterion Collection, AFI lists
   - Make list configuration data-driven
   - Allow custom IMDb list URLs

2. **Import History**
   - Track when imports were last run
   - Show statistics from previous imports
   - Allow re-running failed imports

3. **Selective Import**
   - Choose specific Oscar categories
   - Import only missing movies
   - Dry-run mode to preview changes

## Tasks

- [ ] Create CanonicalImportWorker
- [ ] Create OscarImportWorker  
- [ ] Add canonical list dropdown to imports UI
- [ ] Add Oscar import controls to imports UI
- [ ] Implement progress monitoring via PubSub
- [ ] Add loading states and progress indicators
- [ ] Test full import flow for both types
- [ ] Verify data integrity after imports
- [ ] Update documentation

## Related Issues

- Closes #88 - Implement JSONB canonical sources field
- Prepares for #89 - Import additional IMDb lists