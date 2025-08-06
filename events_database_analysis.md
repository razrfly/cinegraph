# IMDb Events Integration: Database vs Hardcoded Configuration

## Current State Analysis

### Lists (Database-Driven) ✅
**Implementation**: `lib/cinegraph/movies/movie_list.ex` + database table
- ✅ **Stored in database**: Full CRUD operations via UI
- ✅ **Rich metadata**: tracks_awards, import statistics, categories
- ✅ **Dynamic management**: Add/edit/disable lists without code changes
- ✅ **Import tracking**: last_import_at, status, total_imports
- ✅ **Source flexibility**: IMDB, TMDb, custom sources

### Events (Hardcoded) ❌
**Implementation**: `lib/cinegraph/scrapers/unified_festival_scraper.ex` - `@event_mappings`
- ❌ **Hardcoded module attribute**: Requires code deployment to modify
- ❌ **Limited metadata**: Basic info (name, country, founded_year, website)
- ❌ **No date tracking**: Cannot determine current/upcoming festival status
- ❌ **No import tracking**: No visibility into import success/failure rates
- ❌ **No range management**: Manual year range determination

## Problems with Current Events Implementation

### 1. **Missing Date Information** 🗓️
```elixir
# Current hardcoded data lacks essential scheduling info
"cannes" => %{
  event_id: "ev0000147",
  name: "Cannes Film Festival",
  # ❌ Missing: when does 2025 Cannes occur?
  # ❌ Missing: has 2025 already happened?
  # ❌ Missing: typical month/date range?
}
```

**Real Requirements**:
- **Cannes 2024**: May 14-25, 2024 (✅ completed)
- **Venice 2024**: Aug 28 - Sep 7, 2024 (✅ completed)  
- **Berlin 2025**: Feb 13-23, 2025 (❓ upcoming)
- **Venice 2025**: Aug 27 - Sep 6, 2025 (❓ future)

### 2. **Source Reliability Issues** 📊
```elixir
# No tracking of which sources work/fail
@event_mappings %{
  "cannes" => %{event_id: "ev0000147"} # What if this ID changes?
  # ❌ No reliability scoring
  # ❌ No fallback sources  
  # ❌ No import success tracking
}
```

### 3. **Year Range Management** 📅
```elixir
# Current: Manual determination of valid years
fetch_festival_data("cannes", 2025) # Will this work?
# ❌ No tracking of valid year ranges
# ❌ No automatic current/historical year detection
```

### 4. **Configuration Management** ⚙️
```elixir
# Adding new festival requires code changes
@event_mappings %{
  # To add Toronto Film Festival, need:
  # 1. Code modification
  # 2. Deployment
  # 3. Testing
  # ❌ No dynamic addition capability
}
```

## Proposed Solution: Database-Driven Events

### Schema Design

```elixir
defmodule Cinegraph.Events.FestivalEvent do
  schema "festival_events" do
    # Basic Info
    field :source_key, :string          # "cannes", "venice", "berlin"
    field :name, :string                # "Cannes Film Festival"
    field :abbreviation, :string        # "CFF", "VIFF", "BIFF"
    field :country, :string             # "France", "Italy", "Germany"
    field :founded_year, :integer       # 1946, 1932, 1951
    field :website, :string             # Official website
    
    # IMDb Integration  
    field :imdb_event_id, :string       # "ev0000147"
    field :source_type, :string         # "imdb", "tmdb", "custom"
    field :source_url_template, :string # "https://www.imdb.com/event/{event_id}/{year}/1/"
    
    # Date Management
    field :typical_start_month, :integer    # 5 (May for Cannes)
    field :typical_start_day, :integer      # 14 
    field :typical_duration_days, :integer  # 11 days
    field :timezone, :string                # "Europe/Paris"
    
    # Year Range Management
    field :min_available_year, :integer     # 1946 (first Cannes)
    field :max_available_year, :integer     # 2024 (last known available)
    field :current_year_status, :string     # "completed", "upcoming", "in_progress"
    
    # Import Configuration  
    field :active, :boolean, default: true
    field :import_priority, :integer        # Higher = import first
    field :auto_detect_new_years, :boolean  # Automatically try current_year + 1
    
    # Statistics & Reliability
    field :last_successful_import, :utc_datetime
    field :total_successful_imports, :integer, default: 0
    field :reliability_score, :float, default: 0.0  # 0.0-1.0
    field :last_error, :string
    
    # Metadata
    field :metadata, :map, default: %{}
    
    timestamps()
  end
end
```

### Festival Date Tracking

```elixir
defmodule Cinegraph.Events.FestivalDate do
  schema "festival_dates" do
    belongs_to :festival_event, Cinegraph.Events.FestivalEvent
    
    field :year, :integer
    field :start_date, :date
    field :end_date, :date
    field :status, :string              # "upcoming", "in_progress", "completed", "cancelled"
    field :announcement_date, :date     # When dates were officially announced
    field :source, :string              # Where date info came from
    field :notes, :text                 # Special circumstances, venue changes, etc.
    
    timestamps()
  end
end
```

## Benefits of Database-Driven Events

### ✅ **Dynamic Festival Management**
```elixir
# Add Toronto Film Festival via UI/API
%{
  source_key: "toronto",
  name: "Toronto International Film Festival", 
  imdb_event_id: "ev0000123",
  typical_start_month: 9,
  typical_start_day: 5,
  # ... no code changes needed
}
```

### ✅ **Smart Date Awareness**
```elixir
# Automatically determine what to import
Cinegraph.Events.get_importable_festivals()
# => [
#   %{festival: "berlin", year: 2025, status: "upcoming", start_date: ~D[2025-02-13]},
#   %{festival: "cannes", year: 2024, status: "completed", start_date: ~D[2024-05-14]}
# ]
```

### ✅ **Reliability Tracking**
```elixir
# Track which sources are reliable
festival = Cinegraph.Events.get_by_source_key("cannes")
# => %{reliability_score: 0.94, total_successful_imports: 47, last_error: nil}
```

### ✅ **Source URL Flexibility**
```elixir
# Handle source changes dynamically
festival.source_url_template
# => "https://www.imdb.com/event/{event_id}/{year}/1/"

# If IMDb changes structure, update template in database
update_festival(festival, %{
  source_url_template: "https://www.imdb.com/events/{event_id}/year/{year}/"
})
```

## Implementation Strategy

### Phase 1: Database Schema ⚗️
1. Create `festival_events` and `festival_dates` tables
2. Migrate existing `@event_mappings` data to database
3. Add UI for festival management

### Phase 2: Enhanced Logic 🧠
1. Date awareness service (`when_is_next_cannes?`)
2. Import scheduling (`should_import_festival?(festival, year)`)
3. Reliability tracking and fallback strategies

### Phase 3: Integration 🔗
1. Update `UnifiedFestivalScraper` to use database
2. Add automatic year detection
3. Implement smart import prioritization

## Migration Path

### Step 1: Preserve Existing Functionality
```elixir
# Keep @event_mappings temporarily
# Add database events as secondary source
def get_festival_config(festival_key) do
  case Cinegraph.Events.get_active_by_source_key(festival_key) do
    nil -> Map.get(@event_mappings, festival_key)  # fallback
    festival -> convert_to_legacy_format(festival)
  end
end
```

### Step 2: Database Population
```elixir
defmodule Cinegraph.Release do
  def migrate_events_to_database do
    # Migrate @event_mappings to database
    # Add 2024/2025 date information
    # Set reliability scores based on historical data
  end
end
```

### Step 3: Feature Enhancement
```elixir
# Smart scheduling
def should_import_festival?(festival_key, year) do
  festival = Events.get_by_source_key(festival_key)
  festival_date = Events.get_festival_date(festival.id, year)
  
  case festival_date.status do
    "completed" -> true   # Safe to import
    "upcoming" -> false   # Wait until after festival
    "in_progress" -> false # Wait for completion
  end
end
```

## Questions for Decision

### 1. **Scope of Database Migration** 🤔
- **Option A**: Full migration, remove all hardcoded configs
- **Option B**: Hybrid approach, database as primary + hardcode fallback
- **Option C**: Database-first, but keep simple configs in code

### 2. **Date Information Sources** 📅
- **Official websites**: Most accurate, requires scraping
- **Manual entry**: Initial data entry, maintain via UI  
- **Third-party APIs**: Eventbrite, Wikipedia, festival databases
- **Hybrid**: Manual seed + automatic detection

### 3. **Backwards Compatibility** 🔄
- **Maintain existing API**: `UnifiedFestivalScraper.get_festival_config/1`
- **Internal refactor only**: No changes to consumer code
- **Enhanced API**: Add date-aware methods, deprecate old ones

## Recommendation: **Database-Driven Events** ✅

**Why**: 
- **Consistency** with lists implementation (already database-driven)
- **Operational flexibility** for adding/modifying festivals
- **Date awareness** critical for import scheduling  
- **Reliability tracking** improves system robustness
- **Future-proof** for additional festival sources

**Timeline**:
- **Week 1**: Schema + basic CRUD
- **Week 2**: Data migration + UI
- **Week 3**: Enhanced import logic
- **Week 4**: Integration + testing

---

**Next Steps**:
1. ✅ Create this analysis
2. 🎯 Get stakeholder approval for database approach
3. 🚀 Implement Phase 1 (schema + migration)
4. 🔄 Update import logic for date awareness
5. 🎉 Add new festivals via UI instead of code!