# Implement External Data Sources for Cultural Relevance Index

## Overview
We need to integrate multiple external data sources beyond TMDb to build our Cultural Relevance Index (CRI). This issue tracks the phased implementation of these sources, prioritizing ease of integration and impact on CRI quality.

## Current State
- ✅ TMDb integration complete with 5,000+ movies
- ✅ Database schema supports external data
- 🔄 Need additional sources for comprehensive CRI calculation

## Implementation Plan

### Phase 1: Quick Wins - Critical Consensus & Canon (Week 1-2)

#### 1.1 OMDb API Integration
**What**: Rotten Tomatoes, Metacritic, IMDb ratings  
**Cost**: Free (1,000 req/day) or $1-15/month  
**How to get it**:
```bash
# 1. Sign up at http://www.omdbapi.com/apikey.aspx
# 2. Make requests:
GET http://www.omdbapi.com/?i=tt0111161&apikey=[yourkey]
```
**Storage**: Use `external_ratings` table with source types: "rotten_tomatoes", "metacritic", "imdb"

#### 1.2 National Film Registry
**What**: 875 culturally significant films preserved by Library of Congress  
**Cost**: Free  
**How to get it**:
```elixir
# Scrape from:
https://www.loc.gov/programs/national-film-preservation-board/film-registry/complete-national-film-registry-listing/
# Or download their CSV export
```
**Storage**: Create entry in `curated_lists`, link via `movie_list_items`

#### 1.3 Sight & Sound Poll 2022
**What**: Most prestigious critical consensus  
**Cost**: Free  
**How to get it**:
```bash
# Option 1: Clone existing data
git clone https://github.com/serve-and-volley/sight-and-sound-poll-data

# Option 2: Use Google Sheets
https://docs.google.com/spreadsheets/d/1tZPZEd-ZxjzKlBy7DxLfV6goIquxl-r8oGOj_xIWZ5A/
```
**Storage**: Create lists for "Critics Poll 2022" and "Directors Poll 2022" with rankings

### Phase 2: Awards & Festivals (Week 3-4)

#### 2.1 Academy Awards Database
**What**: Complete Oscar history  
**Cost**: Free (scraping required)  
**How to get it**:
```elixir
# Scrape structured data from:
https://awardsdatabase.oscars.org/
# Parse by: Year -> Category -> Nominees/Winners
```
**Storage**: Consider new `awards` table or extend `movie_list_items`

#### 2.2 Major Film Festivals
**What**: Cannes, Venice, Berlin, Sundance winners  
**Cost**: Free (scraping required)  
**How to get it**:
```
Cannes: https://www.festival-cannes.com/en/archives
Venice: https://www.labiennale.org/en/cinema/archive
Berlin: https://www.berlinale.de/en/archive/
Sundance: https://festival.sundance.org/archive/
```
**Storage**: Festival-specific lists (e.g., "Cannes Palme d'Or Winners")

#### 2.3 AFI Top 100 Lists
**What**: American Film Institute rankings  
**Cost**: Free  
**How to get it**:
```elixir
# Scrape from https://www.afi.com/afis-100-years-100-movies/
# Multiple lists: 100 Movies, 100 Laughs, 100 Thrills, etc.
```
**Storage**: Separate `curated_lists` entry for each theme

### Phase 3: Social Signals (Week 5-6)

#### 3.1 Reddit API
**What**: Discussion volume and sentiment  
**Cost**: Free  
**How to get it**:
```python
# Using PRAW:
import praw
reddit = praw.Reddit(client_id='YOUR_ID', client_secret='YOUR_SECRET')

# Target subreddits: r/movies, r/criterion, r/TrueFilm
# Search by IMDb ID or title
```
**Storage**: New `social_signals` table for time-series data

#### 3.2 Google Trends
**What**: Search interest over time  
**Cost**: Free  
**How to get it**:
```python
from pytrends.request import TrendReq
pytrends = TrendReq()
pytrends.build_payload(['The Godfather movie'])
interest_data = pytrends.interest_over_time()
```
**Storage**: Calculate "longevity score" from sustained interest

#### 3.3 YouTube Data API
**What**: Video essays, analysis content  
**Cost**: Free tier available  
**How to get it**:
```
# Search for: "[movie] analysis", "[movie] explained", "[movie] video essay"
# Track: video count, total views, recent uploads
```
**Storage**: Add to `social_signals` with view counts

### Phase 4: Cultural Penetration (Week 7-8)

#### 4.1 Giphy API
**What**: GIF usage as cultural currency  
**Cost**: Free with API key  
**How to get it**:
```elixir
# Get key from https://developers.giphy.com/
HTTPoison.get("https://api.giphy.com/v1/gifs/search?api_key=#{key}&q=#{movie_title}")
```
**Storage**: Track GIF count in `social_signals`

#### 4.2 Wikiquote
**What**: Memorable quote count  
**Cost**: Free  
**How to get it**:
```python
import wikiquote
quotes = wikiquote.quotes('The Godfather')
# Or scrape directly
```
**Storage**: Quote count as cultural penetration metric

### Phase 5: Academic & Specialized (Week 9+)

#### 5.1 Google Scholar (via SerpApi)
**What**: Academic citations  
**Cost**: $50/month for 5,000 searches  
**How to get it**:
```
# SerpApi: https://serpapi.com/google-scholar-api
# Alternative: scholarly Python library (free but limited)
```
**Storage**: Track citation count and growth

#### 5.2 Criterion Collection
**What**: Curated arthouse selection  
**Cost**: Free (scraping)  
**How to get it**:
```
# Scrape https://www.criterion.com/shop/browse/list
# Match by title + director to TMDb
```
**Storage**: High-authority entry in `curated_lists`

#### 5.3 They Shoot Pictures Don't They
**What**: Meta-aggregation of critical lists  
**Cost**: Free  
**How to get it**:
```
# Download annual Excel from https://www.theyshootpictures.com/
# Track year-over-year ranking changes
```
**Storage**: Annual snapshots with ranking trends

## Database Schema Extensions

```sql
-- For time-series social data
CREATE TABLE social_signals (
  id BIGSERIAL PRIMARY KEY,
  movie_id BIGINT REFERENCES movies(id),
  platform VARCHAR(50),
  metric_type VARCHAR(50),
  value FLOAT,
  metadata JSONB,
  measured_at TIMESTAMP
);

-- For detailed awards (optional)
CREATE TABLE awards (
  id BIGSERIAL PRIMARY KEY,
  movie_id BIGINT REFERENCES movies(id),
  award_body VARCHAR(100),
  category VARCHAR(200),
  year INTEGER,
  result VARCHAR(20) -- 'won', 'nominated'
);
```

## Implementation Details

### Matching Strategy
1. Primary: IMDb ID (most reliable)
2. Fallback: Title + Release Year
3. Manual review for ambiguous matches
4. Store match confidence in metadata

### Rate Limiting & Caching
- Use Oban for background jobs
- Implement exponential backoff
- Cache responses 24-48 hours
- Respect API limits (especially OMDb free tier)

### CRI Component Mapping
```elixir
# Each source contributes to CRI components:
canonical_authority: [national_film_registry, sight_sound, afi, criterion]
critical_consensus: [rotten_tomatoes, metacritic, sight_sound]
cultural_penetration: [giphy, wikiquote, youtube_views]
social_engagement: [reddit_mentions, google_trends]
academic_influence: [google_scholar_citations]
institutional_recognition: [oscars, cannes, venice]
```

## Success Criteria
- [ ] Match 90%+ of "1001 Movies You Must See Before You Die" list
- [ ] Integrate all Phase 1-3 sources within 6 weeks
- [ ] CRI scores correlate >0.7 with expert consensus
- [ ] Automated daily updates for social signals

## Next Steps
1. [ ] Set up API keys in `.env`
2. [ ] Create generic HTTP client module with rate limiting
3. [ ] Build Oban jobs for each data source
4. [ ] Implement data normalization layer
5. [ ] Create admin dashboard for integration monitoring

## Questions
- Should we store raw API responses for reprocessing?
- Update frequency for each source? (Daily? Weekly? Monthly?)
- Initial weights for each signal in CRI calculation?
- How to handle films not found in external sources?

## Resources
- [TMDb to IMDb mapping](https://developers.themoviedb.org/3/find/find-by-id)
- [Reddit API Documentation](https://www.reddit.com/dev/api/)
- [YouTube Data API](https://developers.google.com/youtube/v3)
- [Giphy API Docs](https://developers.giphy.com/docs/api/)

---

**Labels**: enhancement, data-integration, high-priority  
**Assignees**: @razrfly  
**Milestone**: CRI Alpha Launch