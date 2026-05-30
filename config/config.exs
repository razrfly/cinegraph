# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :cinegraph,
  ecto_repos: [Cinegraph.Repo],
  generators: [timestamp_type: :utc_datetime],
  # Minimum confidence threshold for fuzzy matching movies (0.0 - 1.0)
  # Movies found with confidence below this threshold will be skipped
  fuzzy_match_min_confidence: 0.7,
  # Scraping adapter chains per source — tried in order until one succeeds
  scraping_strategies: %{
    oscars: [:crawlbase],
    # Direct always fails for IMDb (AWS WAF returns 202). Crawlbase-only means
    # failures surface as real Crawlbase errors, not the misleading "HTTP 202".
    imdb: [:crawlbase],
    # IMDb /list/ pages: as of 2026-05-29 the Crawlbase JS Crawling API once again solves
    # IMDb's AWS WAF challenge (520 + pc_status=200 + full rendered HTML) on /list/ pages —
    # the hard 403 documented in #1002/#1003 has lifted. Crawlbase JS is tried first; Smart
    # AI Proxy stays as a fallback (datacenter-IP-only on the free tier, so mostly 613/202 —
    # kept only in case the JS path regresses again). See GitHub issue #1003.
    imdb_list: [:crawlbase, :crawlbase_smart_proxy],
    default: [:direct]
  }

# Health/drift thresholds (#722). Tuples are `{green_max, amber_max}`.
# Float values compared against `affected_pct`; integer values against
# `affected_count`. Values above amber_max are :red.
config :cinegraph, :health,
  thresholds: %{
    default: {1.0, 10.0},
    people: %{
      missing_profile_path: {2.0, 8.0},
      # genuinely sparse on TMDb
      missing_biography: {30.0, 60.0},
      missing_known_for_department: {2.0, 10.0},
      stale_record: {20.0, 50.0},
      zero_credits: {1.0, 5.0},
      person_required_nomination_missing_person: {2.0, 10.0},
      pqs_stale: {10.0, 30.0}
    },
    movies: %{
      year_gap: {1.0, 5.0},
      missing_omdb: {5.0, 15.0},
      stale_omdb: {30.0, 60.0},
      missing_imdb_id: {2.0, 10.0}
    },
    festivals: %{
      # absolute counts not pcts
      nominations_below_floor: {0, 2},
      missing_categories: {0, 1},
      # corruption — any → red
      nominations_missing_movie: {0, 0},
      person_required_missing_person: {2.0, 10.0}
    },
    ratings: %{
      omdb_null_backlog: {5.0, 15.0},
      omdb_stale: {30.0, 60.0},
      rt_metacritic_gap: {30.0, 50.0}
    },
    availability: %{
      availability_missing: {5.0, 20.0},
      availability_stale: {20.0, 50.0},
      availability_fetch_errors: {1.0, 5.0},
      availability_provider_catalog_stale: {0, 0}
    },
    collaborations: %{
      missing_details: {1.0, 10.0},
      queue_backlog: {10_000, 50_000},
      recent_failures: {0, 10}
    }
  }

# Configures the endpoint
config :cinegraph, CinegraphWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CinegraphWeb.ErrorHTML, json: CinegraphWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Cinegraph.PubSub,
  live_view: [signing_salt: "ZsY3nhKf"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :cinegraph, Cinegraph.Mailer, adapter: Swoosh.Adapters.Local

# R2 client module (#890). Real impl in dev/prod; tests override to a stub
# in config/test.exs so unit tests don't hit live R2.
config :cinegraph, :r2_client, Cinegraph.Images.R2

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  cinegraph: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  cinegraph: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ],
  cinegraph_neutral: [
    args: ~w(
      --config=tailwind.cinegraph_neutral.config.js
      --input=css/cinegraph_neutral.css
      --output=../priv/static/assets/cinegraph_neutral.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ],
  oatmeal: [
    args: ~w(
      --config=tailwind.oatmeal.config.js
      --input=css/oatmeal.css
      --output=../priv/static/assets/oatmeal.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Honeybadger error monitoring. API key injected at runtime via runtime.exs.
# Disabled in dev/test; active in prod automatically via exclude_envs.
config :honeybadger,
  app: :cinegraph,
  environment_name: config_env(),
  exclude_envs: [:dev, :test],
  filter_keys: [:password, :key, :api_key, :access_key],
  insights_enabled: true,
  insights_config: %{
    oban: %{telemetry_events: [[:oban, :job, :stop], [:oban, :job, :exception]]}
  }

# Redact secrets from Phoenix request logs. Pixabay's upstream API requires
# `key=` in the query string, so keep generic key names filtered too.
config :phoenix, :filter_parameters, ["password", "key", "api_key", "access_key"]

# Configure Oban
config :cinegraph, Oban,
  repo: Cinegraph.Repo,
  queues: [
    # DB-protective defaults for native Postgres. Production may override these
    # with OBAN_*_LIMIT env vars in runtime.exs after measuring capacity.
    # All TMDb API work (orchestration, discovery, details, availability)
    tmdb: 5,
    # OMDb data enrichment (separate API rate limit, shared DB budget)
    omdb: 5,
    # Collaboration processing
    collaboration: 3,
    # Web scraping (IMDb, festivals, Oscars)
    scraping: 3,
    # Festival discovery processing - very low concurrency to prevent overwhelming the system
    # Each ceremony queues many child jobs, so limit to 1 concurrent ceremony
    festival_discovery: 1,
    # Movie watch-provider availability refresh — concurrency 1 to prevent deadlocks.
    # Multiple concurrent workers all upsert the same shared global watch_providers rows
    # (Netflix, Amazon, etc.) inside a long Repo.transaction, causing PostgreSQL ShareLock
    # deadlocks on the watch_providers unique index. See: GitHub #999.
    movie_availability: 1,
    # All metrics/calculations (person quality scores, predictions, CRI)
    metrics: 2,
    # Background maintenance tasks (cache warming, sitemap, backfills)
    maintenance: 1
  ],
  # Give jobs more time to complete during deployments/restarts
  shutdown_grace_period: :timer.seconds(60),
  plugins: [
    # Rescue orphaned jobs left in executing state after node crashes/restarts
    # Checks every 1 minute, rescues jobs stuck for more than 10 minutes
    {Oban.Plugins.Lifeline, interval: :timer.minutes(1), rescue_after: :timer.minutes(10)},
    # Keep jobs for 7 days
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Reindexer, schedule: "@daily"},
    # Cache warming and daily imports cron jobs
    {Oban.Plugins.Cron,
     crontab: [
       # Warm movies page cache every 30 minutes
       {"*/30 * * * *", Cinegraph.Workers.MoviesCacheWarmer},
       # Daily year-by-year TMDb import at 4 AM UTC
       # Imports one year at a time, working backwards from current year
       {"0 4 * * *", Cinegraph.Workers.DailyYearImportWorker},
       # Generate sitemap daily at 2 AM UTC
       # Runs after most daily imports have completed
       {"0 2 * * *", Cinegraph.Workers.SitemapWorker},
       # Backfill queue regulation - runs every 15 minutes to check queue health
       # Queues more movies if pending jobs fall below threshold (stateless approach)
       {"*/15 * * * *", Cinegraph.Workers.ScheduledBackfillWorker},
       # Daily OMDb gap fill + stale refresh at 3 AM UTC
       {"0 3 * * *", Cinegraph.Workers.RatingsRefreshWorker},
       # Daily completeness snapshot at 5:05 AM UTC (after the 4 AM TMDb sync settles) — #722
       {"5 5 * * *", Cinegraph.Workers.CompletenessSnapshotWorker},
       # Health-cache warmer (#745 Phase 3.3) — keeps `:health_cache` warm
       # so `/admin/health` cold-paint stays sub-second. Drift checks have a
       # 35-min Cachex TTL; warm every 30 min so rows are recomputed before
       # they expire. Plus a one-shot warm fires from `Cinegraph.Application`
       # on app boot (so the very first request after deploy is also fast).
       {"*/30 * * * *", Cinegraph.Workers.HealthCacheWarmer},
       # Now Playing sweep (#943) — polls TMDB /movie/now_playing across 5
       # regions (US, GB, DE, FR, PL) and stamps `now_playing_last_seen` on
       # matched movies. Films missing from all regions for >3 days go stale
       # naturally. ~60 TMDB requests/day total (5 regions × 3 pages × 4 runs).
       {"0 */6 * * *", Cinegraph.Workers.NowPlayingSweeper},
       # Monthly festival sync (#745 Phase 2) — discovers new ceremony years
       # for active festivals + enqueues imports for any year not yet in
       # the DB. Runs at 02:00 UTC on the 1st of each month to avoid burning
       # Crawlbase tokens on stable year lists.
       {"0 2 1 * *", Cinegraph.Workers.FestivalSyncSweeper},
       # Monthly canonical IMDb-list refresh — queues a small capped batch
       # of blank/stale `movie_lists` backed by IMDb `ls...` pages.
       {"30 1 1 * *", Cinegraph.Workers.CanonicalListRefreshSweeper},
       # Homeostasis sweepers (#735 Phase 3.1, #739 Phase A, #745 Phase 1) —
       # autonomously drain the dashboard's drift backlogs. Capped per-run;
       # idempotent (workers are uniqueness-keyed).
       #
       # Biography refresh: 5,000/day on :tmdb queue.
       {"30 5 * * *", Cinegraph.Workers.BiographyRefreshSweeper},
       # Profile-data refresh (profile_path + known_for_department): 3,000/day
       # on :tmdb. 5 min after bio sweeper so PersonTmdbRefreshWorker's 1-hour
       # unique constraint dedupes overlapping enqueues.
       {"35 5 * * *", Cinegraph.Workers.ProfileDataRefreshSweeper},
       # Watch availability provider catalog + supported regions.
       {"45 5 * * *", Cinegraph.Workers.WatchProviderCatalogRefreshWorker},
       # Festival person-resolver: 2,000/day on :maintenance.
       {"0 6 * * *", Cinegraph.Workers.FestivalPersonResolverSweeper},
       # OMDb null backfill: 5,000/day on :omdb. Canonical-list movies first.
       {"30 6 * * *", Cinegraph.Workers.OmdbBackfillSweeper},
       # Watch availability refresh: 5,000/day on :tmdb.
       {"45 6 * * *", Cinegraph.Workers.AvailabilityRefreshSweeper},
       # IMDb-id repair via TMDb fetches: 5,000/day on :tmdb.
       {"0 7 * * *", Cinegraph.Workers.ImdbIdRepairSweeper},
       # Collaboration graph repair: 5,000 movies/day enqueued.
       # Sweeper itself runs on :maintenance; the per-movie rebuilds it
       # enqueues run on :collaboration (concurrency 3).
       {"30 7 * * *", Cinegraph.Workers.CollaborationRepairSweeper},
       # Zero-credits cleanup — two phases. Sunday 04:00 enqueues TMDb
       # refetches for orphan people; Monday 04:00 deletes those that
       # remained orphaned (gives the refetches 24h to land).
       {"0 4 * * 0", Cinegraph.Workers.ZeroCreditsCleanupSweeper},
       {"0 4 * * 1", Cinegraph.Workers.ZeroCreditsCleanupDeleteSweeper},
       # PQS recurring recalc — only the two functional cron entries (weekly_full,
       # monthly_deep) remain. Removed in #928: daily_incremental, health_check,
       # stale_cleanup — those args don't match any worker perform/1 clause and
       # discarded 100% every fire. For autonomous stale-score handling, see
       # `Cinegraph.Metrics.PQSScheduler` (schedule_daily_incremental/0,
       # schedule_stale_cleanup/1, check_system_health/0) which look up the
       # right person_ids before enqueueing.
       {"30 3 * * SUN", Cinegraph.Workers.PersonQualityScoreWorker,
        args: %{"batch" => "weekly_full", "trigger" => "weekly_scheduled", "min_credits" => 5}},
       {"0 1 1-7 * SUN", Cinegraph.Workers.PersonQualityScoreWorker,
        args: %{"batch" => "monthly_deep", "trigger" => "monthly_scheduled", "min_credits" => 1}}
     ]}
  ]

# Import movie import configuration
import_config "import.exs"

# Clerk authentication configuration (credentials loaded at runtime)
import_config "clerk.exs"

config :appsignal, :config,
  otp_app: :cinegraph,
  name: "cinegraph",
  env: config_env()

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
