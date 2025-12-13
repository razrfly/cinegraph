defmodule CinegraphWeb.ListLive.Show do
  @moduledoc """
  LiveView for displaying movies from a specific curated list.
  Provides a clean URL at /lists/:slug while reusing the movie search infrastructure.
  """
  use CinegraphWeb, :live_view
  use CinegraphWeb.SearchEventHandlers

  alias Cinegraph.Lists.ListSlugs
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
      list_view_filter_configs: 0,
      list_view_filter_fields: 0
    ]

  @site_url "https://cinegraph.io"

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
     |> assign(:sort_criteria, "release_date")
     |> assign(:sort_direction, :desc)
     |> assign(:show_filters, false)
     |> assign(:filters, %{})
     # Filter options for dropdowns
     |> assign(:available_genres, filter_options.genres)
     |> assign(:available_decades, filter_options.decades)
     |> assign(:festival_organizations, filter_options.festivals)
     # Person search options
     |> assign(:person_options, [])}
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _url, socket) do
    case ListSlugs.get_by_slug(slug) do
      {:ok, list_info} ->
        # Merge the list filter with any additional query params
        search_params =
          params
          |> Map.put("lists", list_info.key)
          |> Map.delete("slug")

        case Search.search_movies(search_params) do
          {:ok, {movies, meta}} ->
            {:noreply,
             socket
             |> assign(:list_info, list_info)
             |> assign(:movies, movies)
             |> assign(:meta, meta)
             |> assign(:params, params)
             |> assign(:search_term, params["search"] || "")
             |> assign(:filters, normalize_filters(params))
             |> assign(
               :sort_criteria,
               extract_sort_criteria(params["sort"] || "release_date_desc")
             )
             |> assign(
               :sort_direction,
               extract_sort_direction(params["sort"] || "release_date_desc")
             )
             |> assign_pagination(meta)
             |> assign(:list_slug, list_info.slug)
             |> assign_list_page_seo(list_info, movies)}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(:list_info, list_info)
             |> assign(:movies, [])
             |> assign(:meta, %{})
             |> assign(:params, params)
             |> assign(:filters, %{})
             |> put_flash(:error, "Unable to load movies")}
        end

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "List not found")
         |> push_navigate(to: ~p"/lists")}
    end
  end

  # ============================================================================
  # SEO Helpers
  # ============================================================================

  defp assign_list_page_seo(socket, list_info, movies) do
    description = list_info.description || "Browse #{list_info.name} on Cinegraph"

    socket
    |> assign(:page_title, list_info.name)
    |> assign(:meta_description, truncate_text(description, 160))
    |> assign(:canonical_url, "#{@site_url}/lists/#{list_info.slug}")
    |> assign(:og_title, list_info.name)
    |> assign(:og_description, truncate_text(description, 200))
    |> assign(:og_type, "website")
    |> assign(:og_url, "#{@site_url}/lists/#{list_info.slug}")
    |> maybe_assign_og_image(movies)
    |> assign(:json_ld, CinegraphWeb.SEO.item_list_schema(movies, list_info.name))
  end

  defp maybe_assign_og_image(socket, [movie | _]) when not is_nil(movie.poster_path) do
    assign(socket, :og_image, "https://image.tmdb.org/t/p/w780#{movie.poster_path}")
  end

  defp maybe_assign_og_image(socket, _movies), do: socket

  defp truncate_text(nil, _length), do: nil

  defp truncate_text(text, length) when is_binary(text) do
    if String.length(text) > length do
      text |> String.slice(0, length - 3) |> String.trim_trailing() |> Kernel.<>("...")
    else
      text
    end
  end

  # ============================================================================
  # Filter Helpers
  # ============================================================================

  defp normalize_filters(params) do
    %{
      genres: parse_array_param(params["genres"]),
      decade: params["decade"],
      people_ids: parse_array_param(params["people_ids"]),
      festivals: parse_array_param(params["festivals"])
    }
  end

  # Check if any filters are active (called from template)
  defp has_active_filters(filters) do
    has_active_filters?(filters, list_view_filter_fields())
  end

  # Get list of active filters for display (called from template)
  defp get_active_filters(filters, assigns) do
    build_active_filters_list(filters, assigns, list_view_filter_configs())
  end
end
