# TMDB API Comprehensive Audit - Final Check

## Executive Summary

This is a final comprehensive audit of TMDB's API v3 against Cinegraph's current implementation to ensure we have identified all endpoints and data that could be valuable for the Cultural Relevance Index (CRI) calculations. This audit covers all endpoint categories and evaluates their importance for CRI.

## 1. /movie/{id} Endpoints Audit

### ✅ Currently Captured

| Endpoint | Data Provided | Status | CRI Critical |
|----------|---------------|---------|--------------|
| `/movie/{movie_id}` | Basic movie details | ✅ Implemented | Yes |
| `/movie/{movie_id}/credits` | Cast & crew | ✅ via append_to_response | Yes |
| `/movie/{movie_id}/images` | Posters, backdrops, logos | ✅ via append_to_response | Medium |
| `/movie/{movie_id}/keywords` | Movie keywords/tags | ✅ via append_to_response | Yes |
| `/movie/{movie_id}/external_ids` | IMDb, Facebook, Instagram, Twitter | ✅ via append_to_response | Medium |
| `/movie/{movie_id}/release_dates` | Release dates & certifications by country | ✅ via append_to_response | Yes |
| `/movie/{movie_id}/videos` | Trailers, teasers, clips | ✅ via append_to_response | Medium |
| `/movie/{movie_id}/recommendations` | TMDb's recommended movies | ✅ via append_to_response | Yes |
| `/movie/{movie_id}/similar` | Similar movies | ✅ via append_to_response | Yes |
| `/movie/{movie_id}/alternative_titles` | Titles in different countries | ✅ via append_to_response | Medium |
| `/movie/{movie_id}/translations` | Translated data | ✅ via append_to_response | Medium |

### ❌ NOT Captured (Critical for CRI)

| Endpoint | Data Provided | Schema Change Required | CRI Critical |
|----------|---------------|------------------------|--------------|
| `/movie/{movie_id}/watch/providers` | Streaming availability by country | New table: `movie_watch_providers` | **HIGH** |
| `/movie/{movie_id}/reviews` | User reviews with ratings | New table: `movie_reviews` | **HIGH** |
| `/movie/{movie_id}/lists` | Lists containing this movie | New table: `movie_lists` | Medium |
| `/movie/{movie_id}/changes` | Change history | New table: `movie_changes` | Low |
| `/movie/{movie_id}/account_states` | User-specific data (rated, watchlist) | Requires auth | Low |

## 2. /person/{id} Endpoints Audit

### ✅ Currently Captured

| Endpoint | Data Provided | Status | CRI Critical |
|----------|---------------|---------|--------------|
| `/person/{person_id}` | Basic person details | ✅ Implemented | Yes |
| `/person/{person_id}/images` | Profile images | ✅ via append_to_response | Low |
| `/person/{person_id}/external_ids` | Social media IDs | ✅ via append_to_response | Medium |
| `/person/{person_id}/combined_credits` | All movie/TV credits | ✅ via append_to_response | Yes |

### ❌ NOT Captured

| Endpoint | Data Provided | Schema Change Required | CRI Critical |
|----------|---------------|------------------------|--------------|
| `/person/{person_id}/movie_credits` | Movie-only credits | No (use combined_credits) | Low |
| `/person/{person_id}/tv_credits` | TV-only credits | No (use combined_credits) | Low |
| `/person/{person_id}/tagged_images` | Tagged photos | New table: `person_tagged_images` | Low |
| `/person/{person_id}/changes` | Change history | New table: `person_changes` | Low |
| `/person/popular` | Popular people list | Use `external_trending` | **HIGH** |
| `/person/latest` | Latest added person | No | Low |

## 3. /search Endpoints Audit

### ✅ Currently Captured

| Endpoint | Data Provided | Status | CRI Critical |
|----------|---------------|---------|--------------|
| `/search/movie` | Movie search | ✅ Implemented | Yes |

### ❌ NOT Captured

| Endpoint | Data Provided | Schema Change Required | CRI Critical |
|----------|---------------|------------------------|--------------|
| `/search/person` | Person search | No | Medium |
| `/search/company` | Company search | No | Low |
| `/search/keyword` | Keyword search | No | Low |
| `/search/collection` | Collection search | No | Low |
| `/search/multi` | Multi-entity search | No | Medium |
| `/search/tv` | TV show search | New tables for TV | Low |

## 4. /discover Endpoints Audit

### ✅ Currently Captured

| Endpoint | Data Provided | Status | CRI Critical |
|----------|---------------|---------|--------------|
| `/discover/movie` | Advanced movie discovery | ✅ Implemented (basic filters) | Yes |

### ⚠️ Partially Captured

The discover endpoint supports 30+ filters, but we only use:
- `page`, `sort_by`, `year`, `vote_count.gte`, `vote_average.gte`

### Missing Discover Filters (No Schema Change Required)

| Filter | Description | CRI Critical |
|--------|-------------|--------------|
| `with_genres` | Filter by genre IDs | **HIGH** |
| `with_keywords` | Filter by keyword IDs | **HIGH** |
| `with_companies` | Filter by company IDs | Medium |
| `with_people` | Filter by person IDs | **HIGH** |
| `with_crew` | Filter by crew member IDs | Medium |
| `with_cast` | Filter by cast member IDs | **HIGH** |
| `primary_release_date.gte/lte` | Release date range | **HIGH** |
| `with_original_language` | Filter by language | **HIGH** |
| `with_watch_providers` | Filter by streaming service | **HIGH** |
| `watch_region` | Watch provider region | **HIGH** |
| `with_runtime.gte/lte` | Runtime range | Medium |
| `region` | Release region | Medium |
| `certification` | Content rating | Medium |
| `certification_country` | Certification region | Medium |

## 5. Additional Endpoints Audit

### ❌ NOT Captured (High Value)

| Endpoint Category | Endpoints | Schema Change Required | CRI Critical |
|-------------------|-----------|------------------------|--------------|
| **Trending** | `/trending/movie/{time_window}` | Use `external_trending` | **HIGH** |
| | `/trending/person/{time_window}` | Use `external_trending` | **HIGH** |
| | `/trending/all/{time_window}` | Use `external_trending` | Medium |
| **Now Playing/Upcoming** | `/movie/now_playing` | New table: `movie_now_playing` | **HIGH** |
| | `/movie/upcoming` | New table: `movie_upcoming` | **HIGH** |
| **Certifications** | `/certification/movie/list` | New table: `certifications` | Medium |
| **Watch Providers** | `/watch/providers/movie` | New table: `watch_providers` | **HIGH** |
| | `/watch/providers/regions` | New table: `watch_provider_regions` | Medium |
| **Genres** | `/genre/movie/list` | ✅ Have table, not fetching | **HIGH** |
| **Configuration** | `/configuration` | New table: `tmdb_configuration` | Medium |
| | `/configuration/countries` | New table: `countries` | Low |
| | `/configuration/languages` | New table: `languages` | Low |
| | `/configuration/timezones` | No | Low |

## 6. Critical Missing Data for CRI

### 🚨 Top Priority Missing Data

1. **Watch Providers** (`/movie/{id}/watch/providers`)
   - **Why Critical**: Streaming availability directly impacts cultural reach
   - **Schema Change**: Add `movie_watch_providers` table
   - **Data**: Provider name, type (stream/rent/buy), regions, URLs

2. **Trending Data** (`/trending/movie/{time_window}`)
   - **Why Critical**: Real-time popularity metrics
   - **Schema Change**: Already have `external_trending` table
   - **Data**: Daily/weekly trending ranks and scores

3. **User Reviews** (`/movie/{id}/reviews`)
   - **Why Critical**: Sentiment analysis, engagement metrics
   - **Schema Change**: Add `movie_reviews` table
   - **Data**: Review text, rating, author, date

4. **Now Playing & Upcoming** (`/movie/now_playing`, `/movie/upcoming`)
   - **Why Critical**: Current theatrical presence
   - **Schema Change**: Add `movie_now_playing` and `movie_upcoming` tables
   - **Data**: Current/future theatrical releases by region

5. **Enhanced Discover Filters**
   - **Why Critical**: Find movies by cultural markers (language, region, people)
   - **Schema Change**: None required
   - **Implementation**: Extend discover_movies function parameters

## 7. Schema Changes Required

### High Priority Tables to Add

```sql
-- 1. Watch Providers
CREATE TABLE movie_watch_providers (
  id BIGSERIAL PRIMARY KEY,
  movie_id BIGINT REFERENCES movies(id) ON DELETE CASCADE,
  country_code VARCHAR(2) NOT NULL,
  provider_id INTEGER NOT NULL,
  provider_name VARCHAR(255),
  provider_type VARCHAR(50), -- 'stream', 'rent', 'buy', 'ads'
  display_priority INTEGER,
  logo_path VARCHAR(255),
  link_url TEXT,
  fetched_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 2. Movie Reviews
CREATE TABLE movie_reviews (
  id BIGSERIAL PRIMARY KEY,
  movie_id BIGINT REFERENCES movies(id) ON DELETE CASCADE,
  tmdb_review_id VARCHAR(255) UNIQUE,
  author VARCHAR(255),
  author_details JSONB, -- rating, username, avatar_path
  content TEXT,
  created_at TIMESTAMP WITH TIME ZONE,
  updated_at TIMESTAMP WITH TIME ZONE,
  url TEXT,
  fetched_at TIMESTAMP WITH TIME ZONE
);

-- 3. Now Playing Movies
CREATE TABLE movie_now_playing (
  id BIGSERIAL PRIMARY KEY,
  movie_id BIGINT REFERENCES movies(id) ON DELETE CASCADE,
  region VARCHAR(2),
  page INTEGER,
  position INTEGER,
  fetched_at TIMESTAMP WITH TIME ZONE,
  UNIQUE(movie_id, region, fetched_at)
);

-- 4. Upcoming Movies
CREATE TABLE movie_upcoming (
  id BIGSERIAL PRIMARY KEY,
  movie_id BIGINT REFERENCES movies(id) ON DELETE CASCADE,
  region VARCHAR(2),
  page INTEGER,
  position INTEGER,
  fetched_at TIMESTAMP WITH TIME ZONE,
  UNIQUE(movie_id, region, fetched_at)
);

-- 5. Certifications
CREATE TABLE certifications (
  id BIGSERIAL PRIMARY KEY,
  country_code VARCHAR(2) NOT NULL,
  certification VARCHAR(20) NOT NULL,
  meaning TEXT,
  order_index INTEGER,
  UNIQUE(country_code, certification)
);

-- 6. Watch Provider Registry
CREATE TABLE watch_providers (
  id BIGSERIAL PRIMARY KEY,
  provider_id INTEGER UNIQUE NOT NULL,
  provider_name VARCHAR(255),
  logo_path VARCHAR(255),
  display_priority INTEGER
);
```

## 8. Implementation Recommendations

### Phase 1: Critical for CRI (Implement Immediately)

1. **Extend TMDb Service Module**
   ```elixir
   # Add these functions to lib/cinegraph/services/tmdb.ex
   def get_movie_watch_providers(movie_id)
   def get_trending_movies(time_window \\ "day", opts \\ [])
   def get_movie_reviews(movie_id, opts \\ [])
   def get_now_playing_movies(opts \\ [])
   def get_upcoming_movies(opts \\ [])
   ```

2. **Update Comprehensive Fetch**
   - Add `watch/providers` to append_to_response
   - Store in new tables during import

3. **Enhance Discover Function**
   - Add all missing filter parameters
   - Enable complex cultural queries

### Phase 2: Medium Priority

1. **Person Popularity Tracking**
   - Implement `/person/popular` endpoint
   - Track person trending data

2. **Regional Data Enhancement**
   - Fetch and store certifications
   - Track regional availability

### Phase 3: Future Enhancements

1. **TV Show Support** (if needed)
   - Mirror movie structure
   - Add season/episode support

2. **User Features** (if OAuth implemented)
   - Watchlists, favorites, ratings

## 9. Final Assessment

### Current API Utilization: ~35-40%

### After Recommended Changes: ~75-80%

### Critical Missing Features for CRI:
1. **Watch Provider Data** - Essential for understanding global reach
2. **Trending Metrics** - Real-time popularity indicators
3. **User Reviews** - Sentiment and engagement data
4. **Enhanced Discovery** - Cultural filtering capabilities
5. **Theatrical Presence** - Now playing/upcoming data

### Schema Stability Assessment:
With the addition of the 6 recommended tables, the schema should be stable for CRI v1.0. The existing flexible JSONB fields and external sources architecture can accommodate future API additions without major schema changes.

## 10. Conclusion

The current implementation has a solid foundation but is missing several critical data points for comprehensive CRI calculations. The recommended schema additions focus on high-impact data that directly influences cultural relevance measurement. Once implemented, Cinegraph will have access to the most valuable TMDB data for CRI calculations while maintaining schema stability for future enhancements.