defmodule Cinegraph.Admin.JobRegistry do
  @moduledoc """
  Single source of truth for every Oban worker the admin UI knows about.

  Two flavors of entry coexist here:

  - **Scheduled entries** (`schedule: cron_string`) — every cron tuple in
    `config/config.exs` Oban Cron plugin gets one entry. The companion test
    in `test/cinegraph/admin/job_registry_test.exs` enforces drift-free
    parity: any cron entry added to `config.exs` without a matching entry
    here fails the test build.

  - **On-demand entries** (`schedule: nil`) — workers that other code
    enqueues (orchestrators, sweepers, manual mix tasks). Surfacing them
    here lets the admin offer a "Run for…" form per worker, even though
    they don't run on a schedule.

  ## Usage

      JobRegistry.scheduled() |> Enum.map(& &1.label)  # 24 cron entries
      JobRegistry.by_id(:biography_refresh_sweeper)
      JobRegistry.enqueue!(entry)                       # → {:ok, %Oban.Job{}}

  Adding a new cron entry is a two-step:

  1. Add the cron tuple to `config/config.exs`.
  2. Add a matching entry to `@entries` here.

  The parity test will fail loudly if you forget step 2.

  ## Why a registry?

  The original #880 audit caught that `/admin/scheduled` would otherwise
  hand-code its table from `config.exs`, and would silently desync any
  time someone added a worker. Reading from a registry that's drift-tested
  on CI is the structural fix.
  """

  alias Cinegraph.Workers

  @typedoc """
  - `id` — stable atom for use in URLs (`/admin/scheduled/:id`)
  - `label` — human-readable name for the table row
  - `worker` — the `Cinegraph.Workers.*` module
  - `queue` — Oban queue (matches `config.exs` queue config)
  - `schedule` — cron string for scheduled entries; `nil` for on-demand
  - `args` — default args passed to `Worker.new/1` when triggered
  - `trigger_action` — how the UI should behave on click
  - `mutating` — whether the worker writes to DB or external APIs
  - `description` — one-line description copied from `config.exs` comments
  - `destination` — drift domain this worker affects (drives drilldown links)
  - `doc_url` — optional external doc link
  """
  @type entry :: %{
          id: atom(),
          label: String.t(),
          worker: module(),
          queue: atom(),
          schedule: String.t() | nil,
          args: map(),
          trigger_action: :enqueue_now | :run_inline | :disabled,
          mutating: boolean(),
          description: String.t(),
          destination: atom(),
          doc_url: String.t() | nil
        }

  @entries [
    # =========================================================================
    # Scheduled entries (25 — must match config.exs crontab exactly)
    # =========================================================================

    %{
      id: :movies_cache_warmer,
      label: "Movies cache warmer",
      worker: Workers.MoviesCacheWarmer,
      queue: :maintenance,
      schedule: "*/30 * * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: false,
      description: "Warm /movies page cache every 10 minutes",
      destination: :system,
      doc_url: nil
    },
    %{
      id: :daily_year_import_worker,
      label: "Daily year import",
      worker: Workers.DailyYearImportWorker,
      queue: :tmdb,
      schedule: "0 4 * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "One-year-per-day TMDb backfill, working backwards from current year",
      destination: :movies,
      doc_url: nil
    },
    %{
      id: :sitemap_worker,
      label: "Sitemap",
      worker: Workers.SitemapWorker,
      queue: :maintenance,
      schedule: "0 2 * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: false,
      description: "Generate XML sitemap daily at 2 AM UTC",
      destination: :system,
      doc_url: nil
    },
    %{
      id: :scheduled_backfill_worker,
      label: "Backfill queue regulator",
      worker: Workers.ScheduledBackfillWorker,
      queue: :maintenance,
      schedule: "*/15 * * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Queues more movies if pending TMDb jobs fall below threshold",
      destination: :movies,
      doc_url: nil
    },
    %{
      id: :ratings_refresh_worker,
      label: "Ratings refresh",
      worker: Workers.RatingsRefreshWorker,
      queue: :omdb,
      schedule: "0 3 * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Daily OMDb gap fill + stale refresh at 3 AM UTC",
      destination: :ratings,
      doc_url: nil
    },
    %{
      id: :completeness_snapshot_worker,
      label: "Completeness snapshot",
      worker: Workers.CompletenessSnapshotWorker,
      queue: :maintenance,
      schedule: "5 5 * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Daily completeness snapshot persisted to completeness_log",
      destination: :system,
      doc_url: nil
    },
    %{
      id: :health_cache_warmer,
      label: "Health cache warmer",
      worker: Workers.HealthCacheWarmer,
      queue: :maintenance,
      schedule: "*/30 * * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: false,
      description: "Pre-compute drift checks every 30 minutes (Cachex 35-min TTL)",
      destination: :system,
      doc_url: nil
    },
    %{
      id: :now_playing_sweeper,
      label: "Now Playing sweeper",
      worker: Workers.NowPlayingSweeper,
      queue: :maintenance,
      schedule: "0 */6 * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Stamps now_playing_last_seen across 5 TMDB regions every 6 hours (#943)",
      destination: :movies,
      doc_url: nil
    },
    %{
      id: :festival_sync_sweeper,
      label: "Festival sync sweeper",
      worker: Workers.FestivalSyncSweeper,
      queue: :festival_discovery,
      schedule: "0 2 1 * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Monthly festival sync — discovers new ceremony years for active festivals",
      destination: :festivals,
      doc_url: nil
    },
    %{
      id: :canonical_list_refresh_sweeper,
      label: "Canonical list refresh",
      worker: Workers.CanonicalListRefreshSweeper,
      queue: :tmdb,
      schedule: "30 1 1 * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Monthly canonical IMDb-list refresh (blank/stale movie_lists)",
      destination: :imports,
      doc_url: nil
    },
    %{
      id: :biography_refresh_sweeper,
      label: "Biography refresh sweeper",
      worker: Workers.BiographyRefreshSweeper,
      queue: :tmdb,
      schedule: "30 5 * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "5,000/day biography fetch on :tmdb queue",
      destination: :people,
      doc_url: nil
    },
    %{
      id: :profile_data_refresh_sweeper,
      label: "Profile data refresh",
      worker: Workers.ProfileDataRefreshSweeper,
      queue: :tmdb,
      schedule: "35 5 * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "3,000/day profile_path + known_for_department on :tmdb",
      destination: :people,
      doc_url: nil
    },
    %{
      id: :watch_provider_catalog_refresh_worker,
      label: "Watch provider catalog refresh",
      worker: Workers.WatchProviderCatalogRefreshWorker,
      queue: :tmdb,
      schedule: "45 5 * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Watch availability provider catalog + supported regions",
      destination: :availability,
      doc_url: nil
    },
    %{
      id: :festival_person_resolver_sweeper,
      label: "Festival person resolver",
      worker: Workers.FestivalPersonResolverSweeper,
      queue: :maintenance,
      schedule: "0 6 * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Festival person-resolver: 2,000/day on :maintenance",
      destination: :festivals,
      doc_url: nil
    },
    %{
      id: :omdb_backfill_sweeper,
      label: "OMDb backfill sweeper",
      worker: Workers.OmdbBackfillSweeper,
      queue: :omdb,
      schedule: "30 6 * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "OMDb null backfill: 5,000/day on :omdb (canonical-list movies first)",
      destination: :ratings,
      doc_url: nil
    },
    %{
      id: :availability_refresh_sweeper,
      label: "Availability refresh",
      worker: Workers.AvailabilityRefreshSweeper,
      queue: :maintenance,
      schedule: "45 6 * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description:
        "Watch availability refresh: 5,000/day — sweeper on :maintenance, child jobs on :movie_availability",
      destination: :availability,
      doc_url: nil
    },
    %{
      id: :imdb_id_repair_sweeper,
      label: "IMDb id repair",
      worker: Workers.ImdbIdRepairSweeper,
      queue: :tmdb,
      schedule: "0 7 * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "IMDb-id repair via TMDb fetches: 5,000/day on :tmdb",
      destination: :movies,
      doc_url: nil
    },
    %{
      id: :collaboration_repair_sweeper,
      label: "Collaboration repair",
      worker: Workers.CollaborationRepairSweeper,
      queue: :collaboration,
      schedule: "30 7 * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Collaboration graph repair: 5,000/day on :collaboration",
      destination: :collaborations,
      doc_url: nil
    },
    %{
      id: :materialized_view_refresh_sweeper,
      label: "Materialized view refresh",
      worker: Workers.MaterializedViewRefreshSweeper,
      queue: :maintenance,
      schedule: "0 8 * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Refresh all public matviews (CONCURRENTLY-only) daily",
      destination: :system,
      doc_url: nil
    },
    %{
      id: :connection_monitor_worker,
      label: "Connection monitor",
      worker: Workers.ConnectionMonitorWorker,
      queue: :maintenance,
      schedule: "*/5 * * * *",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: false,
      description: "pg_stat_activity snapshot + saturation/long-query alerts (every 5 min)",
      destination: :system,
      doc_url: nil
    },
    %{
      id: :zero_credits_cleanup_sweeper,
      label: "Zero-credits cleanup (Sun: refetch)",
      worker: Workers.ZeroCreditsCleanupSweeper,
      queue: :tmdb,
      schedule: "0 4 * * 0",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Sunday 04:00 — enqueue TMDb refetches for orphan people",
      destination: :people,
      doc_url: nil
    },
    %{
      id: :zero_credits_cleanup_delete_sweeper,
      label: "Zero-credits cleanup (Mon: delete)",
      worker: Workers.ZeroCreditsCleanupDeleteSweeper,
      queue: :maintenance,
      schedule: "0 4 * * 1",
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Monday 04:00 — delete still-orphaned crew (24h after refetch)",
      destination: :people,
      doc_url: nil
    },
    %{
      id: :pqs_weekly_full,
      label: "PQS — weekly full",
      worker: Workers.PersonQualityScoreWorker,
      queue: :metrics,
      schedule: "30 3 * * SUN",
      args: %{
        "batch" => "weekly_full",
        "trigger" => "weekly_scheduled",
        "min_credits" => 5
      },
      trigger_action: :enqueue_now,
      mutating: true,
      description: "PQS staleness recurring recalc — weekly full",
      destination: :people,
      doc_url: nil
    },
    %{
      id: :pqs_monthly_deep,
      label: "PQS — monthly deep",
      worker: Workers.PersonQualityScoreWorker,
      queue: :metrics,
      schedule: "0 1 1-7 * SUN",
      args: %{
        "batch" => "monthly_deep",
        "trigger" => "monthly_scheduled",
        "min_credits" => 1
      },
      trigger_action: :enqueue_now,
      mutating: true,
      description: "PQS staleness recurring recalc — monthly deep",
      destination: :people,
      doc_url: nil
    },
    # =========================================================================
    # On-demand entries — workers that other code enqueues, surfaced here so
    # the admin can offer a "Run for..." form. `schedule: nil` excludes them
    # from the parity test against config.exs.
    # =========================================================================

    # TMDb sync / discovery
    %{
      id: :year_discovery_worker,
      label: "Year discovery",
      worker: Workers.YearDiscoveryWorker,
      queue: :tmdb,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Discover all movies for one year via TMDb",
      destination: :movies,
      doc_url: nil
    },
    %{
      id: :year_import_completion_worker,
      label: "Year import completion",
      worker: Workers.YearImportCompletionWorker,
      queue: :tmdb,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Finalize a year-import run after all child jobs complete",
      destination: :movies,
      doc_url: nil
    },
    %{
      id: :tmdb_discovery_worker,
      label: "TMDb discovery",
      worker: Workers.TMDbDiscoveryWorker,
      queue: :tmdb,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Pagination worker for TMDb discovery endpoints",
      destination: :movies,
      doc_url: nil
    },
    %{
      id: :tmdb_details_worker,
      label: "TMDb details",
      worker: Workers.TMDbDetailsWorker,
      queue: :tmdb,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Fetch full movie metadata from TMDb",
      destination: :movies,
      doc_url: nil
    },
    %{
      id: :tmdb_company_metadata_worker,
      label: "TMDb company metadata",
      worker: Workers.TMDbCompanyMetadataWorker,
      queue: :tmdb,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Production company enrichment from TMDb",
      destination: :movies,
      doc_url: nil
    },
    %{
      id: :movie_availability_refresh_worker,
      label: "Movie availability refresh",
      worker: Workers.MovieAvailabilityRefreshWorker,
      queue: :movie_availability,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description:
        "Refresh watch availability for one movie on :movie_availability (concurrency 1)",
      destination: :availability,
      doc_url: nil
    },
    %{
      id: :person_tmdb_refresh_worker,
      label: "Person TMDb refresh",
      worker: Workers.PersonTmdbRefreshWorker,
      queue: :tmdb,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Refresh profile data for one person",
      destination: :people,
      doc_url: nil
    },

    # OMDb / ratings
    %{
      id: :omdb_enrichment_worker,
      label: "OMDb enrichment",
      worker: Workers.OMDbEnrichmentWorker,
      queue: :omdb,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Fetch ratings/plot from OMDb for one movie",
      destination: :ratings,
      doc_url: nil
    },

    # Festivals / awards
    %{
      id: :award_import_orchestrator_worker,
      label: "Award import orchestrator",
      worker: Workers.AwardImportOrchestratorWorker,
      queue: :scraping,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Orchestrate festival/awards import for one organization",
      destination: :festivals,
      doc_url: nil
    },
    %{
      id: :award_import_worker,
      label: "Award import",
      worker: Workers.AwardImportWorker,
      queue: :scraping,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Import awards/nominations for one ceremony year",
      destination: :festivals,
      doc_url: nil
    },
    %{
      id: :oscar_import_worker,
      label: "Oscar import",
      worker: Workers.OscarImportWorker,
      queue: :scraping,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Oscars-specific scraping",
      destination: :festivals,
      doc_url: nil
    },
    %{
      id: :unified_festival_worker,
      label: "Unified festival worker",
      worker: Workers.UnifiedFestivalWorker,
      queue: :festival_discovery,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "General festival discovery worker",
      destination: :festivals,
      doc_url: nil
    },
    %{
      id: :festival_discovery_worker,
      label: "Festival discovery",
      worker: Workers.FestivalDiscoveryWorker,
      queue: :festival_discovery,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Process per-ceremony nominations",
      destination: :festivals,
      doc_url: nil
    },
    %{
      id: :festival_person_inference_worker,
      label: "Festival person inference",
      worker: Workers.FestivalPersonInferenceWorker,
      queue: :maintenance,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Match nominated people to DB person records",
      destination: :festivals,
      doc_url: nil
    },
    %{
      id: :nomination_person_resolver,
      label: "Nomination person resolver",
      worker: Workers.NominationPersonResolver,
      queue: :maintenance,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Resolve a single nomination's person",
      destination: :festivals,
      doc_url: nil
    },

    # Canonical lists
    %{
      id: :canonical_import_worker,
      label: "Canonical import",
      worker: Workers.CanonicalImportWorker,
      queue: :scraping,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Import a single canonical IMDb list",
      destination: :imports,
      doc_url: nil
    },
    %{
      id: :canonical_retry_worker,
      label: "Canonical retry worker",
      worker: Workers.CanonicalRetryWorker,
      queue: :tmdb,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Retry a failed canonical-list import",
      destination: :imports,
      doc_url: nil
    },

    # Predictions / scoring
    %{
      id: :predictions_orchestrator,
      label: "Predictions orchestrator",
      worker: Workers.PredictionsOrchestrator,
      queue: :metrics,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Orchestrate prediction batch runs",
      destination: :metrics,
      doc_url: nil
    },
    %{
      id: :predictions_worker,
      label: "Predictions worker",
      worker: Workers.PredictionsWorker,
      queue: :metrics,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Compute predictions for one chunk of movies",
      destination: :metrics,
      doc_url: nil
    },
    %{
      id: :prediction_calculator,
      label: "Prediction calculator",
      worker: Workers.PredictionCalculator,
      queue: :metrics,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Lower-level prediction computation",
      destination: :metrics,
      doc_url: nil
    },
    %{
      id: :comprehensive_predictions_calculator,
      label: "Comprehensive predictions calculator",
      worker: Workers.ComprehensivePredictionsCalculator,
      queue: :metrics,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Batch predictions across the full movie set",
      destination: :metrics,
      doc_url: nil
    },
    %{
      id: :movie_score_cache_worker,
      label: "Movie score cache",
      worker: Workers.MovieScoreCacheWorker,
      queue: :metrics,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Pre-compute discovery score cache for one movie",
      destination: :metrics,
      doc_url: nil
    },
    %{
      id: :tmdb_popularity_fix_sweeper,
      label: "TMDb popularity fix",
      worker: Workers.TmdbPopularityFixSweeper,
      queue: :maintenance,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Repair tmdb/popularity_score collision from tmdb_data (no API; #1036)",
      destination: :metrics,
      doc_url: nil
    },

    # Misc
    %{
      id: :collaboration_worker,
      label: "Collaboration worker",
      worker: Workers.CollaborationWorker,
      queue: :collaboration,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Compute collaborations for one movie",
      destination: :collaborations,
      doc_url: nil
    },
    %{
      id: :continuous_backfill_worker,
      label: "Continuous backfill",
      worker: Workers.ContinuousBackfillWorker,
      queue: :tmdb,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "On-demand queue filler for ad-hoc backfills",
      destination: :movies,
      doc_url: nil
    },
    %{
      id: :data_repair_worker,
      label: "Data repair",
      worker: Workers.DataRepairWorker,
      queue: :maintenance,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Ad-hoc data-integrity repairs",
      destination: :system,
      doc_url: nil
    },
    %{
      id: :export_backfill_worker,
      label: "Export backfill",
      worker: Workers.ExportBackfillWorker,
      queue: :maintenance,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "Discovery export data backfill",
      destination: :system,
      doc_url: nil
    },
    %{
      id: :slug_backfill_worker,
      label: "Slug backfill",
      worker: Workers.SlugBackfillWorker,
      queue: :maintenance,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: true,
      description: "URL slug backfill",
      destination: :system,
      doc_url: nil
    },
    %{
      id: :cache_warmup_worker,
      label: "Cache warmup",
      worker: Workers.CacheWarmupWorker,
      queue: :maintenance,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: false,
      description: "Bootstrap cache on deploy",
      destination: :system,
      doc_url: nil
    },
    %{
      id: :startup_warmup_worker,
      label: "Startup warmup",
      worker: Workers.StartupWarmupWorker,
      queue: :maintenance,
      schedule: nil,
      args: %{},
      trigger_action: :enqueue_now,
      mutating: false,
      description: "App-boot cache warming",
      destination: :system,
      doc_url: nil
    }
  ]

  @doc "All entries (scheduled + on-demand)."
  @spec all() :: [entry()]
  def all, do: @entries

  @doc "Only scheduled (cron) entries — should match `config.exs` exactly."
  @spec scheduled() :: [entry()]
  def scheduled, do: Enum.filter(@entries, &(&1.schedule != nil))

  @doc "Only on-demand entries (workers other code enqueues)."
  @spec on_demand() :: [entry()]
  def on_demand, do: Enum.filter(@entries, &(&1.schedule == nil))

  @doc "Look up an entry by id. Returns `nil` if not found."
  @spec by_id(atom()) :: entry() | nil
  def by_id(id) when is_atom(id), do: Enum.find(@entries, &(&1.id == id))

  @doc "Filter entries by destination domain."
  @spec by_destination(atom()) :: [entry()]
  def by_destination(domain), do: Enum.filter(@entries, &(&1.destination == domain))

  @doc """
  Enqueue a one-off run of an entry's worker with its registered args.

  Returns `{:ok, %Oban.Job{}}` on success, `{:error, reason}` otherwise.
  """
  @spec enqueue!(entry()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue!(%{trigger_action: :disabled}), do: {:error, :disabled}

  def enqueue!(%{worker: worker, args: args} = _entry) do
    case worker.new(args) |> Oban.insert() do
      {:ok, job} -> {:ok, job}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end
end
