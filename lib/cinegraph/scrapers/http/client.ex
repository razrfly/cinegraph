defmodule Cinegraph.Scrapers.Http.Client do
  @moduledoc """
  HTTP client that tries adapters in order based on configured scraping strategies.

  Each source (e.g., `:oscars`, `:imdb`) has a configured adapter chain.
  The client tries each adapter until one succeeds.

  ## Configuration

      # config/config.exs
      config :cinegraph, :scraping_strategies, %{
        oscars: [:crawlbase],
        imdb: [:crawlbase, :direct],
        default: [:direct]
      }
  """

  require Logger

  alias Cinegraph.Scrapers.Http.Adapters.{Crawlbase, CrawlbaseSmartProxy, Direct}

  @adapter_modules %{
    crawlbase: Crawlbase,
    crawlbase_smart_proxy: CrawlbaseSmartProxy,
    direct: Direct
  }

  @doc """
  Fetch a URL using the adapter chain configured for `source`.

  ## Parameters
  - `url` - The URL to fetch
  - `source` - Source identifier (e.g., `:oscars`, `:imdb`) for strategy lookup
  - `opts` - Options passed through to adapters (`:mode`, `:timeout`, etc.)

  ## Returns
  - `{:ok, body}` - HTML body from the first successful adapter
  - `{:error, reason}` - Error from the last adapter tried
  """
  def fetch(url, source, opts \\ []) do
    adapters = resolve_adapter_chain(source)
    merged_opts = Keyword.merge(source_default_opts(source), opts)

    Logger.info(
      "Fetching #{url} for :#{source} with chain: #{inspect(Enum.map(adapters, & &1.name()))}"
    )

    try_adapters(adapters, url, merged_opts)
  end

  # Crawlbase mode history for IMDb:
  #   2026-05-18: Normal mode confirmed higher success rate for /title/ and /name/
  #   2026-05-28: IMDb tightened Cloudflare WAF — Normal mode now returns pc_status=207
  #               with empty body for ALL paths. JS mode is the only working path for
  #               /title/ and /name/ (520 + pc=200 + real HTML). JS mode is still hard-
  #               blocked (403) on /list/ pages specifically — see GitHub issue #965.
  #               Default switched to :javascript.
  defp source_default_opts(:imdb), do: [mode: :javascript]
  # IMDb /list/ pages: JS mode required so Crawlbase's headless browser solves the AWS WAF
  # challenge. The hard 403 documented in #1002/#1003 lifted on 2026-05-29 — JS mode now
  # returns 520 + pc_status=200 + full rendered HTML for /list/ pages again.
  defp source_default_opts(:imdb_list), do: [mode: :javascript]
  defp source_default_opts(_), do: []

  defp resolve_adapter_chain(source) do
    strategies = Application.get_env(:cinegraph, :scraping_strategies, %{})

    adapter_keys =
      Map.get(strategies, source) ||
        Map.get(strategies, :default) ||
        [:direct]

    adapter_keys
    |> Enum.map(&Map.get(@adapter_modules, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(& &1.available?())
  end

  defp try_adapters([], _url, _opts) do
    Logger.error("No available adapters to fetch URL")
    {:error, :no_available_adapters}
  end

  defp try_adapters([adapter | rest], url, opts) do
    Logger.info("Trying adapter: #{adapter.name()}")

    case adapter.fetch(url, opts) do
      {:ok, body, _metadata} ->
        Logger.info("#{adapter.name()} succeeded (#{byte_size(body)} bytes)")
        {:ok, body}

      {:ok, body} ->
        Logger.info("#{adapter.name()} succeeded (#{byte_size(body)} bytes)")
        {:ok, body}

      {:error, reason} ->
        if rest == [] do
          Logger.error("All adapters failed. Last error: #{inspect(reason)}")
          {:error, reason}
        else
          Logger.warning("#{adapter.name()} failed: #{inspect(reason)}, trying next adapter")
          try_adapters(rest, url, opts)
        end
    end
  end
end
