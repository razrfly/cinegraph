# Issue #100: Fix Festival/Oscar Import - Port Missing Fuzzy Matching from Main Branch

## Executive Summary

The main branch Oscar import works perfectly, processing **all 120 nominees** from a ceremony. Our new festival-based implementation only processes **15 out of 120 nominees** because it lacks the sophisticated fuzzy matching fallback that the main branch has. We're only changing where data is stored (festival_* tables instead of oscar_* tables), but we lost critical functionality in the process.

## Current Problem

### What Works in Main Branch (OscarDiscoveryWorker)
- Processes **100% of nominees** (120/120 for 2024 ceremony)
- Has sophisticated fuzzy matching fallback (lines 351-674)
- Successfully handles nominees without IMDb IDs
- Creates movies for all Oscar nominees

### What's Broken in Our Version (FestivalDiscoveryWorker)
- Only processes **12.5% of nominees** (15/120 for 2024 ceremony)
- **MISSING: 323 lines of fuzzy matching code**
- Skips 105 nominees that don't have IMDb IDs
- Dashboard shows only 15 nominations instead of 80+

## Root Cause Analysis

### Main Branch Success Factors

The main branch `OscarDiscoveryWorker` (lines 351-674) includes:

1. **Fuzzy Search Fallback** (`attempt_fuzzy_search_fallback`)
   - Attempts to match nominees without IMDb IDs
   - Uses TMDb search API with intelligent matching
   - Creates movies even when IMDb ID is missing

2. **Country Name Mapping** (lines 608-636)
   - Maps country names to film titles for International Feature Film category
   - Example: "Denmark" → "Another Round" (2021)

3. **Title Similarity Matching** (lines 546-553)
   - Uses Jaro distance algorithm for fuzzy title matching
   - Normalizes titles for better comparison
   - Handles subtitles and special characters

4. **Local Database Search** (lines 394-460)
   - Searches existing movies by title before creating new ones
   - Prevents duplicates
   - Uses scoring algorithm to find best matches

5. **TMDb Search with Validation** (lines 462-528)
   - Searches TMDb with year constraints
   - Validates matches using multiple criteria
   - Falls back to search without year if needed

6. **Match Scoring Algorithm** (lines 530-544)
   - 60% weight: Title similarity
   - 30% weight: Year matching
   - 10% weight: Category validation
   - Bonus for high vote count

### Our Version's Deficiencies

Our `FestivalDiscoveryWorker` only has:
```elixir
# Line 144-148 - This is ALL we have for nominees without IMDb IDs
if is_nil(film_imdb_id) do
  Logger.info("No IMDb ID for #{film_title} - skipping")
  %{action: :skipped, reason: :no_imdb_id, title: film_title}
end
```

**We're missing the entire fuzzy matching system!**

## Detailed Code Comparison

### Main Branch Process Flow
```
Nominee → Has IMDb ID? → Yes → Create/Update Movie
                      ↓
                      No → Fuzzy Search Fallback
                           ↓
                           Try Local DB Search
                           ↓
                           Try TMDb Search
                           ↓
                           Score & Validate Matches
                           ↓
                           Create Movie with TMDb ID
```

### Our Broken Process Flow
```
Nominee → Has IMDb ID? → Yes → Create/Update Movie
                      ↓
                      No → Skip (105 out of 120 nominees!)
```

## Missing Functions to Port

### 1. Core Fuzzy Matching Function
```elixir
defp attempt_fuzzy_search_fallback(nominee, category_name, ceremony)
  # 42 lines of sophisticated fallback logic
  # Handles country names, searches local DB, searches TMDb
```

### 2. Local Database Search
```elixir
defp find_existing_movie_by_title(title, year)
defp title_match_acceptable?(movie_title, search_title, target_year, release_date)
defp find_best_local_match(movies, title, year)
```

### 3. TMDb Fuzzy Search
```elixir
defp fuzzy_search_movie(title, year, category_name)
defp find_best_match(results, original_title, target_year, category_name)
defp calculate_match_score(movie, original_title, target_year, category_name)
```

### 4. Title Processing
```elixir
defp calculate_title_similarity(movie_title, original_title)
defp normalize_title(title)
defp clean_title_for_search(title)
```

### 5. Supporting Functions
```elixir
defp calculate_year_score(release_date, target_year)
defp validate_category_match(movie, category_name)
defp extract_year(date_string)
defp is_country_name?(title)
defp map_country_to_film_title(country, year)
defp queue_movie_creation_by_tmdb(tmdb_id, nominee, category_name, ceremony)
```

## Statistics Proving the Issue

### Main Branch (Working)
- **2024 Ceremony**: 120 nominees processed
- **With IMDb IDs**: 15 nominees
- **Without IMDb IDs**: 105 nominees
- **Successfully processed via fuzzy matching**: 105
- **Total success rate**: 100%

### Our Version (Broken)
- **2024 Ceremony**: 120 nominees found
- **With IMDb IDs**: 15 nominees
- **Without IMDb IDs**: 105 nominees  
- **Skipped (no fuzzy matching)**: 105
- **Total success rate**: 12.5%

## Implementation Plan

### Step 1: Port Fuzzy Matching System
Copy the entire fuzzy matching system (lines 351-674) from `OscarDiscoveryWorker` to `FestivalDiscoveryWorker`, adapting for festival tables:
- `attempt_fuzzy_search_fallback/3`
- All supporting functions
- Jaro distance matching
- TMDb search integration

### Step 2: Adapt for Festival Tables
Change references from:
- `OscarNomination` → `FestivalNomination`
- `OscarCategory` → `FestivalCategory`
- `OscarCeremony` → `FestivalCeremony`

### Step 3: Maintain Modular Architecture
Ensure the fuzzy matching integrates with our worker chain:
- FestivalDiscoveryWorker processes and creates missing movies
- TMDbDetailsWorker still handles enrichment
- Keep the modular job spawning pattern

### Step 4: Test & Verify
- Import 2024 ceremony
- Verify all 120 nominees are processed
- Check dashboard shows correct counts
- Ensure movies are created with proper data

## Key Insight

**The only difference should be WHERE we store the data, not HOW we process it.** The main branch works perfectly because it has comprehensive fallback mechanisms. Our version fails because we gutted these mechanisms when creating the new worker.

## Success Criteria

1. **Process all 120 nominees** from 2024 ceremony (not just 15)
2. **Dashboard shows 80+ nominations** (not 0)
3. **Fuzzy matching creates movies** for nominees without IMDb IDs
4. **Maintain modular architecture** with workers spawning other workers
5. **Use festival_* tables** instead of oscar_* tables

## Code to Port

The exact code to port from `/lib/cinegraph/workers/oscar_discovery_worker.ex` lines 351-674:

```elixir
# This ENTIRE section is missing from our FestivalDiscoveryWorker
defp attempt_fuzzy_search_fallback(nominee, category_name, ceremony) do
  # ... 323 lines of sophisticated matching logic
end

# Plus all the supporting functions for:
# - Local database searching
# - TMDb API searching  
# - Title similarity scoring
# - Year matching
# - Category validation
# - Country name mapping
```

## Bottom Line

We have a working solution in the main branch. We just need to port the missing fuzzy matching code to our new festival-based worker. This isn't about guessing or trying new approaches - it's about taking what works perfectly and adapting it to use different database tables.

The main branch handles 100% of nominees. Our version handles 12.5%. The difference is 323 lines of fuzzy matching code that we failed to port over.