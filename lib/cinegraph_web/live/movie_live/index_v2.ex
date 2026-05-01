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

  alias CinegraphWeb.MovieLive.IndexV2Components
  alias CinegraphWeb.MovieLive.IndexV2.Canonicalize
  alias CinegraphWeb.MovieLive.IndexV2.Events
  alias CinegraphWeb.MovieLive.IndexV2.SearchHandler
  alias CinegraphWeb.MovieLive.SortOptions

  @page_size 24

  # ============================================================================
  # SearchEventHandlers callback
  # ============================================================================

  @impl CinegraphWeb.SearchEventHandlers
  def build_path(socket, params) do
    params = Canonicalize.filter_params(socket, params)
    query = Plug.Conn.Query.encode(params) |> String.replace("%2C", ",")

    if query == "", do: ~p"/movies", else: "/movies?#{query}"
  end

  # ============================================================================
  # Mount / handle_params
  # ============================================================================

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Movies")
     |> assign(:active_nav, "Movies")
     |> assign(:filter_options, SearchHandler.filter_options())
     |> assign(:sort_options, SortOptions.all())
     # SearchEventHandlers expects these
     |> assign(:params, %{})
     |> assign(:people_slug_cache, %{})
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
    {:noreply, SearchHandler.assign_search(socket, params, @page_size)}
  end

  @impl true
  def handle_info({:search_people_autocomplete, component_id, query}, socket) do
    results =
      if String.trim(query) == "" do
        []
      else
        Cinegraph.Movies.Search.search_people(query, 10)
      end

    send_update(CinegraphWeb.Components.PersonAutocomplete,
      id: component_id,
      search_results: results,
      searching: false,
      cache_query: query,
      cache_timestamp: DateTime.utc_now()
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:people_selected, _component_id, selected_people}, socket) do
    slugs =
      selected_people
      |> Enum.map(&person_slug/1)
      |> Enum.reject(&(&1 in [nil, ""]))

    people_slug_cache =
      selected_people
      |> Enum.reduce(socket.assigns[:people_slug_cache] || %{}, fn person, acc ->
        slug = person_slug(person)
        id = person_id(person)

        if id in [nil, ""] or slug in [nil, ""] do
          acc
        else
          Map.put(acc, id, slug)
        end
      end)

    params =
      socket.assigns.params
      |> Events.put_or_delete("people", if(slugs == [], do: nil, else: Enum.join(slugs, ",")))
      |> Map.delete("people_ids")
      |> Map.put("page", "1")

    socket = assign(socket, :people_slug_cache, people_slug_cache)

    {:noreply, push_patch(socket, to: build_path(socket, params))}
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

  defp person_slug(%{slug: slug}), do: slug
  defp person_slug(%{"slug" => slug}), do: slug
  defp person_slug(_), do: nil

  defp person_id(%{id: id}), do: id
  defp person_id(%{"id" => id}), do: id
  defp person_id(_), do: nil
end
