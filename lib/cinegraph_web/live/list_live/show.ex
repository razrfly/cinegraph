defmodule CinegraphWeb.ListLive.Show do
  @moduledoc """
  LiveView for displaying movies from a specific curated list.
  Provides a clean URL at /lists/:slug while reusing the movie search infrastructure.
  """
  use CinegraphWeb, :live_view
  use CinegraphWeb.SearchEventHandlers

  alias Cinegraph.Lists.ListSlugs
  alias Cinegraph.Movies.Search
  alias CinegraphWeb.MovieLive.IndexV2.Events
  alias CinegraphWeb.MovieLive.IndexV2.Results
  alias CinegraphWeb.MovieLive.SortOptions

  import CinegraphWeb.SEOHelpers, only: [assign_curated_list_seo: 3]

  import CinegraphWeb.LiveViewHelpers,
    only: [
      extract_sort_criteria: 1,
      extract_sort_direction: 1,
      assign_pagination: 2
    ]

  # ============================================================================
  # SearchEventHandlers Callback
  # ============================================================================

  @impl CinegraphWeb.SearchEventHandlers
  def build_path(socket, params) do
    ~p"/lists/#{socket.assigns.list_info.slug}?#{params}"
  end

  # ============================================================================
  # LiveView Callbacks
  # ============================================================================

  @impl true
  def mount(_params, _session, socket) do
    # Load filter options (same as MovieLive.Index)
    filter_options = Search.get_filter_options()

    {:ok,
     socket
     |> assign(:movies, [])
     |> assign(:meta, %{})
     |> assign(:list_info, nil)
     |> assign(:search_term, "")
     |> assign(:active_nav, "Lists")
     |> assign(:filter_options, filter_options)
     |> assign(:sort_options, SortOptions.all())
     |> assign(:sort_criteria, "release_date")
     |> assign(:sort_direction, :desc)
     |> assign(:sort_is_preset, false)
     |> assign(:active_lens_key, nil)
     |> assign(:show_drawer, false)
     |> assign(:show_scoring_info, false)
     |> assign(:show_filters, false)
     |> assign(:person_options, [])}
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, url, socket) do
    if query_slug_param?(url) do
      clean_params = Map.delete(params, "slug")
      {:noreply, push_patch(socket, to: ~p"/lists/#{slug}?#{clean_params}")}
    else
      load_list_page(slug, params, socket)
    end
  end

  defp load_list_page(slug, params, socket) do
    case ListSlugs.get_by_slug(slug) do
      {:ok, list_info} ->
        page_params = Map.delete(params, "slug")
        sort_param = params["sort"] || "release_date_desc"
        criteria = extract_sort_criteria(sort_param)
        direction = extract_sort_direction(sort_param)
        sort_is_preset = SortOptions.preset?(criteria)
        active_lens_key = SortOptions.active_lens_key(criteria)

        # Merge the list filter with any additional query params
        search_params =
          params
          |> Map.put("lists", list_info.key)
          |> Map.put("per_page", "24")
          |> Map.delete("slug")

        case Search.search_movies(search_params) do
          {:ok, {movies, meta}} ->
            movies = Results.preload_card_assocs(movies, active_lens_key)

            {:noreply,
             socket
             |> assign(:list_info, list_info)
             |> assign(:movies, movies)
             |> assign(:meta, meta)
             |> assign(:params, page_params)
             |> assign(:search_term, params["search"] || "")
             |> assign(:sort_criteria, criteria)
             |> assign(:sort_direction, direction)
             |> assign(:sort_is_preset, sort_is_preset)
             |> assign(:active_lens_key, active_lens_key)
             |> assign_pagination(meta)
             |> assign(:list_slug, list_info.slug)
             |> assign_curated_list_seo(list_info, movies)}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(:list_info, list_info)
             |> assign(:movies, [])
             |> assign(:meta, %{})
             |> assign(:params, page_params)
             |> put_flash(:error, "Unable to load movies")}
        end

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "List not found")
         |> push_navigate(to: ~p"/lists")}
    end
  end

  defp query_slug_param?(url) do
    case URI.parse(url).query do
      nil -> false
      query -> Map.has_key?(URI.decode_query(query), "slug")
    end
  end

  @impl Phoenix.LiveView
  def handle_event(event, params, socket) do
    case Events.handle_event(event, params, socket) do
      :unknown -> super(event, params, socket)
      reply -> reply
    end
  end
end
