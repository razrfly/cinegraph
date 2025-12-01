# Feature: Automated Daily TMDb Sync System with Progress Tracking

## Overview

Build an automated Oban-based system to incrementally sync the entire TMDb database and keep it updated daily. This includes:
1. **Phase 1 (Short-term)**: Progressive bulk import to download the entire TMDb catalog over time
2. **Phase 2 (Long-term)**: Daily delta sync to capture new/changed movies
3. **Dashboard UI**: Real-time visibility into sync progress, errors, and completion estimates

---

## Problem Statement

### Current State
- TMDb has ~1,000,000+ movies total
- We currently have a partial database (tracked via `ImportStateV2`)
- Manual import triggers via dashboard (`start_full_import`, `import_pages`)
- No automated daily sync for new content
- No persistent tracking of import progress across sessions
- Limited visibility into what percentage of TMDb we've captured
- Side jobs (OMDb, collaborations, PQS) run but aren't coordinated with main import

### Desired State
- Automated background process that progressively imports the full TMDb catalog
- Daily sync to capture new releases and changes
- Clear visibility into import progress (X% complete, Y days remaining)
- Dashboard showing sync health, errors, and historical trends
- Coordinated side job orchestration

---

## Analysis: TMDb API Capabilities

### Available Endpoints for Sync

| Endpoint | Use Case | Rate Limit Consideration |
|----------|----------|-------------------------|
| `GET /discover/movie` | Bulk pagination through entire catalog | High volume, ~20 movies/page |
| `GET /movie/changes` | Daily delta - movies changed in last 24h | Lower volume, IDs only |
| `GET /movie/now_playing` | Recent theatrical releases | Focused, region-specific |
| `GET /movie/{id}` | Full movie details | Required for each movie |

### Recommended Sync Strategies

#### Strategy A: Changes API (Recommended for Daily Updates)
```
GET /movie/changes?start_date=YYYY-MM-DD&end_date=YYYY-MM-DD
```
- Returns movie IDs that changed in the date range
- Efficient for daily deltas (typically 2,000-10,000 changes/day)
- Requires separate detail fetch per movie
- **Best for**: Post-full-sync daily maintenance

#### Strategy B: Discover Pagination (Recommended for Bulk Import)
```
GET /discover/movie?page=N&sort_by=popularity.desc
```
- Returns full movie list data (20 movies/page)
- ~50,000 pages total for complete catalog
- Already implemented in `TMDbDiscoveryWorker`
- **Best for**: Initial bulk import

#### Strategy C: Daily Export Files (Alternative)
TMDb provides daily export files with all movie IDs. Could be used for:
- Identifying gaps in our database
- Bulk validation of what we're missing
- **Consideration**: Requires additional download/parse infrastructure

---

## Proposed Architecture

### Phase 1: Progressive Bulk Import System

#### New Worker: `DailyBulkImportOrchestrator`
Runs daily at off-peak hours to import a configurable batch of movies.

```elixir
# Cron: "0 2 * * *" (2 AM UTC daily)
defmodule Cinegraph.Workers.DailyBulkImportOrchestrator do
  use Oban.Worker,
    queue: :tmdb_orchestration,
    max_attempts: 3

  # Configurable daily batch size
  @daily_page_limit 200  # ~4,000 movies/day

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # 1. Check if we've completed bulk import
    progress = get_bulk_import_progress()

    if progress.percent_complete >= 100.0 do
      Logger.info("Bulk import complete, switching to delta sync mode")
      {:ok, :bulk_complete}
    else
      # 2. Queue next batch of pages
      start_page = ImportState.last_page_processed() + 1
      end_page = start_page + @daily_page_limit - 1

      # 3. Respect TMDb total pages
      end_page = min(end_page, progress.total_pages)

      # 4. Queue discovery jobs
      TMDbImporter.queue_pages(start_page, end_page, "bulk_daily")

      # 5. Record metrics
      record_bulk_import_metrics(start_page, end_page)

      {:ok, :batch_queued}
    end
  end
end
```

#### New Schema: `import_sync_runs`
Track each sync run for historical analysis.

```elixir
schema "import_sync_runs" do
  field :run_type, :string  # "bulk_daily", "delta_daily", "manual"
  field :status, :string    # "running", "completed", "failed"
  field :started_at, :utc_datetime
  field :completed_at, :utc_datetime
  field :pages_processed, :integer
  field :movies_imported, :integer
  field :movies_skipped, :integer
  field :errors_count, :integer
  field :metadata, :map     # Additional context
  timestamps()
end
```

#### Progress Calculation
```elixir
def get_bulk_import_progress do
  tmdb_total = ImportState.get_tmdb_total_movies()
  our_total = Repo.aggregate(Movie, :count, :id)
  total_pages = div(tmdb_total, 20) + 1  # ~20 movies per page

  %{
    tmdb_total: tmdb_total,
    our_total: our_total,
    remaining: max(0, tmdb_total - our_total),
    percent_complete: Float.round(our_total / tmdb_total * 100, 2),
    total_pages: total_pages,
    last_page: ImportState.last_page_processed(),
    estimated_days_remaining: calculate_days_remaining(remaining, @daily_page_limit * 20)
  }
end
```

### Phase 2: Daily Delta Sync System

#### New Worker: `DailyDeltaSyncWorker`
Once bulk import is complete, switch to changes-based sync.

```elixir
# Cron: "0 4 * * *" (4 AM UTC daily, after bulk import window)
defmodule Cinegraph.Workers.DailyDeltaSyncWorker do
  use Oban.Worker,
    queue: :tmdb_orchestration,
    max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # Only run if bulk import is complete
    unless bulk_import_complete?(), do: {:ok, :skipped_bulk_incomplete}

    # 1. Get yesterday's date range
    end_date = Date.utc_today()
    start_date = Date.add(end_date, -1)

    # 2. Fetch changed movie IDs from TMDb
    changed_ids = fetch_all_changed_movie_ids(start_date, end_date)

    # 3. Filter to movies we need to update
    ids_to_process = filter_processable_ids(changed_ids)

    # 4. Queue detail jobs
    queue_detail_jobs(ids_to_process, "delta_daily")

    # 5. Record metrics
    record_delta_sync_metrics(changed_ids, ids_to_process)

    {:ok, :delta_sync_complete}
  end

  defp fetch_all_changed_movie_ids(start_date, end_date) do
    # Paginate through changes API
    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&TMDb.get_movie_changes(&1, start_date, end_date))
    |> Stream.take_while(fn {:ok, %{results: r}} -> length(r) > 0 end)
    |> Enum.flat_map(fn {:ok, %{results: r}} -> Enum.map(r, & &1["id"]) end)
  end
end
```

### Phase 3: Side Job Orchestration

#### Current Side Job Cascade
When a movie is imported via `TMDbDetailsWorker`:
1. ✅ `OMDbEnrichmentWorker` - Fetches OMDB data
2. ✅ `CollaborationWorker` - Builds person-to-person relationships
3. ❌ `PersonQualityScoreWorker` - Currently disabled in cron

#### Recommended: Job Dependency Tracking

```elixir
# New schema: import_job_dependencies
schema "import_job_dependencies" do
  field :movie_id, :integer
  field :tmdb_details_completed, :boolean, default: false
  field :omdb_enrichment_completed, :boolean, default: false
  field :collaboration_completed, :boolean, default: false
  field :pqs_recalculated, :boolean, default: false
  field :all_complete, :boolean, default: false
  timestamps()
end
```

#### Side Job Coordination Worker
```elixir
defmodule Cinegraph.Workers.ImportCompletionChecker do
  use Oban.Worker, queue: :orchestration

  # Called after each side job completes
  def check_movie_completion(movie_id) do
    deps = get_or_create_dependencies(movie_id)

    if all_dependencies_complete?(deps) do
      mark_import_fully_complete(movie_id)
      maybe_trigger_pqs_recalc(movie_id)
    end
  end
end
```

---

## Dashboard UI Enhancements

### New Dashboard Section: "Sync Health"

```
┌─────────────────────────────────────────────────────────────────┐
│  📊 SYNC HEALTH                                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Bulk Import Progress                                           │
│  ████████████░░░░░░░░░░░░░░░░░░░░░░░░  35.2%                   │
│  352,000 / 1,000,000 movies                                     │
│                                                                 │
│  📅 Estimated Completion: March 15, 2025 (~162 days)            │
│  📈 Import Rate: 4,000 movies/day                               │
│                                                                 │
│  ─────────────────────────────────────────────────────────────  │
│                                                                 │
│  Last 7 Days                                                    │
│  ┌────┬────────┬─────────┬────────┬────────┐                   │
│  │Day │Imported│ Skipped │ Errors │ Status │                   │
│  ├────┼────────┼─────────┼────────┼────────┤                   │
│  │Mon │  4,102 │    892  │     3  │   ✅   │                   │
│  │Tue │  3,998 │    756  │     0  │   ✅   │                   │
│  │Wed │  4,210 │    812  │     1  │   ✅   │                   │
│  │Thu │  4,056 │    901  │     0  │   ✅   │                   │
│  │Fri │  0     │    0    │     0  │   ⏸️   │                   │
│  │Sat │  4,150 │    845  │     2  │   ✅   │                   │
│  │Sun │  4,089 │    867  │     0  │   ✅   │                   │
│  └────┴────────┴─────────┴────────┴────────┘                   │
│                                                                 │
│  ─────────────────────────────────────────────────────────────  │
│                                                                 │
│  Side Job Status                                                │
│  • OMDb Enrichment: 98.2% complete (348,456 / 352,000)         │
│  • Collaborations: 97.8% complete (344,456 / 352,000)          │
│  • PQS Calculations: Scheduled (next run: 3 AM)                 │
│                                                                 │
│  ─────────────────────────────────────────────────────────────  │
│                                                                 │
│  ⚠️  Alerts                                                     │
│  • 3 API errors in last 24h (rate limit retried successfully)   │
│  • 156 movies missing OMDb data (no IMDb ID)                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Implementation: LiveView Component

```elixir
defmodule CinegraphWeb.Live.SyncHealthComponent do
  use CinegraphWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="sync-health-panel">
      <h2>Sync Health</h2>

      <.progress_bar
        percent={@progress.percent_complete}
        label={"#{@progress.our_total} / #{@progress.tmdb_total} movies"}
      />

      <div class="stats-grid">
        <.stat_card
          title="Est. Completion"
          value={@progress.estimated_completion_date}
        />
        <.stat_card
          title="Daily Rate"
          value={"#{@progress.daily_rate} movies/day"}
        />
      </div>

      <.sync_history_table runs={@recent_runs} />
      <.side_job_status jobs={@side_jobs} />
      <.alerts alerts={@alerts} />
    </div>
    """
  end
end
```

---

## Error Handling & Alerting

### Error Categories

| Category | Example | Recovery Strategy |
|----------|---------|-------------------|
| Rate Limit | TMDb 429 response | Exponential backoff, auto-retry |
| API Error | 500 from TMDb | Retry 3x, then skip & log |
| Data Error | Missing required fields | Soft import, flag for review |
| Network | Connection timeout | Retry with backoff |

### Alert Triggers

```elixir
defmodule Cinegraph.Imports.AlertManager do
  # Alert if daily import didn't run
  def check_daily_import_ran do
    last_run = get_last_sync_run("bulk_daily")
    if DateTime.diff(DateTime.utc_now(), last_run.completed_at, :hour) > 36 do
      send_alert(:import_stalled, "Daily import hasn't run in 36+ hours")
    end
  end

  # Alert if error rate exceeds threshold
  def check_error_rate do
    last_run = get_last_sync_run()
    error_rate = last_run.errors_count / last_run.movies_processed * 100
    if error_rate > 5.0 do
      send_alert(:high_error_rate, "Error rate #{error_rate}% exceeds 5% threshold")
    end
  end

  # Alert if import rate drops significantly
  def check_import_rate do
    avg_rate = get_7_day_average_rate()
    today_rate = get_today_rate()
    if today_rate < avg_rate * 0.5 do
      send_alert(:low_import_rate, "Today's import rate is 50% below average")
    end
  end
end
```

### Dashboard Alert Display
- Show in ImportDashboardLive
- Color-coded severity (info, warning, error)
- Link to relevant logs/jobs
- Clear/acknowledge functionality

---

## Configuration Options

### Environment Variables

```elixir
# config/runtime.exs
config :cinegraph, :tmdb_sync,
  # Daily bulk import settings
  bulk_daily_page_limit: System.get_env("TMDB_BULK_DAILY_PAGES", "200") |> String.to_integer(),
  bulk_import_enabled: System.get_env("TMDB_BULK_IMPORT_ENABLED", "true") == "true",
  bulk_import_cron: System.get_env("TMDB_BULK_IMPORT_CRON", "0 2 * * *"),

  # Delta sync settings
  delta_sync_enabled: System.get_env("TMDB_DELTA_SYNC_ENABLED", "true") == "true",
  delta_sync_cron: System.get_env("TMDB_DELTA_SYNC_CRON", "0 4 * * *"),
  delta_lookback_days: System.get_env("TMDB_DELTA_LOOKBACK_DAYS", "1") |> String.to_integer(),

  # Rate limiting
  requests_per_second: System.get_env("TMDB_REQUESTS_PER_SECOND", "4") |> String.to_integer(),

  # Alerting
  alert_email: System.get_env("TMDB_SYNC_ALERT_EMAIL"),
  error_rate_threshold: System.get_env("TMDB_ERROR_RATE_THRESHOLD", "5.0") |> String.to_float()
```

### Oban Cron Configuration

```elixir
# config/config.exs
{Oban.Plugins.Cron,
  crontab: [
    # Existing
    {"*/10 * * * *", Cinegraph.Workers.MoviesCacheWarmer},

    # New: Daily bulk import orchestrator (2 AM UTC)
    {"0 2 * * *", Cinegraph.Workers.DailyBulkImportOrchestrator},

    # New: Daily delta sync (4 AM UTC)
    {"0 4 * * *", Cinegraph.Workers.DailyDeltaSyncWorker},

    # New: Sync health check (every 6 hours)
    {"0 */6 * * *", Cinegraph.Workers.SyncHealthChecker},

    # Re-enable: PQS calculations
    {"0 5 * * *", Cinegraph.Workers.PersonQualityScoreWorker, args: %{batch: "daily_incremental"}}
  ]
}
```

---

## Implementation Plan

### Phase 1: Foundation (Week 1-2)
- [ ] Create `import_sync_runs` migration
- [ ] Implement `DailyBulkImportOrchestrator` worker
- [ ] Add bulk progress tracking to `ImportState`
- [ ] Update dashboard with basic progress bar
- [ ] Enable cron job for daily bulk import

### Phase 2: Monitoring (Week 3)
- [ ] Implement `SyncHealthChecker` worker
- [ ] Add `import_alerts` schema and `AlertManager`
- [ ] Build sync history table in dashboard
- [ ] Add error rate and stall detection
- [ ] Create alert display component

### Phase 3: Delta Sync (Week 4)
- [ ] Implement TMDb Changes API client
- [ ] Build `DailyDeltaSyncWorker`
- [ ] Add automatic switch from bulk to delta mode
- [ ] Update dashboard for delta sync metrics

### Phase 4: Side Job Orchestration (Week 5)
- [ ] Create job dependency tracking schema
- [ ] Implement `ImportCompletionChecker`
- [ ] Re-enable PQS cron jobs
- [ ] Add side job status to dashboard

### Phase 5: Polish (Week 6)
- [ ] Historical charts (Oban job metrics over time)
- [ ] Export/download sync reports
- [ ] Manual override controls (pause, resume, reset)
- [ ] Documentation

---

## Comparison: Eventasaurus Patterns Applied

| Eventasaurus Pattern | Cinegraph Application |
|---------------------|----------------------|
| **20+ queues with rate limits** | Add `tmdb_orchestration` queue (low concurrency) |
| **Cron-based orchestrators** | `DailyBulkImportOrchestrator` runs daily |
| **Job metadata tracking** | Use Oban's `job.meta` for progress |
| **Multi-stage pipelines** | Discovery → Details → OMDb → Collaboration → PQS |
| **JobExecutionSummaries** | `import_sync_runs` table for history |
| **Admin dashboard components** | New `SyncHealthComponent` LiveView |
| **Pre-filtering** | Skip already-imported movies in discovery |
| **Exponential backoff** | Implement `backoff/1` in workers |

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| TMDb rate limits | Respect 40 req/10s, use queue concurrency limits |
| Import job failures | 3 retry attempts, then log and continue |
| Missing side job data | Track dependencies, flag incomplete imports |
| Silent failures | Health checks every 6 hours, stall detection |
| Disk/DB pressure | Spread imports over time, monitor resource usage |

---

## Success Metrics

1. **Coverage**: Track `our_total / tmdb_total` percentage
2. **Freshness**: Days since last successful sync
3. **Reliability**: Daily import success rate >99%
4. **Side Job Completion**: % of movies with all side jobs complete
5. **Error Rate**: <5% of import attempts failing

---

## Questions for Discussion

1. **Batch Size**: Is 4,000 movies/day (~200 pages) sustainable? Should we start smaller?
2. **Priority**: Should we prioritize popular movies first, or go sequentially?
3. **Storage**: Any concerns about database size growth (~1M movies)?
4. **Side Jobs**: Should OMDb/Collaboration jobs run inline or via separate scheduled batches?
5. **PQS**: Re-enable the disabled cron jobs or redesign the scheduling?

---

## References

- [TMDb API Documentation](https://developer.themoviedb.org/reference/changes-movie-list)
- [Oban Documentation](https://hexdocs.pm/oban/)
- Eventasaurus Oban patterns: `/Users/holdenthomas/Code/paid-projects-2025/eventasaurus/`
- Current import implementation: `lib/cinegraph/imports/tmdb_importer.ex`
