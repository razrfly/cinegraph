# OMDb Data Analysis

## Current Storage Status

### ✅ Data We ARE Storing:

1. **Ratings** (stored in `external_ratings` table):
   - IMDb Rating (9.3/10)
   - Metacritic Score (82/100) 
   - Rotten Tomatoes Score (89%)
   - IMDb Vote Count (as popularity metric)
   - Box Office (when available)
   - Source tracking (via source_id and metadata)

2. **Awards** (stored in `external_ids.omdb_awards`):
   - Raw awards text
   - Oscar wins count
   - Total wins count
   - Total nominations count
   - Has Oscars flag

### ❌ Data We're NOT Storing from OMDb:

1. **Basic Movie Info** (duplicates TMDb data):
   - Title, Year, Plot - Already have from TMDb
   - Runtime, Released date - Already have from TMDb
   - Genre, Language, Country - Already have from TMDb
   
2. **Additional Metadata We Could Store**:
   - **MPAA Rating** (e.g., "R", "PG-13") - Useful for content filtering
   - **Director** - String of director names
   - **Writer** - String of writer names
   - **Actors** - String of main actors
   - **Poster URL** - OMDb's poster URL (different from TMDb)
   - **Production Company** - Production info string
   - **DVD Release Date** - When available
   - **Website** - Official movie website

3. **Rotten Tomatoes Extended Data** (when tomatoes=true):
   - Currently getting "N/A" for most fields
   - Could store tomatoURL when available

## Recommendations:

1. **Add MPAA Rating** - Store in movies table or metadata
2. **Store full OMDb response** - Keep raw response in metadata for future use
3. **Parse awards text better** - Extract specific award names (Golden Globe, BAFTA, etc.)
4. **Add data source timestamp** - Track when data was fetched from each source

## Source Tracking Enhancement:

Currently tracking source via:
- `source_id` links to "tmdb" or "OMDb" 
- `metadata["source_name"]` shows "IMDb", "Metacritic", etc.

Could improve by:
- Adding `fetched_via` field to show API source
- Adding `original_source` for data origin (e.g., IMDb data via OMDb API)