# Festival Tables Field Usage Audit

## Executive Summary

Analysis of the festival database tables reveals significant gaps in data population, particularly for ceremony metadata (name, date, location) and person linking in nominations. Several fields are either completely unused or could be enhanced.

## Current State Analysis

### Festival Ceremonies Table
- **Total Records**: 6 ceremonies (years 2020-2024)
- **Critical Issues**:
  - ❌ **name field**: 0/6 filled (completely empty)
  - ❌ **date field**: 0/6 filled (completely empty)  
  - ❌ **location field**: 0/6 filled (completely empty)
- **Well-populated fields**:
  - ✅ **data_source**: 6/6 filled ("official_website")
  - ✅ **source_url**: 6/6 filled 
  - ✅ **scraped_at**: 6/6 filled
  - ✅ **ceremony_number**: 6/6 filled (93, 94, 95, 96, 97)

### Festival Organizations Table  
- **Total Records**: 1 organization (AMPAS)
- **Status**: ✅ All fields properly populated
  - name: "Academy of Motion Picture Arts and Sciences"
  - abbreviation: "AMPAS" 
  - country: "USA"
  - founded_year: 1927
  - website: "https://www.oscars.org"

### Festival Categories Table
- **Total Records**: 29 categories
- **Status**: ✅ All core fields populated
  - name: 29/29 filled
  - category_type: 29/29 filled  
  - tracks_person: 19 true, 10 false

### Festival Nominations Table
- **Total Records**: 306 nominations
- **Critical Issues**:
  - ❌ **person_id**: 0/306 filled (no person linking despite 19 person-tracking categories)
  - ❌ **prize_name**: 0/306 filled (completely unused)
- **Well-populated fields**:
  - ✅ **movie_id**: 306/306 filled
  - ✅ **won**: 65 true, 241 false

## Root Cause Analysis

### 1. Oscar Scraper Limitations
The `OscarScraper` module extracts categories and nominees but **does not extract ceremony-level metadata**:

```elixir
defp extract_ceremony_data(document, year) do
  %{
    year: year,
    ceremony_number: extract_ceremony_number(document, year),
    categories: extract_categories(document),  # ✅ Works
    # ❌ Missing: ceremony name, date, location
    raw_html_parsed: true,
    timestamp: DateTime.utc_now()
  }
end
```

### 2. Person Linking Gap
The `FestivalDiscoveryWorker` identifies person-tracking categories but fails to link `person_id`:

```elixir
# Worker finds person IMDb IDs but doesn't create person records
person_id = if category && category.tracks_person && person_imdb_ids != [] do
  find_or_create_person(person_imdb_ids, nominee_name)  # Returns nil
else
  nil
end
```

## Recommendations

### High Priority (Should Fix)

1. **Ceremony Name Extraction** 
   - **Issue**: All ceremony names are empty
   - **Solution**: Enhance `OscarScraper` to extract ceremony titles like "96th Academy Awards"
   - **Effort**: Medium (modify scraper selectors)

2. **Ceremony Date Extraction**
   - **Issue**: All ceremony dates are empty  
   - **Solution**: Extract date from ceremony pages or use external data
   - **Effort**: Medium (scraper enhancement or data lookup)

3. **Person Linking for Nominations**
   - **Issue**: 0/306 nominations have `person_id` despite person-tracking categories
   - **Solution**: Implement person creation/linking in `FestivalDiscoveryWorker`
   - **Effort**: High (requires TMDb person API integration)

### Medium Priority (Consider for Future)

4. **Ceremony Location**
   - **Issue**: All locations empty
   - **Solution**: Add location extraction (usually "Dolby Theatre, Hollywood")
   - **Effort**: Low (mostly static data for Oscars)

### Low Priority (Evaluate Usage)

5. **Prize Name Field**
   - **Issue**: Completely unused (0/306)
   - **Decision**: Keep for future non-Oscar festivals or remove if unnecessary
   - **Effort**: Low (schema change if removing)

## Implementation Plan

### Phase 1: Ceremony Metadata Enhancement
1. Update `OscarScraper.extract_ceremony_data/2` to extract:
   - Ceremony name from page title/header
   - Ceremony date (if available)
   - Ceremony location (default to "Dolby Theatre" for recent years)

### Phase 2: Person Linking
1. Implement person creation in `FestivalDiscoveryWorker.find_or_create_person/2`
2. Add TMDb person API calls for missing person data
3. Link existing person records by IMDb ID

### Phase 3: Data Backfill
1. Re-scrape existing ceremonies to populate metadata
2. Run person linking jobs for existing nominations

## Questions for Stakeholder

1. **Priority**: Which missing fields are most important for the application?
2. **Person Data**: Should we create person records immediately or queue separate jobs?
3. **Prize Names**: Is this field needed for non-Oscar festivals, or can we remove it?
4. **Location Strategy**: Static data for Oscar venues or dynamic scraping?

## Schema Change Considerations

If we decide certain fields are unnecessary, we could:
- Remove `prize_name` if truly unused
- Make `date` and `location` nullable but populate where possible
- Add validation to ensure ceremony `name` is always populated