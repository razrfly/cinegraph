defmodule Cinegraph.Scrapers.Imdb.HttpClient do
  @moduledoc """
  HTTP client for IMDb scraping operations.
  Handles rate limiting, retries, and HTTP requests to IMDb.
  """

  require Logger

  @timeout 60_000
  @max_retries 3
  @base_delay 1000

  @doc """
  Fetch HTML content from an IMDb list URL with retries and rate limiting.
  """
  def fetch_list_page(list_id, page \\ 1) do
    url = build_list_url(list_id, page)

    case fetch_with_retries(url, @max_retries) do
      {:ok, html} ->
        {:ok, html}

      {:error, reason} ->
        Logger.error("Failed to fetch #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Build IMDb list URL for a given list ID and page number.
  """
  def build_list_url(list_id, page \\ 1) do
    start_index = (page - 1) * 100 + 1
    "https://www.imdb.com/list/#{list_id}/?sort=list_order,asc&start=#{start_index}&mode=detail"
  end

  # Private functions
  defp fetch_with_retries(url, retries_left) when retries_left > 0 do
    case HTTPoison.get(url, headers(), timeout: @timeout, recv_timeout: @timeout) do
      {:ok, %{status_code: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status_code: status}} when status in [429, 503] ->
        # Rate limited or server error, wait and retry
        delay = @base_delay * (4 - retries_left)
        :timer.sleep(delay)
        fetch_with_retries(url, retries_left - 1)

      {:ok, %{status_code: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        if retries_left > 1 do
          :timer.sleep(@base_delay)
          fetch_with_retries(url, retries_left - 1)
        else
          {:error, reason}
        end
    end
  end

  defp fetch_with_retries(_url, 0), do: {:error, "Max retries exceeded"}

  defp headers do
    [
      {"User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"},
      {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
      {"Accept-Language", "en-US,en;q=0.5"},
      {"Accept-Encoding", "gzip, deflate"},
      {"Connection", "keep-alive"}
    ]
  end
end
