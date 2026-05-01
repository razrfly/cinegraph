defmodule CinegraphWeb.MovieLive.IndexV2 do
  @moduledoc """
  V2 movies discovery page.

  Lives at `/movies` (after route promotion). Reuses
  `Cinegraph.Movies.Search.search_movies/1` as the sole data source. UI is built
  on `CinegraphWeb.NeutralV2Components` (mist palette + Instrument Serif italic).

  Filter shell (Option C from issue #785):
  - Sort segmented control (Most recent / Top rated / Mob / Critics / Insiders + ▼ More) + ↑↓ + ?
  - Decade chips (multi-select)
  - Genre chips (multi-select)
  - Filters drawer (Lists, Festivals, Cast & Crew, Rating Quality, Include Unreleased)
  - Active-filter chip strip with individual ✕

  Sort handlers, search, pagination, clear, remove-filter, and people-autocomplete
  plumbing come from the shared `CinegraphWeb.SearchEventHandlers` macro — same
  one v1 uses, so the two pages stay behaviorally consistent.
  """
  use CinegraphWeb, :live_view
  use CinegraphWeb.SearchEventHandlers

  require Logger

  import Ecto.Query

  alias Cinegraph.Repo
  alias Cinegraph.Movies.Search
  alias Cinegraph.Movies.Genre
  alias Cinegraph.Movies.Person
  alias CinegraphWeb.MovieLive.IndexV2Components
  alias CinegraphWeb.MovieLive.IndexV2.Events
  alias CinegraphWeb.MovieLive.IndexV2.Results
  alias CinegraphWeb.MovieLive.SortOptions

  import CinegraphWeb.LiveViewHelpers,
    only: [
      extract_sort_criteria: 1,
      extract_sort_direction: 1,
      assign_pagination: 2
    ]

  @page_size 24

  # ============================================================================
  # SearchEventHandlers callback
  # ============================================================================

  @impl CinegraphWeb.SearchEventHandlers
  def build_path(socket, params) do
    params = canonicalize_filter_params(socket, params)
    query = Plug.Conn.Query.encode(params) |> String.replace("%2C", ",")

    if query == "", do: ~p"/movies", else: "/movies?#{query}"
  end

  # ============================================================================
  # Mount / handle_params
  # ============================================================================

  @impl true
  def mount(_params, _session, socket) do
    filter_options =
      try do
        Search.get_filter_options()
      rescue
        exception ->
          Logger.error(
            "Search.get_filter_options failed: " <>
              Exception.format(:error, exception, __STACKTRACE__)
          )

          %{genres: [], decades: [], lists: [], festivals: [], languages: []}
      end

    {:ok,
     socket
     |> assign(:page_title, "Movies")
     |> assign(:active_nav, "Movies")
     |> assign(:filter_options, filter_options)
     |> assign(:sort_options, SortOptions.all())
     # SearchEventHandlers expects these
     |> assign(:params, %{})
     |> assign(:show_filters, false)
     |> assign(:sort_criteria, "release_date")
     |> assign(:sort_direction, :desc)
     # V2-specific UI state
     |> assign(:show_drawer, false)
     |> assign(:show_scoring_info, false)
     |> assign(:active_lens_key, nil)
     |> assign(:sort_is_preset, false)
     # Empty initial assigns the SearchEventHandlers info handlers expect
     |> assign(:director_options, [])
     |> assign(:actor_options, [])
     |> assign(:person_options, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    sort_param = params["sort"] || "release_date_desc"
    criteria = extract_sort_criteria(sort_param)
    direction = extract_sort_direction(sort_param)
    sort_is_preset = SortOptions.preset?(criteria)
    active_lens_key = SortOptions.active_lens_key(criteria)

    query_params = Map.put(params, "per_page", to_string(@page_size))

    case Search.search_movies(query_params) do
      {:ok, {movies, meta}} ->
        movies = Results.preload_card_assocs(movies, active_lens_key)

        {:noreply,
         socket
         |> assign(:movies, movies)
         |> assign(:meta, meta)
         |> assign(:params, params)
         |> assign(:search_term, params["search"] || "")
         |> assign(:sort_criteria, criteria)
         |> assign(:sort_direction, direction)
         |> assign(:sort_is_preset, sort_is_preset)
         |> assign(:active_lens_key, active_lens_key)
         |> assign(:total_count, meta.total_count)
         |> assign_pagination(meta)}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:movies, [])
         |> assign(:meta, %Flop.Meta{total_count: 0, total_pages: 0, current_page: 1})
         |> assign(:params, params)
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
         |> assign(:per_page, @page_size)}
    end
  end

  @impl true
  def handle_event(event, params, socket) do
    case Events.handle_event(event, params, socket) do
      :unknown -> super(event, params, socket)
      reply -> reply
    end
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="mx-auto w-full max-w-2xl px-6 md:max-w-3xl lg:max-w-7xl lg:px-10 pt-6 pb-16"
      phx-window-keydown="hide_drawer"
      phx-key="Escape"
    >
      <IndexV2Components.hero total_count={@total_count} />
      <IndexV2Components.discovery_body
        movies={@movies}
        meta={@meta}
        params={@params}
        filter_options={@filter_options}
        search_term={@search_term}
        sort_options={@sort_options}
        sort_criteria={@sort_criteria}
        sort_direction={@sort_direction}
        sort_is_preset={@sort_is_preset}
        active_lens_key={@active_lens_key}
        show_drawer={@show_drawer}
        show_scoring_info={@show_scoring_info}
      />

      <%!-- Legacy v1 escape hatch — temporary during the V2 soak period --%>
      <a
        href="/movies/legacy"
        class="fixed bottom-4 right-4 z-30 inline-flex items-center gap-2 rounded-full bg-mist-950 px-4 py-2 text-xs font-medium text-mist-100 shadow-lg hover:bg-mist-800"
      >
        ← Old movies page
      </a>
    </div>
    """
  end

  defp canonicalize_filter_params(socket, params) do
    params
    |> canonicalize_genre_param(socket)
    |> canonicalize_festival_param(socket)
    |> canonicalize_list_param(socket)
    |> canonicalize_people_param()
    |> strip_empty_filter_params()
  end

  defp canonicalize_genre_param(params, socket) do
    genres = Map.get(params, "genres") || Map.get(params, "genres[]")

    params =
      case canonical_genre_slugs(socket, genres) do
        [] -> Map.delete(params, "genres")
        slugs -> Map.put(params, "genres", Enum.join(slugs, ","))
      end

    Map.delete(params, "genres[]")
  end

  defp canonicalize_festival_param(params, socket) do
    festivals = Map.get(params, "festivals") || Map.get(params, "festivals[]")

    params =
      case canonical_festival_slugs(socket, festivals) do
        [] -> Map.delete(params, "festivals")
        slugs -> Map.put(params, "festivals", Enum.join(slugs, ","))
      end

    Map.delete(params, "festivals[]")
  end

  defp canonicalize_list_param(params, socket) do
    lists = Map.get(params, "lists") || Map.get(params, "lists[]")

    params =
      case canonical_list_slugs(socket, lists) do
        [] -> Map.delete(params, "lists")
        slugs -> Map.put(params, "lists", Enum.join(slugs, ","))
      end

    Map.delete(params, "lists[]")
  end

  defp canonicalize_people_param(params) do
    values =
      cond do
        Map.has_key?(params, "people") ->
          params["people"]

        Map.has_key?(params, "people_ids") ->
          params["people_ids"]

        match?(%{}, params["people_search"]) ->
          get_in(params, ["people_search", "people_ids"])

        Map.has_key?(params, "people_search[people_ids]") ->
          params["people_search[people_ids]"]

        true ->
          nil
      end

    params =
      case canonical_people_slugs(values) do
        [] -> Map.delete(params, "people")
        slugs -> Map.put(params, "people", Enum.join(slugs, ","))
      end

    params
    |> Map.delete("people_ids")
    |> Map.delete("people_search")
    |> Map.delete("people_search[people_ids]")
    |> Map.delete("people_search[role_filter]")
  end

  defp canonical_genre_slugs(_socket, nil), do: []
  defp canonical_genre_slugs(_socket, []), do: []

  defp canonical_genre_slugs(socket, values) do
    values = CinegraphWeb.LiveViewHelpers.parse_array_param(values)

    genres =
      socket.assigns
      |> Map.get(:filter_options, %{})
      |> Map.get(:genres, [])

    values
    |> Enum.map(&genre_slug_for_value(&1, genres))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp genre_slug_for_value(value, genres) when is_integer(value) do
    genres
    |> Enum.find(&(&1.id == value))
    |> Genre.slug()
  end

  defp genre_slug_for_value(value, genres) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> genre_slug_for_value(id, genres)
      _ -> Genre.slug(value)
    end
  end

  defp genre_slug_for_value(_value, _genres), do: nil

  defp canonical_festival_slugs(_socket, nil), do: []
  defp canonical_festival_slugs(_socket, []), do: []

  defp canonical_festival_slugs(socket, values) do
    values = CinegraphWeb.LiveViewHelpers.parse_array_param(values)

    festivals =
      socket.assigns
      |> Map.get(:filter_options, %{})
      |> Map.get(:festivals, [])

    values
    |> Enum.map(&festival_slug_for_value(&1, festivals))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp festival_slug_for_value(value, festivals) when is_integer(value) do
    festivals
    |> Enum.find(&(&1.id == value))
    |> map_slug()
  end

  defp festival_slug_for_value(value, festivals) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> festival_slug_for_value(id, festivals)
      _ -> value
    end
  end

  defp festival_slug_for_value(_value, _festivals), do: nil

  defp canonical_list_slugs(_socket, nil), do: []
  defp canonical_list_slugs(_socket, []), do: []

  defp canonical_list_slugs(socket, values) do
    values = CinegraphWeb.LiveViewHelpers.parse_array_param(values)

    lists =
      socket.assigns
      |> Map.get(:filter_options, %{})
      |> Map.get(:lists, [])

    values
    |> Enum.map(&list_slug_for_value(&1, lists))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp list_slug_for_value(value, lists) do
    value = to_string(value)

    case Enum.find(lists, &(&1.key == value or Map.get(&1, :slug) == value)) do
      nil -> value
      list -> Map.get(list, :slug) || list.key
    end
  end

  defp canonical_people_slugs(nil), do: []
  defp canonical_people_slugs([]), do: []

  defp canonical_people_slugs(values) do
    values
    |> CinegraphWeb.LiveViewHelpers.parse_array_param()
    |> people_slugs_for_values()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp people_slugs_for_values(values) do
    {ids, slugs} =
      Enum.reduce(values, {[], []}, fn
        v, {ids, slugs} when is_integer(v) ->
          {[v | ids], slugs}

        v, {ids, slugs} when is_binary(v) ->
          case Integer.parse(v) do
            {id, ""} -> {[id | ids], slugs}
            _ -> {ids, [v | slugs]}
          end

        _v, acc ->
          acc
      end)

    id_slugs =
      case ids do
        [] ->
          []

        ids ->
          Person
          |> where([p], p.id in ^ids)
          |> select([p], p.slug)
          |> Repo.replica().all()
      end

    (slugs ++ id_slugs)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp strip_empty_filter_params(params) do
    params
    |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)
    |> Map.new()
  end

  defp map_slug(nil), do: nil
  defp map_slug(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp map_slug(_), do: nil
end
