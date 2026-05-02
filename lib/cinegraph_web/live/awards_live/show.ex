defmodule CinegraphWeb.AwardsLive.Show do
  @moduledoc """
  LiveView for displaying movies from a specific festival/awards organization.
  Provides clean URLs at /awards/:slug while reusing the movie search infrastructure.

  Routes:
  - /awards/:slug - All films for this festival
  - /awards/:slug/winners - Only winners
  - /awards/:slug/nominees - Only nominees (non-winners)
  """
  use CinegraphWeb, :live_view
  use CinegraphWeb.SearchEventHandlers

  alias Cinegraph.Festivals
  alias Cinegraph.Movies.Search
  alias CinegraphWeb.MovieLive.IndexV2.Events
  alias CinegraphWeb.MovieLive.IndexV2.Results
  alias CinegraphWeb.MovieLive.SortOptions

  import CinegraphWeb.SEOHelpers, only: [assign_awards_seo: 4]

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
    org = socket.assigns.organization
    slug_or_id = org.slug || org.id

    case socket.assigns.filter_mode do
      :winners -> ~p"/awards/#{slug_or_id}/winners?#{params}"
      :nominees -> ~p"/awards/#{slug_or_id}/nominees?#{params}"
      _ -> ~p"/awards/#{slug_or_id}?#{params}"
    end
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
     |> assign(:organization, nil)
     |> assign(:search_term, "")
     |> assign(:active_nav, "Awards")
     |> assign(:filter_options, filter_options)
     |> assign(:sort_options, SortOptions.all())
     |> assign(:filter_mode, :all)
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

      {:noreply,
       push_patch(socket, to: build_awards_path(slug, socket.assigns.live_action, clean_params))}
    else
      load_awards_page(slug, params, socket)
    end
  end

  defp load_awards_page(slug, params, socket) do
    organization = Festivals.get_organization_by_slug_or_id(slug)

    if organization do
      page_params = Map.delete(params, "slug")
      filter_mode = determine_filter_mode(socket.assigns.live_action)
      sort_param = params["sort"] || "release_date_desc"
      criteria = extract_sort_criteria(sort_param)
      direction = extract_sort_direction(sort_param)
      sort_is_preset = SortOptions.preset?(criteria)
      active_lens_key = SortOptions.active_lens_key(criteria)

      # Build search params with festival filter
      search_params =
        params
        |> Map.put("festivals", to_string(organization.id))
        |> Map.put("award_status", award_status_for_mode(filter_mode))
        |> Map.put("per_page", "24")
        |> Map.delete("slug")

      case Search.search_movies(search_params) do
        {:ok, {movies, meta}} ->
          movies = Results.preload_card_assocs(movies, active_lens_key)

          {:noreply,
           socket
           |> assign(:organization, organization)
           |> assign(:movies, movies)
           |> assign(:meta, meta)
           |> assign(:params, page_params)
           |> assign(:filter_mode, filter_mode)
           |> assign(:search_term, params["search"] || "")
           |> assign(:sort_criteria, criteria)
           |> assign(:sort_direction, direction)
           |> assign(:sort_is_preset, sort_is_preset)
           |> assign(:active_lens_key, active_lens_key)
           |> assign_pagination(meta)
           |> assign_awards_seo(organization, filter_mode, movies)}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(:organization, organization)
           |> assign(:movies, [])
           |> assign(:meta, %{})
           |> assign(:params, page_params)
           |> put_flash(:error, "Unable to load movies")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Festival not found")
       |> push_navigate(to: ~p"/awards")}
    end
  end

  defp query_slug_param?(url) do
    case URI.parse(url).query do
      nil -> false
      query -> Map.has_key?(URI.decode_query(query), "slug")
    end
  end

  defp build_awards_path(slug, :winners, params), do: ~p"/awards/#{slug}/winners?#{params}"
  defp build_awards_path(slug, :nominees, params), do: ~p"/awards/#{slug}/nominees?#{params}"
  defp build_awards_path(slug, _live_action, params), do: ~p"/awards/#{slug}?#{params}"

  # ============================================================================
  # Awards-Specific Event Handlers
  # ============================================================================

  # This handler is specific to AwardsLive for switching between all/winners/nominees views
  # We override the macro's handle_event and delegate non-matching events to super
  @impl Phoenix.LiveView
  def handle_event("change_filter", %{"filter" => filter}, socket) do
    org = socket.assigns.organization
    slug_or_id = org.slug || org.id

    base_path =
      case filter do
        "winners" -> ~p"/awards/#{slug_or_id}/winners"
        "nominees" -> ~p"/awards/#{slug_or_id}/nominees"
        _ -> ~p"/awards/#{slug_or_id}"
      end

    {:noreply, push_navigate(socket, to: base_path)}
  end

  @impl Phoenix.LiveView
  def handle_event(event, params, socket) do
    case Events.handle_event(event, params, socket) do
      :unknown -> super(event, params, socket)
      reply -> reply
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp determine_filter_mode(:winners), do: :winners
  defp determine_filter_mode(:nominees), do: :nominees
  defp determine_filter_mode(_), do: :all

  defp award_status_for_mode(:winners), do: "won"
  defp award_status_for_mode(:nominees), do: "nominated_only"
  defp award_status_for_mode(:all), do: "any_nomination"
end
