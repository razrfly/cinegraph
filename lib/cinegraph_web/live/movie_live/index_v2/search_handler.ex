defmodule CinegraphWeb.MovieLive.IndexV2.SearchHandler do
  @moduledoc """
  Search and filter-option orchestration for the V2 movie index.
  """

  require Logger

  import Phoenix.Component, only: [assign: 3]

  alias Cinegraph.Movies.Search
  alias CinegraphWeb.MovieLive.IndexV2.Canonicalize
  alias CinegraphWeb.MovieLive.IndexV2.Results
  alias CinegraphWeb.MovieLive.SortOptions

  import CinegraphWeb.LiveViewHelpers,
    only: [
      extract_sort_criteria: 1,
      extract_sort_direction: 1,
      assign_pagination: 2
    ]

  def filter_options do
    Search.get_filter_options()
  rescue
    exception ->
      Logger.error(
        "Search.get_filter_options failed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      %{genres: [], decades: [], lists: [], festivals: [], languages: []}
  end

  def assign_search(socket, params, page_size) do
    sort_param = params["sort"] || "release_date_desc"
    criteria = extract_sort_criteria(sort_param)
    direction = extract_sort_direction(sort_param)
    sort_is_preset = SortOptions.preset?(criteria)
    active_lens_key = SortOptions.active_lens_key(criteria)
    query_params = Map.put(params, "per_page", to_string(page_size))
    people_slug_cache = Canonicalize.people_slug_cache_from_params(params)

    case Search.search_movies(query_params) do
      {:ok, {movies, meta}} ->
        movies = Results.preload_card_assocs(movies, active_lens_key)

        socket
        |> assign(:movies, movies)
        |> assign(:meta, meta)
        |> assign(:params, params)
        |> assign(:people_slug_cache, people_slug_cache)
        |> assign(:search_term, params["search"] || "")
        |> assign(:sort_criteria, criteria)
        |> assign(:sort_direction, direction)
        |> assign(:sort_is_preset, sort_is_preset)
        |> assign(:active_lens_key, active_lens_key)
        |> assign(:total_count, meta.total_count)
        |> assign_pagination(meta)

      {:error, _} ->
        socket
        |> assign(:movies, [])
        |> assign(:meta, %Flop.Meta{total_count: 0, total_pages: 0, current_page: 1})
        |> assign(:params, params)
        |> assign(:people_slug_cache, people_slug_cache)
        |> assign(:search_term, params["search"] || "")
        |> assign(:sort_criteria, criteria)
        |> assign(:sort_direction, direction)
        |> assign(:sort_is_preset, false)
        |> assign(:active_lens_key, nil)
        |> assign(:total_count, 0)
        |> assign(:total_movies, 0)
        |> assign(:total_pages, 1)
        |> assign(:current_page, 1)
        |> assign(:page, 1)
        |> assign(:per_page, page_size)
    end
  end
end
