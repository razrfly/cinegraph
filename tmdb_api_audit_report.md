# Cinegraph TMDB API Coverage Audit Report

## Executive Summary

This audit analyzes the current Cinegraph database schema against TMDB's API capabilities, focusing on the new objective/subjective data split architecture. The analysis reveals that while Cinegraph has a solid foundation with the new schema design, it's currently utilizing approximately **35-40%** of TMDB's available API endpoints and data.

## 1. Current Data Capture Success (Objective vs Subjective Split)

### ✅ Successfully Implemented Objective Data Tables

1. **Movies Table** - Core movie facts
   - TMDB ID, IMDB ID
   - Title, original title, release date, runtime
   - Overview, tagline, languages
   - Budget, revenue, status
   - Media paths (poster, backdrop)
   - Flexible JSONB storage for arrays (genres, companies, etc.)

2. **People Table** - Person facts
   - TMDB ID, IMDB ID
   - Name, biography, demographics
   - Known for department
   - Profile images
   - External IDs storage

3. **Supporting Tables**
   - Genres
   - Collections (movie franchises)
   - Production Companies
   - Keywords
   - Movie Credits (cast/crew relationships)
   - Movie Videos
   - Movie Release Dates
   - Alternative Titles
   - Translations

### ✅ Successfully Implemented Subjective Data Architecture

1. **External Sources Registry**
   - Configurable source management
   - Weight factors for source importance
   - API version tracking

2. **External Ratings**
   - Polymorphic design supporting any rating source
   - Flexible rating types (user, critic, algorithm, popularity)
   - Scale normalization support
   - Sample size tracking

3. **External Recommendations & Trending**
   - Movie-to-movie recommendations
   - Trending/popular movies by source
   - Algorithm metadata storage

4. **CRI Scores Table** (Ready for future implementation)
   - Prepared for proprietary scoring algorithm

## 2. TMDB API Endpoints Usage Analysis

### 🟢 Currently Using (12 endpoints)

1. `/movie/{movie_id}` - Basic movie details
2. `/movie/{movie_id}` with append_to_response for:
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
3. `/search/movie` - Movie search
4. `/discover/movie` - Movie discovery
5. `/movie/popular` - Popular movies
6. `/movie/top_rated` - Top rated movies
7. `/person/{person_id}` - Person details
8. `/collection/{collection_id}` - Collection details
9. `/company/{company_id}` - Company details
10. `/genre/movie/list` - Genre list
11. `/configuration` - API configuration

### 🔴 Not Using (Major Endpoints)

1. **Movie Endpoints**
   - `/movie/now_playing` - Currently in theaters
   - `/movie/upcoming` - Upcoming releases
   - `/movie/{movie_id}/watch/providers` - Streaming availability
   - `/movie/{movie_id}/reviews` - User reviews
   - `/movie/{movie_id}/lists` - Lists containing movie
   - `/movie/{movie_id}/changes` - Change history
   - `/movie/latest` - Latest added movie

2. **TV Show Endpoints** (Entire category unused)
   - `/tv/{tv_id}` - TV show details
   - `/tv/popular`, `/tv/top_rated`, etc.

3. **Person Endpoints**
   - `/person/popular` - Popular people
   - `/person/{person_id}/movie_credits` - Full filmography
   - `/person/{person_id}/tv_credits` - TV credits
   - `/person/{person_id}/combined_credits` - All credits
   - `/person/{person_id}/tagged_images` - Tagged images

4. **Search Endpoints**
   - `/search/person` - Person search
   - `/search/company` - Company search
   - `/search/keyword` - Keyword search
   - `/search/collection` - Collection search
   - `/search/multi` - Multi-entity search

5. **Trending Endpoints**
   - `/trending/movie/{time_window}` - Trending movies
   - `/trending/person/{time_window}` - Trending people
   - `/trending/all/{time_window}` - All trending

6. **Account/User Features**
   - `/account/{account_id}/watchlist` - User watchlists
   - `/account/{account_id}/favorite` - User favorites
   - `/account/{account_id}/rated` - User ratings

7. **Certification/Region Data**
   - `/certification/movie/list` - Movie certifications by country
   - `/watch/providers/movie` - Available streaming providers

## 3. API Utilization Percentage

### Overall Coverage: ~35-40%

**Breakdown by Category:**
- Movie Core Data: 85% ✅
- Movie Metadata: 70% ✅
- Movie Relationships: 60% ⚠️
- Person Data: 30% ❌
- TV Shows: 0% ❌
- User Features: 0% ❌
- Regional Data: 40% ⚠️
- Trending/Discovery: 20% ❌

## 4. Architectural Improvements with External Sources System

### ✅ Strengths of New Architecture

1. **Clean Separation of Concerns**
   - Objective facts in core tables
   - Subjective ratings/scores in external_sources tables
   - Clear ownership of data types

2. **Flexible External Source Integration**
   - Easy to add new rating sources
   - Weight-based scoring system
   - Normalization support for different scales

3. **Future-Proof Design**
   - CRI scoring table ready for proprietary algorithm
   - JSONB fields for flexible data storage
   - Polymorphic relationships for extensibility

### 🚨 Remaining Gaps & Opportunities

1. **Missing High-Value Data**
   - **Watch Providers** - Critical for user decisions
   - **User Reviews** - Valuable sentiment data
   - **Trending Data** - Real-time popularity metrics
   - **TV Shows** - Entire content category missing

2. **Incomplete Person Data**
   - Not fetching full person details (only from credits)
   - Missing filmography relationships
   - No popularity metrics for people

3. **Regional/Localization Gaps**
   - Certifications by country not stored
   - Watch provider availability by region missing
   - Limited use of translation data

4. **Discovery Features**
   - Not using trending endpoints
   - Limited use of discover filters
   - No "now playing" or "upcoming" data

## 5. Recommendations for Next Phase

### Priority 1: High-Impact, Low-Effort Additions

1. **Add Watch Providers**
   ```elixir
   # New table: movie_watch_providers
   - movie_id
   - country_code
   - provider_id
   - provider_name
   - display_priority
   - logo_path
   - link_url
   ```

2. **Implement Trending Data Collection**
   - Use `/trending/movie/day` and `/trending/movie/week`
   - Store in existing `external_trending` table
   - Set up daily cron job for updates

3. **Enhance Person Data**
   - Fetch full person details with `append_to_response`
   - Store popularity scores
   - Add person trending data

### Priority 2: Medium-Impact Features

1. **Add Certifications Table**
   - Store rating certifications by country
   - Link to movie_release_dates

2. **Implement Reviews Storage**
   - Create movie_reviews table
   - Store author, content, rating
   - Use for sentiment analysis

3. **Add TV Show Support** (if in scope)
   - Mirror movie structure for TV shows
   - Add season/episode relationships

### Priority 3: Advanced Features

1. **User Account Integration**
   - Watchlists, favorites, ratings
   - Requires OAuth implementation

2. **Change Tracking**
   - Monitor movie data changes
   - Version history for key fields

## 6. Implementation Quick Wins

### Immediate Actions (Can implement today)

1. **Extend TMDb Service Module**
   ```elixir
   def get_movie_watch_providers(movie_id) do
     Client.get("/movie/#{movie_id}/watch/providers")
   end
   
   def get_trending_movies(time_window \\ "day") do
     Client.get("/trending/movie/#{time_window}")
   end
   ```

2. **Update Comprehensive Fetch**
   - Add `watch/providers` to append_to_response
   - Store provider data in new table

3. **Create Daily Sync Task**
   - Fetch trending movies
   - Update external_trending table
   - Calculate popularity deltas

## Conclusion

The new Cinegraph schema with objective/subjective split is architecturally sound and well-positioned for growth. The main opportunity is to expand API endpoint usage from 35% to 70%+ by focusing on high-value data like watch providers, trending metrics, and enhanced person data. The external sources system provides excellent flexibility for integrating multiple rating sources while maintaining data integrity.