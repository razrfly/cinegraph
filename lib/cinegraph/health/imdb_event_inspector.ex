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
        parser_status: :ok | :no_next_data | :no_editions | :json_failed | :fetch_error,
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

    Logger.info("ImdbEventInspector: fetching #{url}")

    case Client.fetch(url, :imdb) do
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
                  parser_status: :no_editions,
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
        Map.merge(base, %{
          parser_status: :no_next_data,
          has_next_data: false,
          editions_count: 0,
          years_with_data: %{count: 0, sample: []},
          event_name: nil,
          suggested_label: :parser_breakage
        })
    end
  end

  defp classify_fetch_error(reason) do
    text = Kernel.inspect(reason)

    cond do
      String.contains?(text, "404") -> :bad_event_id
      true -> :parser_breakage
    end
  end
end
