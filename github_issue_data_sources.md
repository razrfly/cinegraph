# GitHub Issue: Implement External Data Sources for Cultural Relevance Index

## Summary
Implement phased integration of external data sources to build the Cultural Relevance Index (CRI), starting with easily accessible APIs and canonical lists, then expanding to social signals and academic sources.

## Current State
- ✅ TMDb integration complete with 5,000+ movies
- ✅ Database schema supports external data through `curated_lists`, `external_ratings`, and `movie_list_items` tables
- ✅ JSONB fields allow flexible data storage
- 🔄 Need to integrate additional sources for CRI calculation

## Proposed Implementation Phases

### Phase 1: Quick Wins - Critical Consensus & Canon (Week 1-2)
**Goal**: Establish baseline quality signals with minimal effort

#### 1. OMDb API Integration
- **Cost**: Free tier (1,000/day) or $1-15/month  
- **Data**: Rotten Tomatoes, Metacritic, IMDb ratings
- **Implementation**: Simple REST API, store in `external_ratings` table
- **Match by**: IMDb ID (already in our schema)

#### 2. National Film Registry  
- **Cost**: Free
- **Data**: 875 culturally significant films
- **Implementation**: Scrape HTML or use CSV export
- **Storage**: Create list in `curated_lists`, link via `movie_list_items`

#### 3. Sight & Sound Poll 2022
- **Cost**: Free  
- **Data**: Critics' and directors' top films
- **Implementation**: Use existing GitHub repo or Google Sheets
- **Storage**: Multiple lists with rankings in metadata

### Phase 2: Awards & Festivals (Week 3-4)
**Goal**: Add prestige and recognition signals

#### 4. Academy Awards Database
- **Cost**: Free (scraping required)
- **Data**: Complete Oscar history  
- **Implementation**: Scrape awardsdatabase.oscars.org
- **Storage**: New `awards` table or extend `movie_list_items`

#### 5. Major Film Festivals
- **Cost**: Free (scraping required)
- **Sources**: 
  - Cannes (Palme d'Or, Grand Prix)
  - Venice (Golden Lion)
  - Berlin (Golden Bear)
  - Sundance (Grand Jury Prize)
- **Storage**: Festival-specific lists in `curated_lists`

#### 6. AFI Top 100 Lists
- **Cost**: Free
- **Data**: Multiple themed lists (100 Movies, 100 Laughs, etc.)
- **Implementation**: Scrape AFI website
- **Storage**: Separate list for each theme

### Phase 3: Social Signals (Week 5-6)
**Goal**: Measure contemporary cultural engagement

#### 7. Reddit API
- **Cost**: Free
- **Data**: Discussion volume from r/movies, r/criterion, r/TrueFilm
- **Implementation**: PRAW library or direct API
- **Storage**: New `social_signals` table for time-series data

#### 8. Google Trends
- **Cost**: Free
- **Data**: Search interest over time
- **Implementation**: pytrends library  
- **Storage**: Calculate "longevity score" from sustained interest

#### 9. YouTube Data API
- **Cost**: Free tier available
- **Data**: Video essays, analysis videos, view counts
- **Implementation**: Search for "[movie] analysis", "[movie] explained"
- **Storage**: Track video count and total views

### Phase 4: Cultural Penetration (Week 7-8)
**Goal**: Measure how deeply films embed in culture

#### 10. Giphy API
- **Cost**: Free with API key
- **Data**: GIF count and usage
- **Implementation**: Search API for movie-related GIFs
- **Storage**: Add to `social_signals` as cultural currency metric

#### 11. Wikiquote
- **Cost**: Free
- **Data**: Number of memorable quotes
- **Implementation**: Scrape or use wikiquote package
- **Storage**: Quote count as penetration signal

### Phase 5: Academic & Deep Sources (Week 9+)
**Goal**: Add scholarly and specialized signals

#### 12. Google Scholar (via SerpApi)
- **Cost**: $50/month for 5,000 searches
- **Data**: Academic citations
- **Implementation**: SerpApi or scholarly Python library
- **Storage**: Track citation growth over time

#### 13. Criterion Collection
- **Cost**: Free (scraping)
- **Data**: Curated arthouse selection
- **Implementation**: Scrape criterion.com/shop/browse/list
- **Storage**: High-weight entry in `curated_lists`

#### 14. Regional Lists (BFI, TSPDT)
- **Cost**: Free
- **Data**: They Shoot Pictures Don't They, BFI lists
- **Implementation**: Download annual Excel files or scrape
- **Storage**: Track year-over-year ranking changes

## Storage Strategy

### Existing Tables to Use:
- `curated_lists` - For all canonical lists (AFI, Sight & Sound, etc.)
- `movie_list_items` - Links movies to lists with metadata (rank, year)
- `external_ratings` - For rating aggregators (RT, Metacritic)
- `cri_scores` - Store calculated component scores

### New Tables Needed:
```sql
-- For time-series social data
CREATE TABLE social_signals (
  id BIGSERIAL PRIMARY KEY,
  movie_id BIGINT REFERENCES movies(id),
  platform VARCHAR(50), -- 'reddit', 'youtube', 'giphy'
  metric_type VARCHAR(50), -- 'mention_count', 'view_count'
  value FLOAT,
  metadata JSONB,
  measured_at TIMESTAMP,
  created_at TIMESTAMP DEFAULT NOW()
);

-- For awards tracking (optional, could use movie_list_items)
CREATE TABLE awards (
  id BIGSERIAL PRIMARY KEY,
  movie_id BIGINT REFERENCES movies(id),
  award_body VARCHAR(100), -- 'Academy Awards', 'Cannes'
  category VARCHAR(200),
  year INTEGER,
  result VARCHAR(20), -- 'won', 'nominated'
  created_at TIMESTAMP DEFAULT NOW()
);
```

## Technical Implementation Notes

### Matching Strategy
1. Use IMDb ID when available (most reliable)
2. Fall back to title + year matching
3. Manual review for ambiguous matches
4. Store match confidence in metadata

### Rate Limiting
- Implement with Oban background jobs
- Respect API limits (OMDb: 1k/day free tier)
- Cache responses for 24-48 hours
- Use exponential backoff for retries

### Priority Order
1. Start with Phase 1 (immediate high-quality signals)
2. Run initial CRI calculations after Phase 1
3. Backtest against "1001 Movies You Must See Before You Die"
4. Iterate on algorithm while adding more sources

## Success Metrics
- [ ] 90%+ of "1001 Movies" list successfully matched
- [ ] CRI scores correlate >0.7 with expert consensus
- [ ] All Phase 1-3 sources integrated within 6 weeks
- [ ] Automated daily updates for social signals

## Next Actions
1. [ ] Create `.env` variables for API keys
2. [ ] Build generic HTTP client with rate limiting
3. [ ] Create Oban jobs for each data source
4. [ ] Design CRI calculation pipeline
5. [ ] Build admin dashboard for monitoring integration status

## Questions to Resolve
- Should we store raw API responses for future reprocessing?
- How often should we update each data source?
- What weights should we assign to each signal initially?
- Should we track data provenance for transparency?