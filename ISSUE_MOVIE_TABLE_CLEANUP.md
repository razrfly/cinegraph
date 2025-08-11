# Movie Table Cleanup: Separate External and Subjective Data

## Summary
The `movies` table currently contains a mix of core movie attributes and external/subjective data from various sources (TMDb, OMDb). This issue proposes reorganizing the data structure to clearly separate:
1. **Core/Immutable Movie Data** - Facts that don't change (title, release date, runtime)
2. **External Source Data** - Data from APIs with clear source attribution and timestamps
3. **Subjective/Volatile Data** - Ratings, votes, popularity that changes over time

## Current Problems

### 1. Mixed Data Sources Without Attribution
The following fields in the `movies` table come from external sources but lack clear attribution:
- `budget` - Source: TMDb (may be estimates, not always accurate)
- `revenue` - Source: TMDb (may be estimates, not always accurate)
- `vote_average` - Source: TMDb (changes frequently)
- `vote_count` - Source: TMDb (changes frequently)
- `popularity` - Source: TMDb (changes daily)
- `awards_text` - Source: OMDb
- `box_office_domestic` - Source: OMDb

### 2. No Update Tracking
Volatile fields that need regular updates have no timestamp tracking:
- When was `vote_count` last updated?
- When was `popularity` last refreshed?
- Is the `box_office_domestic` figure from 2023 or 2024?

### 3. Unclear Data Quality
- Which budget/revenue figures are verified vs estimates?
- Are box office numbers domestic only or worldwide?
- What's the source and date for each data point?

## Audit of Current Movie Table Fields

### ✅ Core Movie Attributes (Keep in movies table)
These are factual, immutable attributes that define the movie itself:
- `id` - Internal primary key
- `tmdb_id` - External identifier
- `imdb_id` - External identifier  
- `title` - Core attribute
- `original_title` - Core attribute
- `release_date` - Core attribute (primary release)
- `runtime` - Core attribute
- `overview` - Core description
- `tagline` - Core marketing text
- `original_language` - Core attribute
- `status` - Production status (Released, Post Production, etc.)
- `adult` - Content rating flag
- `homepage` - Official website
- `collection_id` - Franchise association
- `poster_path` - Primary poster image
- `backdrop_path` - Primary backdrop image
- `origin_country` - Production countries
- `import_status` - Internal tracking

### ⚠️ External Data (Consolidate into existing external_ratings table)

**Current problematic fields in movies table:**
- `budget` - From TMDb, often estimated
- `revenue` - From TMDb, often estimated  
- `box_office_domestic` - From OMDb
- `vote_average` - From TMDb, changes frequently
- `vote_count` - From TMDb, changes frequently
- `popularity` - From TMDb, changes daily

**Current external_ratings table structure:**
```elixir
# Already supports:
- rating_type: "user", "critic", "algorithm", "popularity", "engagement", 
                "list_appearances", "box_office", "imdb_votes"
- value: float
- scale_min/scale_max: for different rating scales
- metadata: JSONB for additional data
- fetched_at: timestamp tracking
```

**Proposed approach: Extend external_ratings to handle ALL external metrics**

Instead of creating new tables, we can use the existing `external_ratings` table more broadly:

1. **For financial data**, use rating_type = "box_office" with metadata:
   ```elixir
   %{
     rating_type: "box_office",
     value: 100_000_000.0,  # Use value for primary metric
     metadata: %{
       "budget" => 50_000_000,
       "revenue_worldwide" => 100_000_000,
       "revenue_domestic" => 40_000_000,
       "opening_weekend" => 15_000_000,
       "currency" => "USD",
       "is_estimate" => true
     }
   }
   ```

2. **For popularity metrics**, use existing types or add new ones:
   ```elixir
   # Separate records for each metric type
   %{rating_type: "popularity", value: 45.678, ...}
   %{rating_type: "user", value: 7.5, metadata: %{"vote_count" => 12000}, ...}
   ```

3. **Advantages of this approach:**
   - Uses existing infrastructure
   - Already has source attribution via source_id
   - Already has fetched_at timestamps
   - Can track historical data (multiple records with different fetched_at)
   - Flexible metadata JSONB field for source-specific data
   - One less table to maintain
   - **Extremely flexible** - new data types just need a new rating_type string
   - No schema changes needed when APIs add new fields
   - Can handle any external data source without table modifications

### ⚠️ Awards Data (Enhance existing structure or move)
**Current fields:**
- `awards_text` - From OMDb, unstructured text
- `awards` - Structured but rarely used

**Options:**
1. Remove from movies table entirely, rely on festival_nominations and oscar_nominations tables
2. Create a dedicated awards summary table
3. Keep structured `awards` JSONB but remove `awards_text`

### ❓ Fields Needing Review
- `canonical_sources` - Currently a JSONB field, mostly empty
  - **Question:** Are we actively using this? Should it be a separate table?
  - **Current usage:** Tracks which canonical lists include this movie
  - **Recommendation:** Keep but document usage clearly

- `tmdb_data` - Raw API response storage
  - **Question:** Do we need the full response or just extracted fields?
  - **Recommendation:** Keep for debugging but consider archival strategy

- `omdb_data` - Raw API response storage  
  - **Question:** Same as above
  - **Recommendation:** Keep for debugging but consider archival strategy

## Proposed Solution - Simplified Approach

### Use Existing Tables Better
Instead of creating new tables, leverage what we already have:

1. **external_ratings** table becomes our universal external metrics table
2. **external_recommendations** stays as is for movie-to-movie relationships
3. **Movies table** keeps only core, immutable data

### Phase 1: Extend external_ratings usage
1. Add new rating_types as needed: "budget", "revenue", "tmdb_popularity", "tmdb_votes"
2. Use the `metadata` JSONB field for additional context
3. Use `value` field for the primary metric, metadata for breakdowns

### Phase 2: Migration Strategy
1. Migrate current movie table fields to external_ratings records:
   - `budget` → rating_type: "budget"
   - `revenue` → rating_type: "revenue"  
   - `vote_average` + `vote_count` → rating_type: "user" with metadata
   - `popularity` → rating_type: "popularity"
   - `box_office_domestic` → rating_type: "box_office" with metadata
2. Set `fetched_at` to movies.updated_at as best guess
3. Keep original fields temporarily for backward compatibility

### Phase 3: Update Import Pipeline
1. Modify TMDb importer to create external_ratings records
2. Modify OMDb importer to create external_ratings records
3. Stop updating volatile fields in movies table

### Phase 4: Cleanup
1. Remove migrated fields from movies table
2. Update all queries to join with external_ratings
3. Create views for common access patterns

## Benefits

1. **Clear Data Provenance** - Know exactly where each data point came from
2. **Update Tracking** - Know when data was last refreshed
3. **Historical Trends** - Track popularity changes over time
4. **Data Quality** - Distinguish estimates from verified figures
5. **Selective Updates** - Update metrics without touching core movie data
6. **Smaller Core Table** - Faster queries on essential movie attributes

## Questions for Discussion

1. Should we rename `external_ratings` to `external_metrics` or `external_data` to better reflect its expanded purpose?
2. Should we keep historical metrics or just the latest?
3. How often should we refresh popularity metrics? Daily? Weekly?
4. Should we extend the rating_type enum or keep it flexible as a string?
5. Do we need the full `tmdb_data` and `omdb_data` JSON blobs long-term?
6. How should we handle awards data given we have dedicated awards tables?

## Implementation Priority

**High Priority:**
- Move volatile metrics (vote_*, popularity) - these change most frequently
- Add proper timestamps for external data

**Medium Priority:**
- Reorganize financial data with source attribution
- Create historical tracking for metrics

**Low Priority:**
- Optimize storage of raw API responses
- Clean up unused fields

## Related Issues
- #204 - Broader discussion of external data organization