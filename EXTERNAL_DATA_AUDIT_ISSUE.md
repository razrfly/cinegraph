# External Data Storage Audit: TMDb & OMDB API Integration

## Overview
This audit examines how external data from TMDb and OMDB APIs is currently stored after the recent database restructuring to ensure comprehensive data capture and identify any potential gaps.

## Recent Changes Summary

### Database Restructuring
- **Migration**: `20250811084415_reorganize_database_for_metrics.exs`
- **Key Changes**:
  - Created `external_metrics` table for volatile/subjective data
  - Created `movie_recommendations` table for recommendations
  - Removed volatile fields from `movies` table (vote_average, popularity, budget, revenue, etc.)
  - Created backward-compatible view `movies_with_metrics`

## Current Data Storage Analysis

### ✅ OMDB Integration (Excellent Coverage)

**Data Sources Captured**:
- ✅ IMDb ratings & votes → `external_metrics` (source: "imdb")
- ✅ Metascore → `external_metrics` (source: "metacritic") 
- ✅ Box Office (domestic revenue) → `external_metrics` (source: "omdb")
- ✅ Awards text with parsed metadata → `external_metrics` (source: "omdb")
- ✅ Rotten Tomatoes ratings → `external_metrics` (source: "rotten_tomatoes")
- ✅ Complete OMDB JSON → `movies.omdb_data`

**Implementation**: `lib/cinegraph/api_processors/omdb.ex`
- Uses `Metrics.store_omdb_metrics/2` to extract and store all metrics
- Comprehensive parsing in `ExternalMetric.from_omdb/2`
- Smart awards text parsing with Oscar/win/nomination detection

### ⚠️ TMDb Integration (Potential Data Loss)

**Data Sources Captured**:
- ✅ Rating average/votes → `external_metrics` (source: "tmdb")  
- ✅ Popularity score → `external_metrics` (source: "tmdb")
- ✅ Budget/Revenue → `external_metrics` (source: "tmdb")
- ✅ Recommendations → `movie_recommendations` table
- ✅ Credits, genres, keywords, videos, release dates → Junction tables

**❌ Critical Gap Identified**: 
- **Problem**: `movies.tmdb_data` stores complete TMDb response but appears underutilized
- **Evidence**: Analysis shows `tmdb_data: attrs` in `Movie.from_tmdb/1` (line 126) stores entire API response
- **Ultra-Comprehensive Data Available**: `get_movie_ultra_comprehensive/1` fetches:
  - Watch providers (streaming availability)
  - User reviews with ratings
  - List appearances (cultural relevance)
  - Similar movies
  - Alternative titles & translations
  - External IDs (IMDb, Facebook, Instagram, Twitter)

**Missing Data Extraction**:
1. **Watch Providers** - Critical for streaming availability analysis
2. **User Reviews** - Valuable for sentiment analysis (currently only count stored)
3. **List Appearances** - Cultural relevance indicators (partially captured)
4. **External IDs** - Social media & platform connections
5. **Alternative Titles** - International market data
6. **Translations** - Localization data

## Data Flow Analysis

### Current Flow
```
TMDb API → get_movie_ultra_comprehensive() → tmdb_data JSON field
                                          ↓
                    Metrics.store_tmdb_metrics() (limited extraction)
                                          ↓  
                            external_metrics table (basic metrics only)
```

### Recommended Enhanced Flow
```  
TMDb API → get_movie_ultra_comprehensive() → tmdb_data JSON field
                                          ↓
                Enhanced Metrics.store_tmdb_comprehensive_data()
                                          ↓
        ┌─ external_metrics (ratings, popularity, financial)
        ├─ watch_providers table (streaming availability)  
        ├─ user_reviews table (sentiment analysis)
        ├─ cultural_lists table (list appearances)
        └─ external_ids table (social media connections)
```

## Recommendations

### Priority 1: Immediate Actions
1. **Enhance TMDb Data Extraction**
   - Expand `Metrics.store_tmdb_metrics/2` to extract watch providers
   - Add `store_tmdb_engagement_metrics/3` usage for reviews/lists
   - Extract external IDs for social platform connections

2. **Add Missing Data Tables**
   - `movie_watch_providers` (streaming availability by region)
   - `movie_external_ids` (social media & platform IDs)
   - `movie_user_reviews` (user reviews with sentiment scores)

### Priority 2: Data Enhancement  
1. **Comprehensive Data Validation**
   - Audit existing `tmdb_data` JSON fields to identify unused data
   - Implement data completeness metrics
   - Add monitoring for API response coverage

2. **Cultural Relevance Enhancement**
   - Expand list appearance analysis
   - Add cultural significance scoring
   - Track award nominations beyond OMDB coverage

### Priority 3: System Improvements
1. **Performance Optimization**
   - Consider selective JSON field extraction vs full storage
   - Implement intelligent refresh strategies for volatile data
   - Add caching for frequently accessed external data

2. **Data Quality Assurance**
   - Add validation for metric data types and ranges
   - Implement data freshness monitoring
   - Track API coverage and success rates

## Technical Implementation Suggestions

### Enhanced Metrics Storage
```elixir
# Expand in lib/cinegraph/metrics.ex
def store_tmdb_comprehensive_data(movie, tmdb_data) do
  with :ok <- store_tmdb_metrics(movie, tmdb_data),
       :ok <- store_tmdb_watch_providers(movie, tmdb_data["watch_providers"]),
       :ok <- store_tmdb_external_ids(movie, tmdb_data["external_ids"]),
       :ok <- store_tmdb_engagement_metrics(movie, tmdb_data["reviews"], tmdb_data["lists"]) do
    :ok
  end
end
```

### Missing Tables Schema
```sql
-- Watch providers by region
CREATE TABLE movie_watch_providers (
  movie_id BIGINT REFERENCES movies(id),
  region VARCHAR(2),
  provider_type VARCHAR(20), -- 'flatrate', 'rent', 'buy'
  provider_name VARCHAR(100),
  logo_path VARCHAR(200),
  display_priority INTEGER
);

-- External platform IDs  
CREATE TABLE movie_external_ids (
  movie_id BIGINT REFERENCES movies(id),
  platform VARCHAR(50), -- 'facebook', 'instagram', 'twitter'
  external_id VARCHAR(100)
);
```

## Success Metrics

### Data Coverage
- [ ] 100% of OMDB response data utilized (Currently: ~95%)
- [ ] 100% of TMDb ultra-comprehensive response data utilized (Currently: ~60%)
- [ ] Watch provider data available for 80%+ of movies with streaming availability
- [ ] External IDs captured for 70%+ of movies with social media presence

### Quality Assurance  
- [ ] Data freshness monitoring for volatile metrics
- [ ] Validation rules for all extracted metrics
- [ ] Error handling for malformed API responses
- [ ] Performance benchmarks for data extraction processes

## Conclusion

The current external data storage system effectively captures OMDB data but significantly underutilizes the comprehensive TMDb data being fetched. The primary gap is in extracting and storing the rich metadata available in the TMDb ultra-comprehensive response, particularly watch providers, user reviews, and cultural relevance indicators.

Implementing the recommended enhancements would ensure no valuable external data is lost and provide a more complete foundation for movie analysis and recommendations.