# Data Sources Implementation Plan for CineGraph

## Overview
This document outlines a phased approach to integrating external data sources for the Cultural Relevance Index (CRI), with specific implementation details for each source.

## Current Schema Considerations

Based on our schema, we have several storage options:
- `curated_lists` table - for canonical lists (Criterion, AFI, etc.)
- `external_ratings` table - for aggregated scores (Rotten Tomatoes, Metacritic)
- `movie_list_items` - for tracking which movies appear on which lists
- `cri_scores` table - for storing calculated CRI components
- Movies table has `external_ids` JSONB field for cross-referencing

## Phase 1: Critical Consensus & Canonical Lists (Week 1-2)

### 1.1 OMDb API Integration
**What**: Rotten Tomatoes, Metacritic, IMDb ratings
**How to get it**:
```elixir
# 1. Sign up at http://www.omdbapi.com/apikey.aspx
# 2. Choose plan: Free (1,000/day) or Patreon ($1-15/month)
# 3. Implementation:
GET http://www.omdbapi.com/?i=tt0111161&apikey=[yourkey]
```
**Storage**: 
- Use `external_ratings` table with source types: "rotten_tomatoes", "metacritic", "imdb"
- Store both critic and audience scores separately

### 1.2 National Film Registry
**What**: Library of Congress preservation list
**How to get it**:
```elixir
# 1. Scrape from https://www.loc.gov/programs/national-film-preservation-board/film-registry/complete-national-film-registry-listing/
# 2. Or use their CSV export
# 3. Match films by title + year to TMDb IDs
```
**Storage**:
- Create entry in `curated_lists` table: {name: "National Film Registry", authority_type: "preservation"}
- Link via `movie_list_items` with metadata like {year_added: 2023, rank: null}

### 1.3 Sight & Sound Poll Data
**What**: Critical consensus from 2022 poll
**How to get it**:
```bash
# Option 1: Use existing GitHub data
git clone https://github.com/serve-and-volley/sight-and-sound-poll-data

# Option 2: Use structured Google Sheets
# https://docs.google.com/spreadsheets/d/1tZPZEd-ZxjzKlBy7DxLfV6goIquxl-r8oGOj_xIWZ5A/
```
**Storage**:
- Multiple lists in `curated_lists`: "Sight & Sound Critics 2022", "Sight & Sound Directors 2022"
- Store rank in `movie_list_items.metadata`

## Phase 2: Awards & Festival Recognition (Week 3-4)

### 2.1 Academy Awards Database
**What**: Complete Oscar history
**How to get it**:
```elixir
# Scrape from https://awardsdatabase.oscars.org/
# Structure: Year -> Category -> Nominees/Winners
defmodule Cinegraph.Scrapers.Oscars do
  def scrape_year(year) do
    # Parse HTML tables for nominations/wins
  end
end
```
**Storage**:
- New table: `awards` with fields: {movie_id, award_body, category, year, won/nominated}
- Or extend `movie_list_items` with award-specific metadata

### 2.2 Major Film Festivals
**What**: Cannes, Venice, Berlin, Sundance selections
**How to get it**:
```elixir
# Cannes: https://www.festival-cannes.com/en/archives
# Venice: https://www.labiennale.org/en/cinema/archive
# Berlin: https://www.berlinale.de/en/archive/
# Sundance: https://festival.sundance.org/archive/
```
**Storage**:
- Create festival lists in `curated_lists`: "Cannes Palme d'Or", "Venice Golden Lion"
- Track selections vs. winners in metadata

### 2.3 AFI Lists
**What**: AFI Top 100 (multiple versions)
**How to get it**:
```elixir
# Scrape from https://www.afi.com/afis-100-years-100-movies/
# Multiple lists: 100 Movies, 100 Laughs, 100 Thrills, etc.
```
**Storage**:
- Separate `curated_lists` entries for each AFI list
- Preserve original rankings

## Phase 3: Public Discourse & Social Signals (Week 5-6)

### 3.1 Reddit API
**What**: Discussion volume, sentiment, references
**How to get it**:
```python
# Using PRAW (Python Reddit API Wrapper)
import praw
reddit = praw.Reddit(client_id='YOUR_ID', client_secret='YOUR_SECRET')

# Search for movie discussions
def get_movie_mentions(imdb_id):
    subreddits = ['movies', 'criterion', 'TrueFilm', 'moviesuggestions']
    for sub in subreddits:
        reddit.subreddit(sub).search(f'imdb:{imdb_id}')
```
**Storage**:
- New table: `social_signals` {movie_id, platform, metric_type, value, timestamp}
- Metrics: mention_count, avg_sentiment, discussion_threads

### 3.2 Google Trends
**What**: Search interest over time
**How to get it**:
```python
from pytrends.request import TrendReq
pytrends = TrendReq()

# Get interest over time
pytrends.build_payload(['The Godfather movie'])
interest_data = pytrends.interest_over_time()
```
**Storage**:
- Time series data in `social_signals` table
- Calculate "longevity score" based on sustained interest

### 3.3 Letterboxd (When Available)
**What**: Cinephile ratings and lists
**How to get it**:
```elixir
# Currently requires approval - email api@letterboxd.com
# OAuth2 authentication required
# Monitor https://letterboxd.com/api-beta/ for updates
```
**Storage**:
- Similar to other rating sources in `external_ratings`
- Track list appearances separately

## Phase 4: Cultural Penetration (Week 7-8)

### 4.1 Giphy API
**What**: GIF usage as cultural currency
**How to get it**:
```elixir
# 1. Get API key from https://developers.giphy.com/
# 2. Search for movie-related GIFs
def get_gif_metrics(movie_title) do
  HTTPoison.get("https://api.giphy.com/v1/gifs/search?api_key=#{key}&q=#{movie_title}")
  # Count total GIFs, view counts, trending status
end
```
**Storage**:
- Add to `social_signals`: {platform: "giphy", metric_type: "gif_count"}

### 4.2 YouTube Data API
**What**: Video essays, analysis videos, clip views
**How to get it**:
```elixir
# YouTube Data API v3
def search_movie_content(movie_title, imdb_id) do
  # Search for: "[movie] analysis", "[movie] explained", "[movie] video essay"
  # Count videos, total views, recent uploads
end
```
**Storage**:
- Track in `social_signals`: video_count, total_views, recent_activity

### 4.3 Wikiquote
**What**: Memorable quotes
**How to get it**:
```python
# Use wikiquote Python package or scrape
import wikiquote
quotes = wikiquote.quotes('The Godfather')
```
**Storage**:
- New field in movies table or separate quotes table
- Count as cultural penetration signal

## Phase 5: Academic & Scholarly (Week 9-10)

### 5.1 Google Scholar (via SerpApi)
**What**: Academic citations
**How to get it**:
```elixir
# SerpApi pricing: $50/month for 5,000 searches
def get_scholar_citations(movie_title) do
  HTTPoison.get("https://serpapi.com/search.json?engine=google_scholar&q=#{movie_title}+film&api_key=#{key}")
  # Extract citation counts, paper titles
end
```
**Storage**:
- Add scholarly_citations field to CRI components
- Track growth over time

### 5.2 JSTOR (If Accessible)
**What**: Academic paper references
**How to get it**:
```elixir
# Requires institutional access
# Alternative: CrossRef API for DOI lookups
```
**Storage**:
- Similar to Google Scholar approach

## Phase 6: Specialized Sources (Week 11-12)

### 6.1 Criterion Collection
**What**: Curated arthouse selection
**How to get it**:
```elixir
# Scrape https://www.criterion.com/shop/browse/list
# Or use Criterion Channel API if available
# Match by title to TMDb
```
**Storage**:
- Add to `curated_lists` with high authority weight

### 6.2 They Shoot Pictures Don't They
**What**: Aggregate of critical lists
**How to get it**:
```elixir
# Annual updates at https://www.theyshootpictures.com/
# Download their yearly Excel files
```
**Storage**:
- Track year-over-year changes in rankings

### 6.3 BFI Lists
**What**: British Film Institute rankings
**How to get it**:
```elixir
# Scrape various BFI lists
# https://www.bfi.org.uk/lists-polls
```
**Storage**:
- Multiple curated lists with UK/European focus

## Implementation Order & Priority

### Week 1-2: Foundation
1. OMDb API ✓ (immediate value, easy integration)
2. National Film Registry ✓ (simple scrape)
3. Sight & Sound data ✓ (pre-structured)

### Week 3-4: Prestige Signals  
4. Oscar database
5. Major festival winners
6. AFI lists

### Week 5-6: Contemporary Relevance
7. Reddit API integration
8. Google Trends tracking
9. YouTube metrics

### Week 7-8: Cultural Impact
10. Giphy integration
11. Wikiquote scraping

### Week 9+: Deep Signals
12. Google Scholar (if budget allows)
13. Criterion Collection
14. Regional film lists

## Database Schema Extensions Needed

```elixir
# 1. Add to existing schema
- awards table
- social_signals table (time-series data)
- quotes table (optional)

# 2. Extend movie_list_items metadata to include:
- rank/position
- year_added
- special_designation (winner/nominee/selection)

# 3. Add to cri_components calculation:
- canonical_list_score
- critical_consensus_score  
- social_engagement_score
- cultural_penetration_score
- academic_influence_score
```

## Rate Limiting & Caching Strategy

- Use Oban for scheduled jobs
- Implement exponential backoff
- Cache responses for 24-48 hours
- Prioritize movies by popularity/release date

## Next Steps

1. Create individual GitHub issues for each data source
2. Set up API keys and authentication
3. Build generic scraper/API client modules
4. Implement data normalization layer
5. Create CRI calculation pipeline