# Festival Awards Import System Audit - Critical Issues Found

## Summary
After running importers for Academy Awards (Oscars), Venice, and Cannes for 2024, the dashboard statistics show incomplete data. Venice and Cannes have successfully imported nominations, but the Academy Awards import completely failed. This audit reveals the root causes and additional architectural issues.

## Current Status

### Database State (as of 2025-08-06)
```
Organization                                 | Ceremonies | Nominations | Wins
---------------------------------------------|------------|-------------|------
Academy of Motion Picture Arts and Sciences |     0      |      0      |   0
Cannes Film Festival                         |     1      |     54      |  11  
Venice International Film Festival           |     1      |     71      |  48
```

### Import Job Status
- **Venice 2024**: ✅ Completed successfully (Job #48610)
- **Cannes 2024**: ✅ Completed successfully (Job #48778)
- **Oscars 2024**: ❌ Failed and discarded after 3 attempts (Job #48723)
  - Error: `HTTP 404`

## Root Cause Analysis

### 1. ❌ CRITICAL: Missing IMDb Event ID for Academy Awards

**Issue**: The `festival_events` table entry for Oscars is missing the required `event_id` in its `source_config` JSON field.

**Current Configuration**:
```sql
source_key | name            | imdb_event_id | Status
-----------|-----------------|---------------|--------
oscars     | Academy Awards  | NULL          | ❌ Missing
venice     | Venice...       | "ev0000681"   | ✅ Working
cannes     | Cannes...       | "ev0000147"   | ✅ Working
```

**Impact**: The UnifiedFestivalScraper cannot build the IMDb URL without an event_id, resulting in HTTP 404 errors.

**Code Location**: `/lib/cinegraph/scrapers/unified_festival_scraper.ex:32`
```elixir
url = build_imdb_url(festival_config.event_id, year)  # Fails when event_id is nil
```

### 2. ⚠️ Architecture Issue: Dual Table System Confusion

The system currently has two parallel architectures for storing Oscar data:

**Old Architecture** (Not present in current database):
- Tables: `oscar_ceremonies`, `oscar_nominations`, `oscar_categories`
- Used by: Original Oscar-specific import system

**New Architecture** (Currently active):
- Tables: `festival_*` (organizations, ceremonies, nominations, categories, events)
- Used by: UnifiedFestivalWorker

**Problem**: The statistics calculation in the dashboard (`get_oscar_stats`) correctly uses the new `festival_*` tables, but since the UnifiedFestivalWorker failed, no Oscar data exists in either system.

### 3. ⚠️ Missing Data Validation

**Issue**: No validation that required fields (like `event_id`) exist before attempting import.

**Location**: `UnifiedFestivalScraper.fetch_festival_data/2`

**Impact**: Jobs fail at runtime rather than providing early feedback about misconfiguration.

### 4. ℹ️ Statistics Display Logic (Working Correctly)

The dashboard statistics logic is actually working correctly:
- `get_oscar_stats()` properly queries `festival_*` tables
- `get_festival_stats()` only shows Venice data (hardcoded to "VIFF")
- The issue is lack of data, not calculation logic

## Recommendations

### Immediate Fixes (Priority 1)

1. **Add Oscar IMDb Event ID**
   ```sql
   UPDATE festival_events 
   SET source_config = jsonb_set(
     COALESCE(source_config, '{}'::jsonb),
     '{event_id}',
     '"ev0000003"'::jsonb
   )
   WHERE source_key = 'oscars';
   ```
   *Note: Need to verify the correct IMDb event ID for Academy Awards*

2. **Add Validation in UnifiedFestivalScraper**
   ```elixir
   def fetch_festival_data(festival_key, year) do
     case Events.get_active_by_source_key(festival_key) do
       nil -> {:error, "Unknown festival: #{festival_key}"}
       festival_event ->
         festival_config = FestivalEvent.to_scraper_config(festival_event)
         
         # Add validation
         unless festival_config.event_id do
           {:error, "Missing event_id for #{festival_key}"}
         end
         
         # Continue with existing logic...
   ```

### Medium-term Improvements (Priority 2)

3. **Enhance Festival Statistics Display**
   - Currently only shows Venice stats
   - Should dynamically show all festivals with data
   - Group by organization for clearer presentation

4. **Add Import Status Tracking**
   - Track which years have been imported for each festival
   - Show last import timestamp
   - Display import success/failure rates

5. **Implement Data Recovery**
   - Add retry mechanism with better error messages
   - Log configuration issues to a dedicated table
   - Provide UI feedback about missing configuration

### Long-term Considerations (Priority 3)

6. **Unify or Remove Legacy Oscar Tables**
   - Decision needed: Keep dual system or migrate fully to `festival_*` tables
   - If migrating, need data migration strategy for existing Oscar data
   - Update all references to use consistent table structure

7. **Add Configuration Validation on Startup**
   - Validate all festival_events have required fields
   - Check for duplicate abbreviations
   - Verify IMDb event IDs are valid format

## Testing Checklist

After fixes are implemented:

- [ ] Verify Oscar event_id is added to database
- [ ] Re-run Oscar 2024 import
- [ ] Confirm nominations appear in festival_nominations table
- [ ] Check dashboard shows Oscar statistics
- [ ] Test import for multiple years (2022-2024)
- [ ] Verify all three festivals show in statistics
- [ ] Test error handling with invalid event_id
- [ ] Ensure no regression in Venice/Cannes imports

## Additional Notes

- The FestivalDiscoveryWorker successfully processed nominations for Venice (71) and Cannes (54)
- The system correctly creates festival_organizations entries
- Categories are being properly tracked (76 for Venice)
- The "wins" tracking is working (48/71 for Venice, 11/54 for Cannes)

## Files Affected

- `/lib/cinegraph/scrapers/unified_festival_scraper.ex` - Add validation
- `/lib/cinegraph_web/live/import_dashboard_live.ex` - Update statistics display
- `/priv/repo/seeds.exs` or migration - Add Oscar event_id
- `/lib/cinegraph/events/festival_event.ex` - Consider adding validation

## Related Issues

- Previous festival import implementations
- Dashboard statistics display improvements
- Data migration from legacy Oscar tables (if they exist elsewhere)