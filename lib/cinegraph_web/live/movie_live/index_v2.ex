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

  alias Cinegraph.Movies.Search
  alias CinegraphWeb.NeutralV2Components

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
        _ -> %{genres: [], decades: [], lists: [], festivals: []}
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

  # ─── Card adapter ──────────────────────────────────────────────────

  defp to_card_shape(movie) do
    %{
      id: movie.id,
      title: movie.title,
      year: year_of(movie.release_date),
      dir: nil,
      score: overall_score(movie),
      poster_url: tmdb_poster_url(movie.poster_path, "w500"),
      href: movie_href(movie)
    }
  end

  defp year_of(%Date{year: y}), do: y
  defp year_of(_), do: nil

  defp overall_score(%{score_cache: %{overall_score: s}}) when is_number(s),
    do: round(s * 10)

  defp overall_score(_), do: nil

  defp tmdb_poster_url(nil, _), do: nil
  defp tmdb_poster_url("", _), do: nil
  defp tmdb_poster_url("/" <> _ = path, size), do: "https://image.tmdb.org/t/p/#{size}#{path}"
  defp tmdb_poster_url(path, size), do: "https://image.tmdb.org/t/p/#{size}/#{path}"

  defp movie_href(%{slug: slug}) when is_binary(slug) and slug != "",
    do: "/movies/#{slug}"

  defp movie_href(%{id: id}), do: "/movies/#{id}"

  # ─── Render ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-2xl px-6 md:max-w-3xl lg:max-w-7xl lg:px-10 pt-6 pb-16">
      <%!-- HERO --%>
      <section class="mb-8 lg:mb-12">
        <h1 class="font-display italic text-[44px] sm:text-[56px] lg:text-[72px] tracking-[-.02em] text-balance text-mist-950 leading-[1.02]">
          Movies.
        </h1>
        <div class="text-[15px] text-mist-700 mt-2 max-w-2xl">
          {format_count(@total_count)} films across canonical lists, festivals, and critical canon.
        </div>
      </section>

      <%!-- FILTERS --%>
      <section class="mb-8">
        <%!-- Search --%>
        <form phx-change="search" phx-submit="search" class="mb-4">
          <div class="relative flex items-center bg-mist-50 rounded-lg border border-mist-950/15 h-11 px-[14px]">
            <svg
              width="15"
              height="15"
              viewBox="0 0 16 16"
              fill="none"
              class="shrink-0 text-mist-500"
            >
              <circle cx="7" cy="7" r="5" stroke="currentColor" stroke-width="1.4" />
              <path
                d="M11 11 L14 14"
                stroke="currentColor"
                stroke-width="1.4"
                stroke-linecap="round"
              />
            </svg>
            <input
              name="search"
              value={@search_term}
              placeholder="Search films, people, lists, companies…"
              phx-debounce="350"
              autocomplete="off"
              class="flex-1 ml-[9px] text-mist-950 bg-transparent border-0 outline-none min-w-0 font-[inherit] text-[14.5px]"
            />
            <kbd class="font-mono text-[10.5px] font-semibold px-[6px] py-[3px] bg-mist-950/[0.025] border border-mist-950/10 rounded-[4px] text-mist-700">
              ⌘K
            </kbd>
          </div>
        </form>

        <%!-- Sort tabs --%>
        <div class="flex items-center gap-3 mb-4 flex-wrap">
          <span class="text-[11px] font-semibold text-mist-500 tracking-[.06em] uppercase shrink-0">
            SORT
          </span>
          <div class="inline-flex p-[3px] bg-mist-950/[0.025] border border-mist-950/10 rounded-lg gap-[2px]">
            <button
              :for={opt <- @sort_options}
              type="button"
              phx-click="sort"
              phx-value-sort={opt.key}
              class={[
                "px-3 py-[6px] text-[12.5px] border-0 rounded-[6px] cursor-pointer tracking-[-.005em]",
                if(@active_sort == opt.key,
                  do: "font-semibold text-mist-950 bg-mist-50 shadow-[0_1px_2px_rgba(20,18,15,.06)]",
                  else: "font-medium text-mist-700 bg-transparent"
                )
              ]}
            >
              {opt.label}
            </button>
          </div>

          <%!-- Decade pills --%>
          <span class="text-[11px] font-semibold text-mist-500 tracking-[.06em] uppercase shrink-0 ml-2">
            DECADE
          </span>
          <button
            :for={d <- @decade_options}
            type="button"
            phx-click="filter_decade"
            phx-value-decade={d.key}
            class={[
              "px-[11px] py-[5px] text-[12px] rounded-full cursor-pointer whitespace-nowrap shrink-0",
              if(@active_decade == d.key,
                do: "font-semibold text-mist-50 bg-mist-950 border border-mist-950",
                else: "font-medium text-mist-900 bg-mist-50 border border-mist-950/10 hover:bg-mist-950/[0.025]"
              )
            ]}
          >
            {d.label}
          </button>

          <button
            :if={@active_genre_id || @active_decade || @search_term != "" || @active_sort != "release_date_desc"}
            type="button"
            phx-click="clear_filters"
            class="text-[12px] font-medium text-mist-700 underline decoration-mist-950/15 underline-offset-4 ml-2"
          >
            Clear filters
          </button>
        </div>

        <%!-- Genre chips --%>
        <div :if={@filter_options[:genres] != []} class="flex items-center gap-[6px] flex-wrap">
          <span class="text-[11px] font-semibold text-mist-500 tracking-[.06em] uppercase shrink-0 mr-1">
            GENRE
          </span>
          <button
            :for={genre <- @filter_options[:genres] || []}
            type="button"
            phx-click="filter_genre"
            phx-value-id={to_string(genre.id)}
            class={[
              "px-[11px] py-[5px] text-[12px] rounded-full cursor-pointer whitespace-nowrap shrink-0",
              if(@active_genre_id == to_string(genre.id),
                do: "font-semibold text-mist-50 bg-mist-950 border border-mist-950",
                else: "font-medium text-mist-900 bg-mist-50 border border-mist-950/10 hover:bg-mist-950/[0.025]"
              )
            ]}
          >
            {genre.name}
          </button>
        </div>
      </section>

      <%!-- RESULTS --%>
      <section class="mb-8">
        <div :if={@movies == []} class="py-20 text-center">
          <p class="font-display italic text-[28px] text-mist-700">
            No films match these filters.
          </p>
          <button
            phx-click="clear_filters"
            class="mt-4 inline-flex items-center justify-center gap-1 rounded-full bg-mist-950 px-4 py-2 text-sm/7 font-medium text-mist-100 hover:bg-mist-800"
          >
            Clear filters
          </button>
        </div>

        <div
          :if={@movies != []}
          class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 gap-[18px]"
        >
          <NeutralV2Components.n_film_card
            :for={movie <- @movies}
            film={to_card_shape(movie)}
          />
        </div>
      </section>

      <%!-- PAGINATION --%>
      <nav
        :if={@meta && @meta.total_pages && @meta.total_pages > 1}
        class="flex items-center justify-between gap-4 pt-6 border-t border-mist-950/10 text-[13px] text-mist-700"
      >
        <button
          type="button"
          phx-click="paginate"
          phx-value-page={max(1, (@meta.current_page || 1) - 1)}
          disabled={(@meta.current_page || 1) <= 1}
          class="inline-flex items-center gap-2 rounded-full border border-mist-950/15 bg-mist-50 px-4 py-2 font-medium text-mist-950 hover:bg-mist-950/[0.025] disabled:opacity-40 disabled:cursor-not-allowed"
        >
          ← Previous
        </button>

        <div class="text-[12px] tabular-nums">
          Page <b class="text-mist-950 font-semibold">{@meta.current_page}</b>
          of <b class="text-mist-950 font-semibold">{@meta.total_pages}</b>
          <span class="text-mist-500">
            · {format_count(@meta.total_count)} films
          </span>
        </div>

        <button
          type="button"
          phx-click="paginate"
          phx-value-page={min(@meta.total_pages, (@meta.current_page || 1) + 1)}
          disabled={(@meta.current_page || 1) >= @meta.total_pages}
          class="inline-flex items-center gap-2 rounded-full border border-mist-950/15 bg-mist-50 px-4 py-2 font-medium text-mist-950 hover:bg-mist-950/[0.025] disabled:opacity-40 disabled:cursor-not-allowed"
        >
          Next →
        </button>
      </nav>

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

  defp format_count(nil), do: "—"

  defp format_count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
