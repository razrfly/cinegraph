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

  alias Cinegraph.Festivals
  alias Cinegraph.Movies.Search

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:movies, [])
     |> assign(:meta, %{})
     |> assign(:organization, nil)
     |> assign(:search_term, "")
     |> assign(:filter_mode, :all)
     |> assign(:sort_criteria, "release_date")
     |> assign(:sort_direction, :desc)}
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _url, socket) do
    organization = Festivals.get_organization_by_slug(slug)

    if organization do
      filter_mode = determine_filter_mode(socket.assigns.live_action)

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
           |> assign(:params, params)
           |> assign(:filter_mode, filter_mode)
           |> assign(:search_term, params["search"] || "")
           |> assign(:sort_criteria, extract_sort_criteria(params["sort"] || "release_date_desc"))
           |> assign(
             :sort_direction,
             extract_sort_direction(params["sort"] || "release_date_desc")
           )
           |> assign_pagination(meta)
           |> assign(:page_title, page_title(organization, filter_mode))}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(:organization, organization)
           |> assign(:movies, [])
           |> assign(:meta, %{})
           |> put_flash(:error, "Unable to load movies")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Festival not found")
       |> push_navigate(to: ~p"/awards")}
    end
  end

  defp determine_filter_mode(:winners), do: :winners
  defp determine_filter_mode(:nominees), do: :nominees
  defp determine_filter_mode(_), do: :all

  defp award_status_for_mode(:winners), do: "won"
  defp award_status_for_mode(:nominees), do: "nominated_only"
  defp award_status_for_mode(:all), do: "any_nomination"

  defp page_title(org, :winners), do: "#{org.name} - Winners"
  defp page_title(org, :nominees), do: "#{org.name} - Nominees"
  defp page_title(org, _), do: org.name

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    params = build_params(socket, %{"search" => search, "page" => "1"})
    path = build_path(socket, params)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("change_sort", %{"sort" => sort}, socket) do
    params = build_params(socket, %{"sort" => sort, "page" => "1"})
    path = build_path(socket, params)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("change_filter", %{"filter" => filter}, socket) do
    org = socket.assigns.organization

    base_path =
      case filter do
        "winners" -> ~p"/awards/#{org.slug}/winners"
        "nominees" -> ~p"/awards/#{org.slug}/nominees"
        _ -> ~p"/awards/#{org.slug}"
      end

    {:noreply, push_navigate(socket, to: base_path)}
  end

  @impl true
  def handle_event("page", %{"page" => page}, socket) do
    params = build_params(socket, %{"page" => page})
    path = build_path(socket, params)
    {:noreply, push_patch(socket, to: path)}
  end

  defp build_params(socket, updates) do
    socket.assigns.params
    |> Map.merge(updates)
    |> Map.delete("slug")
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  defp build_path(socket, params) do
    org = socket.assigns.organization

    case socket.assigns.filter_mode do
      :winners -> ~p"/awards/#{org.slug}/winners?#{params}"
      :nominees -> ~p"/awards/#{org.slug}/nominees?#{params}"
      _ -> ~p"/awards/#{org.slug}?#{params}"
    end
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

  # Helper for building pagination path (used in template)
  def build_pagination_path(assigns, page) do
    params = build_pagination_params(assigns, page)
    org = assigns.organization

    case assigns.filter_mode do
      :winners -> ~p"/awards/#{org.slug}/winners?#{params}"
      :nominees -> ~p"/awards/#{org.slug}/nominees?#{params}"
      _ -> ~p"/awards/#{org.slug}?#{params}"
    end
  end
end
