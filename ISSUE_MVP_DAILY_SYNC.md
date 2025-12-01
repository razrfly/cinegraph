# MVP: Daily TMDb Sync by Year with Visual Progress

## Overview

A simplified, incremental approach to importing the entire TMDb database. Instead of complex tracking tables, we leverage what already exists and add minimal infrastructure to:

1. Import movies **year by year**, starting with recent/relevant years
2. Run automatically once per day
3. Show visual progress in the dashboard
4. Store everything in existing structures (movie records, Oban job meta, `api_lookup_metrics`)

---

## Why Year-Based Import?

**Advantages over page-based pagination:**
- **Meaningful progress**: "Imported 2024, 2023, 2022..." vs "Page 4521 of 50000"
- **Prioritization**: Start with recent years (more relevant), work backward
- **Resumable**: If it fails on 2015, we know exactly where to restart
- **Bounded work**: Each year has finite movies (~15k-30k for recent years, less for older)
- **Natural batching**: One year per day is manageable and predictable

**TMDb Discover API supports this:**
```
GET /discover/movie?primary_release_year=2024&sort_by=popularity.desc&page=1
```

---

## What We Already Have (No New Tables Needed)

| Existing Infrastructure | How We Use It |
|------------------------|---------------|
| `ImportStateV2` | Store `current_import_year`, `years_completed` |
| `api_lookup_metrics` | All state stored here via `ApiTracker` |
| `TMDbDiscoveryWorker` | Already handles pagination, just add year filter |
| `TMDbDetailsWorker` | Already stores full TMDb response in `tmdb_data` JSONB |
| `ImportDashboardLive` | Add year progress display |
| Oban job `meta` field | Track per-job progress |
| Movie `tmdb_data` JSONB | **Already stores full TMDb response** - future-proof |

**Key Point:** The `tmdb_data` JSONB field on movies already stores the complete TMDb API response. If we need new fields later, the data is already there - we just query the JSONB.

---

## MVP Implementation

### Phase 1: Year-Based Import Worker (Day 1-2)

**New Oban Worker: `DailyYearImportWorker`**

Simple orchestrator that runs once per day:

```elixir
defmodule Cinegraph.Workers.DailyYearImportWorker do
  use Oban.Worker,
    queue: :tmdb_orchestration,
    max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # 1. Get current year to import
    current_year = get_next_year_to_import()

    if current_year < 1900 do
      Logger.info("All years imported!")
      {:ok, :complete}
    else
      # 2. Queue discovery for this year
      queue_year_import(current_year)

      {:ok, :year_queued}
    end
  end

  defp get_next_year_to_import do
    # Start with current year, work backward
    # Check ImportState for last completed year
    last_completed = ImportStateV2.get_integer("last_completed_year", Date.utc_today().year + 1)
    last_completed - 1
  end

  defp queue_year_import(year) do
    # Use existing TMDbDiscoveryWorker with year filter
    # Queue page 1, it will discover total pages and queue the rest
    %{
      "page" => 1,
      "import_type" => "year_import",
      "year" => year,
      "primary_release_year" => year,
      "sort_by" => "popularity.desc"
    }
    |> TMDbDiscoveryWorker.new()
    |> Oban.insert()

    # Track that we started this year
    ImportStateV2.set("current_import_year", year)
    ImportStateV2.set("year_#{year}_started_at", DateTime.utc_now() |> DateTime.to_iso8601())
  end
end
```

### Phase 2: Modify Existing Discovery Worker (Day 2-3)

**Update `TMDbDiscoveryWorker` to support year filtering:**

The worker already accepts args - just need to pass them to the TMDb API:

```elixir
# In TMDbDiscoveryWorker.perform/1
def perform(%Oban.Job{args: %{"page" => page} = args}) do
  # Build discovery params from args
  params = build_discovery_params(args)

  case TMDb.discover_movies(page, params) do
    {:ok, %{results: movies, total_pages: total_pages}} ->
      # If this is page 1, queue remaining pages for this year
      if page == 1 and args["import_type"] == "year_import" do
        queue_remaining_year_pages(args["year"], total_pages)
      end

      # Process movies (existing logic)
      process_discovery_page(page, movies)
  end
end

defp build_discovery_params(args) do
  %{}
  |> maybe_add_param("primary_release_year", args["primary_release_year"])
  |> maybe_add_param("sort_by", args["sort_by"])
  # ... other filters as needed
end
```

### Phase 3: Year Completion Detection (Day 3-4)

**When all pages for a year are done, mark it complete:**

Option A: Completion checker worker (like `CanonicalImportCompletionWorker`)
```elixir
defmodule Cinegraph.Workers.YearImportCompletionWorker do
  # Polls Oban for all year_import jobs for a specific year
  # When all completed, marks year as done
  def perform(%Oban.Job{args: %{"year" => year}}) do
    pending_jobs = count_pending_jobs_for_year(year)

    if pending_jobs == 0 do
      mark_year_complete(year)
      {:ok, :year_complete}
    else
      # Reschedule to check again in 5 minutes
      {:snooze, 300}
    end
  end

  defp mark_year_complete(year) do
    ImportStateV2.set("last_completed_year", year)
    ImportStateV2.set("year_#{year}_completed_at", DateTime.utc_now() |> DateTime.to_iso8601())

    # Count movies imported for this year
    count = count_movies_for_year(year)
    ImportStateV2.set("year_#{year}_movie_count", count)
  end
end
```

Option B: Simpler - just check in dashboard (no extra worker)
- Dashboard queries movies by release year
- Compares to TMDb total for that year
- Visual shows "2024: 28,432 / 28,500 (99.7%)"

**Recommendation: Start with Option B** - simpler, less infrastructure.

### Phase 4: Dashboard Updates (Day 4-5)

**Add year progress to `ImportDashboardLive`:**

```
┌─────────────────────────────────────────────────────────────────┐
│  📅 YEAR-BY-YEAR IMPORT PROGRESS                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Currently Importing: 2021                                      │
│  ████████████████░░░░░░░░░░░░░░░░  52% (14,234 / 27,500)       │
│                                                                 │
│  Completed Years:                                               │
│  ✅ 2024: 28,432 movies                                         │
│  ✅ 2023: 31,205 movies                                         │
│  ✅ 2022: 29,876 movies                                         │
│  🔄 2021: 14,234 / ~27,500 (importing...)                       │
│  ⏳ 2020: pending                                                │
│  ⏳ 2019: pending                                                │
│  ...                                                            │
│                                                                 │
│  Total: 103,747 / ~1,000,000 movies (10.4%)                     │
│  Est. time to complete all years: ~340 days (1 year/day)        │
│                                                                 │
│  Last sync: Today at 2:00 AM UTC ✅                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Implementation:**
```elixir
defp load_year_progress(socket) do
  current_year = Date.utc_today().year

  # Get years we've imported
  years_data =
    for year <- current_year..1900 do
      movie_count = count_movies_by_year(year)
      status = determine_year_status(year)

      %{year: year, count: movie_count, status: status}
    end
    |> Enum.filter(fn y -> y.count > 0 or y.status == :current end)
    |> Enum.take(10)  # Show last 10 years

  assign(socket, :year_progress, years_data)
end

defp count_movies_by_year(year) do
  # Query movies where release_date year matches
  Repo.one(
    from m in Movie,
    where: fragment("EXTRACT(YEAR FROM ?::date) = ?", m.release_date, ^year),
    select: count(m.id)
  )
end
```

### Phase 5: Cron Setup (Day 5)

**Add to Oban cron config:**

```elixir
{Oban.Plugins.Cron,
  crontab: [
    # Existing
    {"*/10 * * * *", Cinegraph.Workers.MoviesCacheWarmer},

    # NEW: Daily year import at 2 AM UTC
    {"0 2 * * *", Cinegraph.Workers.DailyYearImportWorker}
  ]
}
```

---

## State Tracking (Using Existing Infrastructure)

All state stored in `api_lookup_metrics` via `ImportStateV2`:

| Key | Example Value | Purpose |
|-----|---------------|---------|
| `current_import_year` | `2021` | Year currently being imported |
| `last_completed_year` | `2022` | Most recent fully imported year |
| `year_2024_started_at` | `2024-01-15T02:00:00Z` | When import started |
| `year_2024_completed_at` | `2024-01-15T03:45:00Z` | When import finished |
| `year_2024_movie_count` | `28432` | Movies imported for year |
| `total_movies` | `1000000` | TMDb total (existing) |

**No new tables needed.** The `api_lookup_metrics` table already handles this.

---

## Error Handling & Visibility

### Automatic Retry
- Oban handles retries (max 3 attempts per job)
- Failed jobs visible in Oban dashboard / existing queue stats

### Dashboard Alerts
Simple checks in dashboard:
```elixir
defp check_sync_health do
  last_run = ImportStateV2.get_date("last_daily_sync")
  hours_since = DateTime.diff(DateTime.utc_now(), last_run, :hour)

  cond do
    hours_since > 36 -> {:error, "Daily sync hasn't run in #{hours_since} hours"}
    hours_since > 24 -> {:warning, "Daily sync is overdue"}
    true -> {:ok, "Sync healthy"}
  end
end
```

### Visual Indicators
- ✅ Green: Year complete
- 🔄 Blue: Currently importing
- ⚠️ Yellow: Import stalled (no progress in 4+ hours)
- ❌ Red: Import failed (check Oban)

---

## Future Evolution

This MVP design supports future enhancements without breaking changes:

| Future Feature | How It Fits |
|---------------|-------------|
| **Delta sync** | Add new worker that uses `/movie/changes` API after all years done |
| **Priority years** | Modify `get_next_year_to_import()` to skip to specific years first |
| **Parallel years** | Queue multiple years at once (adjust concurrency) |
| **Historical tracking** | Query `api_lookup_metrics` for `year_*` keys |
| **New movie fields** | Already in `tmdb_data` JSONB - just add migration to extract |

---

## Implementation Checklist

### Week 1: Core Infrastructure
- [ ] Create `DailyYearImportWorker` with basic year selection logic
- [ ] Update `TMDbDiscoveryWorker` to accept `primary_release_year` param
- [ ] Add year state keys to `ImportStateV2` (`current_import_year`, `last_completed_year`)
- [ ] Test manual year import via `iex`

### Week 2: Dashboard & Monitoring
- [ ] Add "Year Progress" section to `ImportDashboardLive`
- [ ] Show completed years with counts
- [ ] Show current year progress bar
- [ ] Add sync health indicator

### Week 3: Automation & Polish
- [ ] Enable cron job for daily execution
- [ ] Add year completion detection (simple dashboard check)
- [ ] Test full cycle: year imports overnight, dashboard shows progress
- [ ] Document manual override commands

### Future (As Needed)
- [ ] Delta sync for post-complete maintenance
- [ ] More granular progress (pages within year)
- [ ] Historical charts of import progress
- [ ] Alerting for stalled imports

---

## Questions to Decide

1. **Starting year**: Current year (2024) and work backward? Or start with a specific range (2020-2024)?

2. **Import speed**: One year per day, or can we do 2-3 years per day?

3. **Year granularity**: Should we track pages within a year, or just "year complete/incomplete"?

4. **Side jobs**: Should OMDb/Collaboration jobs run inline (current behavior) or batch separately?

---

## Related Issues

- Parent issue: #397 (comprehensive design)
- This MVP simplifies and phases the approach

---

## Summary: What's Different from #397

| Aspect | #397 (Original) | This MVP |
|--------|----------------|----------|
| **New tables** | `import_sync_runs` | None - use existing |
| **Tracking** | Complex run history | Simple year-based state |
| **Progress unit** | Pages | Years |
| **Complexity** | 5+ new workers | 1-2 new workers |
| **Time to MVP** | 6 weeks | 2-3 weeks |
| **Dashboard** | Complex charts | Simple year list |

The MVP gets us to **"movies importing daily with visible progress"** faster, with a clear path to add complexity later if needed.
