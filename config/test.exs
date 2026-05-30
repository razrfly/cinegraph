import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Skip background GenServers (ImportStats, DashboardStats, AwardImportStats,
# FestivalInferenceMonitor) in tests — their timer-driven Repo queries run
# outside the test sandbox and crash the connection pool.
config :cinegraph, :start_background_children, false

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :cinegraph, Cinegraph.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "cinegraph_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # 10 is plenty in sandbox mode where each test owns one connection.
  # The previous default (schedulers * 2) exhausted Postgres' default 100-conn cap
  # when both primary + replica pools were created.
  pool_size: 10

# Read replica configuration for tests
# Points to same database as primary - uses sandbox for isolation
config :cinegraph, Cinegraph.Repo.Replica,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "cinegraph_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # 10 is plenty in sandbox mode where each test owns one connection.
  # The previous default (schedulers * 2) exhausted Postgres' default 100-conn cap
  # when both primary + replica pools were created.
  pool_size: 10

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cinegraph, CinegraphWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ZvT7Ev535Bb2J286R+IXfqiaU1qfD56Gi40lKkRhnv1vNyf02JEx2uAPazUxNDSu",
  server: false

# In test we don't send emails
config :cinegraph, Cinegraph.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Oban — disable job processing in tests; use Oban.Testing helpers to inspect enqueued jobs
config :cinegraph, Oban, testing: :manual

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Disable basic auth on admin routes so LiveView tests can hit them directly
config :cinegraph, :admin_auth_disabled, true

# Use pure-Elixir backend in tests — EXLA requires native XLA artifacts not present in CI
config :nx, default_backend: Nx.BinaryBackend

# Stub R2 client for tests (#890). Records calls in the test process's
# dictionary; tests can inject error paths via Cinegraph.Images.R2Stub.put_response/2.
config :cinegraph, :r2_client, Cinegraph.Images.R2Stub

# Stub HTTP client for festival year-discovery tests (#932). Tests register
# URL → response mappings via FestivalHttpStub.set_response/2 and reset between
# cases via FestivalHttpStub.reset!/0.
config :cinegraph, :festival_http_client, Cinegraph.Scrapers.FestivalHttpStub

# Stub HTTP client for IMDb canonical-list import tests (#1004). Reuses the same
# ETS-backed FestivalHttpStub (URL→response). The scraper reads this via
# Application.get_env(:cinegraph, :imdb_list_http_client, HttpClient).
config :cinegraph, :imdb_list_http_client, Cinegraph.Scrapers.FestivalHttpStub

# Disable live IMDb GraphQL cursor pagination in tests so no real network call is made
# (the importer tests use lists whose total == item count, but keep this explicit).
config :cinegraph, :imdb_graphql_pagination, false

# Provide deterministic R2 config so configured?/0 returns true in tests
# that exercise the rehost path. Stub never makes a real call.
config :cinegraph, :r2,
  account_id: "test-account",
  access_key_id: "test-access-key",
  secret_access_key: "test-secret",
  bucket: "cinegraph-test",
  cdn_url: "https://test-cdn.example"
