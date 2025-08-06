# Modular IMDb Events Architecture: Extending Lists System with Code Reuse

## Executive Summary

This document outlines how to extend our existing modular list import system to support IMDb Events while maximizing code reuse and maintaining our proven Oban job architecture. The solution leverages 90%+ of existing patterns while adding minimal new components.

## Current Architecture Analysis

### ✅ What We Have (Proven & Working)

#### 1. **Modular Oban Job Pipeline**
```
CanonicalImportOrchestrator → CanonicalPageWorker → TMDbDetailsWorker
```
- ✅ Database-driven configuration (`movie_lists` table)
- ✅ Progress tracking and error recovery
- ✅ Parallel processing with unique constraints
- ✅ Completion orchestration and statistics

#### 2. **Flexible Scraper Foundation**
```elixir
# ImdbCanonicalScraper pattern:
fetch_single_page(list_id, page, tracks_awards) 
  → parse_imdb_list_html(html, config, page)
  → process_canonical_movies(movies, config)
```
- ✅ Configurable HTML parsing
- ✅ Award detection via `tracks_awards` flag
- ✅ Modular data extraction
- ✅ Error handling and retries

#### 3. **Database Configuration System**
```sql
movie_lists table:
- source_key (unique identifier)
- source_type ("imdb") 
- source_id ("ls527026601")
- tracks_awards (boolean)
- metadata (JSONB for flexibility)
```

#### 4. **Festival Infrastructure**
```
festival_organizations → festival_ceremonies → festival_nominations
```
- ✅ Oscar imports working via `FestivalDiscoveryWorker`
- ✅ Structured award data storage
- ✅ Organization management

## Proposed Extension: IMDb Events Support

### Core Principle: **Extend, Don't Replace**

We'll add IMDb Events as a new `source_type` alongside existing lists, reusing 90% of current code.

### 1. Database Configuration Extension

#### Option A: Extend `movie_lists` table (RECOMMENDED)
```sql
-- Add new source_type values
UPDATE movie_lists SET source_type = 'imdb_event' WHERE source_id LIKE 'ev%';

-- Example configurations:
INSERT INTO movie_lists VALUES (
  'cannes_2024', 'Cannes Film Festival 2024', 'imdb_event', 
  'https://www.imdb.com/event/ev0000147/2024/1/', 'ev0000147',
  'awards', true, -- tracks_awards
  '{"year": 2024, "organization": "cannes", "ceremony_type": "competition"}'
);
```

**Benefits:**
- ✅ Reuse entire existing pipeline
- ✅ Same dashboard, same workers, same monitoring
- ✅ Zero breaking changes
- ✅ Gradual migration from lists to events

#### Option B: Create `festival_events` table
```sql
CREATE TABLE festival_events (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER REFERENCES festival_organizations(id),
  imdb_event_id VARCHAR(20) UNIQUE, -- ev0000147
  year INTEGER,
  event_url TEXT,
  source_type VARCHAR(20) DEFAULT 'imdb_event',
  metadata JSONB DEFAULT '{}',
  active BOOLEAN DEFAULT true,
  last_import_at TIMESTAMP,
  last_import_status VARCHAR(50),
  timestamps()
);
```

**Trade-offs:**
- ➕ Cleaner separation of concerns
- ➖ Requires new workers and pipeline
- ➖ More complex configuration management

**RECOMMENDATION: Start with Option A** for fastest implementation with maximum code reuse.

### 2. Modular Scraper Extension

#### Reuse Pattern: `ImdbCanonicalScraper` → `ImdbEventScraper`

```elixir
defmodule Cinegraph.Scrapers.ImdbEventScraper do
  @moduledoc """
  Scraper for IMDb Event pages (ev* format).
  Reuses 80% of ImdbCanonicalScraper patterns.
  """
  
  # REUSE: Same HTTP handling, retry logic, error patterns
  use ImdbCanonicalScraper, :http_client
  
  def fetch_event_page(event_id, year, page \\ 1) do
    url = build_event_url(event_id, year, page)
    
    # REUSE: Same fetch_html/1 function
    case fetch_html(url) do
      {:ok, html} -> parse_event_html(html, event_id, year, page)
      error -> error
    end
  end
  
  # NEW: Event-specific HTML parsing (different selectors)
  defp parse_event_html(html, event_id, year, page) do
    document = Floki.parse_document!(html)
    
    # Event pages have different structure than lists:
    # - Categories with nominees/winners
    # - Structured award data
    # - Different pagination
    
    categories = extract_event_categories(document)
    
    # Convert to similar format as list movies for pipeline compatibility
    movies = categories
    |> Enum.flat_map(&extract_movies_from_category(&1, event_id, year))
    |> add_position_data(page)
    
    {:ok, movies}
  end
  
  # REUSE: Same movie processing pipeline
  def process_event_movies(movies, event_config) do
    # This can call the same process_canonical_movies/2
    # with event-specific metadata
    ImdbCanonicalScraper.process_canonical_movies(movies, event_config)
  end
end
```

### 3. Worker Pipeline Extension

#### Reuse Existing Workers with Source Type Detection

```elixir
# In CanonicalImportOrchestrator
def perform(%Oban.Job{args: %{"action" => "orchestrate_import", "list_key" => list_key}}) do
  with {:ok, config} <- get_list_config(list_key) do
    case config.source_type do
      "imdb" -> orchestrate_list_import(config)      # EXISTING
      "imdb_event" -> orchestrate_event_import(config) # NEW
    end
  end
end

# NEW: Event orchestration (similar pattern)
defp orchestrate_event_import(config) do
  # Get total pages from event structure
  case ImdbEventScraper.get_event_page_count(config.source_id, config.metadata["year"]) do
    {:ok, total_pages} ->
      # Queue same CanonicalPageWorker but with event configuration
      jobs = Enum.map(1..total_pages, fn page ->
        %{
          "action" => "import_page",
          "list_key" => config.source_key,
          "source_type" => "imdb_event",    # NEW: Source type detection
          "event_id" => config.source_id,
          "year" => config.metadata["year"],
          "page" => page,
          # ... rest same as list jobs
        }
        |> CanonicalPageWorker.new()  # REUSE: Same worker!
      end)
      
      Oban.insert_all(jobs)
  end
end
```

#### Extend CanonicalPageWorker for Event Support

```elixir
# In CanonicalPageWorker.perform/1
def perform(%Oban.Job{args: args}) do
  case args["source_type"] do
    "imdb" -> process_list_page(args)      # EXISTING
    "imdb_event" -> process_event_page(args) # NEW
    _ -> process_list_page(args)           # FALLBACK
  end
end

# NEW: Event page processing
defp process_event_page(args) do
  %{"event_id" => event_id, "year" => year, "page" => page} = args
  
  # Use new scraper but same processing pipeline
  case ImdbEventScraper.fetch_event_page(event_id, year, page) do
    {:ok, movies} ->
      # REUSE: Same movie processing logic
      results = Enum.map(movies, &process_canonical_movie(&1, args))
      # ... rest identical to process_list_page
  end
end
```

### 4. Festival Configuration Management

#### Database-Driven Event Mapping

Instead of hardcoding event IDs, store them in `movie_lists` or new table:

```elixir
# In database seed or migration:
festival_events = [
  %{
    source_key: "cannes_2024",
    name: "Cannes Film Festival 2024",
    source_type: "imdb_event",
    source_id: "ev0000147", 
    metadata: %{
      "year" => 2024,
      "organization_abbreviation" => "CANNES",
      "ceremony_type" => "competition",
      "categories" => ["Palme d'Or", "Grand Prix", "Best Director", "etc."]
    }
  },
  %{
    source_key: "golden_globes_2024",
    name: "81st Golden Globe Awards",
    source_type: "imdb_event", 
    source_id: "ev0000292",
    metadata: %{
      "year" => 2024,
      "organization_abbreviation" => "HFPA",
      "ceremony_number" => 81
    }
  }
]

# Auto-create festival organizations
Enum.each(festival_events, &create_festival_organization_from_config/1)
```

### 5. Data Flow Integration

#### Route Events to Festival Tables

```elixir
defp process_canonical_movie(movie_data, config) do
  case config["source_type"] do
    "imdb_event" ->
      # Route to festival system
      process_festival_movie(movie_data, config)
    
    "imdb" when config["tracks_awards"] ->
      # Route to canonical_sources (existing)
      process_award_list_movie(movie_data, config)
    
    "imdb" ->
      # Route to canonical_sources (existing)
      process_regular_list_movie(movie_data, config)
  end
end

defp process_festival_movie(movie_data, config) do
  # NEW: Create/update festival nominations instead of canonical_sources
  organization = get_festival_organization(config["metadata"]["organization_abbreviation"])
  ceremony = get_or_create_ceremony(organization, config)
  
  # Create nominations for each category/award
  movie_data.awards
  |> Enum.each(&create_festival_nomination(&1, ceremony, movie_data))
end
```

## Implementation Phases

### Phase 1: Foundation (Week 1)
- [ ] Add `source_type = 'imdb_event'` support to `movie_lists` table
- [ ] Create `ImdbEventScraper` module (reuse HTTP patterns)
- [ ] Extend `CanonicalPageWorker` with event detection
- [ ] Add event URL builder functions

### Phase 2: Event Configuration (Week 2) 
- [ ] Create database seeder for major festival events
- [ ] Build event → organization mapping logic
- [ ] Add event-specific metadata handling
- [ ] Extend `CanonicalImportOrchestrator` for events

### Phase 3: Festival Integration (Week 3)
- [ ] Route event data to festival tables instead of canonical_sources
- [ ] Create ceremony/nomination records from event data
- [ ] Add festival organization auto-creation
- [ ] Update dashboard to show events vs lists

### Phase 4: Testing & Migration (Week 4)
- [ ] Import one event (Cannes 2024) alongside existing list
- [ ] Compare data quality and completeness
- [ ] Create migration tools for existing festival lists → events
- [ ] Performance testing and optimization

## Configuration Strategy Decision

### Recommendation: Start with `movie_lists` Extension

**Pros:**
- ✅ 95% code reuse (same workers, same pipeline, same dashboard)
- ✅ Zero breaking changes to existing system
- ✅ Fastest implementation (2-3 weeks vs 6-8 weeks)
- ✅ Easy rollback if issues arise
- ✅ Can migrate individual festivals gradually

**Implementation:**
```sql
-- Add events as new source_type in existing table
INSERT INTO movie_lists (source_key, name, source_type, source_url, source_id, category, tracks_awards, metadata) 
VALUES 
  ('cannes_2024', 'Cannes 2024 Competition', 'imdb_event', 'https://www.imdb.com/event/ev0000147/2024/1/', 'ev0000147', 'awards', true, '{"year": 2024, "org": "cannes"}'),
  ('venice_2024', 'Venice 2024 Competition', 'imdb_event', 'https://www.imdb.com/event/ev0000681/2024/1/', 'ev0000681', 'awards', true, '{"year": 2024, "org": "venice"}');
```

### Future: Dedicated Festival Events Table

Once proven, we can migrate to dedicated `festival_events` table for cleaner architecture while maintaining the same worker pipeline.

## Code Reuse Summary

| Component | Reuse % | What's Reused | What's New |
|-----------|---------|---------------|------------|
| **Oban Workers** | 95% | Orchestration, page processing, completion | Event type detection |
| **HTTP Client** | 100% | fetch_html, retries, error handling | Different URLs |
| **Database Config** | 90% | movie_lists table structure | imdb_event source_type |
| **Movie Processing** | 85% | TMDb lookup, database storage | Festival table routing |
| **Dashboard** | 100% | All existing UI and monitoring | Zero changes needed |

**Total System Reuse: ~90%**

This approach maximizes our investment in the existing proven architecture while adding the minimum necessary components for IMDb Events support.