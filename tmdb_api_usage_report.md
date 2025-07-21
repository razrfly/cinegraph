# TMDB API Usage vs Database Schema Analysis

## Executive Summary

**Overall Database Utilization: ~25-30%**
**TMDB API Utilization: ~35-40%**

## Detailed Breakdown

### 1. Tables Usage Status

#### ✅ Fully Populated Tables (10/23 = 43%)
- `movies` - Core movie data
- `people` - Cast and crew 
- `movie_credits` - Cast/crew associations
- `keywords` - Movie keywords
- `movie_keywords` - Keyword associations
- `movie_videos` - Trailers and clips
- `movie_release_dates` - Release info by country
- `production_companies` - Production company data
- `movie_production_companies` - Company associations
- `external_sources` - Source configuration (1 record: TMDB)
- `external_ratings` - Aggregate metrics (reviews, lists, ratings)

#### ❌ Empty Tables (13/23 = 57%)
- `collections` - Movie collections (e.g., "The Godfather Collection")
- `movie_alternative_titles` - Alternative titles by region
- `movie_translations` - Translated overviews
- `external_trending` - Trending data tracking
- `cultural_authorities` - Award bodies, critics, etc.
- `curated_lists` - AFI 100, Oscars, etc.
- `movie_list_items` - Movie appearances on lists
- `user_lists` - User-created TMDB lists
- `movie_user_list_appearances` - TMDB list tracking
- `movie_data_changes` - Change tracking
- `cri_scores` - Cultural Relevance Index scores

### 2. TMDB API Endpoints Usage

#### ✅ Used Endpoints
```elixir
# From TMDb.get_movie_ultra_comprehensive/1
append_to_response: "credits,images,keywords,external_ids,release_dates,
                     videos,recommendations,similar,alternative_titles,
                     translations,watch/providers,reviews,lists"
```

#### ❌ Unused Endpoints (Defined but Never Called)
- `get_trending/2` - Trending movies
- `get_now_playing/1` - Currently in theaters
- `get_upcoming/1` - Upcoming releases  
- `get_popular/1` - Popular movies
- `get_top_rated/1` - Top rated movies
- `discover_movies/1` - Advanced search/filter
- `search_movies/2` - Text search
- `get_person_comprehensive/1` - Full person details
- `get_collection/1` - Collection details
- `get_watch_provider_regions/0` - Watch regions
- `get_certifications/0` - Rating systems

### 3. Data Processing Gaps

#### 🟡 Fetched but Not Stored
| Data Type | Status | Issue |
|-----------|---------|--------|
| Alternative Titles | Fetched ✅ Stored ❌ | Function exists but unused |
| Translations | Fetched ✅ Stored ❌ | Function exists but unused |
| Watch Providers | Fetched ⚠️ Stored ❌ | Prints count, no storage |
| Collection Details | Fetched ✅ Stored ❌ | Gets data but doesn't link |
| Individual Reviews | Fetched ✅ Stored 🟡 | Only counts stored |
| Individual Lists | Fetched ✅ Stored 🟡 | Only counts stored |

#### 🔴 Schema Fields with No Data Source
| Field | Table | Issue |
|-------|-------|-------|
| `imdb_id` | movies | In external_ids but not extracted (97% null) |
| `homepage` | movies | Available but not stored |
| `collection_id` | movies | Available but not linked |
| `production_company_ids` | movies | Array field unused |
| All fields | cultural_authorities | No implementation |
| All fields | curated_lists | No implementation |
| All fields | cri_scores | No implementation |

### 4. Actual vs Planned Implementation

#### What We Built
- Basic TMDB movie importer
- Cast/crew tracking
- Keyword extraction
- Video/trailer storage
- Release date tracking
- Aggregate metrics (review counts, list counts)

#### What We Planned But Didn't Build
- Multi-source data aggregation
- Cultural authority integration
- Award tracking system
- Curated list management
- CRI scoring algorithm
- Trending analysis
- User list tracking
- Change detection system
- Watch provider integration

### 5. Quick Wins (Easy Improvements)

1. **Extract IMDB ID** (1 line change)
   ```elixir
   imdb_id: tmdb_data["external_ids"]["imdb_id"]
   ```

2. **Store Alternative Titles** (Function exists, just call it)
   ```elixir
   :ok <- process_movie_alternative_titles(movie, tmdb_data["alternative_titles"])
   ```

3. **Store Translations** (Function exists, just call it)
   ```elixir
   :ok <- process_movie_translations(movie, tmdb_data["translations"])
   ```

4. **Link Collections** (Data fetched, needs linking)
   ```elixir
   collection_id: collection.id
   ```

5. **Store Homepage** (Field exists, data available)
   ```elixir
   homepage: tmdb_data["homepage"]
   ```

### 6. API Cost Analysis

You're making expensive "ultra_comprehensive" calls but throwing away ~20% of the data:
- Each movie = 1 API call with 13 appended resources
- Alternative titles: Fetched for 100% movies, stored for 0%
- Translations: Fetched for 100% movies, stored for 0%
- Watch providers: Attempted for 100% movies, stored for 0%

### 7. Recommendations

**Immediate Actions:**
1. Implement the 5 quick wins above
2. Create schemas for alternative titles and translations
3. Fix watch provider storage
4. Extract and store IMDB IDs

**Medium Term:**
1. Implement trending/popular movie fetching
2. Build basic CRI scoring with existing data
3. Add person biography fetching
4. Implement collection linking

**Long Term:**
1. Design external source integration beyond TMDB
2. Build cultural authority system
3. Implement award tracking
4. Create list curation system

## Conclusion

The current implementation uses only **~30% of the database schema** and **~40% of TMDB's capabilities**. The ambitious multi-source cultural relevance engine has devolved into a basic TMDB data importer that discards significant amounts of fetched data.

The good news: Many improvements are trivial to implement since the data is already being fetched.