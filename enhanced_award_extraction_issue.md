# Enhanced Award Extraction for Festival Lists

## Problem Statement

Our current canonical list scraper works perfectly for basic movie data (title, year, position), but when `tracks_awards = true`, we're missing the specific award information that appears in IMDB lists.

**Current State:**
```json
{
  "cannes_winners": {
    "included": true,
    "list_position": 1,
    "scraped_title": "Anatomy of a Fall", 
    "scraped_year": 2023,
    "tracks_awards": true
  }
}
```

**We Know:** The movie won at Cannes  
**We Don't Know:** What specific award it won

## What We Need

When `tracks_awards = true`, extract the award-specific text that appears below each movie in IMDB lists.

**Example from Cannes IMDB List:**
```
1. Anatomy of a Fall
   2023 2h 31m R 86 Metascore 7.6 (180K)
   A woman is suspected of murder after her husband's death...
   Director: Justine Triet Stars: Sandra Hüller...
   [2023]: Palme d'Or winner (Best Film).    ← THIS IS WHAT WE WANT

2. The Zone of Interest  
   2023 1h 45m PG-13 92 Metascore 7.3 (138K)
   Auschwitz commandant Rudolf Höss...
   Director: Jonathan Glazer...
   Grand Prix                                ← AND THIS

3. Fallen Leaves
   2023 1h 21m Unrated 86 Metascore 7.3 (34K)  
   In modern-day Helsinki, two lonely souls...
   Director: Aki Kaurismäki...
   Jury Prize                               ← AND THIS
```

## Proposed Enhanced JSON Structure

```json
{
  "cannes_winners": {
    "included": true,
    "list_position": 1,
    "scraped_title": "Anatomy of a Fall",
    "scraped_year": 2023,
    "tracks_awards": true,
    
    // NEW: Award-specific fields when tracks_awards = true
    "award_text": "[2023]: Palme d'Or winner (Best Film).",
    "extracted_awards": [
      {
        "award_name": "Palme d'Or",
        "award_category": "Best Film", 
        "award_year": "2023",
        "raw_text": "[2023]: Palme d'Or winner (Best Film)."
      }
    ],
    "description": "A woman is suspected of murder after her husband's death; their half-blind son faces a moral dilemma as the main witness.",
    "director": "Justine Triet",
    "stars": ["Sandra Hüller", "Swann Arlaud", "Milo Machado-Graner"]
  }
}
```

## Implementation Plan

### Phase 1: Basic Award Text Extraction
1. **Modify `extract_enhanced_lister_data()`** to capture award-specific text
2. **Update award text patterns** to match IMDB list format:
   - `[YYYY]: Award Name (Category).`
   - `Grand Prix`
   - `Jury Prize` 
   - `Caméra d'Or (Best First Feature Film).`

### Phase 2: Structured Award Parsing  
3. **Parse award text into structured data** for database storage
4. **Validate against `award_types`** column in `movie_lists` table
5. **Store both raw text and parsed awards** for flexibility

### Phase 3: Integration with Issue #100
6. **Map extracted awards** to unified festival system tables
7. **Create award categories** from parsed data
8. **Populate festival nominations** with winners

## Technical Details

### HTML Parsing Strategy
Based on the provided IMDB HTML, award information appears in several patterns:
- Bracketed format: `[2023]: Palme d'Or winner (Best Film).`
- Simple format: `Grand Prix`, `Jury Prize`
- Detailed format: `Caméra d'Or (Best First Feature Film).`

### CSS Selectors to Target
- `.text-small` - Often contains award text
- `p` elements following movie metadata
- Text patterns after director/stars information

### Database Integration
- Use existing `tracks_awards` boolean to trigger enhanced extraction
- Leverage `award_types` array to validate extracted awards
- Store in `canonical_sources` JSONB for Issue #100 processing

## Success Criteria

1. ✅ **Award text captured** for movies where `tracks_awards = true`
2. ✅ **Structured award data** available for database insertion 
3. ✅ **Backwards compatible** - doesn't break existing functionality
4. ✅ **Ready for Issue #100** - provides data needed for unified festival system

## Files to Modify

- `lib/cinegraph/scrapers/imdb_canonical_scraper.ex` - Enhanced extraction logic
- Award parsing patterns and structured data extraction
- Integration with existing `tracks_awards` workflow

## Next Steps

1. **Implement enhanced extraction** for award text capture
2. **Test with Cannes list** to verify data quality  
3. **Re-import Cannes data** with enhanced extraction
4. **Proceed with Issue #100** using the captured award data