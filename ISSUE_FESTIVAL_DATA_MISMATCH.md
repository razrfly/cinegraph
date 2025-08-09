# Festival Statistics Data Source Mismatch Issue

## Problem Description
The Festival Awards Statistics display on the Import Dashboard is showing inconsistent data for Academy Awards (and potentially other festivals). The statistics change values on page refresh, showing different nomination counts (e.g., 50 nominations on one load, 106 on refresh).

## Root Cause Analysis

### 1. Table Structure Mismatch
The `get_festival_stats/0` function in `import_dashboard_live.ex` (lines 1122-1254) queries the following tables:
- `festival_organizations`
- `festival_ceremonies` 
- `festival_nominations`
- `festival_categories`

However, investigation reveals these tables may not be properly populated or may not exist in the expected form.

### 2. Migration History
- Migration `20250806101521_drop_oscar_tables.exs` dropped the original Oscar-specific tables (`oscar_ceremonies`, `oscar_nominations`, `oscar_categories`)
- Comment states: "All data has been successfully migrated and verified"
- The migration suggests data was moved to unified `festival_*` tables

### 3. Actual Database Structure
Database inspection shows:
- The seeds file creates `festival_events` and `festival_dates` tables
- These are different from the `festival_organizations`, `festival_ceremonies`, and `festival_nominations` tables that the LiveView expects
- This mismatch causes the query to return inconsistent or empty results

## Evidence of the Problem

### User-Reported Symptoms
1. Academy Awards showing 50 nominations on first load
2. Same statistics showing 106 nominations on refresh
3. Data inconsistency cannot be fixed with template changes

### Actual 96th Academy Awards (2024) Data
According to official sources (Wikipedia and Academy records), the correct numbers for the 2024 (96th) Academy Awards should be:
- **Total Nominations**: 115 individual nominations (across all 23 categories)
- **Total Wins**: 23 (one winner per category)
- **Categories**: 23 total
- **Breakdown by category**:
  - Best Picture: 10 nominees
  - All other 22 categories: 5 nominees each (22 × 5 = 110)
  - Total: 10 + 110 = 115 individual nominations

**Key Films**:
- Oppenheimer: 13 nominations (most nominated)
- Poor Things: 11 nominations
- Killers of the Flower Moon: 10 nominations
- Barbie: 8 nominations
- Maestro: 7 nominations

The dashboard showing "50 nominations" or "106 nominations" are both incorrect. Neither matches the actual 115 total nominations for the 96th Academy Awards.

### Code Analysis
```elixir
# The function expects these tables (import_dashboard_live.ex:1122-1254)
def get_festival_stats do
  query = from fo in Cinegraph.Festivals.FestivalOrganization,
    left_join: fc in assoc(fo, :ceremonies),
    left_join: fn in assoc(fc, :nominations),
    # ... queries festival_organizations, ceremonies, nominations
```

But the actual database may have:
- `festival_events` (not `festival_organizations`)
- `festival_dates` (not `festival_ceremonies`)
- Missing or improperly migrated nomination data

## Impact
- Incorrect statistics displayed to users
- Data changes randomly on page refresh
- Academy Awards (AMPAS) statistics particularly affected
- Potentially affects all festival statistics, not just Academy Awards

## Proposed Solutions

### Option 1: Update the Query Function
Modify `get_festival_stats/0` to query the correct tables that actually exist in the database:
- Query `festival_events` instead of `festival_organizations`
- Query `festival_dates` instead of `festival_ceremonies`
- Properly handle the actual data structure

### Option 2: Complete the Data Migration
Ensure the data migration from Oscar tables to festival tables is actually complete:
- Verify `festival_organizations` table exists and is populated
- Verify `festival_ceremonies` table has the Academy Awards data
- Verify `festival_nominations` table has the nomination records
- Re-run or fix the migration if necessary

### Option 3: Create Missing Tables and Populate
If the tables don't exist:
- Create the expected `festival_organizations`, `festival_ceremonies`, `festival_nominations` tables
- Populate them with the correct data
- Ensure proper foreign key relationships

## Verification Steps
1. Check which tables actually exist: `\dt` in psql
2. Verify table contents: `SELECT COUNT(*) FROM festival_organizations;`
3. Check if Academy Awards organization exists: `SELECT * FROM festival_organizations WHERE abbreviation = 'AMPAS';`
4. Verify ceremony data: `SELECT COUNT(*) FROM festival_ceremonies WHERE organization_id = (SELECT id FROM festival_organizations WHERE abbreviation = 'AMPAS');`

## Additional Notes
- The template fix (replacing lines 489-501 in the .heex file) was successful and correctly displays the modular boxes
- The display issue is purely a data source problem, not a template problem
- The inconsistent values suggest either:
  - Multiple queries returning different results
  - Cache invalidation issues
  - Data being read from wrong tables/columns

## Priority
HIGH - This affects the accuracy of all festival statistics displayed to users and makes the dashboard unreliable.