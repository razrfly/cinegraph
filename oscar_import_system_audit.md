# Oscar Import System Audit & Documentation

## Current System Overview

### What We Have Built

1. **Data Collection Pipeline**
   - `OscarScraper` - Fetches ceremony data from Oscars.org using Zyte API
   - `ImdbOscarScraper` - Enhances ceremony data with IMDb IDs
   - `OscarImporter` - Processes ceremonies and creates/updates movies

2. **Database Structure**
   - `oscar_ceremonies` - Stores raw ceremony data in JSONB
   - `oscar_categories` - 25 categories with person-tracking flags
   - `oscar_nominations` - Links movies/people to categories
   - `movie_oscar_stats` view - Quick access to nomination counts
   - `person_oscar_stats` view - Quick access to person achievements

3. **Movie Integration**
   - Uses TMDb API to lookup movies by IMDb ID
   - Creates full movie records with TMDb data
   - Safely handles existing movies (update only)
   - Stores nomination data in both JSONB and relational tables

### Current Import Flow

1. Fetch ceremony HTML from Oscars.org (year-based URL)
2. Parse categories and nominees
3. Enhance with IMDb IDs using Zyte API
4. For each nominee:
   - Check if movie exists by IMDb ID
   - If exists: Update with nomination data
   - If not: Fetch from TMDb and create with full data
5. Create nomination records in relational table
6. Track person nominations for actors/directors

## Import Methods Analysis

### Existing Methods

```elixir
# Import all ceremonies (processes whatever is in DB)
OscarImporter.import_all_ceremonies()

# Import single ceremony (requires ceremony already in DB)
OscarImporter.import_ceremony(ceremony)
```

### What's Missing

We need a single command that:
1. Fetches ceremony data for a specific year
2. Enhances it with IMDb IDs
3. Imports all movies and nominations

## Proposed Solution

### New Mix Task

```bash
# Import a single year
mix import_oscars --year 2024

# Import multiple years
mix import_oscars --years 2020-2024

# Import all available years
mix import_oscars --all
```

### New Module Methods

```elixir
# Single year import
Cinegraph.Cultural.import_oscar_year(2024)

# Range import
Cinegraph.Cultural.import_oscar_years(2020..2024)

# All available years
Cinegraph.Cultural.import_all_oscar_years()
```

## Integration Safety Audit

### Movie Creation/Update Safety

✅ **Safe Integration Points**:
- Both import methods use `Movie.changeset/2` 
- Both check for existing movies before creating
- TMDb ID is the primary key for deduplication
- IMDb ID provides secondary matching

✅ **No Conflicts Because**:
- Oscar import checks if movie exists first
- Updates are additive (only adds award data)
- TMDb data structure is identical from both sources
- Queue same enrichment jobs

### Potential Issues & Solutions

1. **Race Conditions**
   - Issue: Simultaneous imports might create duplicates
   - Solution: Database unique constraints on tmdb_id and imdb_id

2. **Data Quality**
   - Issue: Oscar data might have different movie titles
   - Solution: We use IMDb ID + TMDb lookup for accuracy

3. **Missing Movies**
   - Issue: Some Oscar nominees might not be in TMDb
   - Solution: Create partial records with import_status flag

## Implementation Plan

### Phase 1: Create Unified Import Method
```elixir
defmodule Cinegraph.Cultural do
  def import_oscar_year(year) do
    # 1. Fetch or create ceremony
    ceremony = fetch_or_create_ceremony(year)
    
    # 2. Enhance with IMDb if needed
    ceremony = ensure_imdb_enhancement(ceremony)
    
    # 3. Import all movies
    OscarImporter.import_ceremony(ceremony)
  end
  
  defp fetch_or_create_ceremony(year) do
    case Repo.get_by(OscarCeremony, year: year) do
      nil -> 
        {:ok, data} = OscarScraper.fetch_ceremony(year)
        create_oscar_ceremony(%{
          year: year,
          ceremony_number: year - 1927,
          data: data
        })
      ceremony -> 
        ceremony
    end
  end
end
```

### Phase 2: Create Mix Task
```elixir
defmodule Mix.Tasks.ImportOscars do
  use Mix.Task
  
  def run(args) do
    # Parse arguments
    # Call Cultural.import_oscar_year(year)
    # Show progress
  end
end
```

### Phase 3: Add to README
```markdown
## Importing Oscar Data

Import Oscar ceremony data and create/update all nominated movies:

```bash
# Import a single year
mix import_oscars --year 2024

# Import a range of years
mix import_oscars --years 2020-2024

# Import with options
mix import_oscars --year 2024 --skip-enrichment
```

This will:
1. Fetch ceremony data from Oscars.org
2. Enhance with IMDb IDs
3. Create/update movies using TMDb data
4. Create nomination records
5. Track person achievements (actors/directors)
```

## Benefits of This Approach

1. **Simple Command**: One command imports everything for a year
2. **Safe Integration**: Works alongside existing movie imports
3. **Complete Data**: Creates full movie records with TMDb data
4. **Fast Queries**: Optimized tables for nomination counts
5. **Person Tracking**: Boost films with Oscar-winning talent

## Testing Plan

1. Import a year with no existing movies
2. Import a year with some existing movies  
3. Import same year twice (idempotency test)
4. Run concurrent with regular movie import
5. Verify nomination counts in database

## Performance Considerations

- Each ceremony has ~100-150 nominees
- TMDb API rate limit: 40 requests/10 seconds
- Estimated time per ceremony: 3-5 minutes
- Can parallelize person creation

## Conclusion

The Oscar import system is well-architected and safe to use alongside regular imports. We just need to add convenience methods and documentation to make it easy to use.