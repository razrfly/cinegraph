defmodule CinegraphWeb.ListLive.Show do
  @moduledoc """
  LiveView for displaying movies from a specific curated list.
  Provides a clean URL at /lists/:slug while reusing the movie search infrastructure.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Lists.ListSlugs
  alias Cinegraph.Movies.Search

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:movies, [])
     |> assign(:meta, %{})
     |> assign(:list_info, nil)
     |> assign(:search_term, "")
     |> assign(:sort_criteria, "release_date")
     |> assign(:sort_direction, :desc)}
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
             |> assign(
               :sort_criteria,
               extract_sort_criteria(params["sort"] || "release_date_desc")
             )
             |> assign(
               :sort_direction,
               extract_sort_direction(params["sort"] || "release_date_desc")
             )
             |> assign_pagination(meta)
             |> assign(:page_title, list_info.name)}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(:list_info, list_info)
             |> assign(:movies, [])
             |> assign(:meta, %{})
             |> assign(:params, params)
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
end
