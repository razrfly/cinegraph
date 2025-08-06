# Issue: Migrate Oscar Import to Festival Tables While Preserving All Functionality

## Current Situation

We have a WORKING Oscar import system that successfully imports data into `oscar_*` tables:
- `oscar_ceremonies` 
- `oscar_categories`
- `oscar_nominations`

Current stats show the system works perfectly:
- **6 ceremonies imported** (2016-2024)
- **489 total nominations**
- **92 total wins**
- **21 categories**
- Individual year breakdowns (e.g., 2024: 15/82 wins/nominations)

## The Goal

**MOVE THE DATA TO NEW TABLES** - that's literally the only goal:
- FROM: `oscar_ceremonies` → TO: `festival_ceremonies`
- FROM: `oscar_categories` → TO: `festival_categories`  
- FROM: `oscar_nominations` → TO: `festival_nominations`

## What We Did Wrong

1. Created `FestivalDiscoveryWorker` but it STILL USES Oscar tables (lines 23-24)
2. We renamed the worker but didn't change what tables it writes to
3. We got distracted by fuzzy matching instead of focusing on the table migration

## The Plan - EXACTLY What To Do

### Step 1: Create Festival Tables (If They Don't Exist)
```sql
-- Check if these exist, create if not:
CREATE TABLE festival_ceremonies (
  -- Same structure as oscar_ceremonies
  id SERIAL PRIMARY KEY,
  festival_type VARCHAR(50) DEFAULT 'oscar',
  ceremony_number INTEGER,
  year INTEGER,
  ceremony_date DATE,
  data JSONB,
  inserted_at TIMESTAMP,
  updated_at TIMESTAMP
);

CREATE TABLE festival_categories (
  -- Same structure as oscar_categories  
  id SERIAL PRIMARY KEY,
  festival_type VARCHAR(50) DEFAULT 'oscar',
  name VARCHAR(255),
  category_type VARCHAR(50),
  is_major BOOLEAN,
  tracks_person BOOLEAN,
  inserted_at TIMESTAMP,
  updated_at TIMESTAMP
);

CREATE TABLE festival_nominations (
  -- Same structure as oscar_nominations
  id SERIAL PRIMARY KEY,
  ceremony_id INTEGER REFERENCES festival_ceremonies(id),
  category_id INTEGER REFERENCES festival_categories(id),
  movie_id INTEGER REFERENCES movies(id),
  person_id INTEGER REFERENCES people(id),
  won BOOLEAN DEFAULT FALSE,
  details JSONB,
  inserted_at TIMESTAMP,
  updated_at TIMESTAMP
);
```

### Step 2: Create New Ecto Schemas
Create these files:
- `lib/cinegraph/festivals/festival_ceremony.ex`
- `lib/cinegraph/festivals/festival_category.ex`
- `lib/cinegraph/festivals/festival_nomination.ex`

Each should be IDENTICAL to the Oscar version but with:
- Module name: `Cinegraph.Festivals.FestivalCeremony` (etc.)
- Table name: `festival_ceremonies` (etc.)
- Add field: `festival_type` with default "oscar"

### Step 3: Update FestivalDiscoveryWorker
Change these lines:
```elixir
# Line 23 - WRONG:
alias Cinegraph.Cultural.{OscarCeremony, OscarCategory, OscarNomination}

# CORRECT:
alias Cinegraph.Festivals.{FestivalCeremony, FestivalCategory, FestivalNomination}
```

Then update EVERY reference:
- `OscarCeremony` → `FestivalCeremony`
- `OscarCategory` → `FestivalCategory`
- `OscarNomination` → `FestivalNomination`

### Step 4: Update Cultural.ex
Change import functions to use festival tables:
```elixir
def import_oscar_year(year, options \\ []) do
  # Fetch/create in FESTIVAL_CEREMONIES table
  ceremony = Repo.get_by(FestivalCeremony, year: year, festival_type: "oscar")
  # ... rest stays the same but uses FestivalDiscoveryWorker
end
```

### Step 5: Update Dashboard 
The dashboard needs to query the NEW tables:
```elixir
# WRONG:
from(n in Cinegraph.Cultural.OscarNomination, ...)

# CORRECT:  
from(n in Cinegraph.Festivals.FestivalNomination, 
  where: n.ceremony.festival_type == "oscar", ...)
```

## Success Criteria - MUST MATCH EXACTLY

After migration, the dashboard MUST show:
```
Academy Awards Statistics
Ceremonies Imported: 6 (2016-2024)
Total Nominations: 489
Total Wins: 92
Categories: 21
People Nominations: 245/489 ✅  [THIS WAS MISSING]
2025 Wins: 14/80
2024 Wins: 15/82
2023 Wins: 16/82
2022 Wins: 16/83
2021 Wins: 16/83
2020 Wins: 15/79
```

## How To Verify Success

1. Import Oscar data for 2016-2024
2. Check `festival_ceremonies` table has 6 records with `festival_type = 'oscar'`
3. Check `festival_nominations` table has 489 records
4. Check dashboard shows EXACT same stats as before
5. Verify People Nominations stat shows correctly (245/489 with checkmark)

## What NOT To Do

1. DON'T get distracted by fuzzy matching improvements
2. DON'T change the import logic 
3. DON'T modify how data is processed
4. DON'T create new features

**JUST CHANGE WHICH TABLES THE DATA GOES INTO**

## Testing Commands

```bash
# Clear festival tables
PGPASSWORD=postgres psql -h 127.0.0.1 -p 54332 -U postgres -d postgres -c "
DELETE FROM festival_nominations;
DELETE FROM festival_categories;  
DELETE FROM festival_ceremonies;
"

# Import all Oscar years
mix run -e 'Cinegraph.Cultural.import_oscar_years(2016..2024)'

# Verify counts
PGPASSWORD=postgres psql -h 127.0.0.1 -p 54332 -U postgres -d postgres -c "
SELECT 
  (SELECT COUNT(*) FROM festival_ceremonies WHERE festival_type = 'oscar') as ceremonies,
  (SELECT COUNT(*) FROM festival_nominations) as nominations,
  (SELECT COUNT(*) FROM festival_nominations WHERE won = true) as wins,
  (SELECT COUNT(DISTINCT category_id) FROM festival_nominations) as categories;
"
```

Expected output: `ceremonies: 6, nominations: 489, wins: 92, categories: 21`

## Summary

This is a SIMPLE table migration:
1. Create new tables with same structure
2. Create new Ecto schemas pointing to new tables
3. Update worker to use new schemas
4. Update dashboard to query new tables
5. Add missing "People Nominations" stat
6. Verify exact same numbers appear

**Nothing else changes. Same logic. Same data. Different tables.**