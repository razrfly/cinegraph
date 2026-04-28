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
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure Oban
config :cinegraph, Oban,
  repo: Cinegraph.Repo,
  queues: [
    # All TMDb API work (orchestration, discovery, details) - single rate limit
    tmdb: 15,
    # OMDb data enrichment (separate API rate limit)
    # Temporarily 20 for backfill burst — revert to 5 after backlog cleared
    omdb: 20,
    # Collaboration processing
    collaboration: 5,
    # Web scraping (IMDb, festivals, Oscars) - low concurrency for rate limiting
    scraping: 5,
    # Festival discovery processing - very low concurrency to prevent overwhelming the system
    # Each ceremony queues many child jobs, so limit to 2 concurrent ceremonies
    festival_discovery: 2,
    # All metrics/calculations (person quality scores, predictions, CRI)
    # Reduced from 10 to 5 to prevent resource contention during heavy scoring queries
    metrics: 5,
    # Background maintenance tasks (cache warming, sitemap, backfills)
    maintenance: 2
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
       # Warm movies page cache every 10 minutes
       {"*/10 * * * *", Cinegraph.Workers.MoviesCacheWarmer},
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
       # Homeostasis sweepers (#735 Phase 3.1, #739 Phase A) — autonomously
       # drain the dashboard's drift backlogs. Capped per-run; idempotent.
       # Biography refresh: TMDb-rate-limited, capped at 5,000/day.
       {"30 5 * * *", Cinegraph.Workers.BiographyRefreshSweeper},
       # Festival person-resolver: capped at 2,000/day, runs after biographies
       # so resolver lookups can use newly-populated person rows.
       {"0 6 * * *", Cinegraph.Workers.FestivalPersonResolverSweeper}
     ]}
    # PQS scheduling (temporarily disabled for basic functionality)
    # TODO: Fix cron job configuration format
    # {Oban.Plugins.Cron,
    #   crontab: [
    #     # Daily incremental PQS update at 3 AM
    #     {"0 3 * * *", Cinegraph.Workers.PersonQualityScoreWorker, batch: "daily_incremental", trigger: "daily_scheduled", min_credits: 1},
    #     # Weekly full recalculation at 2 AM Sunday
    #     {"0 2 * * SUN", Cinegraph.Workers.PersonQualityScoreWorker, batch: "weekly_full", trigger: "weekly_scheduled", min_credits: 5},
    #     # Monthly deep recalculation at 1 AM first Sunday of month
    #     {"0 1 1-7 * SUN", Cinegraph.Workers.PersonQualityScoreWorker, batch: "monthly_deep", trigger: "monthly_scheduled", min_credits: 1},
    #     # Health check every 6 hours
    #     {"0 */6 * * *", Cinegraph.Workers.PersonQualityScoreWorker, batch: "health_check", trigger: "health_scheduled"},
    #     # Stale cleanup every 12 hours
    #     {"0 */12 * * *", Cinegraph.Workers.PersonQualityScoreWorker, batch: "stale_cleanup", trigger: "stale_scheduled", max_age_days: 7}
    #   ]
    # }
  ]

# Import movie import configuration
import_config "import.exs"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
