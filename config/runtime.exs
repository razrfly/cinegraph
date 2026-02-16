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

zyte_api_key =
  if config_env() == :dev,
    do: env!("ZYTE_API_KEY", :string, ""),
    else: System.get_env("ZYTE_API_KEY") || ""

# Configure TMDb
# API key is optional at config time - the service will handle missing keys at runtime
config :cinegraph, Cinegraph.Services.TMDb.Client, api_key: tmdb_api_key

# Configure OMDb (optional)
config :cinegraph, Cinegraph.Services.OMDb.Client, api_key: omdb_api_key

# Configure Zyte API (optional, for Oscar scraping)
config :cinegraph, :zyte_api_key, zyte_api_key

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
    username: username,
    password: password,
    hostname: hostname,
    port: port_num,
    database: database,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: socket_opts,
    connect_timeout: 30_000,
    # Increased from 15s to 180s to allow complex scoring queries in Oban jobs
    # Per-query timeouts can override this for specific operations
    timeout: 180_000,
    handshake_timeout: 30_000

  # Read replica points to same database (no separate replica on local Postgres)
  config :cinegraph, Cinegraph.Repo.Replica,
    username: username,
    password: password,
    hostname: hostname,
    port: port_num,
    database: database,
    pool_size: String.to_integer(System.get_env("REPLICA_POOL_SIZE") || "5"),
    socket_options: socket_opts,
    connect_timeout: 30_000,
    timeout: 180_000,
    handshake_timeout: 30_000

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
      port: port
    ],
    check_origin: [
      "https://cinegraph.org",
      "https://www.cinegraph.org"
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
