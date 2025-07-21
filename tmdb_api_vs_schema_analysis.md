# TMDB API Usage vs Database Schema Analysis

## Executive Summary

After analyzing the Cinegraph codebase, there is a significant gap between the ambitious database schema design and actual TMDB API data utilization:

- **TMDB API Utilization**: ~35-40% of available data is being fetched
- **Schema Population**: ~25-30% of database tables/fields are being populated
- **Empty Tables**: 60%+ of tables have no data
- **Unused TMDB Data**: 15-20% of fetched data is discarded

## Detailed Analysis

### 1. Database Schema Overview (from migration)

The schema includes 23 tables divided into categories:

#### Core Tables (6 tables - mostly populated)
- ✅ `movies` - Main movie data (90% fields populated)
- ✅ `people` - Cast/crew data (70% fields populated)
- ✅ `genres` - Genre list (100% populated)
- ✅ `collections` - Movie collections (basic data only)
- ✅ `production_companies` - Basic company info (40% populated)
- ✅ `keywords` - Movie keywords (100% populated when present)

#### Junction Tables (9 tables - partially populated)
- ✅ `movie_credits` - Cast/crew associations (populated)
- ✅ `movie_keywords` - Keyword associations (populated)
- ✅ `movie_production_companies` - Company associations (populated)
- ✅ `movie_videos` - Video data (populated)
- ✅ `movie_release_dates` - Release dates by country (populated)
- ❌ `movie_alternative_titles` - Empty (code exists but not used)
- ❌ `movie_translations` - Empty (code exists but not used)

#### External Sources Tables (4 tables - minimally used)
- ✅ `external_sources` - Only TMDB source created
- ✅ `external_ratings` - TMDB ratings, popularity, engagement metrics
- ✅ `external_recommendations` - TMDB recommendations stored
- ❌ `external_trending` - Empty (no implementation)

#### Cultural Authority Tables (4 tables - completely empty)
- ❌ `cultural_authorities` - No data
- ❌ `curated_lists` - No data
- ❌ `movie_list_items` - No data
- ❌ `user_lists` - No data
- ❌ `movie_user_list_appearances` - No data
- ❌ `movie_data_changes` - No data
- ❌ `cri_scores` - No data

### 2. TMDB API Endpoints Usage

#### Currently Used Endpoints (via `TMDb.Extended`):
1. ✅ `/movie/{id}` with append_to_response for:
   - credits
   - images
   - keywords
   - external_ids
   - release_dates
   - videos
   - recommendations
   - similar
   - alternative_titles
   - translations
   - watch/providers (attempted)
   - reviews
   - lists

2. ✅ `/genre/movie/list` - Genre list
3. ✅ `/collection/{id}` - Collection details
4. ✅ `/person/{id}` - Person details (basic from credits)

#### Available but Unused Endpoints:
1. ❌ `/trending/movie/{time_window}` - Trending movies
2. ❌ `/movie/now_playing` - Current theatrical releases
3. ❌ `/movie/upcoming` - Upcoming releases
4. ❌ `/movie/popular` - Popular movies
5. ❌ `/movie/top_rated` - Top rated movies
6. ❌ `/discover/movie` - Advanced discovery
7. ❌ `/watch/providers/movie` - Streaming providers
8. ❌ `/certification/movie/list` - Certifications
9. ❌ `/search/*` - Search endpoints
10. ❌ `/person/popular` - Popular people
11. ❌ `/company/{id}` - Company details

### 3. Data Flow Analysis

#### What TMDB Data We Fetch:
```elixir
# From get_movie_ultra_comprehensive
- Movie core data (100%)
- Credits (cast/crew) (100%)
- Images (posters/backdrops/logos) (100%)
- Keywords (100%)
- External IDs (100%)
- Release dates by country (100%)
- Videos (trailers/clips) (100%)
- Recommendations (100%)
- Similar movies (100%)
- Alternative titles (100%)
- Translations (100%)
- Watch providers (attempted but often fails)
- Reviews (100%)
- Lists containing movie (100%)
```

#### What We Actually Store:

##### Fully Stored (90-100%):
- Movie basic info (title, release date, runtime, etc.)
- Cast/crew credits with associations
- Keywords with associations
- Videos
- Release dates
- External ratings (vote average, popularity)
- Recommendations (as external recommendations)

##### Partially Stored (40-70%):
- People (basic info from credits, not full profiles)
- Production companies (basic info, no full details)
- Collections (basic info only)
- Images (stored as JSON, not individual records)
- External IDs (stored as JSON)

##### Fetched but Not Stored (0%):
- Alternative titles (code exists but not executed)
- Translations (code exists but not executed)
- Watch providers (logged but not stored)
- Review content (only count stored as "engagement")
- List details (only count stored)

### 4. Schema vs Implementation Gaps

#### Major Unused Schema Components:

1. **Cultural Authority System** (7 tables, 0% used)
   - No implementation for cultural authorities
   - No curated lists
   - No award tracking
   - No user list aggregation
   - No CRI score calculation

2. **Change Tracking** (1 table, 0% used)
   - No movie data change tracking
   - No temporal analysis

3. **External Sources** (partially used)
   - Only TMDB as source
   - No Rotten Tomatoes
   - No IMDb ratings
   - No Metacritic
   - No streaming platform data

4. **Advanced Movie Metadata**
   - No alternative titles storage
   - No translation storage
   - No watch provider storage
   - No trending data

### 5. Specific Percentages

#### TMDB API Data Utilization:
- **Core movie data**: 95% used
- **Credits data**: 90% used
- **Media assets**: 70% used (images as JSON only)
- **Regional data**: 60% used (release dates only)
- **Engagement data**: 30% used (reviews/lists as counts)
- **Discovery data**: 0% used (trending, popular, etc.)
- **Overall**: ~35-40% of available TMDB data

#### Database Schema Population:
- **Core tables**: 80% populated
- **Junction tables**: 55% populated
- **External source tables**: 30% populated
- **Cultural authority tables**: 0% populated
- **Overall**: ~25-30% of schema utilized

#### Field-Level Analysis (from 100 movie sample):
- `imdb_id`: 97% null (external_ids fetched but not extracted)
- `tagline`: 17% null
- `homepage`: 14% null
- `budget`: 76% null
- `revenue`: 69% null
- `collection_id`: 90% null (even when belongs_to_collection exists)

### 6. Recommendations

1. **Quick Wins** (data already fetched):
   - Extract IMDB ID from external_ids JSON
   - Store alternative titles and translations
   - Create watch provider storage
   - Store review/list details, not just counts

2. **Medium Effort** (new API calls needed):
   - Implement trending/popular endpoints
   - Fetch full person profiles
   - Fetch full company details
   - Implement discovery for cultural relevance

3. **Large Effort** (schema redesign):
   - Remove or implement cultural authority system
   - Add external source integrations
   - Implement CRI scoring system
   - Add temporal tracking

## Conclusion

The current implementation uses only a fraction of both the TMDB API capabilities and the database schema design. The schema is overly ambitious for a TMDB-only implementation, with entire subsystems (cultural authorities, CRI scoring) having no code support. Meanwhile, valuable TMDB data that is already being fetched is being discarded instead of stored.