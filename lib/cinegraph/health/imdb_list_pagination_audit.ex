defmodule Cinegraph.Health.ImdbListPaginationAudit do
  @moduledoc """
  Non-mutating diagnostics for IMDb list pagination/window behavior.

  This module fetches candidate IMDb list windows through the configured IMDb
  HTTP client and reports whether the rendered windows look contiguous and safe
  to import. It intentionally does not enqueue jobs or update movie/list rows.
  """

  alias Cinegraph.Movies.MovieLists
  alias Cinegraph.Scrapers.Http.BodyDiagnostics
  alias Cinegraph.Scrapers.Http.Client, as: HttpClient

  @default_starts [1, 76, 151, 226, 301, 376]
  @sample_size 3

  @doc """
  Audit an IMDb list's rendered pagination windows.
  """
  def audit(opts \\ []) do
    opts = normalize_opts(opts)
    {list_key, list_id} = resolve_list!(opts)
    starts = Keyword.get(opts, :starts, @default_starts)
    fetch_opts = fetch_opts(opts)
    fetcher = Keyword.get(opts, :fetcher, &HttpClient.fetch/3)

    raw_windows =
      starts
      |> Enum.map(fn start ->
        url = build_window_url(list_id, start)
        probe_window(url, start, fetch_opts, fetcher)
      end)
      |> annotate_windows()

    windows = Enum.map(raw_windows, &Map.delete(&1, :_ids))

    %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      list_key: list_key,
      list_id: list_id,
      tested_urls: Enum.map(windows, & &1.url),
      windows: windows,
      summary: summarize(raw_windows)
    }
  end

  @doc false
  def default_starts, do: @default_starts

  @doc false
  def build_window_url(list_id, start) do
    "https://www.imdb.com/list/#{list_id}/?sort=list_order,asc&start=#{start}&mode=detail"
  end

  @doc false
  def parse_window_html(html, start) when is_binary(html) do
    document = Floki.parse_document!(html)
    {items, layout} = find_movie_items(document)

    movies =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, index} -> parse_item(item, start, index) end)
      |> Enum.reject(&is_nil/1)

    %{
      parser_layout: layout,
      movies: movies
    }
  end

  defp normalize_opts(opts) do
    opts
    |> normalize_alias(:"list-id", :list_id)
    |> normalize_alias(:"page-wait", :page_wait)
    |> normalize_alias(:"ajax-wait", :ajax_wait)
    |> normalize_alias(:"scroll-interval", :scroll_interval)
    |> normalize_starts()
  end

  defp normalize_alias(opts, from, to) do
    case Keyword.pop(opts, from) do
      {nil, opts} -> opts
      {value, opts} -> Keyword.put(opts, to, value)
    end
  end

  defp normalize_starts(opts) do
    case Keyword.get(opts, :starts) do
      nil ->
        opts

      starts when is_binary(starts) ->
        Keyword.put(opts, :starts, parse_starts!(starts))

      starts when is_list(starts) ->
        Keyword.put(opts, :starts, Enum.map(starts, &parse_start!/1))

      other ->
        raise ArgumentError,
              "starts must be a comma-separated string or list, got: #{inspect(other)}"
    end
  end

  defp parse_starts!(starts) do
    starts
    |> String.split(",", trim: true)
    |> Enum.map(&parse_start!/1)
  end

  defp parse_start!(value) when is_integer(value) and value > 0, do: value

  defp parse_start!(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _ -> raise ArgumentError, "invalid start value: #{inspect(value)}"
    end
  end

  defp parse_start!(value), do: raise(ArgumentError, "invalid start value: #{inspect(value)}")

  defp resolve_list!(opts) do
    case {Keyword.get(opts, :list), Keyword.get(opts, :list_id)} do
      {nil, nil} ->
        raise ArgumentError, "provide either --list or --list-id"

      {list_key, nil} when is_binary(list_key) ->
        case MovieLists.get_config(list_key) do
          {:ok, %{list_id: list_id}} when is_binary(list_id) and list_id != "" ->
            {list_key, list_id}

          {:ok, _config} ->
            raise ArgumentError, "list #{inspect(list_key)} does not have an IMDb list_id"

          {:error, reason} ->
            raise ArgumentError, reason
        end

      {nil, list_id} when is_binary(list_id) ->
        validate_list_id!(list_id)
        {nil, list_id}

      {_list_key, list_id} when is_binary(list_id) ->
        validate_list_id!(list_id)
        {Keyword.get(opts, :list), list_id}
    end
  end

  defp validate_list_id!(list_id) do
    unless Regex.match?(~r/^ls\d+$/, list_id) do
      raise ArgumentError, "list_id must look like an IMDb ls id, got: #{inspect(list_id)}"
    end
  end

  defp fetch_opts(opts) do
    [
      mode: :javascript,
      page_wait: Keyword.get(opts, :page_wait, 5_000),
      ajax_wait: Keyword.get(opts, :ajax_wait, true),
      scroll: Keyword.get(opts, :scroll, false),
      scroll_interval: Keyword.get(opts, :scroll_interval)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp probe_window(url, start, fetch_opts, fetcher) do
    crawlbase_options = %{
      page_wait: Keyword.get(fetch_opts, :page_wait),
      ajax_wait: Keyword.get(fetch_opts, :ajax_wait),
      scroll: Keyword.get(fetch_opts, :scroll, false),
      scroll_interval: Keyword.get(fetch_opts, :scroll_interval)
    }

    case fetcher.(url, :imdb, fetch_opts) do
      {:ok, html} ->
        success_or_blocked_window(url, start, html, crawlbase_options, nil)

      {:ok, html, metadata} ->
        success_or_blocked_window(url, start, html, crawlbase_options, metadata)

      {:error, {:blocked, reason, diagnostics}} ->
        error_window(url, start, "blocked", {:blocked, reason}, crawlbase_options, diagnostics)

      {:error, reason} ->
        error_window(url, start, "error", reason, crawlbase_options)
    end
  end

  defp success_or_blocked_window(url, start, html, crawlbase_options, metadata) do
    diagnostics =
      metadata
      |> body_diagnostics_from_metadata()
      |> case do
        nil -> BodyDiagnostics.diagnostics(url, html)
        diagnostics -> diagnostics
      end

    case BodyDiagnostics.blocked_error(url, html) do
      {:blocked, reason, blocked_diagnostics} ->
        error_window(
          url,
          start,
          "blocked",
          {:blocked, reason},
          crawlbase_options,
          blocked_diagnostics
        )

      nil ->
        success_window(url, start, html, crawlbase_options, diagnostics)
    end
  end

  defp body_diagnostics_from_metadata(%{body_diagnostics: diagnostics}) when is_map(diagnostics),
    do: diagnostics

  defp body_diagnostics_from_metadata(%{"body_diagnostics" => diagnostics})
       when is_map(diagnostics),
       do: diagnostics

  defp body_diagnostics_from_metadata(_metadata), do: nil

  defp success_window(url, start, html, crawlbase_options, diagnostics) do
    parsed = parse_window_html(html, start)
    movies = parsed.movies

    %{
      url: url,
      start: start,
      fetch_status: "ok",
      movie_count: length(movies),
      first_rank: rank_at(movies, :first),
      last_rank: rank_at(movies, :last),
      first_imdb_id: imdb_id_at(movies, :first),
      last_imdb_id: imdb_id_at(movies, :last),
      sample_titles: sample_titles(movies),
      duplicate_ids: [],
      rank_gap_from_previous: nil,
      parser_layout: parsed.parser_layout,
      crawlbase_options: crawlbase_options,
      body_bytes: diagnostics.body_bytes,
      html_title: diagnostics.html_title,
      title_link_count: diagnostics.title_link_count,
      ipc_item_count: diagnostics.ipc_item_count,
      lister_item_count: diagnostics.lister_item_count,
      body_classification: diagnostics.body_classification,
      _ids: Enum.map(movies, & &1.imdb_id)
    }
  end

  defp error_window(url, start, fetch_status, reason, crawlbase_options, diagnostics \\ %{}) do
    %{
      url: url,
      start: start,
      fetch_status: fetch_status,
      error: inspect(reason),
      movie_count: 0,
      first_rank: nil,
      last_rank: nil,
      first_imdb_id: nil,
      last_imdb_id: nil,
      sample_titles: [],
      duplicate_ids: [],
      rank_gap_from_previous: nil,
      parser_layout: "none",
      crawlbase_options: crawlbase_options
    }
    |> Map.merge(body_diagnostics_fields(diagnostics))
  end

  defp body_diagnostics_fields(diagnostics) when is_map(diagnostics) do
    %{
      body_bytes: Map.get(diagnostics, :body_bytes) || Map.get(diagnostics, "body_bytes"),
      html_title:
        Map.get(diagnostics, :html_title) || Map.get(diagnostics, "html_title") ||
          Map.get(diagnostics, :title) || Map.get(diagnostics, "title"),
      title_link_count:
        Map.get(diagnostics, :title_link_count) || Map.get(diagnostics, "title_link_count"),
      ipc_item_count:
        Map.get(diagnostics, :ipc_item_count) || Map.get(diagnostics, "ipc_item_count"),
      lister_item_count:
        Map.get(diagnostics, :lister_item_count) || Map.get(diagnostics, "lister_item_count"),
      body_classification:
        Map.get(diagnostics, :body_classification) || Map.get(diagnostics, "body_classification")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp find_movie_items(document) do
    selectors = [
      {".lister-item", "lister"},
      {".ipc-metadata-list-summary-item", "ipc"},
      {".titleColumn", "title_column"},
      {".cli-item", "cli"},
      {".list-item", "list_item"},
      {".movie-item", "movie_item"}
    ]

    Enum.find_value(selectors, {[], "none"}, fn {selector, layout} ->
      items = Floki.find(document, selector)
      if items == [], do: nil, else: {items, layout}
    end)
  end

  defp parse_item(item, start, index) do
    href =
      item
      |> Floki.find("a[href*='/title/tt']")
      |> List.first()
      |> then(fn
        nil -> nil
        link -> Floki.attribute(link, "href") |> List.first()
      end)

    imdb_id = extract_imdb_id(href)

    if imdb_id do
      title = extract_title(item)
      displayed_rank = extract_displayed_rank(item)

      %{
        imdb_id: imdb_id,
        title: title,
        rank: displayed_rank || start + index,
        rank_source: if(displayed_rank, do: "displayed", else: "fallback")
      }
    end
  end

  defp extract_imdb_id(nil), do: nil

  defp extract_imdb_id(href) do
    case Regex.run(~r/\/title\/(tt\d+)/, href) do
      [_, imdb_id] -> imdb_id
      _ -> nil
    end
  end

  defp extract_title(item) do
    title_text =
      item
      |> Floki.find("h3")
      |> Floki.text()
      |> String.trim()

    title_text =
      if title_text == "" do
        item
        |> Floki.find("a[href*='/title/tt']")
        |> List.first()
        |> case do
          nil -> ""
          link -> Floki.text(link)
        end
        |> String.trim()
      else
        title_text
      end

    title_text
    |> String.replace(~r/^\s*\d+[\.)]\s*/, "")
    |> String.trim()
  end

  defp extract_displayed_rank(item) do
    rank_texts = [
      Floki.find(item, ".lister-item-index") |> Floki.text(),
      Floki.find(item, "h3") |> Floki.text(),
      Floki.find(item, ".ipc-title__text") |> Floki.text()
    ]

    rank_texts
    |> Enum.find_value(fn text ->
      case Regex.run(~r/^\s*(\d+)[\.)]/, String.trim(text || "")) do
        [_, rank] -> String.to_integer(rank)
        _ -> nil
      end
    end)
  end

  defp rank_at([], _), do: nil
  defp rank_at(movies, :first), do: List.first(movies).rank
  defp rank_at(movies, :last), do: List.last(movies).rank

  defp imdb_id_at([], _), do: nil
  defp imdb_id_at(movies, :first), do: List.first(movies).imdb_id
  defp imdb_id_at(movies, :last), do: List.last(movies).imdb_id

  defp sample_titles(movies) do
    movies
    |> Enum.take(@sample_size)
    |> Enum.map(& &1.title)
  end

  defp annotate_windows(windows) do
    {_seen, _previous_rank, annotated} =
      Enum.reduce(windows, {MapSet.new(), nil, []}, fn window, {seen, previous_rank, acc} ->
        ids = window_ids(window)

        duplicates =
          (repeated_ids(ids) ++ Enum.filter(ids, &MapSet.member?(seen, &1))) |> Enum.uniq()

        rank_gap =
          cond do
            previous_rank == nil or window.first_rank == nil -> nil
            true -> window.first_rank - previous_rank - 1
          end

        annotated_window = %{window | duplicate_ids: duplicates, rank_gap_from_previous: rank_gap}
        next_seen = Enum.reduce(ids, seen, &MapSet.put(&2, &1))
        next_previous_rank = window.last_rank || previous_rank

        {next_seen, next_previous_rank, [annotated_window | acc]}
      end)

    Enum.reverse(annotated)
  end

  defp window_ids(%{fetch_status: "ok"} = window) do
    # Re-fetching parsed movies would be wasteful; the first/last fields are
    # not enough for cross-window duplicates, so keep IDs in a private key until
    # summary is built.
    Map.get(window, :_ids, [])
  end

  defp window_ids(_window), do: []

  defp repeated_ids(ids) do
    ids
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(fn {id, _count} -> id end)
  end

  defp summarize(windows) do
    successful = Enum.filter(windows, &(&1.fetch_status == "ok"))
    non_empty = Enum.filter(successful, &(&1.movie_count > 0))
    all_ids = Enum.flat_map(windows, &window_ids/1)
    has_duplicates = Enum.any?(windows, &(&1.duplicate_ids != []))
    all_windows_ok = successful != [] and length(successful) == length(windows)
    all_windows_non_empty = length(non_empty) == length(windows)

    has_gaps =
      Enum.any?(
        windows,
        &(is_integer(&1.rank_gap_from_previous) and &1.rank_gap_from_previous != 0)
      )

    safe_to_import =
      all_windows_ok and all_windows_non_empty and not has_gaps and not has_duplicates

    %{
      total_unique_ids: all_ids |> MapSet.new() |> MapSet.size(),
      position_ranges: position_ranges(non_empty),
      has_gaps: has_gaps,
      has_duplicates: has_duplicates,
      recommended_page_size: recommended_page_size(non_empty),
      recommended_url_strategy:
        if(safe_to_import, do: "start_offset", else: "start_offset_unverified"),
      safe_to_import: safe_to_import
    }
  end

  defp position_ranges(windows) do
    Enum.map(windows, fn window ->
      %{
        start: window.start,
        first_rank: window.first_rank,
        last_rank: window.last_rank,
        movie_count: window.movie_count
      }
    end)
  end

  defp recommended_page_size([]), do: nil

  defp recommended_page_size(windows) do
    windows
    |> Enum.map(& &1.movie_count)
    |> Enum.frequencies()
    |> Enum.max_by(fn {count, frequency} -> {frequency, count} end)
    |> elem(0)
  end
end
