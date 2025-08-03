defmodule CinegraphWeb.MovieLive.Index do
  use CinegraphWeb, :live_view

  alias Cinegraph.Movies

  @impl true
  def mount(_params, _session, socket) do
    # Initialize with empty state - actual data loading happens in handle_params
    {:ok, 
     socket
     |> assign(:page, 1)
     |> assign(:per_page, 50)
     |> assign(:movies, [])
     |> assign(:total_movies, 0)
     |> assign(:total_pages, 0)
     |> assign(:sort, "release_date_desc")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, 
     socket
     |> assign_pagination_params(params)
     |> load_paginated_movies()
     |> apply_action(socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("change_sort", %{"sort" => sort}, socket) do
    params = %{
      "page" => "1",  # Reset to page 1 when changing sort
      "per_page" => to_string(socket.assigns.per_page),
      "sort" => sort
    }
    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  # Private functions
  defp assign_pagination_params(socket, params) do
    page = parse_int_param(params["page"], 1, [min: 1])
    per_page = parse_int_param(params["per_page"], 50, [min: 10, max: 100])
    sort = params["sort"] || "release_date_desc"
    
    socket
    |> assign(:page, page)
    |> assign(:per_page, per_page)
    |> assign(:sort, sort)
  end

  defp load_paginated_movies(socket) do
    %{page: page, per_page: per_page, sort: sort} = socket.assigns
    
    params = %{
      "page" => to_string(page),
      "per_page" => to_string(per_page),
      "sort" => sort
    }
    
    movies = Movies.list_movies(params)
    total_movies = Movies.count_movies(params)
    total_pages = ceil(total_movies / per_page)
    
    socket
    |> assign(:movies, movies)
    |> assign(:total_movies, total_movies)
    |> assign(:total_pages, max(total_pages, 1))
  end

  defp parse_int_param(param, default, opts) do
    min_val = Keyword.get(opts, :min, 1)
    max_val = Keyword.get(opts, :max, 999999)
    
    case Integer.parse(param || to_string(default)) do
      {num, _} when num >= min_val and num <= max_val -> num
      _ -> default
    end
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Movies Database")
  end

  # Pagination path builder
  def build_pagination_path(assigns, new_params \\ %{}) do
    current_params = %{
      "page" => to_string(assigns.page),
      "per_page" => to_string(assigns.per_page),
      "sort" => assigns.sort
    }
    
    params = 
      current_params
      |> Map.merge(new_params)
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()
    
    ~p"/movies?#{params}"
  end

  # Pagination helper
  def pagination_range(current_page, total_pages, opts \\ []) do
    max_links = Keyword.get(opts, :max_links, 7)
    
    cond do
      total_pages <= max_links ->
        1..total_pages |> Enum.to_list()
        
      current_page <= 3 ->
        [1, 2, 3, 4, "...", total_pages]
        
      current_page >= total_pages - 2 ->
        [1, "...", total_pages - 3, total_pages - 2, total_pages - 1, total_pages]
        
      true ->
        [1, "...", current_page - 1, current_page, current_page + 1, "...", total_pages]
    end
  end
end