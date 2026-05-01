defmodule CinegraphWeb.AwardsLive.ShowLegacy do
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

  import CinegraphWeb.LiveViewHelpers,
    only: [
      extract_sort_criteria: 1,
      extract_sort_direction: 1,
      assign_pagination: 2,
      build_pagination_params: 2,
      parse_array_param: 1
    ]

  import CinegraphWeb.FilterHelpers,
    only: [
      has_active_filters?: 2,
      build_active_filters_list: 3,
      awards_view_filter_configs: 0,
      awards_view_filter_fields: 0
    ]

  @site_url "https://cinegraph.io"

  # ============================================================================
  # SearchEventHandlers Callback
  # ============================================================================

  @impl CinegraphWeb.SearchEventHandlers
  def build_path(socket, params) do
    org = socket.assigns.organization
    slug_or_id = org.slug || org.id

    case socket.assigns.filter_mode do
      :winners -> ~p"/awards/#{slug_or_id}/winners/legacy?#{params}"
      :nominees -> ~p"/awards/#{slug_or_id}/nominees/legacy?#{params}"
      _ -> ~p"/awards/#{slug_or_id}/legacy?#{params}"
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
     |> assign(:filter_mode, :all)
     |> assign(:sort_criteria, "release_date")
     |> assign(:sort_direction, :desc)
     |> assign(:show_filters, false)
     |> assign(:filters, %{})
     # Filter options for dropdowns
     |> assign(:available_genres, filter_options.genres)
     |> assign(:available_decades, filter_options.decades)
     |> assign(:available_lists, filter_options.lists)
     # Person search options
     |> assign(:person_options, [])}
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _url, socket) do
    organization = Festivals.get_organization_by_slug_or_id(slug)

    if organization do
      filter_mode = determine_filter_mode(socket.assigns.live_action)
      page_params = Map.delete(params, "slug")

      # Build search params with festival filter
      search_params =
        params
        |> Map.put("festivals", to_string(organization.id))
        |> Map.put("award_status", award_status_for_mode(filter_mode))
        |> Map.delete("slug")

      case Search.search_movies(search_params) do
        {:ok, {movies, meta}} ->
          {:noreply,
           socket
           |> assign(:organization, organization)
           |> assign(:movies, movies)
           |> assign(:meta, meta)
           |> assign(:params, page_params)
           |> assign(:filter_mode, filter_mode)
           |> assign(:search_term, params["search"] || "")
           |> assign(:sort_criteria, extract_sort_criteria(params["sort"] || "release_date_desc"))
           |> assign(
             :sort_direction,
             extract_sort_direction(params["sort"] || "release_date_desc")
           )
           |> assign(:filters, normalize_filters(params))
           |> assign_pagination(meta)
           |> assign_awards_page_seo(organization, filter_mode, movies)}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(:organization, organization)
           |> assign(:movies, [])
           |> assign(:meta, %{})
           |> assign(:params, page_params)
           |> assign(:filter_mode, filter_mode)
           |> assign(:search_term, params["search"] || "")
           |> assign(:sort_criteria, extract_sort_criteria(params["sort"] || "release_date_desc"))
           |> assign(
             :sort_direction,
             extract_sort_direction(params["sort"] || "release_date_desc")
           )
           |> assign(:filters, %{})
           |> assign(:total_movies, 0)
           |> assign(:total_pages, 1)
           |> assign(:current_page, 1)
           |> assign(:page, 1)
           |> assign(:per_page, 50)
           |> put_flash(:error, "Unable to load movies")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Festival not found")
       |> push_navigate(to: ~p"/awards")}
    end
  end

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
        "winners" -> ~p"/awards/#{slug_or_id}/winners/legacy"
        "nominees" -> ~p"/awards/#{slug_or_id}/nominees/legacy"
        _ -> ~p"/awards/#{slug_or_id}/legacy"
      end

    query =
      (socket.assigns[:params] || %{})
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> URI.encode_query()

    path = if query == "", do: base_path, else: "#{base_path}?#{query}"

    {:noreply, push_navigate(socket, to: path)}
  end

  # Delegate all other events to the SearchEventHandlers macro
  @impl Phoenix.LiveView
  def handle_event(event, params, socket), do: super(event, params, socket)

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp determine_filter_mode(:winners), do: :winners
  defp determine_filter_mode(:nominees), do: :nominees
  defp determine_filter_mode(_), do: :all

  defp award_status_for_mode(:winners), do: "won"
  defp award_status_for_mode(:nominees), do: "nominated_only"
  defp award_status_for_mode(:all), do: "any_nomination"

  defp page_title(org, :winners), do: "#{org.name} - Winners"
  defp page_title(org, :nominees), do: "#{org.name} - Nominees"
  defp page_title(org, _), do: org.name

  # Helper for building pagination path (used in template)
  def build_pagination_path(assigns, page) do
    params = build_pagination_params(assigns, page)
    org = assigns.organization
    slug_or_id = org.slug || org.id

    case assigns.filter_mode do
      :winners -> ~p"/awards/#{slug_or_id}/winners/legacy?#{params}"
      :nominees -> ~p"/awards/#{slug_or_id}/nominees/legacy?#{params}"
      _ -> ~p"/awards/#{slug_or_id}/legacy?#{params}"
    end
  end

  # ============================================================================
  # SEO Helpers
  # ============================================================================

  defp assign_awards_page_seo(socket, organization, filter_mode, movies) do
    title = page_title(organization, filter_mode)
    description = awards_description(organization, filter_mode)
    path = awards_canonical_path(organization, filter_mode)

    socket
    |> assign(:page_title, title)
    |> assign(:meta_description, description)
    |> assign(:canonical_url, "#{@site_url}#{path}")
    |> assign(:og_title, title)
    |> assign(:og_description, description)
    |> assign(:og_type, "website")
    |> assign(:og_url, "#{@site_url}#{path}")
    |> maybe_assign_og_image(movies)
    |> assign(:json_ld, CinegraphWeb.SEO.item_list_schema(movies, title))
  end

  defp awards_description(org, :winners) do
    "Browse all #{org.name} award winners. Discover acclaimed films honored by #{org.name}."
  end

  defp awards_description(org, :nominees) do
    "Browse #{org.name} nominees. Explore films nominated for #{org.name} awards."
  end

  defp awards_description(org, _) do
    "Explore #{org.name} films, winners, and nominees. Discover award-winning cinema on Cinegraph."
  end

  defp awards_canonical_path(org, :winners), do: "/awards/#{org.slug || org.id}/winners"
  defp awards_canonical_path(org, :nominees), do: "/awards/#{org.slug || org.id}/nominees"
  defp awards_canonical_path(org, _), do: "/awards/#{org.slug || org.id}"

  defp maybe_assign_og_image(socket, [movie | _]) when not is_nil(movie.poster_path) do
    assign(socket, :og_image, "https://image.tmdb.org/t/p/w780#{movie.poster_path}")
  end

  defp maybe_assign_og_image(socket, _movies), do: socket

  # ============================================================================
  # Filter Helpers
  # ============================================================================

  defp normalize_filters(params) do
    %{
      genres: parse_array_param(params["genres"]),
      decade: params["decade"],
      people_ids: parse_array_param(params["people_ids"]),
      lists: parse_array_param(params["lists"])
    }
  end

  # Check if any filters are active (called from template)
  defp has_active_filters(filters) do
    has_active_filters?(filters, awards_view_filter_fields())
  end

  # Get list of active filters for display (called from template)
  defp get_active_filters(filters, assigns) do
    build_active_filters_list(filters, assigns, awards_view_filter_configs())
  end
end
