defmodule CinegraphWeb.MovieLive.Index do
  use CinegraphWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Cinegraph.Movies
  alias Cinegraph.Movies.{Genre, ProductionCountry, SpokenLanguage, MovieLists}
  alias Cinegraph.Repo

  @impl true
  def mount(_params, _session, socket) do
    # Initialize with empty state - actual data loading happens in handle_params
    {:ok,
     socket
     |> assign(:page, 1)
     |> assign(:per_page, 50)
     |> assign(:movies, [])
     |> assign(:total_movies, 0)
     |> assign(:total_pages, 0)
     |> assign(:sort, "release_date_desc")
     |> assign(:filters, %{})
     |> assign(:search_term, "")
     |> assign(:show_filters, false)
     |> assign_filter_options()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply,
     socket
     |> assign_pagination_params(params)
     |> assign_filter_params(params)
     |> load_paginated_movies()
     |> apply_action(socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("change_sort", %{"sort" => sort}, socket) do
    params =
      build_filter_params(socket)
      |> Map.put("sort", sort)
      |> Map.put("page", "1")

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("toggle_filters", _params, socket) do
    {:noreply, assign(socket, :show_filters, !socket.assigns.show_filters)}
  end

  @impl true
  def handle_event("search", %{"search" => search_term}, socket) do
    params =
      build_filter_params(socket)
      |> Map.put("search", search_term)
      |> Map.put("page", "1")

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("apply_filters", %{"filters" => filters}, socket) do
    params =
      build_filter_params(socket)
      |> Map.merge(filters)
      |> Map.put("page", "1")
      |> Enum.reject(fn {_k, v} -> v == "" or v == [] end)
      |> Map.new()

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    params = %{
      "page" => "1",
      "per_page" => to_string(socket.assigns.per_page),
      "sort" => socket.assigns.sort
    }

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  # Private functions
  defp assign_pagination_params(socket, params) do
    page = parse_int_param(params["page"], 1, min: 1)
    per_page = parse_int_param(params["per_page"], 50, min: 10, max: 100)
    sort = params["sort"] || "release_date_desc"

    socket
    |> assign(:page, page)
    |> assign(:per_page, per_page)
    |> assign(:sort, sort)
  end

  defp assign_filter_params(socket, params) do
    socket
    |> assign(:search_term, params["search"] || "")
    |> assign(:filters, %{
      genres: parse_list_param(params["genres"]),
      countries: parse_list_param(params["countries"]),
      languages: parse_list_param(params["languages"]),
      lists: parse_list_param(params["lists"]),
      year: params["year"],
      year_from: params["year_from"],
      year_to: params["year_to"],
      decade: params["decade"],
      runtime_min: params["runtime_min"],
      runtime_max: params["runtime_max"],
      rating_min: params["rating_min"],
      show_unreleased: params["show_unreleased"] == "true"
    })
  end

  defp assign_filter_options(socket) do
    socket
    |> assign(:available_genres, list_genres())
    |> assign(:available_countries, list_production_countries())
    |> assign(:available_languages, list_spoken_languages())
    |> assign(:available_lists, list_canonical_lists())
    |> assign(:available_decades, generate_decades())
  end

  defp load_paginated_movies(socket) do
    %{page: page, per_page: per_page, sort: sort, filters: filters, search_term: search_term} =
      socket.assigns

    params =
      %{
        "page" => to_string(page),
        "per_page" => to_string(per_page),
        "sort" => sort,
        "search" => search_term
      }
      |> Map.merge(stringify_filters(filters))

    movies = Movies.list_movies(params)
    total_movies = Movies.count_movies(params)
    total_pages = ceil(total_movies / per_page)

    socket
    |> assign(:movies, movies)
    |> assign(:total_movies, total_movies)
    |> assign(:total_pages, max(total_pages, 1))
  end

  defp build_filter_params(socket) do
    %{
      "page" => to_string(socket.assigns.page),
      "per_page" => to_string(socket.assigns.per_page),
      "sort" => socket.assigns.sort,
      "search" => socket.assigns.search_term
    }
    |> Map.merge(stringify_filters(socket.assigns.filters))
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" or v == [] end)
    |> Map.new()
  end

  defp stringify_filters(filters) do
    filters
    |> Enum.map(fn {k, v} ->
      {to_string(k), stringify_value(v)}
    end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" or v == [] end)
    |> Map.new()
  end

  defp stringify_value(nil), do: nil
  defp stringify_value(v) when is_list(v), do: Enum.join(v, ",")
  defp stringify_value(true), do: "true"
  defp stringify_value(false), do: "false"
  defp stringify_value(v), do: to_string(v)

  defp parse_list_param(nil), do: []
  defp parse_list_param(""), do: []

  defp parse_list_param(param) when is_binary(param) do
    String.split(param, ",", trim: true)
  end

  defp parse_list_param(param) when is_list(param), do: param

  defp parse_int_param(param, default, opts) do
    min_val = Keyword.get(opts, :min, 1)
    max_val = Keyword.get(opts, :max, 999_999)

    case Integer.parse(param || to_string(default)) do
      {num, _} when num >= min_val and num <= max_val -> num
      _ -> default
    end
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Movies Database")
  end

  # Data loading helpers
  defp list_genres do
    Repo.all(from g in Genre, order_by: g.name)
  end

  defp list_production_countries do
    Repo.all(from c in ProductionCountry, order_by: c.name)
  end

  defp list_spoken_languages do
    Repo.all(from l in SpokenLanguage, order_by: l.english_name)
  end

  defp list_canonical_lists do
    MovieLists.get_active_source_keys()
    |> Enum.map(fn key ->
      case MovieLists.get_config(key) do
        {:ok, config} -> %{key: key, name: config.name}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp generate_decades do
    current_year = Date.utc_today().year
    start_decade = 1900

    for decade <- start_decade..current_year//10 do
      %{value: decade, label: "#{decade}s"}
    end
    |> Enum.reverse()
  end

  # Pagination path builder
  def build_pagination_path(assigns, new_params \\ %{}) do
    current_params =
      %{
        "page" => to_string(assigns.page),
        "per_page" => to_string(assigns.per_page),
        "sort" => assigns.sort,
        "search" => assigns.search_term
      }
      |> Map.merge(stringify_filters(assigns.filters))

    params =
      current_params
      |> Map.merge(new_params)
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" or v == [] end)
      |> Map.new()

    ~p"/movies?#{params}"
  end

  # Pagination helper
  def pagination_range(current_page, total_pages, opts \\ []) do
    max_links = Keyword.get(opts, :max_links, 7)

    cond do
      total_pages <= max_links ->
        1..total_pages |> Enum.to_list()

      current_page <= 3 ->
        [1, 2, 3, 4, "...", total_pages]

      current_page >= total_pages - 2 ->
        [1, "...", total_pages - 3, total_pages - 2, total_pages - 1, total_pages]

      true ->
        [1, "...", current_page - 1, current_page, current_page + 1, "...", total_pages]
    end
  end
end
