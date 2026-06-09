defmodule CinegraphWeb.Plugs.AppsignalSampler do
  @moduledoc """
  Keeps AppSignal request-billing under the Starter tier (250K/mo). See #1100.

  Runs right after Plug.Telemetry (endpoint.ex), before the router. Decision order:
    1. Operational surfaces (/admin, /api, /health) -> always tracked, never sampled.
    2. Bot / crawler / empty User-Agent              -> dropped (Tracer.ignore/0).
    3. Everything else (anonymous public traffic)    -> keep only `sample_rate` of it.

  Errors are unaffected: captured by Honeybadger (router.ex `use Honeybadger.Plug`), so
  dropping a transaction from AppSignal billing never loses error visibility.

  Config (`config :cinegraph, #{inspect(__MODULE__)}`):
    * `:enabled`     - master switch (default false; prod overrides to true)
    * `:sample_rate` - fraction of anonymous, non-bot traffic to KEEP (0.0..1.0, default 1.0)
  """
  @behaviour Plug
  import Plug.Conn, only: [get_req_header: 2]

  @excluded_prefixes ["/admin", "/api", "/health"]

  @bot_pattern ~r/bot|crawler|spider|slurp|googlebot|bingbot|duckduckbot|yandexbot|baiduspider|applebot|petalbot|sogou|facebookexternalhit|twitterbot|linkedinbot|slackbot|discordbot|telegrambot|whatsapp|pinterest|redditbot|embedly|mastodon|ia_archiver|archive\.org_bot|gptbot|chatgpt-user|oai-searchbot|claudebot|anthropic-ai|perplexitybot|amazonbot|bytespider|dataforseo|semrushbot|ahrefsbot|mj12bot|dotbot|headlesschrome|phantomjs|python-requests|go-http-client|node-fetch|axios|okhttp|libwww-perl|curl|wget|scrapy|uptimerobot|pingdom|statuscake/i

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case decision(conn, Application.get_env(:cinegraph, __MODULE__, [])) do
      :ignore ->
        Appsignal.Tracer.ignore()
        conn

      :track ->
        conn
    end
  end

  @doc """
  Pure billing decision for a request given the sampler config. Returns `:track`
  (bill it) or `:ignore` (drop from AppSignal). Exposed for testing every branch
  without observing the `Tracer.ignore/0` side effect.
  """
  @spec decision(Plug.Conn.t(), keyword()) :: :track | :ignore
  def decision(conn, cfg) do
    cond do
      not Keyword.get(cfg, :enabled, false) -> :track
      not filterable_path?(conn.request_path) -> :track
      bot_request?(conn) -> :ignore
      :rand.uniform() <= Keyword.get(cfg, :sample_rate, 1.0) -> :track
      true -> :ignore
    end
  end

  @doc "True when the path is eligible for filtering (not an /admin, /api, or /health surface)."
  @spec filterable_path?(String.t()) :: boolean()
  def filterable_path?(path),
    do: not Enum.any?(@excluded_prefixes, &(path == &1 or String.starts_with?(path, &1 <> "/")))

  @doc "True when the request looks like a bot/crawler, or has an empty/missing User-Agent."
  @spec bot_request?(Plug.Conn.t()) :: boolean()
  def bot_request?(conn) do
    case get_req_header(conn, "user-agent") do
      [ua | _] -> ua == "" or Regex.match?(@bot_pattern, ua)
      [] -> true
    end
  end
end
