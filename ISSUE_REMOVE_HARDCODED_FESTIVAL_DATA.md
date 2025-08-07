# Remove Hardcoded Festival Data from Codebase

## Issue Description

An audit of the codebase reveals several hardcoded festival-related values that should be removed or made dynamic, as all festival configuration has been moved to database tables (`festival_events`, `festival_organizations`, etc.). Most critically, the Oscar IMDb event ID is hardcoded but shouldn't be used at all since Oscars data comes from oscars.org, not IMDb.

## Hardcoded Values Found

### 1. Oscar IMDb Event ID (Should be removed entirely)
**File**: `lib/cinegraph/scrapers/imdb_oscar_scraper.ex:17`
```elixir
@oscar_event_id "ev0000003"
```
- **Problem**: This IMDb event ID for Oscars is hardcoded and used to fetch from IMDb
- **Critical Issue**: We don't use IMDb for Oscar data - we use oscars.org
- **Action Required**: Remove this entirely or refactor to prevent any IMDb fetching for Oscars

### 2. AMPAS Organization Check (Should be dynamic)
**File**: `lib/cinegraph/workers/festival_discovery_worker.ex:184`
```elixir
if ceremony.organization.abbreviation == "AMPAS" do
```
- **Problem**: Hardcoded check for Oscar organization abbreviation
- **Action Required**: Either remove IMDb enhancement entirely for Oscars or make this check configurable

### 3. IMDb URL Template (Hardcoded in scrapers)
**File**: `lib/cinegraph/scrapers/unified_festival_scraper.ex:65`
```elixir
def build_imdb_url(event_id, year) do
  "https://www.imdb.com/event/#{event_id}/#{year}/1/"
end
```
- **Problem**: URL template is hardcoded in code rather than coming from database
- **Action Required**: Consider using the `url_template` field from `festival_events` table

## Current Architecture

The system has been refactored to use database tables:
- `festival_events` - Stores festival configurations including IMDb event IDs
- `festival_organizations` - Stores organization data (AMPAS, CFF, VIFF, etc.)
- Seeds properly populate these tables with event IDs

## Recommendations

1. **Remove Oscar IMDb Integration Entirely**
   - Delete or disable `ImdbOscarScraper.enhance_ceremony_with_imdb()` 
   - Remove the `@oscar_event_id` constant
   - Ensure Oscars only use oscars.org data source

2. **Make Organization Checks Dynamic**
   - Instead of hardcoding "AMPAS", check a database field like `uses_imdb_enhancement`
   - Or remove the IMDb enhancement step entirely since it's causing confusion

3. **Use Database URL Templates**
   - Pull URL templates from `festival_events` table
   - This allows different URL patterns for different data sources

## Impact

- **Current Behavior**: System incorrectly tries to fetch Oscar data from IMDb (ev0000003) even though we use oscars.org
- **Logs Showing Issue**: `[info] Fetching IMDb Oscar data for 2023 from: https://www.imdb.com/event/ev0000003/2024/1`
- **Expected Behavior**: Oscars should never attempt to fetch from IMDb

## Priority

**High** - This is causing incorrect data fetching and confusion in the system. The Oscar IMDb integration should be removed immediately since it's not being used and is causing errors.

## Files Affected

1. `lib/cinegraph/scrapers/imdb_oscar_scraper.ex` - Remove or refactor
2. `lib/cinegraph/workers/festival_discovery_worker.ex` - Remove AMPAS hardcoding
3. `lib/cinegraph/scrapers/unified_festival_scraper.ex` - Make URL template dynamic

## Testing Required

After changes:
1. Verify Oscar imports work correctly using only oscars.org
2. Verify other festivals (Cannes, Venice, Berlin) continue to work with IMDb
3. Ensure no hardcoded festival IDs or abbreviations remain in code
4. Confirm all festival configuration comes from database tables