# Oban Queue System

This document describes the Oban job queue architecture for Cinegraph. The system uses 6 consolidated queues to handle all background processing with clear separation of concerns and appropriate rate limiting.

## Queue Overview

| Queue | Concurrency | Purpose |
|-------|-------------|---------|
| `tmdb` | 15 | All TMDb API interactions |
| `omdb` | 5 | OMDb API enrichment |
| `collaboration` | 5 | Person collaboration processing |
| `scraping` | 5 | Web scraping (IMDb, festivals, awards) |
| `metrics` | 10 | Calculations and analytics |
| `maintenance` | 2 | Background maintenance tasks |

## Queue Details

### `tmdb` (Concurrency: 15)

**Purpose**: All interactions with the TMDb API. This queue handles movie discovery, detail fetching, and import orchestration.

**Rate Limiting**: TMDb has a single API rate limit, so all TMDb work is consolidated here for coordinated throttling.

**Current Workers**:
- `DailyYearImportWorker` - Daily scheduled year-by-year imports
- `YearImportCompletionWorker` - Completion handling for year imports
- `TMDbDiscoveryWorker` - Movie discovery from TMDb
- `TMDbDetailsWorker` - Fetching detailed movie information

**Use this queue for**: Any new worker that calls the TMDb API.

---

### `omdb` (Concurrency: 5)

**Purpose**: OMDb API data enrichment. Fetches additional movie data including awards, box office, and critic ratings.

**Rate Limiting**: OMDb has its own separate rate limit (1000/day for free tier), so it has a dedicated queue.

**Current Workers**:
- `OMDbEnrichmentWorker` - Enriches movies with OMDb data

**Use this queue for**: Any new worker that calls the OMDb API.

---

### `collaboration` (Concurrency: 5)

**Purpose**: Processing collaboration relationships between people (actors, directors, etc.).

**Current Workers**:
- `CollaborationWorker` - Processes and updates collaboration data

**Use this queue for**: Any work related to person-to-person collaboration analysis, relationship building, or collaboration graph updates.

---

### `scraping` (Concurrency: 5)

**Purpose**: All web scraping operations including IMDb data extraction, festival information, and awards data.

**Rate Limiting**: Low concurrency to be respectful to scraped sites and avoid rate limiting/blocking.

**Current Workers**:
- `UnifiedFestivalWorker` - Festival data import
- `FestivalDiscoveryWorker` - Discovering festival nominations
- `AwardImportWorker` - Importing award data
- `AwardImportOrchestratorWorker` - Orchestrating award imports
- `FestivalPersonInferenceWorker` - Inferring person data from festivals
- `YearDiscoveryWorker` - Discovering movies by year
- `OscarImportWorker` - Oscar-specific imports
- `CanonicalImportOrchestrator` - Orchestrating canonical list imports
- `CanonicalPageWorker` - Processing canonical list pages
- `CanonicalImportWorker` - Importing canonical list items
- `CanonicalImportCompletionWorker` - Completion handling
- `CanonicalRetryWorker` - Retry logic for failed imports

**Use this queue for**: Any worker that scrapes websites (IMDb, festival sites, etc.) or processes scraped data.

---

### `metrics` (Concurrency: 10)

**Purpose**: All metric calculations, analytics, and prediction work. Higher concurrency since these are CPU-bound rather than I/O-bound.

**Current Workers**:
- `PersonQualityScoreWorker` - Calculating person quality scores
- `PredictionsWorker` - Running predictions
- `PredictionsOrchestrator` - Orchestrating prediction workflows
- `PredictionCalculator` - Individual prediction calculations
- `ComprehensivePredictionsCalculator` - Full prediction recalculations

**Use this queue for**: Any computational work involving metrics, scores, predictions, rankings, or analytics.

---

### `maintenance` (Concurrency: 2)

**Purpose**: Background maintenance tasks that run periodically. Low concurrency since these are non-urgent.

**Current Workers**:
- `MoviesCacheWarmer` - Warming the movies page cache
- `SitemapWorker` - Generating sitemaps
- `CacheWarmupWorker` - General cache warming
- `SlugBackfillWorker` - Backfilling missing slugs

**Use this queue for**: Any periodic/scheduled tasks, cache warming, cleanup jobs, backfills, or other maintenance work.

---

## Guidelines for Adding New Workers

### Do NOT Create New Queues

The current 6-queue system is intentionally consolidated. Before creating a new queue, consider:

1. **Does it call TMDb?** → Use `tmdb`
2. **Does it call OMDb?** → Use `omdb`
3. **Does it scrape websites?** → Use `scraping`
4. **Does it process collaborations?** → Use `collaboration`
5. **Does it calculate metrics/scores?** → Use `metrics`
6. **Is it a maintenance/background task?** → Use `maintenance`

### When to Consider a New Queue

Only create a new queue if:
- You're integrating a **new external API** with its own rate limits
- You have a **fundamentally different workload** that would conflict with existing queues
- You have **specific isolation requirements** (e.g., critical path vs. batch processing)

If you think you need a new queue, discuss with the team first.

### Worker Configuration Example

```elixir
defmodule Cinegraph.Workers.MyNewWorker do
  use Oban.Worker,
    queue: :metrics,  # Choose appropriate queue
    max_attempts: 3,
    unique: [fields: [:args], keys: [:my_id], period: 3600]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # Worker implementation
  end
end
```

## Configuration

Queue configuration is defined in `config/config.exs`:

```elixir
config :cinegraph, Oban,
  repo: Cinegraph.Repo,
  queues: [
    tmdb: 15,
    omdb: 5,
    collaboration: 5,
    scraping: 5,
    metrics: 10,
    maintenance: 2
  ],
  # ... plugins
```

## Monitoring

Queue statistics are displayed in the Import Dashboard (`/import`) and tracked via:
- `Cinegraph.Cache.DashboardStats` - Dashboard statistics
- `Cinegraph.Imports.ImportStats` - Import-specific statistics

## History

This consolidated queue system was implemented in December 2024 (Issue #475), reducing the original 16 queues to 6 for:
- Simpler mental model
- Better rate limit management
- Easier monitoring
- Reduced configuration complexity
