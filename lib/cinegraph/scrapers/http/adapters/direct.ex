defmodule Cinegraph.Scrapers.Http.Adapters.Direct do
  @moduledoc """
  Direct HTTP adapter for web scraping without a proxy service.

  Uses HTTPoison with a Chrome-like User-Agent. Always available since
  it requires no API keys, but may be blocked by anti-bot protections.
  """

  @behaviour Cinegraph.Scrapers.Http.Adapter

  require Logger

  @default_timeout 30_000

  @impl true
  def fetch(url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    recv_timeout = Keyword.get(opts, :recv_timeout, timeout)

    headers = [
      {"User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"},
      {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
      {"Accept-Language", "en-US,en;q=0.5"},
      {"Accept-Encoding", "gzip, deflate"},
      {"Connection", "keep-alive"}
    ]

    start_time = System.monotonic_time(:millisecond)

    case HTTPoison.get(url, headers, timeout: timeout, recv_timeout: recv_timeout) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.info("Direct fetch OK (#{byte_size(body)} bytes, #{duration}ms)")
        metadata = %{adapter: name(), duration_ms: duration, mode: :direct}
        {:ok, body, metadata}

      {:ok, %HTTPoison.Response{status_code: status_code}} ->
        Logger.error("Direct fetch HTTP #{status_code} for #{url}")
        {:error, "HTTP #{status_code}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("Direct fetch error for #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    exception ->
      Logger.error("Direct fetch exception for #{url}: #{inspect(exception)}")
      {:error, exception}
  end

  @impl true
  def name, do: "direct"

  @impl true
  def available?, do: true
end
