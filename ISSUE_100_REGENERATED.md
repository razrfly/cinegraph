# Issue #152 & #100: Unified Festival Tables Migration - AUDIT REPORT

## Executive Summary

The Oscar import jobs complete successfully but **don't actually import any data**. The root cause is a fundamental architectural mismatch: the code is trying to **migrate** data from old `oscar_*` tables to new `festival_*` tables, but there's **no data in the old tables to migrate from**.

## Current State Analysis

### 1. Database Tables Status

**Old Oscar Tables (to be replaced):**
- ✅ `oscar_ceremonies` - EXISTS but EMPTY (0 rows)
- ✅ `oscar_categories` - EXISTS but EMPTY (0 rows)  
- ✅ `oscar_nominations` - EXISTS but EMPTY (0 rows)

**New Unified Festival Tables (replacement):**
- ✅ `festival_organizations` - EXISTS but EMPTY (0 rows)
- ✅ `festival_ceremonies` - EXISTS but EMPTY (0 rows)
- ✅ `festival_categories` - EXISTS but EMPTY (0 rows)
- ✅ `festival_nominations` - EXISTS but EMPTY (0 rows)

### 2. The Import Flow Problem

**Current (BROKEN) Flow:**
```
OscarImportWorker.perform()
  ↓
Cultural.import_oscar_year(year)
  ↓
fetch_or_create_ceremony(year)
  ├→ Checks oscar_ceremonies table (OLD) 
  ├→ Finds nothing (table is empty)
  ├→ Fetches from OscarScraper
  └→ Inserts into oscar_ceremonies (OLD) ❌
  ↓
UnifiedOscarImporter.import_ceremony(ceremony)
  ├→ Expects ceremony from oscar_ceremonies
  ├→ Creates festival_ceremony (NEW)
  └→ Processes nominations into festival_nominations (NEW)
```

**The Fundamental Problem:**
1. `fetch_or_create_ceremony` still uses the OLD `oscar_ceremonies` table
2. `UnifiedOscarImporter` expects data to exist in OLD tables first
3. We're trying to MIGRATE from old to new, not REPLACE
4. But there's no data in old tables to migrate from!

### 3. What We Actually Did

Based on the git status and conversation history:

1. **Created new unified festival tables** (migration `20250805173523_create_unified_festival_tables.exs`)
   - `festival_organizations`
   - `festival_ceremonies`
   - `festival_categories`
   - `festival_nominations`

2. **Created UnifiedOscarImporter** (`lib/cinegraph/festivals/unified_oscar_importer.ex`)
   - But it expects data from `oscar_ceremonies` table first
   - It's a migrator, not a fresh importer

3. **Updated the dashboard** (`lib/cinegraph_web/live/import_dashboard_live.ex`)
   - Now correctly queries from `festival_*` tables
   - But there's no data to display

4. **Updated Cultural module** (`lib/cinegraph/cultural.ex`)
   - `import_oscar_year` now calls `UnifiedOscarImporter`
   - But still uses `fetch_or_create_ceremony` which populates OLD tables

5. **Updated OscarImportWorker** (`lib/cinegraph/workers/oscar_import_worker.ex`)
   - Now handles the new result structure
   - But the underlying import doesn't work

## What Should Have Happened (Per Issue #152)

According to Issue #152, the goal was a **"bulletproof migration strategy with zero data loss risk"**:

1. Extract nominations from existing JSONB data
2. Run systems in parallel  
3. Create unified query layer
4. Maintain backward compatibility

**BUT** the actual requirement evolved to **REPLACE** the old system entirely:
- Fetch Oscar data directly from scraper
- Insert directly into `festival_*` tables  
- Skip `oscar_*` tables entirely
- Dashboard queries from `festival_*` tables

## The Solution Path

### Option 1: Fix the Import Chain (RECOMMENDED)

Modify `Cultural.import_oscar_year` to bypass old tables entirely:

```elixir
def import_oscar_year(year, options \\ []) do
  # Get AMPAS organization
  oscar_org = Festivals.get_organization_by_abbreviation("AMPAS") || 
              create_ampas_organization()
  
  # Fetch directly from scraper (skip old tables)
  with {:ok, ceremony_data} <- OscarScraper.fetch_ceremony(year),
       {:ok, enhanced_data} <- ImdbOscarScraper.enhance_ceremony_data(ceremony_data) do
    
    # Pass raw data directly to unified importer
    UnifiedOscarImporter.import_from_scraped_data(
      enhanced_data, 
      oscar_org, 
      year,
      options
    )
  end
end
```

### Option 2: Populate Old Tables First (NOT RECOMMENDED)

Keep the current architecture but populate `oscar_ceremonies` first:
- This maintains the migration approach
- But adds unnecessary complexity
- Goes against the goal of replacing old tables

### Option 3: Dual-Write Strategy (COMPLEX)

Write to both old and new tables simultaneously:
- Maintains backward compatibility
- But doubles the complexity
- Delays the eventual migration

## Critical Files That Need Changes

1. **`lib/cinegraph/cultural.ex`**
   - Remove `fetch_or_create_ceremony` function
   - Make `import_oscar_year` fetch directly from scraper
   - Pass raw data to UnifiedOscarImporter

2. **`lib/cinegraph/festivals/unified_oscar_importer.ex`**
   - Add `import_from_scraped_data` function
   - Remove dependency on `oscar_ceremonies` table
   - Create all data fresh in `festival_*` tables

3. **`lib/cinegraph/festivals.ex`** 
   - Add `seed_festival_organizations` if not exists
   - Ensure AMPAS organization is always created

## Why The Jobs "Do Nothing"

When the user runs an import job for years 2020-2025:

1. Job starts successfully ✅
2. Calls `Cultural.import_oscar_year(2020)` ✅
3. Calls `fetch_or_create_ceremony(2020)` ✅
4. Looks in `oscar_ceremonies` table - **EMPTY** ❌
5. Fetches from `OscarScraper` ✅
6. Tries to insert into `oscar_ceremonies` ✅
7. Calls `UnifiedOscarImporter.import_ceremony` ✅
8. But the ceremony wasn't saved properly ❌
9. Returns empty result ❌
10. Job completes "successfully" with no data imported ❌

## Immediate Next Steps

1. **Document Decision**: Confirm we're REPLACING not MIGRATING
2. **Fix Import Chain**: Modify Cultural module to skip old tables
3. **Update UnifiedOscarImporter**: Accept raw scraped data
4. **Seed Organizations**: Ensure AMPAS exists before any import
5. **Test End-to-End**: Verify data flows into festival tables
6. **Remove Old Tables**: Once working, drop oscar_* tables

## Risk Assessment

**Current Risk**: HIGH
- Import functionality is completely broken
- No data is being imported despite successful job completion
- Dashboard shows empty data

**Post-Fix Risk**: LOW  
- Direct import path is simpler and more reliable
- No dependency on intermediate tables
- Clear data flow from scraper to unified tables

## Conclusion

The fundamental issue is an **architectural mismatch**: we built a migration system when we needed a replacement system. The fix is straightforward - bypass the old tables entirely and import directly into the new unified structure.