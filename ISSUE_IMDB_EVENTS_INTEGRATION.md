# Add Support for IMDb Events to Enhance Festival Data Quality

## Problem Statement

We currently scrape festival data from user-created IMDb lists (e.g., `ls527026601` for Cannes winners), which have limitations:
- Inconsistent data structure (awards mixed in descriptions)
- Variable quality and completeness
- No structured nominee/winner information
- Reliability issues (~85-90% accuracy)

IMDb provides official "Events" pages (e.g., https://www.imdb.com/event/ev0000147/2024/1/ for Cannes 2024) with:
- Structured category/nominee/winner data
- Official festival information
- Consistent HTML format
- Better data quality

## Current Architecture

### What We Have:
1. **Festival System** (`Cinegraph.Festivals`):
   - Tables: `festival_ceremonies`, `festival_categories`, `festival_nominations`
   - Stores structured award data
   - Currently used for Oscars (from oscars.org)

2. **Lists System** (`Cinegraph.Movies.MovieLists`):
   - Table: `movie_lists`
   - Handles IMDb user lists (`ls*` format)
   - Currently stores Cannes, Venice, Berlin as lists
   - Data goes to `canonical_sources` JSON in movies table

3. **Data Sources**:
   - Oscars: Direct from oscars.org → festival tables ✅
   - Other festivals: IMDb lists → canonical_sources JSON ⚠️

## Proposed Solution

### Integrate IMDb Events into Festival System (Not Lists)

IMDb Events should populate our `festival_*` tables directly, giving us structured award data instead of JSON blobs.

### Implementation Plan

#### 1. Create IMDb Event Scraper
```elixir
defmodule Cinegraph.Scrapers.ImdbEventScraper do
  @moduledoc """
  Scraper for official IMDb Event pages (ev* format).
  Extracts structured festival/award data.
  """
  
  def scrape_event(event_id, year, page \\ 1)
  def parse_event_html(html)
  def import_to_festival_system(event_data, organization)
end
```

#### 2. Extend Festival Schema
```elixir
# In FestivalCeremony schema, add:
field :source_type, :string  # "official" | "imdb_event" | "imdb_list"
field :source_url, :string   # Track data provenance
field :source_id, :string    # e.g., "ev0000147" for events
```

#### 3. Map IMDb Events to Organizations
```elixir
@event_mappings %{
  "ev0000003" => %{org: "academy_awards", name: "Academy Awards"},
  "ev0000147" => %{org: "cannes", name: "Cannes Film Festival"},
  "ev0000091" => %{org: "berlin", name: "Berlin International Film Festival"},
  "ev0000681" => %{org: "venice", name: "Venice Film Festival"},
  "ev0000292" => %{org: "golden_globes", name: "Golden Globe Awards"},
  "ev0000471" => %{org: "bafta", name: "BAFTA Awards"},
  "ev0000123" => %{org: "critics_choice", name: "Critics Choice Awards"},
  "ev0000631" => %{org: "sundance", name: "Sundance Film Festival"}
}
```

#### 4. Data Priority System
```elixir
def get_best_source(organization, year) do
  # Priority order:
  # 1. Official website (oscars.org, etc.)
  # 2. IMDb Event page (structured data)
  # 3. IMDb List (fallback for historical data)
  
  cond do
    has_official_source?(organization) -> {:official, get_official_url(organization, year)}
    has_imdb_event?(organization, year) -> {:imdb_event, get_event_id(organization)}
    has_imdb_list?(organization) -> {:imdb_list, get_list_id(organization)}
    true -> {:error, :no_source}
  end
end
```

## Migration Strategy

### Phase 1: Build Infrastructure (No Breaking Changes)
- [ ] Create `ImdbEventScraper` module
- [ ] Add source tracking fields to festival schemas
- [ ] Build event ID → organization mapping

### Phase 2: Import & Compare
- [ ] Import Cannes 2024 from both list and event
- [ ] Compare data quality and completeness
- [ ] Verify event data is superior

### Phase 3: Gradual Migration
- [ ] Import all available event data for existing festivals
- [ ] Keep list data as fallback
- [ ] Update dashboard to show data source

### Phase 4: Deprecate Lists for Festivals
- [ ] Stop using lists for festival data
- [ ] Keep lists only for non-award collections (Criterion, 1001 Movies, etc.)
- [ ] Update documentation

## Benefits

1. **Better Data Quality**: Structured nominees/winners vs. parsing descriptions
2. **Consistency**: All festivals use same table structure
3. **Provenance Tracking**: Know where each piece of data came from
4. **Single Source of Truth**: Festival tables for all award data
5. **Future-Proof**: Can add more festivals easily

## Technical Details

### What Stays in Lists:
- Curated collections (Criterion Collection)
- Editorial lists (1001 Movies You Must See)
- Critics polls (Sight & Sound)
- Registry lists (National Film Registry)

### What Moves to Festivals:
- All award ceremonies (Cannes, Venice, Berlin, Golden Globes, etc.)
- Any event with categories and nominees
- Festival competitions

### Database Changes:
```sql
-- Add to festival_ceremonies table
ALTER TABLE festival_ceremonies 
ADD COLUMN source_type VARCHAR(20),
ADD COLUMN source_url TEXT,
ADD COLUMN source_id VARCHAR(50);

-- Add to festival_organizations table
ALTER TABLE festival_organizations
ADD COLUMN imdb_event_id VARCHAR(20);
```

## Success Criteria

- [ ] Can import Cannes 2024 from IMDb event page
- [ ] Data includes structured categories and nominees
- [ ] Festival dashboard shows accurate counts
- [ ] Source tracking shows "imdb_event" for new imports
- [ ] No regression in existing Oscar imports

## Tasks

- [ ] Research IMDb event HTML structure
- [ ] Create `ImdbEventScraper` with tests
- [ ] Add source tracking to festival schemas
- [ ] Build event mapping configuration
- [ ] Import one festival as proof of concept
- [ ] Create migration plan for existing data
- [ ] Update dashboard to show data sources
- [ ] Document new import process

## Questions to Resolve

1. Should we keep historical list data or re-import from events?
2. How do we handle festivals without IMDb events?
3. Should we auto-discover new festivals from IMDb?
4. Do we need to track event-specific metadata (e.g., ceremony location)?

## References

- Example IMDb Event: https://www.imdb.com/event/ev0000147/2024/1/ (Cannes 2024)
- Example IMDb List: https://www.imdb.com/list/ls527026601/ (Cannes Winners)
- Current festival migration issue: `ISSUE_FESTIVAL_MIGRATION.md`