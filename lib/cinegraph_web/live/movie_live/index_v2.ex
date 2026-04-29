defmodule CinegraphWeb.MovieLive.IndexV2 do
  @moduledoc """
  Phase 3 starter — `/movies-v2` discovery page on the V2 design system.

  Side-by-side prototype of the existing `/movies` LiveView, rebuilt with
  `CinegraphWeb.NeutralV2Components` (mist palette, Instrument Serif italic
  display, Inter body, Oatmeal responsive container). Reuses the existing
  `Cinegraph.Movies.Search` data layer — no schema or context changes.

  The existing `/movies` route is untouched. After parity is confirmed in a
  future plan, the routes swap (this becomes `/movies`, original goes to
  `/movies/classic`).
  """
  use CinegraphWeb, :live_view

  require Logger

  alias Cinegraph.Movies.Search
  alias CinegraphWeb.MovieLive.IndexV2Components

  @page_size 24

  @sort_options [
    %{key: "release_date_desc", label: "Most recent"},
    %{key: "score_desc", label: "Top rated"},
    %{key: "popularity_desc", label: "Most popular"}
  ]

  @decade_options [
    %{key: "1980", label: "1980s"},
    %{key: "1990", label: "1990s"},
    %{key: "2000", label: "2000s"},
    %{key: "2010", label: "2010s"},
    %{key: "2020", label: "2020s"}
  ]

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

          %{genres: [], decades: [], lists: [], festivals: []}
      end

    {:ok,
     socket
     |> assign(:page_title, "Movies")
     |> assign(:active_nav, "Movies")
     |> assign(:filter_options, filter_options)
     |> assign(:sort_options, @sort_options)
     |> assign(:decade_options, @decade_options)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Force per_page on the query so the V2 grid shows a consistent count.
    query_params =
      params
      |> Map.put("per_page", to_string(@page_size))

    case Search.search_movies(query_params) do
      {:ok, {movies, meta}} ->
        {:noreply,
         socket
         |> assign(:movies, movies)
         |> assign(:meta, meta)
         |> assign(:params, params)
         |> assign(:search_term, params["search"] || "")
         |> assign(:active_genre_id, params["genres"])
         |> assign(:active_decade, params["decade"])
         |> assign(:active_sort, params["sort"] || "release_date_desc")
         |> assign(:total_count, meta.total_count)}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:movies, [])
         |> assign(:meta, %Flop.Meta{total_count: 0, total_pages: 0, current_page: 1})
         |> assign(:params, params)
         |> assign(:search_term, params["search"] || "")
         |> assign(:active_genre_id, params["genres"])
         |> assign(:active_decade, params["decade"])
         |> assign(:active_sort, params["sort"] || "release_date_desc")
         |> assign(:total_count, 0)}
    end
  end

  @impl true
  def handle_event("search", %{"search" => term}, socket) do
    socket
    |> patch_with(%{"search" => term, "page" => "1"})
    |> noreply()
  end

  def handle_event("filter_genre", %{"id" => id}, socket) do
    new = if socket.assigns.active_genre_id == id, do: nil, else: id

    socket
    |> patch_with(%{"genres" => new, "page" => "1"})
    |> noreply()
  end

  def handle_event("filter_decade", %{"decade" => decade}, socket) do
    new = if socket.assigns.active_decade == decade, do: nil, else: decade

    socket
    |> patch_with(%{"decade" => new, "page" => "1"})
    |> noreply()
  end

  def handle_event("sort", %{"sort" => sort}, socket) do
    socket
    |> patch_with(%{"sort" => sort, "page" => "1"})
    |> noreply()
  end

  def handle_event("clear_filters", _params, socket) do
    socket
    |> patch_with(%{}, replace: true)
    |> noreply()
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    socket
    |> patch_with(%{"page" => page})
    |> noreply()
  end

  defp patch_with(socket, new_params, opts \\ []) do
    base = if opts[:replace], do: %{}, else: socket.assigns.params

    merged =
      base
      |> Map.merge(new_params)
      |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    qs =
      case URI.encode_query(merged) do
        "" -> ""
        s -> "?" <> s
      end

    push_patch(socket, to: "/movies-v2" <> qs, replace: opts[:replace] == true)
  end

  defp noreply(socket), do: {:noreply, socket}

  # ─── Render ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-2xl px-6 md:max-w-3xl lg:max-w-7xl lg:px-10 pt-6 pb-16">
      <IndexV2Components.hero total_count={@total_count} />
      <IndexV2Components.filters
        search_term={@search_term}
        sort_options={@sort_options}
        decade_options={@decade_options}
        filter_options={@filter_options}
        active_sort={@active_sort}
        active_decade={@active_decade}
        active_genre_id={@active_genre_id}
      />
      <IndexV2Components.results movies={@movies} />
      <IndexV2Components.pagination meta={@meta} />

      <%!-- v1 access pill --%>
      <a
        href="/movies"
        class="fixed bottom-4 right-4 z-50 inline-flex items-center gap-2 rounded-full bg-mist-950 px-4 py-2 text-xs font-medium text-mist-100 shadow-lg hover:bg-mist-800"
      >
        ← see /movies (v1)
      </a>
    </div>
    """
  end
end
