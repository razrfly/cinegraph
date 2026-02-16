defmodule Cinegraph.Scrapers.Http.Adapters.Crawlbase do
  @moduledoc """
  Crawlbase API adapter for web scraping with anti-bot bypass.

  Uses the Crawlbase API to fetch web pages with optional JavaScript rendering,
  effective for bypassing Cloudflare and other anti-bot protections.

  ## Modes

  - `:javascript` (default) — Browser rendering via `CRAWLBASE_JS_API_KEY` (2 credits)
  - `:normal` — Static HTML via `CRAWLBASE_API_KEY` (1 credit)

  ## Configuration

      # config/runtime.exs
      config :cinegraph, :crawlbase_api_key, System.get_env("CRAWLBASE_API_KEY")
      config :cinegraph, :crawlbase_js_api_key, System.get_env("CRAWLBASE_JS_API_KEY")
  """

  @behaviour Cinegraph.Scrapers.Http.Adapter

  require Logger

  @crawlbase_api_url "https://api.crawlbase.com/"
  @default_timeout 60_000
  @default_recv_timeout 60_000
  @default_page_wait 2000

  @impl true
  def fetch(url, opts \\ []) do
    mode = Keyword.get(opts, :mode, :javascript)

    if available_for_mode?(mode) do
      do_fetch(url, opts)
    else
      {:error, :not_configured}
    end
  end

  @impl true
  def name, do: "crawlbase"

  @impl true
  def available? do
    has_normal_key?() or has_js_key?()
  end

  @doc "Checks if the adapter is available for a specific mode."
  @spec available_for_mode?(atom()) :: boolean()
  def available_for_mode?(:javascript), do: has_js_key?()
  def available_for_mode?(:normal), do: has_normal_key?()
  def available_for_mode?(_), do: has_js_key?()

  defp do_fetch(url, opts) do
    mode = Keyword.get(opts, :mode, :javascript)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    recv_timeout = Keyword.get(opts, :recv_timeout, @default_recv_timeout)
    page_wait = Keyword.get(opts, :page_wait, @default_page_wait)
    ajax_wait = Keyword.get(opts, :ajax_wait, true)

    request_url = build_request_url(url, mode, page_wait, ajax_wait)

    http_opts = [
      timeout: timeout,
      recv_timeout: recv_timeout
    ]

    start_time = System.monotonic_time(:millisecond)

    case HTTPoison.get(request_url, [], http_opts) do
      {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
        handle_success_response(response_body, mode, start_time)

      {:ok, %HTTPoison.Response{status_code: 429, headers: resp_headers}} ->
        retry_after = extract_retry_after(resp_headers)
        Logger.warning("Crawlbase rate limited, retry after #{retry_after}s")
        {:error, {:rate_limit, retry_after}}

      {:ok, %HTTPoison.Response{status_code: status, body: response_body}} ->
        handle_error_response(status, response_body, url)

      {:error, %HTTPoison.Error{reason: :timeout}} ->
        Logger.warning("Crawlbase timeout connecting to #{url}")
        {:error, {:timeout, :connect}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.warning("Crawlbase network error: #{inspect(reason)}")
        {:error, {:network_error, reason}}
    end
  end

  defp build_request_url(url, mode, page_wait, ajax_wait) do
    token = get_token_for_mode(mode)

    query_params = %{
      "token" => token,
      "url" => url,
      "format" => "json"
    }

    query_params =
      if mode == :javascript do
        query_params
        |> Map.put("page_wait", to_string(page_wait))
        |> then(fn params ->
          if ajax_wait, do: Map.put(params, "ajax_wait", "true"), else: params
        end)
      else
        query_params
      end

    "#{@crawlbase_api_url}?#{URI.encode_query(query_params)}"
  end

  defp handle_success_response(response_body, mode, start_time) do
    duration = System.monotonic_time(:millisecond) - start_time

    case Jason.decode(response_body) do
      {:ok, %{"body" => body}} ->
        metadata = %{adapter: name(), duration_ms: duration, mode: mode}
        {:ok, body, metadata}

      {:ok, %{"pc_status" => pc_status} = response} when pc_status >= 200 and pc_status < 300 ->
        body = Map.get(response, "body", response_body)
        metadata = %{adapter: name(), duration_ms: duration, mode: mode}
        {:ok, body, metadata}

      {:ok, %{"pc_status" => pc_status} = response} when pc_status >= 400 ->
        error_msg = Map.get(response, "error", "HTTP #{pc_status}")
        Logger.warning("Crawlbase error status #{pc_status}: #{error_msg}")
        {:error, {:crawlbase_error, pc_status, error_msg}}

      {:ok, response} when is_map(response) ->
        body = Map.get(response, "body", response_body)

        if is_binary(body) and String.contains?(body, "<") do
          metadata = %{adapter: name(), duration_ms: duration, mode: mode}
          {:ok, body, metadata}
        else
          {:error, {:crawlbase_error, 200, "Unexpected response format"}}
        end

      {:error, _decode_error} ->
        if String.contains?(response_body, "<!") or String.contains?(response_body, "<html") do
          metadata = %{adapter: name(), duration_ms: duration, mode: mode}
          {:ok, response_body, metadata}
        else
          {:error, {:crawlbase_error, 200, "JSON decode error"}}
        end
    end
  end

  defp handle_error_response(status, response_body, url) do
    message =
      case Jason.decode(response_body) do
        {:ok, %{"error" => error}} -> error
        {:ok, %{"message" => msg}} -> msg
        _ -> "HTTP #{status}"
      end

    Logger.warning("Crawlbase error (#{status}) for #{url}: #{message}")
    {:error, {:crawlbase_error, status, message}}
  end

  defp extract_retry_after(headers) do
    case Enum.find(headers, fn {key, _} -> String.downcase(key) == "retry-after" end) do
      {_, value} ->
        case Integer.parse(value) do
          {seconds, _} -> seconds
          :error -> 60
        end

      nil ->
        60
    end
  end

  defp get_token_for_mode(:javascript), do: get_js_api_key()
  defp get_token_for_mode(:normal), do: get_normal_api_key()
  defp get_token_for_mode(_), do: get_js_api_key()

  defp has_normal_key? do
    key = get_normal_api_key()
    is_binary(key) and key != ""
  end

  defp has_js_key? do
    key = get_js_api_key()
    is_binary(key) and key != ""
  end

  defp get_normal_api_key do
    Application.get_env(:cinegraph, :crawlbase_api_key) ||
      System.get_env("CRAWLBASE_API_KEY") ||
      ""
  end

  defp get_js_api_key do
    Application.get_env(:cinegraph, :crawlbase_js_api_key) ||
      System.get_env("CRAWLBASE_JS_API_KEY") ||
      ""
  end
end
