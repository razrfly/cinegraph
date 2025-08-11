# External Data Storage Implementation Gaps - Audit Report

**Issue**: Complete implementation of TMDb ultra-comprehensive data extraction and storage

## Problem Statement

Following audit of issue #208, significant gaps exist between TMDb data fetched and data actually extracted/stored. While database restructuring was successful, critical extraction logic remains missing, resulting in only ~60% utilization of ultra-comprehensive TMDb data vs 95% for OMDB.

## Implementation Status

### ✅ Successfully Implemented
- `external_metrics` table and database restructuring
- OMDB integration (95% data utilization) 
- Basic TMDb metrics (ratings, popularity, budget, revenue)
- Engagement metrics for reviews/lists

### ❌ Critical Missing Components

#### 1. Watch Providers Storage (HIGH PRIORITY)
- **Missing**: `movie_watch_providers` table
- **Impact**: Streaming availability data completely lost
- **Data Status**: Fetched via ultra-comprehensive endpoint but not extracted

#### 2. External IDs Storage (HIGH PRIORITY)  
- **Missing**: `movie_external_ids` table
- **Impact**: Social media connections (Facebook, Instagram, Twitter) lost
- **Data Status**: Available in TMDb response but not processed

#### 3. Enhanced User Reviews (MEDIUM PRIORITY)
- **Missing**: `movie_user_reviews` table for full review content
- **Current**: Only engagement count stored, full review data discarded
- **Impact**: Lost sentiment analysis and review quality opportunities

#### 4. Comprehensive TMDb Extraction Function (CRITICAL)
- **Missing**: Enhanced extraction logic in `ExternalMetric.from_tmdb/2`
- **Impact**: 40% of ultra-comprehensive data unutilized
- **Location**: `lib/cinegraph/movies/external_metric.ex:77-149`

## Technical Requirements

### Database Tables Needed
```sql
CREATE TABLE movie_watch_providers (
  id SERIAL PRIMARY KEY,
  movie_id INTEGER REFERENCES movies(id),
  provider_name VARCHAR(255) NOT NULL,
  provider_type VARCHAR(50) NOT NULL, -- 'flatrate', 'rent', 'buy'
  availability_region VARCHAR(2) NOT NULL,
  link TEXT,
  display_priority INTEGER,
  inserted_at TIMESTAMP,
  updated_at TIMESTAMP
);

CREATE TABLE movie_external_ids (
  id SERIAL PRIMARY KEY,
  movie_id INTEGER REFERENCES movies(id),
  platform VARCHAR(50) NOT NULL, -- 'facebook', 'instagram', 'twitter'
  external_id VARCHAR(255) NOT NULL,
  verified_at TIMESTAMP,
  inserted_at TIMESTAMP,
  updated_at TIMESTAMP
);

CREATE TABLE movie_user_reviews (
  id SERIAL PRIMARY KEY,
  movie_id INTEGER REFERENCES movies(id),
  author VARCHAR(255),
  content TEXT,
  rating FLOAT,
  language VARCHAR(10),
  created_date TIMESTAMP,
  helpful_votes INTEGER DEFAULT 0,
  inserted_at TIMESTAMP,
  updated_at TIMESTAMP
);
```

### Code Changes Required

#### 1. Enhanced TMDb Extraction (`lib/cinegraph/movies/external_metric.ex`)
```elixir
def from_tmdb(movie_id, tmdb_data) do
  # Current basic metrics +
  # Add watch providers extraction
  # Add external IDs extraction  
  # Add enhanced review processing
end
```

#### 2. Processing Integration (`lib/cinegraph/movies.ex:177-196`)
Add to `fetch_and_store_movie_comprehensive/1`:
```elixir
:ok <- process_movie_watch_providers(movie, tmdb_data["watch/providers"]),
:ok <- process_movie_external_ids(movie, tmdb_data["external_ids"]),
:ok <- process_movie_user_reviews_detailed(movie, tmdb_data["reviews"]),
```

## Data Utilization Impact

| Component | Current Status | After Implementation |
|-----------|----------------|---------------------|
| TMDb Basic Data | 80% utilized | 80% utilized |
| TMDb Ultra Data | 60% utilized | **95% utilized** |
| Watch Providers | 0% utilized | **100% utilized** |
| External IDs | 0% utilized | **100% utilized** |
| Review Details | 10% utilized | **90% utilized** |

## Implementation Priority

### Phase 1 (Immediate - High ROI)
1. **Watch Providers Implementation**
   - High user value (streaming availability)
   - Clear business use case
   - Data readily available in current fetches

2. **External IDs Implementation**  
   - Social media integration capabilities
   - Cross-platform movie linking
   - Marketing and analytics opportunities

### Phase 2 (Near-term)
3. **Enhanced User Reviews Storage**
4. **Cultural List Context Enhancement**

### Phase 3 (Long-term)
5. **Systematic TMDb data audit for additional gaps**

## Success Metrics

- **Primary**: Achieve 95%+ TMDb ultra-comprehensive data utilization (matching OMDB)
- **Secondary**: Enable streaming availability features
- **Tertiary**: Support social media integration capabilities

## Files Affected

- `priv/repo/migrations/` - New table migrations
- `lib/cinegraph/movies/external_metric.ex` - Enhanced extraction
- `lib/cinegraph/movies.ex` - Processing integration
- `lib/cinegraph/metrics.ex` - Storage coordination

## Context

This addresses the core finding from issue #208 audit: while infrastructure exists for comprehensive external data storage, extraction logic remains incomplete, leaving valuable TMDb ultra-comprehensive data unutilized despite being successfully fetched.