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

  alias Cinegraph.Scrapers.Http.Adapters.{Crawlbase, Direct}

  @adapter_modules %{
    crawlbase: Crawlbase,
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

    Logger.info(
      "Fetching #{url} for :#{source} with chain: #{inspect(Enum.map(adapters, & &1.name()))}"
    )

    try_adapters(adapters, url, opts)
  end

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
