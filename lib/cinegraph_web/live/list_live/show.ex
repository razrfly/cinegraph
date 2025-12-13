defmodule CinegraphWeb.ListLive.Show do
  @moduledoc """
  LiveView for displaying movies from a specific curated list.
  Provides a clean URL at /lists/:slug while reusing the movie search infrastructure.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Lists.ListSlugs
  alias Cinegraph.Movies.Search

  @site_url "https://cinegraph.io"

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

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    params = build_params(socket, %{"search" => search, "page" => "1"})
    {:noreply, push_patch(socket, to: ~p"/lists/#{socket.assigns.list_info.slug}?#{params}")}
  end

  @impl true
  def handle_event("change_sort", %{"sort" => sort}, socket) do
    params = build_params(socket, %{"sort" => sort, "page" => "1"})
    {:noreply, push_patch(socket, to: ~p"/lists/#{socket.assigns.list_info.slug}?#{params}")}
  end

  @impl true
  def handle_event("page", %{"page" => page}, socket) do
    params = build_params(socket, %{"page" => page})
    {:noreply, push_patch(socket, to: ~p"/lists/#{socket.assigns.list_info.slug}?#{params}")}
  end

  @impl true
  def handle_event("toggle_filters", _params, socket) do
    {:noreply, assign(socket, :show_filters, !socket.assigns.show_filters)}
  end

  @impl true
  def handle_event("apply_filters", %{"filters" => filters}, socket) do
    # Clean up filters to handle empty arrays from hidden fields
    cleaned_filters =
      filters
      |> Enum.map(fn
        {key, [""]} -> {key, []}
        {key, value} when is_list(value) -> {key, Enum.reject(value, &(&1 == "" || &1 == nil))}
        other -> other
      end)
      |> Map.new()

    params =
      socket.assigns.params
      |> Map.merge(cleaned_filters)
      |> Map.put("page", "1")
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" or v == [] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/lists/#{socket.assigns.list_info.slug}?#{params}")}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    # Keep only search and sort, reset filters
    params =
      socket.assigns.params
      |> Map.take(["search", "sort"])
      |> Map.put("page", "1")
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/lists/#{socket.assigns.list_info.slug}?#{params}")}
  end

  @impl true
  def handle_event("remove_filter", %{"filter" => filter_key}, socket) do
    params =
      socket.assigns.params
      |> Map.delete(filter_key)
      |> Map.put("page", "1")

    {:noreply, push_patch(socket, to: ~p"/lists/#{socket.assigns.list_info.slug}?#{params}")}
  end

  # Handle autocomplete search for people
  @impl true
  def handle_info({:search_people_autocomplete, component_id, query}, socket) do
    results = Search.search_people(query, 10)

    # Update component with results and cache them
    send_update(CinegraphWeb.Components.PersonAutocomplete,
      id: component_id,
      search_results: results,
      searching: false,
      cache_query: query,
      cache_timestamp: DateTime.utc_now()
    )

    {:noreply, socket}
  end

  # Handle people selection updates from autocomplete component
  @impl true
  def handle_info({:people_selected, _component_id, selected_people}, socket) do
    # Update the filters with the new people selection
    people_ids = Enum.map_join(selected_people, ",", & &1.id)

    params =
      if people_ids == "" do
        Map.delete(socket.assigns.params, "people_ids")
      else
        Map.put(socket.assigns.params, "people_ids", people_ids)
      end
      |> Map.put("page", "1")

    {:noreply, push_patch(socket, to: ~p"/lists/#{socket.assigns.list_info.slug}?#{params}")}
  end

  defp build_params(socket, updates) do
    socket.assigns.params
    |> Map.merge(updates)
    |> Map.delete("slug")
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  defp assign_pagination(socket, meta) do
    socket
    |> assign(:total_movies, meta.total_count || 0)
    |> assign(:total_pages, meta.total_pages || 1)
    |> assign(:current_page, meta.current_page || 1)
    |> assign(:page, meta.current_page || 1)
    |> assign(:per_page, meta.page_size || 50)
  end

  defp extract_sort_criteria(sort_string) do
    sort_string
    |> String.replace(~r/_(asc|desc)$/, "")
  end

  defp extract_sort_direction(sort_string) do
    if String.ends_with?(sort_string, "_asc"), do: :asc, else: :desc
  end

  # Helper for pagination range (used in template)
  def pagination_range(_current_page, total_pages) when total_pages <= 7 do
    1..max(total_pages, 1) |> Enum.to_list()
  end

  def pagination_range(current_page, total_pages) do
    cond do
      current_page <= 3 ->
        [1, 2, 3, 4, "...", total_pages]

      current_page >= total_pages - 2 ->
        [1, "...", total_pages - 3, total_pages - 2, total_pages - 1, total_pages]

      true ->
        [1, "...", current_page - 1, current_page, current_page + 1, "...", total_pages]
    end
  end

  # Helper for building pagination params (used in template)
  def build_pagination_params(assigns, page) do
    assigns.params
    |> Map.put("page", to_string(page))
    |> Map.delete("slug")
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  # SEO helper for list pages
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

  # Filter helpers
  defp normalize_filters(params) do
    %{
      genres: parse_array_param(params["genres"]),
      decade: params["decade"],
      people_ids: parse_array_param(params["people_ids"])
    }
  end

  defp parse_array_param(nil), do: []
  defp parse_array_param([]), do: []
  defp parse_array_param(value) when is_list(value), do: value
  defp parse_array_param(value) when is_binary(value), do: String.split(value, ",", trim: true)

  # Check if any filters are active
  def has_active_filters(filters) do
    (filters.genres != [] and filters.genres != nil) or
      (filters.decade != nil and filters.decade != "") or
      (filters.people_ids != [] and filters.people_ids != nil)
  end

  # Get list of active filters for display
  def get_active_filters(filters, assigns) do
    []
    |> maybe_add_genre_filter(filters, assigns)
    |> maybe_add_decade_filter(filters)
    |> maybe_add_people_filter(filters)
  end

  defp maybe_add_genre_filter(acc, %{genres: genres}, assigns)
       when genres != [] and genres != nil do
    genre_names =
      genres
      |> Enum.map(fn id ->
        id_int = if is_binary(id), do: String.to_integer(id), else: id
        genre = Enum.find(assigns.available_genres, &(&1.id == id_int))
        if genre, do: genre.name, else: to_string(id)
      end)
      |> Enum.join(", ")

    display =
      if String.length(genre_names) > 25,
        do: String.slice(genre_names, 0..22) <> "...",
        else: genre_names

    acc ++ [%{key: "genres", label: "Genres", display_value: display}]
  end

  defp maybe_add_genre_filter(acc, _, _), do: acc

  defp maybe_add_decade_filter(acc, %{decade: decade}) when decade != nil and decade != "" do
    acc ++ [%{key: "decade", label: "Decade", display_value: "#{decade}s"}]
  end

  defp maybe_add_decade_filter(acc, _), do: acc

  defp maybe_add_people_filter(acc, %{people_ids: people_ids})
       when people_ids != [] and people_ids != nil do
    count = length(people_ids)
    display = if count == 1, do: "1 person", else: "#{count} people"
    acc ++ [%{key: "people_ids", label: "People", display_value: display}]
  end

  defp maybe_add_people_filter(acc, _), do: acc
end
