import Config
import Dotenvy

# Load .env files only in development
# After source!, use env/2 to access variables (System.get_env won't see .env values)
if config_env() == :dev do
  source!([
    ".env",
    # Optional: dev-specific overrides
    ".env.dev",
    # System env vars take precedence
    System.get_env()
  ])
end

# In dev, env!/3 reads from source!; in prod, use System.get_env
# Note: env!/3 is only available after source! is called (dev only)
# Syntax: env!(key, type, default) - type can be :string, :integer, :boolean, etc.
tmdb_api_key =
  if config_env() == :dev,
    do: env!("TMDB_API_KEY", :string, nil),
    else: System.get_env("TMDB_API_KEY")

omdb_api_key =
  if config_env() == :dev,
    do: env!("OMDB_API_KEY", :string, ""),
    else: System.get_env("OMDB_API_KEY") || ""

cinegraph_base_url =
  if config_env() == :dev,
    do: env!("CINEGRAPH_BASE_URL", :string, "http://localhost:4000"),
    else: System.get_env("CINEGRAPH_BASE_URL") || "https://cinegraph.app"

config :cinegraph, :cinegraph_base_url, cinegraph_base_url

wombie_base_url =
  if config_env() == :dev,
    do: env!("WOMBIE_BASE_URL", :string, "https://wombie.com"),
    else: System.get_env("WOMBIE_BASE_URL") || "https://wombie.com"

config :cinegraph, :wombie_base_url, wombie_base_url

crawlbase_api_key =
  if config_env() == :dev,
    do: env!("CRAWLBASE_API_KEY", :string, ""),
    else: System.get_env("CRAWLBASE_API_KEY") || ""

crawlbase_js_api_key =
  if config_env() == :dev,
    do: env!("CRAWLBASE_JS_API_KEY", :string, ""),
    else: System.get_env("CRAWLBASE_JS_API_KEY") || ""

# Configure TMDb
# API key is optional at config time - the service will handle missing keys at runtime
config :cinegraph, Cinegraph.Services.TMDb.Client, api_key: tmdb_api_key

# Configure OMDb (optional)
config :cinegraph, Cinegraph.Services.OMDb.Client, api_key: omdb_api_key

# Stock image search APIs (#880 Phase 2 — optional "Suggest images" picker
# for festival admin). Each is read at runtime; provider modules return
# `:disabled` when their key is unset, which the picker uses to hide that
# source without crashing.
unsplash_access_key =
  if config_env() == :dev,
    do: env!("UNSPLASH_ACCESS_KEY", :string, ""),
    else: System.get_env("UNSPLASH_ACCESS_KEY") || ""

pexels_api_key =
  if config_env() == :dev,
    do: env!("PEXELS_API_KEY", :string, ""),
    else: System.get_env("PEXELS_API_KEY") || ""

pixabay_api_key =
  if config_env() == :dev,
    do: env!("PIXABAY_API_KEY", :string, ""),
    else: System.get_env("PIXABAY_API_KEY") || ""

config :cinegraph, Cinegraph.Images.Providers.Unsplash, access_key: unsplash_access_key
config :cinegraph, Cinegraph.Images.Providers.Pexels, api_key: pexels_api_key
config :cinegraph, Cinegraph.Images.Providers.Pixabay, api_key: pixabay_api_key

# Honeybadger — missing key disables reporting silently rather than crashing startup.
config :honeybadger, api_key: System.get_env("HONEYBADGER_API_KEY")

# AppSignal — push_api_key set at runtime so it's never baked into the image.
config :appsignal, :config, push_api_key: System.get_env("APPSIGNAL_PUSH_API_KEY")

# Cloudflare R2 image storage (#890). Used by Cinegraph.Images.R2 for
# admin-uploaded festival logos / hero images. S3-compatible API; the
# CLOUDFLARE_*, R2_BUCKET, and R2_CDN_URL env vars are required in prod.
# Without them we'd be saving bad public URLs even when uploads succeed.
# config/test.exs sets its own deterministic values for `:cinegraph, :r2` so
# we skip this block in test env.
if config_env() != :test do
  r2_account_id =
    if config_env() == :dev,
      do: env!("CLOUDFLARE_ACCOUNT_ID", :string, ""),
      else: System.fetch_env!("CLOUDFLARE_ACCOUNT_ID")

  r2_access_key_id =
    if config_env() == :dev,
      do: env!("CLOUDFLARE_ACCESS_KEY_ID", :string, ""),
      else: System.fetch_env!("CLOUDFLARE_ACCESS_KEY_ID")

  r2_secret_access_key =
    if config_env() == :dev,
      do: env!("CLOUDFLARE_SECRET_ACCESS_KEY", :string, ""),
      else: System.fetch_env!("CLOUDFLARE_SECRET_ACCESS_KEY")

  r2_bucket =
    if config_env() == :dev,
      do: env!("R2_BUCKET", :string, "cinegraph"),
      else: System.fetch_env!("R2_BUCKET")

  r2_cdn_url =
    if config_env() == :dev,
      do: env!("R2_CDN_URL", :string, ""),
      else: System.fetch_env!("R2_CDN_URL")

  config :cinegraph, :r2,
    account_id: r2_account_id,
    access_key_id: r2_access_key_id,
    secret_access_key: r2_secret_access_key,
    bucket: r2_bucket,
    cdn_url: r2_cdn_url
end

# Daily OMDb batch size for RatingsRefreshWorker.
# Defaults to 100,000 — the full Basic plan daily limit.
# Override via OMDB_DAILY_BATCH_SIZE env var only if you need to throttle.
omdb_daily_batch_size =
  if config_env() == :dev do
    env!("OMDB_DAILY_BATCH_SIZE", :integer, 100_000)
  else
    case Integer.parse(String.trim(System.get_env("OMDB_DAILY_BATCH_SIZE") || "")) do
      {n, ""} when n > 0 -> n
      _ -> 100_000
    end
  end

config :cinegraph, :omdb_daily_batch_size, omdb_daily_batch_size

# Configure Crawlbase API (for Oscar and IMDb scraping)
config :cinegraph, :crawlbase_api_key, crawlbase_api_key
config :cinegraph, :crawlbase_js_api_key, crawlbase_js_api_key

# GraphQL API key — used by CinegraphWeb.Middleware.ApiAuth
# dev:  optional (nil bypasses auth for convenience)
# prod: required — raises at startup if missing
# test: optional (tests override via Application.put_env)
api_key =
  cond do
    config_env() == :dev -> env!("CINEGRAPH_API_KEY", :string, nil)
    config_env() == :prod -> System.fetch_env!("CINEGRAPH_API_KEY")
    true -> System.get_env("CINEGRAPH_API_KEY")
  end

config :cinegraph, :api_key, api_key

# Clerk authentication (#838) — credentials + derived domain/JWKS loaded here.
# Cinegraph uses its own dedicated Clerk application (NOT the shared Wombi tenant).
clerk_publishable_key =
  if config_env() == :dev,
    do: env!("CLERK_PUBLISHABLE_KEY", :string, nil),
    else: System.get_env("CLERK_PUBLISHABLE_KEY")

clerk_secret_key =
  if config_env() == :dev,
    do: env!("CLERK_SECRET_KEY", :string, nil),
    else: System.get_env("CLERK_SECRET_KEY")

# Clerk publishable keys encode the frontend API domain:
#   pk_test_<base64url(domain <> "$")>  ->  e.g. "clerk.example.com"
clerk_domain =
  case clerk_publishable_key do
    "pk_" <> _ = key ->
      key
      |> String.split("_", parts: 3)
      |> List.last()
      |> Base.decode64(padding: false)
      |> case do
        {:ok, decoded} -> decoded |> String.trim_trailing("$") |> String.trim()
        :error -> nil
      end

    _ ->
      nil
  end

clerk_jwks_url = if clerk_domain, do: "https://#{clerk_domain}/.well-known/jwks.json"

# Expected JWT issuer — Clerk signs tokens with iss = "https://<frontend-api-domain>".
clerk_issuer = System.get_env("CLERK_ISSUER") || if clerk_domain, do: "https://#{clerk_domain}"

clerk_authorized_parties =
  [
    System.get_env("CLERK_AUTHORIZED_PARTIES"),
    cinegraph_base_url,
    # Local dev runs on :4001 (config/dev.exs); :4000 is the sister project (Wombi).
    "http://localhost:4001",
    "http://localhost:4000",
    "https://cinegraph.org",
    "https://www.cinegraph.org"
  ]
  |> Enum.flat_map(fn
    nil -> []
    val -> String.split(val, ",", trim: true)
  end)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> Enum.uniq()

config :cinegraph, :clerk,
  enabled: not is_nil(clerk_publishable_key) and not is_nil(clerk_secret_key),
  publishable_key: clerk_publishable_key,
  secret_key: clerk_secret_key,
  domain: clerk_domain,
  jwks_url: clerk_jwks_url,
  issuer: clerk_issuer,
  authorized_parties: clerk_authorized_parties,
  jwks_cache_ttl: 3_600_000

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/cinegraph start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :cinegraph, CinegraphWeb.Endpoint, server: true
end

# Development uses config/dev.exs settings (Postgres.app)
# Test environment uses DATABASE_URL environment variable
if config_env() == :test do
  if database_url = System.get_env("DATABASE_URL") do
    config :cinegraph, Cinegraph.Repo, url: database_url
  end
end

if config_env() == :prod do
  # R2 image storage (#890) — required env vars at boot. Without these the
  # festival admin upload flow would silently save broken URLs.
  for var <-
        ~w(CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_ACCESS_KEY_ID CLOUDFLARE_SECRET_ACCESS_KEY R2_BUCKET R2_CDN_URL) do
    System.fetch_env!(var)
  end

  # Get database credentials from environment variables
  username =
    System.get_env("DATABASE_USERNAME") ||
      raise "environment variable DATABASE_USERNAME is missing"

  password =
    System.get_env("DATABASE_PASSWORD") ||
      raise "environment variable DATABASE_PASSWORD is missing"

  hostname =
    System.get_env("DATABASE_HOST") ||
      raise "environment variable DATABASE_HOST is missing"

  port_num = String.to_integer(System.get_env("DATABASE_PORT") || "5432")
  database = System.get_env("DATABASE") || "postgres"

  socket_opts = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: [:inet]

  # Primary database configuration
  # Connects to local Postgres on Mac Mini via host.docker.internal
  config :cinegraph, Cinegraph.Repo,
    # prepare: :unnamed → Postgrex uses one-shot prepared statements, required under
    # PgBouncer transaction pooling (named statements collide across pooled clients).
    # Harmless while connecting directly to Postgres. #1018
    prepare: :unnamed,
    username: username,
    password: password,
    hostname: hostname,
    port: port_num,
    database: database,
    # Pool sized to cover the sum of Oban queue concurrencies (currently 24:
    # tmdb 5 + omdb 5 + collaboration 3 + scraping 3 + metrics 2 + maintenance 4
    # + festival_discovery 1 + movie_availability 1) plus headroom for Phoenix
    # request handlers and ad-hoc admin queries. Bump alongside oban_queues below
    # if concurrencies change. Was 10, raised to 25 in #897 Phase B after
    # MovieAvailabilityRefreshWorker logged 1,578 DBConnection pool-exhaustion discards.
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "25"),
    socket_options: socket_opts,
    connect_timeout: 30_000,
    queue_target: String.to_integer(System.get_env("DB_QUEUE_TARGET_MS") || "5000"),
    queue_interval: String.to_integer(System.get_env("DB_QUEUE_INTERVAL_MS") || "10000"),
    # Increased from 15s to 180s to allow complex scoring queries in Oban jobs
    # Per-query timeouts can override this for specific operations
    timeout: 180_000,
    handshake_timeout: 30_000

  # Read replica points to same database (no separate replica on local Postgres)
  # Public read-heavy pages can issue multiple replica queries per request. Keep
  # this pool large enough for concurrent crawlers/browsing bursts; otherwise
  # ordinary page loads fail with DBConnection queue drops before query timeout.
  config :cinegraph, Cinegraph.Repo.Replica,
    # PgBouncer transaction-pooling safe (see Cinegraph.Repo). #1018
    prepare: :unnamed,
    username: username,
    password: password,
    hostname: hostname,
    port: port_num,
    database: database,
    pool_size: String.to_integer(System.get_env("REPLICA_POOL_SIZE") || "15"),
    socket_options: socket_opts,
    connect_timeout: 30_000,
    queue_target: String.to_integer(System.get_env("DB_REPLICA_QUEUE_TARGET_MS") || "5000"),
    queue_interval: String.to_integer(System.get_env("DB_REPLICA_QUEUE_INTERVAL_MS") || "10000"),
    timeout: 180_000,
    handshake_timeout: 30_000

  # Dedicated pool for background Oban jobs and health-check drift tasks.
  # Keeps job DB usage off the Replica pool so slow workers can't starve page loads.
  # Routes via Repo.replica() when :cinegraph_job_repo is set in the process dict.
  config :cinegraph, Cinegraph.Repo.Worker,
    # PgBouncer transaction-pooling safe (see Cinegraph.Repo). #1018
    prepare: :unnamed,
    username: username,
    password: password,
    hostname: hostname,
    port: port_num,
    database: database,
    pool_size: String.to_integer(System.get_env("WORKER_POOL_SIZE") || "5"),
    socket_options: socket_opts,
    connect_timeout: 30_000,
    queue_target: 5_000,
    queue_interval: 10_000,
    timeout: 180_000,
    handshake_timeout: 30_000

  parse_oban_limit = fn env_var, default ->
    case System.get_env(env_var) do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {limit, ""} when limit > 0 -> limit
          _ -> default
        end

      _ ->
        default
    end
  end

  oban_queues = [
    tmdb: parse_oban_limit.("OBAN_TMDB_LIMIT", 5),
    omdb: parse_oban_limit.("OBAN_OMDB_LIMIT", 5),
    collaboration: parse_oban_limit.("OBAN_COLLABORATION_LIMIT", 3),
    scraping: parse_oban_limit.("OBAN_SCRAPING_LIMIT", 3),
    festival_discovery: parse_oban_limit.("OBAN_FESTIVAL_DISCOVERY_LIMIT", 1),
    # Concurrency 1 prevents ShareLock deadlocks on the shared watch_providers unique
    # index when concurrent workers upsert the same global providers (Netflix, Amazon,
    # etc.) inside a long Repo.transaction. See: GitHub #999.
    movie_availability: parse_oban_limit.("OBAN_MOVIE_AVAILABILITY_LIMIT", 1),
    metrics: parse_oban_limit.("OBAN_METRICS_LIMIT", 2),
    # `:maintenance` runs cron-fired sweepers + cache warmers (HealthCacheWarmer
    # every 4 min, MoviesCacheWarmer, etc.). Was `1` until #897 Phase A turned up
    # a stuck producer that wedged for 73 hours — at limit 1 a single slow job
    # blocks the whole queue. Raised to 4 in #897 Phase B.
    maintenance: parse_oban_limit.("OBAN_MAINTENANCE_LIMIT", 4)
  ]

  oban_config =
    :cinegraph
    |> Application.fetch_env!(Oban)
    |> Keyword.put(:queues, oban_queues)

  config :cinegraph, Oban, oban_config

  # Read-through refresh master switch (#1108 §4) — default OFF; flip via env.
  read_through_enabled =
    (System.get_env("READ_THROUGH_ENABLED") || "")
    |> String.trim()
    |> String.downcase()
    |> Kernel.in(~w(true 1))

  config :cinegraph, :read_through_enabled, read_through_enabled

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host =
    System.get_env("PHX_HOST") ||
      raise "environment variable PHX_HOST is missing"

  port = String.to_integer(System.get_env("PORT") || "4000")

  config :cinegraph, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :cinegraph, CinegraphWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port,
      # Clerk sets sizeable __session (JWT) + __client_uat cookies. Raise Bandit's
      # default header cap (~10KB) so requests carrying them aren't rejected (#838).
      http_1_options: [max_header_length: 16_384]
    ],
    check_origin: [
      "https://cinegraph.org",
      "https://www.cinegraph.org"
    ],
    # See the matching note in config/prod.exs: exclude kamal-proxy's plain-HTTP
    # /health probe so Plug.SSL doesn't 301-redirect it and fail the deploy
    # health check. Passing :exclude overrides the default localhost entries, so
    # they're re-listed here. Real traffic still gets the HTTPS redirect + HSTS.
    force_ssl: [
      rewrite_on: [:x_forwarded_proto],
      hsts: true,
      exclude: [hosts: ["localhost", "127.0.0.1"], paths: ["/health"]]
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :cinegraph, CinegraphWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :cinegraph, CinegraphWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Also, you may need to configure the Swoosh API client of your choice if you
  # are not using SMTP. Here is an example of the configuration:
  #
  #     config :cinegraph, Cinegraph.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # For this example you need include a HTTP client required by Swoosh API client.
  # Swoosh supports Hackney and Finch out of the box:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Hackney
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
