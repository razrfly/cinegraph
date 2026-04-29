defmodule Cinegraph.Health.ImdbEventInspector do
  @moduledoc """
  Live IMDb event-ID inspector. Used to disambiguate `:bad_event_id` vs
  `:source_unavailable` vs `:parser_breakage` labels surfaced by the
  year-discovery audit (`Cinegraph.Health.YearDiscovery`).

  This is the **documented exception** to the pure-DB audit rule
  established by #766: it calls IMDb live via the standard
  `Cinegraph.Scrapers.Http.Client`. The exception is justified by the
  tool's purpose — root-causing what the worker actually sees on the
  upstream side, which a DB query cannot do.

  See #766 (audit pattern), #771 (Phase 2 disposition consumer), #772
  (this tool's home).
  """

  require Logger

  alias Cinegraph.Scrapers.Http.Client

  @next_data_regex ~r/<script id="__NEXT_DATA__" type="application\/json">(.*?)<\/script>/s
  @cache_table :cinegraph_imdb_event_inspector_cache
  @default_cache_ttl_ms :timer.minutes(5)

  @doc """
  Inspect an IMDb event ID. Returns a JSON-encodable map describing what
  IMDb returned and what the parser found.

  Options:
    * `:year` — year to fetch (default: current UTC year). The
      `historyEventEditions` array is on every year's page, so the year
      mostly doesn't matter — it's surfaced here for cases where IMDb's
      page differs by year.

  Shape:

      %{
        event_id: String.t(),
        url: String.t(),
        fetch_status: :ok | {:error, term()},
        bytes: non_neg_integer() | nil,
        parser_status:
          :ok | :no_next_data | :no_editions | :editions_parser_breakage | :json_failed | :fetch_error,
        has_next_data: boolean(),
        editions_count: non_neg_integer(),
        years_with_data: %{count: non_neg_integer(), sample: [integer()]},
        event_name: String.t() | nil,
        raw_excerpt: String.t() | nil,  # first 200 bytes for debugging
        suggested_label: :ok | :bad_event_id | :source_unavailable | :parser_breakage
      }
  """
  def inspect(event_id, opts \\ []) when is_binary(event_id) do
    year = Keyword.get(opts, :year, Date.utc_today().year)
    url = "https://www.imdb.com/event/#{event_id}/#{year}/1/"

    case fetch_html(url, event_id, year) do
      {:ok, html} ->
        parse_inspection_html(html, event_id, url)

      {:error, reason} ->
        %{
          event_id: event_id,
          url: url,
          fetch_status: {:error, reason},
          bytes: nil,
          parser_status: :fetch_error,
          has_next_data: false,
          editions_count: 0,
          years_with_data: %{count: 0, sample: []},
          event_name: nil,
          raw_excerpt: nil,
          suggested_label: classify_fetch_error(reason)
        }
    end
  end

  @doc """
  Pure parser. Same logic as `Cinegraph.Scrapers.UnifiedFestivalScraper`'s
  year-discovery path, surfaced here so it can be tested in isolation
  without live HTTP.
  """
  def parse_inspection_html(html, event_id, url) when is_binary(html) do
    base = %{
      event_id: event_id,
      url: url,
      fetch_status: :ok,
      bytes: byte_size(html),
      raw_excerpt: String.slice(html, 0, 200)
    }

    case Regex.run(@next_data_regex, html) do
      [_, json] ->
        case Jason.decode(json) do
          {:ok, data} ->
            editions = get_in(data, ["props", "pageProps", "historyEventEditions"]) || []

            years =
              editions
              |> Enum.map(&Map.get(&1, "year"))
              |> Enum.reject(&is_nil/1)
              |> Enum.sort(:desc)

            event_name =
              get_in(data, ["props", "pageProps", "edition", "event", "name"]) ||
                get_in(data, ["props", "pageProps", "event", "name"])

            cond do
              length(years) > 0 ->
                Map.merge(base, %{
                  parser_status: :ok,
                  has_next_data: true,
                  editions_count: length(editions),
                  years_with_data: %{count: length(years), sample: Enum.take(years, 5)},
                  event_name: event_name,
                  suggested_label: :ok
                })

              editions == [] ->
                Map.merge(base, %{
                  parser_status: :no_editions,
                  has_next_data: true,
                  editions_count: 0,
                  years_with_data: %{count: 0, sample: []},
                  event_name: event_name,
                  # historyEventEditions is empty — IMDb has the page but
                  # genuinely no editions data, OR the event ID redirects
                  # to a generic page. Need humans to look at event_name.
                  suggested_label: :source_unavailable
                })

              true ->
                # editions is non-empty but no `year` fields present.
                # That's a parser/IMDb-format mismatch.
                Map.merge(base, %{
                  parser_status: :editions_parser_breakage,
                  has_next_data: true,
                  editions_count: length(editions),
                  years_with_data: %{count: 0, sample: []},
                  event_name: event_name,
                  suggested_label: :parser_breakage
                })
            end

          {:error, _} ->
            Map.merge(base, %{
              parser_status: :json_failed,
              has_next_data: true,
              editions_count: 0,
              years_with_data: %{count: 0, sample: []},
              event_name: nil,
              suggested_label: :parser_breakage
            })
        end

      nil ->
        # No __NEXT_DATA__ block — but distinguish two sub-cases:
        # 1. IMDb returned a real page that just lacks the script tag
        #    (rare; would be a real format change → :parser_breakage)
        # 2. Crawlbase/IMDb returned an error page. Access-denied pages mean
        #    IMDb was unavailable through the transport, while not-found pages
        #    point at a bad event ID.
        Map.merge(base, %{
          parser_status: :no_next_data,
          has_next_data: false,
          editions_count: 0,
          years_with_data: %{count: 0, sample: []},
          event_name: nil,
          suggested_label: classify_no_next_data(html)
        })
    end
  end

  defp classify_no_next_data(html) do
    cond do
      String.contains?(html, "403 Forbidden") -> :source_unavailable
      String.contains?(html, "404 Not Found") -> :bad_event_id
      String.contains?(html, "Page Not Found") -> :bad_event_id
      true -> :parser_breakage
    end
  end

  defp classify_fetch_error(reason) do
    text = Kernel.inspect(reason)

    cond do
      String.contains?(text, "404") -> :bad_event_id
      fetch_availability_error?(text) -> :source_unavailable
      true -> :parser_breakage
    end
  end

  defp fetch_html(url, event_id, year) do
    cache_key = {event_id, year}
    now = System.monotonic_time(:millisecond)

    case cache_lookup(cache_key, now) do
      {:ok, html} ->
        Logger.info("ImdbEventInspector: cache hit for #{url}")
        {:ok, html}

      :miss ->
        Logger.info("ImdbEventInspector: fetching #{url}")

        case Client.fetch(url, :imdb) do
          {:ok, html} = ok ->
            cache_put(cache_key, html, now)
            ok

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp cache_lookup(key, now) do
    ensure_cache_table!()

    case :ets.lookup(@cache_table, key) do
      [{^key, expires_at, html}] when expires_at > now -> {:ok, html}
      [{^key, _expires_at, _html}] -> :ets.delete(@cache_table, key) && :miss
      [] -> :miss
    end
  end

  defp cache_put(key, html, now) do
    ensure_cache_table!()
    :ets.insert(@cache_table, {key, now + cache_ttl_ms(), html})
    :ok
  end

  defp ensure_cache_table! do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [:named_table, :public, read_concurrency: true])
        rescue
          ArgumentError -> @cache_table
        end

      _tid ->
        @cache_table
    end
  end

  defp cache_ttl_ms do
    :cinegraph
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:cache_ttl_ms, @default_cache_ttl_ms)
  end

  defp fetch_availability_error?(text) do
    String.contains?(text, "HTTP ") or
      Regex.match?(~r/\b[345]\d\d\b/, text) or
      String.contains?(text, ":timeout") or
      String.contains?(text, ":econnrefused") or
      String.contains?(text, ":nxdomain") or
      String.contains?(text, ":closed") or
      String.contains?(text, ":no_available_adapters") or
      String.contains?(text, "%HTTPoison.Error")
  end
end
