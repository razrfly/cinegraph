# Reuse Existing Scraper Architecture for IMDb Events (No New Tables)

## Current State Analysis

### ✅ What We Already Have

#### Database Tables (All Exist)
- `festival_organizations` - Stores festival entities (currently has AMPAS)
- `festival_ceremonies` - Stores ceremony data with `data_source`, `source_url`, `scraped_at`
- `festival_nominations` - Stores structured award data
- `movie_lists` - Configuration system for list imports

#### Working Scrapers & Workers
- `ImdbCanonicalScraper` - Scrapes IMDb lists (`ls*` format)
- `OscarScraper` - Scrapes oscars.org directly
- `CanonicalImportOrchestrator` - Orchestrates multi-page imports
- `CanonicalPageWorker` - Processes individual pages
- `FestivalDiscoveryWorker` - Processes ceremony data into festival tables

#### Proven Architecture Pattern
```
Data Source → Scraper → Worker → festival_ceremonies.data → FestivalDiscoveryWorker → Structured Tables
```

**Oscars**: oscars.org → OscarScraper → festival_ceremonies → FestivalDiscoveryWorker → festival_nominations ✅  
**Lists**: IMDb lists → ImdbCanonicalScraper → canonical_sources JSON ⚠️

## The Goal: Apply Same Pattern to IMDb Events

**Target**: IMDb events → **New** ImdbEventScraper → festival_ceremonies → **Existing** FestivalDiscoveryWorker → festival_nominations

### Key Insight: Reuse FestivalDiscoveryWorker

The `FestivalDiscoveryWorker` already knows how to:
- Process ceremony JSON data
- Create festival organizations  
- Create categories and nominations
- Handle person vs film nominations
- Match movies via TMDb

**We just need to get IMDb event data into the same format.**

## Implementation Strategy: Maximum Code Reuse

### 1. Create IMDb Event Scraper (Reuse HTTP Patterns)

```elixir
defmodule Cinegraph.Scrapers.ImdbEventScraper do
  @moduledoc """
  Scrapes IMDb Event pages and formats data for festival_ceremonies table.
  Reuses HTTP patterns from ImdbCanonicalScraper and OscarScraper.
  """
  
  # REUSE: Same HTTP client patterns as ImdbCanonicalScraper
  def fetch_event_ceremony(event_id, year) do
    url = "https://www.imdb.com/event/#{event_id}/#{year}/1/"
    
    # REUSE: Same fetch_html and retry logic
    case fetch_html(url) do
      {:ok, html} -> parse_event_ceremony(html, event_id, year)
      error -> error
    end
  end
  
  # NEW: Event-specific parsing (similar to OscarScraper patterns)
  defp parse_event_ceremony(html, event_id, year) do
    document = Floki.parse_document!(html)
    
    # Parse event structure into same format as OscarScraper output
    %{
      year: year,
      event_id: event_id,
      categories: extract_event_categories(document),
      source_type: "imdb_event",
      scraped_at: DateTime.utc_now()
    }
  end
  
  # NEW: Event-specific category extraction
  defp extract_event_categories(document) do
    # Events have different HTML structure than lists
    # Parse categories with nominees/winners
    # Return same structure as OscarScraper for FestivalDiscoveryWorker compatibility
  end
end
```

### 2. Add Festival Organization Management

```elixir
# In Cinegraph.Festivals module
def get_or_create_festival_organization(event_config) do
  %{
    "abbreviation" => abbreviation,
    "name" => name,
    "website" => website
  } = event_config
  
  case get_organization_by_abbreviation(abbreviation) do
    nil -> create_organization(%{
      name: name,
      abbreviation: abbreviation,
      website: website,
      metadata: %{"imdb_event_support" => true}
    })
    org -> org
  end
end
```

### 3. Create Event Import Functions (Mirror Oscar Pattern)

```elixir
# In Cinegraph.Cultural module (reuse exact same pattern as Oscars)
def import_festival_event(event_id, year, organization_config, options \\ []) do
  Logger.info("Starting festival event import: #{event_id}/#{year}")
  
  with {:ok, ceremony} <- fetch_or_create_event_ceremony(event_id, year, organization_config) do
    # REUSE: Identical job queuing pattern as Oscar imports
    job_args = %{
      "ceremony_id" => ceremony.id,
      "options" => Enum.into(options, %{})
    }
    
    # REUSE: Same FestivalDiscoveryWorker (no changes needed!)
    case Cinegraph.Workers.FestivalDiscoveryWorker.new(job_args) |> Oban.insert() do
      {:ok, job} -> {:ok, %{ceremony_id: ceremony.id, job_id: job.id}}
      error -> error
    end
  end
end

defp fetch_or_create_event_ceremony(event_id, year, org_config) do
  # Get or create festival organization
  organization = get_or_create_festival_organization(org_config)
  
  case Festivals.get_ceremony_by_year(organization.id, year) do
    nil -> 
      # Fetch event data using new scraper
      case ImdbEventScraper.fetch_event_ceremony(event_id, year) do
        {:ok, data} ->
          attrs = %{
            organization_id: organization.id,
            year: year,
            data: data,
            data_source: "imdb_event",  # NEW source type
            source_url: "https://www.imdb.com/event/#{event_id}/#{year}/1/",
            scraped_at: DateTime.utc_now(),
            source_metadata: %{
              "scraper" => "ImdbEventScraper",
              "event_id" => event_id
            }
          }
          
          Festivals.upsert_ceremony(attrs)
      end
    ceremony -> {:ok, ceremony}
  end
end
```

### 4. Event Configuration Management

Instead of hardcoding, store event configs in code or eventually database:

```elixir
# Configuration module for IMDb events
defmodule Cinegraph.FestivalEvents do
  @event_configs %{
    "cannes" => %{
      "name" => "Festival de Cannes",
      "abbreviation" => "CANNES",
      "website" => "https://www.festival-cannes.com",
      "imdb_event_id" => "ev0000147",
      "ceremony_type" => "competition"
    },
    "venice" => %{
      "name" => "Venice International Film Festival", 
      "abbreviation" => "VENICE",
      "website" => "https://www.labiennale.org",
      "imdb_event_id" => "ev0000681",
      "ceremony_type" => "competition"
    },
    "berlin" => %{
      "name" => "Berlin International Film Festival",
      "abbreviation" => "BERLINALE", 
      "website" => "https://www.berlinale.de",
      "imdb_event_id" => "ev0000091",
      "ceremony_type" => "competition"
    }
  }
  
  def get_event_config(festival_key), do: @event_configs[festival_key]
  def all_events, do: @event_configs
  
  # Import function using existing patterns
  def import_festival_year(festival_key, year, options \\ []) do
    case get_event_config(festival_key) do
      nil -> {:error, "Unknown festival: #{festival_key}"}
      config ->
        Cinegraph.Cultural.import_festival_event(
          config["imdb_event_id"], 
          year, 
          config, 
          options
        )
    end
  end
end
```

### 5. Usage Examples

```elixir
# Import Cannes 2024 (same pattern as Oscar imports)
Cinegraph.FestivalEvents.import_festival_year("cannes", 2024)

# Import multiple years
2020..2024 
|> Enum.each(&Cinegraph.FestivalEvents.import_festival_year("cannes", &1))

# Batch import all festivals for a year
["cannes", "venice", "berlin"]
|> Enum.each(&Cinegraph.FestivalEvents.import_festival_year(&1, 2024))
```

## Code Reuse Breakdown

| Component | Reuse % | What We Reuse | What's New |
|-----------|---------|---------------|------------|
| **Database Tables** | 100% | All existing festival_* tables | Zero new tables |
| **FestivalDiscoveryWorker** | 100% | Entire ceremony processing logic | Zero changes |
| **HTTP Client** | 95% | fetch_html, retries, error handling | Event URL patterns |
| **Import Patterns** | 100% | Cultural.import_oscar_year structure | Event ID instead of year |
| **Oban Jobs** | 100% | Same queuing, monitoring, completion | Zero changes |

**Total Reuse: ~95%**

## Implementation Steps

### Phase 1: Core Scraper (1 week)
- [ ] Create `ImdbEventScraper` module
- [ ] Reuse HTTP patterns from `ImdbCanonicalScraper`
- [ ] Parse event HTML into ceremony JSON format
- [ ] Test with one event (Cannes 2024)

### Phase 2: Integration (1 week) 
- [ ] Create `FestivalEvents` configuration module
- [ ] Add event import functions to `Cultural` module
- [ ] Test full pipeline: Event → Ceremony → FestivalDiscoveryWorker → Nominations

### Phase 3: Festival Configs (1 week)
- [ ] Add all major festival configurations
- [ ] Create batch import functions
- [ ] Add dashboard support for event imports

### Phase 4: Migration (1 week)
- [ ] Import events for current festivals
- [ ] Compare data quality vs existing list imports
- [ ] Create migration scripts for switching from lists to events

## Benefits

1. **Zero Database Changes** - Use all existing tables
2. **95% Code Reuse** - Leverage proven patterns
3. **Same Monitoring** - Events appear in same dashboard as Oscars
4. **Gradual Migration** - Can import events alongside existing list imports
5. **Consistent Data** - All festivals use same structured format

## Questions to Resolve

1. **Event Discovery**: How do we find IMDb event IDs for new festivals?
2. **Year Coverage**: How far back do IMDb events go for each festival?
3. **Data Quality**: Are IMDb events better than our current list imports?
4. **Configuration**: Store event configs in code vs database?

This approach reuses our proven festival import architecture while adding minimal new code - just the event scraper and configuration management.