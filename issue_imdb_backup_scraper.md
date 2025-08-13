# IMDB Backup Scraper for Missing TMDb Movies

## Problem Statement

We're encountering cases where movies exist on IMDB but not on TMDb, causing our `TMDbDetailsWorker` to fail. These are typically:
- Festival films that haven't been widely released yet
- Independent or regional films with limited distribution
- Older or obscure films not in TMDb's database

Example failure:
- Movie: "Last We Left Off" (tt31194860)
- Exists on IMDB: https://www.imdb.com/title/tt31194860/
- TMDb lookup fails with: `{:error, "Movie 'Last We Left Off' (tt31194860) not found in TMDb"}`

## Proposed Solution

Implement an IMDB scraper as a fallback mechanism when TMDb lookups fail. This would:
1. Create placeholder movie records with basic IMDB data
2. Mark these records with a special status for future updates
3. Periodically retry TMDb lookups to enrich data when available

## Technical Analysis

### Current Infrastructure

We already have IMDB scraping capabilities:
- `Cinegraph.Scrapers.Imdb.HttpClient` - HTTP client with rate limiting
- `Cinegraph.Scrapers.ImdbCanonicalScraper` - Scrapes IMDB lists
- Floki-based HTML parsing infrastructure

### Required Data Fields

#### Minimum Required Fields (from Movie schema)
```elixir
- imdb_id: string (already have)
- title: string
- release_date: date (if available)
- runtime: integer (if available)
- overview: string
- original_language: string (if available)
- poster_path: string (IMDB poster URL)
```

#### Additional Fields to Scrape
```elixir
- director: string (for basic credits)
- cast: array of strings (top 3-5 actors)
- genres: array of strings
- rating: float (IMDB rating)
- vote_count: integer
- production_countries: array
```

### Implementation Tasks

#### 1. Create IMDB Movie Page Scraper Module
```elixir
defmodule Cinegraph.Scrapers.Imdb.MoviePageScraper do
  # Scrape individual movie page (not list)
  def scrape_movie_by_imdb_id(imdb_id)
  # Extract title, year, runtime, plot, etc.
  def parse_movie_page(html)
  # Handle different IMDB page layouts
end
```

#### 2. Modify TMDbDetailsWorker
```elixir
# In handle_no_tmdb_match function:
- Call IMDB scraper as fallback
- Create movie with import_status: "imdb_placeholder"
- Store scraping timestamp in metadata
```

#### 3. Create IMDB Placeholder Management
```elixir
defmodule Cinegraph.Movies.ImdbPlaceholderManager do
  # Track movies that need TMDb enrichment
  def list_placeholder_movies()
  # Retry TMDb lookup for placeholders
  def upgrade_placeholder(movie)
end
```

#### 4. Background Worker for Placeholder Updates
```elixir
defmodule Cinegraph.Workers.PlaceholderEnrichmentWorker do
  # Periodic job to retry TMDb lookups
  # Run daily/weekly to check if movies now exist in TMDb
  # Update import_status when successful
end
```

## Challenges & Considerations

### 1. Data Quality Issues
- IMDB HTML structure changes frequently
- Limited structured data compared to TMDb API
- No standardized IDs for people/companies
- Missing poster URLs or low-quality images

### 2. Rate Limiting & Legal Concerns
- IMDB has strict rate limiting
- Need to respect robots.txt
- Consider using official IMDB datasets (if available)
- May need proxy rotation for scale

### 3. Data Mapping Challenges
- IMDB genres differ from TMDb genres
- Person matching without TMDb IDs
- Production company normalization
- Release date format variations

### 4. Status Tracking
```elixir
# Proposed import_status values:
- "full" - Complete TMDb data
- "soft" - Limited TMDb data (existing)
- "imdb_placeholder" - IMDB-only data (new)
- "imdb_enriched" - IMDB data + partial TMDb (future)
```

### 5. Placeholder Lifecycle
```
1. TMDb lookup fails → Create IMDB placeholder
2. Daily job checks placeholders older than 7 days
3. Retry TMDb lookup
4. If found: Upgrade to full TMDb data
5. If not: Check again in exponential backoff (7, 14, 30, 60 days)
```

## Database Schema Changes

```sql
-- Add to movies table (if not exists)
ALTER TABLE movies ADD COLUMN IF NOT EXISTS imdb_scraped_at TIMESTAMP;
ALTER TABLE movies ADD COLUMN IF NOT EXISTS placeholder_retry_count INTEGER DEFAULT 0;
ALTER TABLE movies ADD COLUMN IF NOT EXISTS next_tmdb_retry_at TIMESTAMP;

-- Index for efficient placeholder queries
CREATE INDEX IF NOT EXISTS idx_movies_placeholder_status 
ON movies(import_status, next_tmdb_retry_at) 
WHERE import_status = 'imdb_placeholder';
```

## Testing Strategy

1. **Unit Tests**
   - HTML parsing for different IMDB layouts
   - Data extraction accuracy
   - Error handling for missing fields

2. **Integration Tests**
   - Full scraping flow with real IMDB pages
   - Fallback triggering in TMDbDetailsWorker
   - Placeholder upgrade process

3. **Test Cases**
   - New release films (like "Last We Left Off")
   - Classic films missing from TMDb
   - Foreign films with limited data
   - TV movies and documentaries

## Performance Considerations

- Cache IMDB responses for 24 hours
- Batch placeholder checks (100 at a time)
- Use connection pooling for HTTP requests
- Implement circuit breaker for IMDB failures

## Monitoring & Metrics

Track in `api_lookup_metrics`:
- IMDB scraping attempts/successes/failures
- Placeholder creation rate
- Successful TMDb upgrades
- Average days until TMDb availability

## MVP Implementation Steps

1. **Phase 1: Basic Scraper** (Week 1)
   - Create movie page scraper
   - Extract title, year, plot, rating
   - Handle basic error cases

2. **Phase 2: Worker Integration** (Week 1)
   - Modify TMDbDetailsWorker
   - Create placeholder records
   - Add import_status tracking

3. **Phase 3: Enrichment System** (Week 2)
   - Build placeholder manager
   - Create enrichment worker
   - Implement retry logic

4. **Phase 4: Production Hardening** (Week 2)
   - Add monitoring/metrics
   - Implement rate limiting
   - Add comprehensive logging

## Alternative Approaches Considered

1. **OMDb API Enhancement** - Limited by API quotas and missing new films
2. **Wikidata Integration** - Good for metadata but lacks recent releases
3. **Direct Festival APIs** - Would require individual integrations per festival
4. **Manual Data Entry** - Not scalable for large volumes

## Success Metrics

- Reduce TMDbDetailsWorker failure rate by 80%
- Successfully create placeholders for 95% of IMDB-only films
- Achieve 60% TMDb upgrade rate within 30 days
- Maintain <2 second response time for IMDB scraping

## Open Questions

1. Should we scrape full cast/crew or just key people?
2. How to handle TV episodes vs movies?
3. Should we store raw IMDB HTML for future reprocessing?
4. Integration with existing festival nomination data?
5. How to handle IMDB Pro data (if needed)?

## References

- Existing IMDB scraper: `/lib/cinegraph/scrapers/imdb/`
- TMDb worker: `/lib/cinegraph/workers/tmdb_details_worker.ex`
- Movie schema: `/lib/cinegraph/movies/movie.ex`
- Example IMDB page: https://www.imdb.com/title/tt31194860/