# Canonical Movie Import System Audit

## Executive Summary

The canonical movie import system (for importing lists like "1001 Movies You Must See Before You Die") is not following the established patterns used by the Oscar import system. This is causing issues with pagination, movie processing, and Oban job queuing.

## Current State

### What's Working ✅

1. **Database Schema**
   - JSONB `canonical_sources` field correctly stores multiple sources with metadata
   - Proper indexes for query performance
   - Helper functions for checking canonical status

2. **Scraping Infrastructure**
   - Successfully fetches HTML via Zyte API
   - Correctly handles different HTML structures on different pages
   - Pagination detection works (finds all 6 pages with 1,260 movies)

3. **First Page Import**
   - First 250 movies are correctly marked as canonical
   - Updates existing movies with canonical metadata

### What's Not Working ❌

1. **Processing Flow**
   - Scraper fetches ALL pages during parsing phase (causing timeouts)
   - No separation between scraping and processing
   - No Oban jobs being created for missing movies
   - No modular processing pattern

2. **Pattern Deviations**
   - Not following the Oscar import's modular approach
   - Missing the TMDbDetailsWorker integration for movie creation
   - No post-processing hooks for canonical marking

## Pattern Analysis: Oscar Import vs Canonical Import

### Oscar Import Pattern (CORRECT) ✅

```elixir
# 1. Entry Point (mix task or Cultural.import_oscar_year)
Cultural.import_oscar_year(2024)
  ↓
# 2. Scraper fetches data
OscarScraper.fetch_ceremony(2024)
  ↓
# 3. Importer processes each nominee
OscarImporter.import_ceremony(ceremony)
  ↓
# 4. For each movie:
if movie_exists?(imdb_id) do
  # Update with Oscar data
  update_movie_oscar_data(movie, nominee_data)
else
  # Queue TMDbDetailsWorker with metadata
  TMDbDetailsWorker.new(%{
    "imdb_id" => imdb_id,
    "source" => "oscar_import",
    "metadata" => %{
      "ceremony_year" => 2024,
      "category" => "Best Picture",
      ...
    }
  })
end
  ↓
# 5. TMDbDetailsWorker creates movie and calls post-processing
handle_post_creation_tasks(tmdb_id, args)
  ↓
# 6. Post-processing creates Oscar nomination
create_oscar_nomination(tmdb_id, metadata)
```

### Canonical Import Pattern (CURRENT - BROKEN) ❌

```elixir
# 1. Entry Point
CanonicalImporter.import_1001_movies()
  ↓
# 2. Scraper fetches AND processes ALL pages
ImdbCanonicalScraper.scrape_and_parse_list()  # ← This fetches all 6 pages!
  ↓
# 3. Returns all 1,260 movies at once
# 4. Tries to process all movies synchronously
# 5. No Oban jobs created
# 6. No post-processing hooks
```

## Root Cause Analysis

1. **Mixing Concerns**: The scraper is doing both fetching AND processing
2. **Wrong Function**: Using `scrape_and_parse_list` which includes pagination instead of a simple single-page fetch
3. **Missing Integration**: Not using TMDbDetailsWorker for movie creation
4. **No Batch Processing**: Trying to process 1,260 movies synchronously

## Proposed Solution

### 1. Separate Scraping from Processing

```elixir
# Add to ImdbCanonicalScraper
def fetch_single_page(list_id, page \\ 1) do
  url = build_imdb_list_url(list_id, page)
  
  with {:ok, html} <- fetch_html(url),
       {:ok, movies} <- parse_imdb_list_html(html) do
    {:ok, movies}
  end
end

def get_total_pages(list_id) do
  # Fetch first page and determine total pages
end
```

### 2. Implement Batch Processing Pattern

```elixir
# In CanonicalImporter
def import_canonical_list(list_id, source_key, list_name, options \\ []) do
  # Option 1: Process page by page
  total_pages = ImdbCanonicalScraper.get_total_pages(list_id)
  
  results = Enum.map(1..total_pages, fn page ->
    with {:ok, movies} <- ImdbCanonicalScraper.fetch_single_page(list_id, page) do
      process_page(movies, source_key, list_name, options)
    end
  end)
  
  # Option 2: Use Oban for page processing
  Enum.each(1..total_pages, fn page ->
    CanonicalPageWorker.new(%{
      "list_id" => list_id,
      "page" => page,
      "source_key" => source_key,
      "list_name" => list_name
    })
    |> Oban.insert()
  end)
end
```

### 3. Follow TMDbDetailsWorker Pattern

```elixir
defp process_canonical_movie(movie_data, source_key, list_name, metadata) do
  case Repo.get_by(Movie, imdb_id: movie_data.imdb_id) do
    nil ->
      # Queue for creation with canonical metadata
      TMDbDetailsWorker.new(%{
        "imdb_id" => movie_data.imdb_id,
        "source" => "canonical_import",
        "canonical_source" => %{
          "source_key" => source_key,
          "metadata" => metadata
        }
      })
      |> Oban.insert()
      
    existing_movie ->
      # Update canonical sources directly
      Movies.update_canonical_sources(existing_movie, source_key, metadata)
  end
end
```

### 4. Add Mix Task

```elixir
defmodule Mix.Tasks.ImportCanonical do
  use Mix.Task
  
  def run(args) do
    Mix.Task.run("app.start")
    
    case parse_args(args) do
      {:ok, "1001_movies"} ->
        Cinegraph.Cultural.import_1001_movies()
        
      {:ok, source_key, list_id, list_name} ->
        Cinegraph.Cultural.import_canonical_list(list_id, source_key, list_name)
        
      :error ->
        show_usage()
    end
  end
end
```

## Implementation Steps

1. **Fix Scraper** (Priority: HIGH)
   - Add `fetch_single_page` method
   - Remove pagination from `scrape_and_parse_list`
   - Add `get_total_pages` helper

2. **Update Importer** (Priority: HIGH)
   - Use page-by-page processing
   - Integrate with TMDbDetailsWorker
   - Add progress tracking

3. **Create Workers** (Priority: MEDIUM)
   - CanonicalPageWorker for async page processing
   - Reuse existing TMDbDetailsWorker with canonical metadata

4. **Add Mix Task** (Priority: LOW)
   - Similar to import_oscars task
   - Support for different canonical lists

5. **Testing** (Priority: HIGH)
   - Test single page import
   - Test movie creation via TMDbDetailsWorker
   - Test canonical marking post-processing

## Benefits of Alignment

1. **Consistency**: All imports follow the same pattern
2. **Scalability**: Can handle large lists without timeouts
3. **Modularity**: Reuses existing workers and patterns
4. **Reliability**: Async processing with retries
5. **Monitoring**: Can track progress via Oban dashboard

## Acceptance Criteria

- [ ] Canonical import uses same pattern as Oscar import
- [ ] No timeouts when importing 1,260 movies
- [ ] Missing movies are queued as TMDbDetailsWorker jobs
- [ ] Existing movies are updated with canonical metadata
- [ ] Progress can be monitored via Oban
- [ ] Mix task available for easy importing
- [ ] Can import other canonical lists (Sight & Sound, AFI, etc)

## Notes

The current implementation works for the first page (250 movies) but fails when trying to import all pages due to:
1. Synchronous processing of 1,260+ movies
2. Fetching all pages during the parsing phase
3. No integration with the existing job queue system

By aligning with the Oscar import pattern, we get a battle-tested approach that handles large datasets reliably.