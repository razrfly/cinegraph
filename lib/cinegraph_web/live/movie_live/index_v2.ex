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

  alias Cinegraph.Movies.Search
  alias Cinegraph.Repo
  alias CinegraphWeb.MovieLive.IndexV2Components
  alias CinegraphWeb.MovieLive.IndexV2Drawer
  alias CinegraphWeb.MovieLive.SortOptions

  import CinegraphWeb.LiveViewHelpers,
    only: [
      extract_sort_criteria: 1,
      extract_sort_direction: 1,
      assign_pagination: 2,
      parse_array_param: 1
    ]

  @page_size 24

  # ============================================================================
  # SearchEventHandlers callback
  # ============================================================================

  @impl CinegraphWeb.SearchEventHandlers
  def build_path(_socket, params), do: ~p"/movies?#{params}"

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
        movies = preload_card_assocs(movies, active_lens_key)

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

  # ============================================================================
  # V2-specific event handlers (drawer / scoring modal / chip toggles)
  # ============================================================================

  @impl true
  def handle_event("toggle_drawer", _params, socket) do
    {:noreply, assign(socket, :show_drawer, !socket.assigns.show_drawer)}
  end

  def handle_event("hide_drawer", _params, socket),
    do: {:noreply, assign(socket, :show_drawer, false)}

  def handle_event("show_scoring_info", _params, socket),
    do: {:noreply, assign(socket, :show_scoring_info, true)}

  def handle_event("hide_scoring_info", _params, socket),
    do: {:noreply, assign(socket, :show_scoring_info, false)}

  # Chip toggle: `mode="multi"` adds/removes value in the list-typed param
  # (genres). `mode="single"` (default) toggles the single-string value (decade).
  def handle_event("toggle_chip", %{"key" => key, "value" => value} = params, socket) do
    mode = params["mode"] || "single"
    str_value = to_string(value)

    new_param =
      case mode do
        "multi" ->
          current = parse_array_param(socket.assigns.params[key])

          new_list =
            if str_value in current,
              do: List.delete(current, str_value),
              else: [str_value | current]

          if new_list == [], do: nil, else: new_list

        _ ->
          if to_string(socket.assigns.params[key]) == str_value, do: nil, else: str_value
      end

    new_params =
      socket.assigns.params
      |> put_or_delete(key, new_param)
      |> Map.put("page", "1")

    path = build_path(socket, new_params)
    {:noreply, push_patch(socket, to: path)}
  end

  # Override remove_filter so the active-filter chip strip can drop one filter at
  # a time. Accepts an optional `filter-type` value ("basic"/"advanced") that the
  # legacy template emits — we ignore it; key alone is enough.
  def handle_event("remove_filter", %{"filter" => filter_key} = params, socket) do
    _ = params["filter-type"]

    new_params =
      socket.assigns.params
      |> Map.delete(filter_key)
      |> Map.put("page", "1")

    path = build_path(socket, new_params)
    {:noreply, push_patch(socket, to: path)}
  end

  # Delegate everything else to the SearchEventHandlers macro
  def handle_event(event, params, socket), do: super(event, params, socket)

  # ============================================================================
  # Helpers
  # ============================================================================

  defp put_or_delete(map, key, nil), do: Map.delete(map, key)
  defp put_or_delete(map, key, ""), do: Map.delete(map, key)
  defp put_or_delete(map, key, []), do: Map.delete(map, key)
  defp put_or_delete(map, key, value), do: Map.put(map, key, value)

  # Preloads only what the V2 grid needs. Empty list = use the read replica.
  # `:score_cache` is preloaded only when a Lens sort is active — this is what
  # surfaces the lens-component % chips on cards. Single batched query for all
  # 24 rows; verified no N+1 in `docs/perf/movies-v2-explain.md`.
  defp preload_card_assocs([], _), do: []

  defp preload_card_assocs(movies, lens_key) when is_binary(lens_key) do
    Repo.replica().preload(movies, [:score_cache])
  end

  defp preload_card_assocs(movies, _), do: movies

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-2xl px-6 md:max-w-3xl lg:max-w-7xl lg:px-10 pt-6 pb-16">
      <IndexV2Components.hero total_count={@total_count} />
      <IndexV2Components.filters
        search_term={@search_term}
        sort_options={@sort_options}
        sort_criteria={@sort_criteria}
        sort_direction={@sort_direction}
        sort_is_preset={@sort_is_preset}
        filter_options={@filter_options}
        params={@params}
        active_filter_count={IndexV2Components.active_filter_count(@params)}
      />
      <IndexV2Components.active_filters params={@params} filter_options={@filter_options} />
      <IndexV2Components.results movies={@movies} active_lens_key={@active_lens_key} />
      <IndexV2Components.pagination meta={@meta} />

      <IndexV2Drawer.filters_drawer
        show={@show_drawer}
        filter_options={@filter_options}
        selected_lists={IndexV2Components.list_param(@params, "lists")}
        selected_festivals={IndexV2Components.list_param(@params, "festivals")}
        selected_people={IndexV2Components.selected_people_ids(@params)}
        rating_preset={@params["rating_preset"]}
        show_unreleased={@params["show_unreleased"]}
        active_filter_count={IndexV2Components.active_filter_count(@params)}
      />
      <IndexV2Drawer.scoring_modal show={@show_scoring_info} />

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
end
