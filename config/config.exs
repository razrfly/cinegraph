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
  fuzzy_match_min_confidence: 0.7

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
    omdb: 5,
    # Collaboration processing
    collaboration: 5,
    # Web scraping (IMDb, festivals, Oscars) - low concurrency for rate limiting
    scraping: 5,
    # All metrics/calculations (person quality scores, predictions, CRI)
    metrics: 10,
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
       {"0 2 * * *", Cinegraph.Workers.SitemapWorker}
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
