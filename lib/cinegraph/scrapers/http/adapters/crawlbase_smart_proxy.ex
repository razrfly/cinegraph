defmodule Cinegraph.Scrapers.Http.Adapters.CrawlbaseSmartProxy do
  @moduledoc """
  Crawlbase Smart AI Proxy adapter.

  Routes requests through Crawlbase's rotating proxy pool at smartproxy.crawlbase.com
  rather than through the Crawling API endpoint. Unlike the Crawling API, this is a
  standard HTTP CONNECT proxy — responses are raw HTML directly from the target server,
  not JSON-wrapped.

  Uses the same Normal token (CRAWLBASE_API_KEY) as the Crawling API. No JS rendering.

  Note: Free/Starter plan routes through datacenter IPs. Advanced/Premium includes
  residential IPs, which would bypass IMDb's application-level 403 on /list/ pages.

  ## Configuration

      config :cinegraph, :crawlbase_api_key, System.get_env("CRAWLBASE_API_KEY")
  """

  @behaviour Cinegraph.Scrapers.Http.Adapter

  require Logger

  @proxy_host "smartproxy.crawlbase.com"
  # Port 8012 is the plain HTTP CONNECT endpoint. Our raw TCP+SSL implementation
  # connects here over plain TCP, sends HTTP CONNECT, then upgrades to TLS.
  # Port 8013 (HTTPS proxy) would require a TLS-to-proxy layer first, which adds
  # complexity without benefit since the proxy-to-target leg is already encrypted.
  @proxy_port 8012
  @default_timeout 30_000
  @default_recv_timeout 30_000

  @impl true
  def fetch(url, opts \\ []) do
    if available?() do
      do_fetch(url, opts)
    else
      {:error, :not_configured}
    end
  end

  @impl true
  def name, do: "crawlbase_smart_proxy"

  @impl true
  def available? do
    key = get_token()
    is_binary(key) and key != ""
  end

  defp do_fetch(url, opts) do
    token = get_token()
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    recv_timeout = Keyword.get(opts, :recv_timeout, @default_recv_timeout)
    country = Keyword.get(opts, :country)

    start_time = System.monotonic_time(:millisecond)

    case raw_proxy_get(url, token, country, timeout, recv_timeout) do
      {:ok, 200, body} ->
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.info("#{name()} succeeded (#{byte_size(body)} bytes, #{duration}ms)")
        {:ok, body, %{adapter: name(), duration_ms: duration}}

      {:ok, status, body} ->
        Logger.warning("#{name()} HTTP #{status} for #{url}: #{String.slice(body, 0, 120)}")
        {:error, {:http_error, status, body}}

      {:error, :timeout} ->
        Logger.warning("#{name()} timeout for #{url}")
        {:error, {:timeout, :connect}}

      {:error, reason} ->
        Logger.warning("#{name()} error for #{url}: #{inspect(reason)}")
        {:error, {:network_error, reason}}
    end
  end

  # Crawlbase Smart AI Proxy sends `Content-Length: 0` in its CONNECT 200 response,
  # which causes hackney to mishandle the subsequent TLS upgrade. Use raw TCP+SSL
  # instead (matches curl's "Ignoring Content-Length in CONNECT 200 response" behavior).
  defp raw_proxy_get(url, token, country, connect_timeout, recv_timeout) do
    uri = URI.parse(url)
    target_host = uri.host
    target_port = uri.port || 443
    path = "#{uri.path}#{if uri.query, do: "?#{uri.query}", else: ""}"
    auth = Base.encode64("#{token}:")
    extra_headers = if country, do: "CrawlbaseAPI-Country: #{country}\r\n", else: ""

    proxy_host_charlist = String.to_charlist(@proxy_host)

    case :gen_tcp.connect(
           proxy_host_charlist,
           @proxy_port,
           [:binary, active: false],
           connect_timeout
         ) do
      {:ok, tcp} ->
        connect_req =
          "CONNECT #{target_host}:#{target_port} HTTP/1.1\r\n" <>
            "Host: #{target_host}:#{target_port}\r\n" <>
            "Proxy-Authorization: Basic #{auth}\r\n\r\n"

        :gen_tcp.send(tcp, connect_req)

        case :gen_tcp.recv(tcp, 0, connect_timeout) do
          {:ok, _connect_resp} ->
            ssl_opts = [verify: :verify_none, versions: [:"tlsv1.2"], active: false]

            case :ssl.connect(tcp, ssl_opts, connect_timeout) do
              {:ok, ssl} ->
                get_req =
                  "GET #{path} HTTP/1.1\r\n" <>
                    "Host: #{target_host}\r\n" <>
                    "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36\r\n" <>
                    "Accept: text/html,application/xhtml+xml\r\n" <>
                    "Accept-Encoding: identity\r\n" <>
                    extra_headers <>
                    "Connection: close\r\n\r\n"

                :ssl.send(ssl, get_req)
                raw = read_ssl(ssl, recv_timeout, <<>>)
                parse_http_response(raw)

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_ssl(ssl, timeout, acc) do
    case :ssl.recv(ssl, 0, timeout) do
      {:ok, data} -> read_ssl(ssl, timeout, acc <> data)
      {:error, :closed} -> acc
      {:error, _} -> acc
    end
  end

  defp parse_http_response(raw) do
    case String.split(raw, "\r\n\r\n", parts: 2) do
      [headers_raw, body] ->
        status =
          headers_raw
          |> String.split("\r\n")
          |> List.first("")
          |> then(fn line ->
            case Regex.run(~r/HTTP\/\d\.\d (\d+)/, line) do
              [_, code] -> String.to_integer(code)
              _ -> 0
            end
          end)

        {:ok, status, body}

      _ ->
        {:error, :bad_response}
    end
  end

  defp get_token do
    Application.get_env(:cinegraph, :crawlbase_api_key) ||
      System.get_env("CRAWLBASE_API_KEY") ||
      ""
  end
end
