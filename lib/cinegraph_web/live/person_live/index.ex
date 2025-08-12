defmodule CinegraphWeb.PersonLive.Index do
  use CinegraphWeb, :live_view

  alias Cinegraph.People

  @impl true
  def mount(_params, _session, socket) do
    # Get filter options
    departments = People.get_departments()
    birth_decades = People.get_birth_decades()
    nationalities = People.get_nationalities()

    {:ok,
     socket
     |> assign(:page, 1)
     |> assign(:per_page, 20)
     |> assign(:people, [])
     |> assign(:total_people, 0)
     |> assign(:search, "")
     |> assign(:search_timer, nil)
     |> assign(:sort, "movie_count_desc")
     |> assign(:departments, departments)
     |> assign(:selected_departments, [])
     |> assign(:genders, [
       %{value: "1", label: "Female"},
       %{value: "2", label: "Male"},
       %{value: "3", label: "Non-binary"}
     ])
     |> assign(:selected_genders, [])
     |> assign(:age_min, "")
     |> assign(:age_max, "")
     |> assign(:birth_decade, "")
     |> assign(:birth_decades, birth_decades)
     |> assign(:status_filters, [
       %{value: "living", label: "Living"},
       %{value: "deceased", label: "Deceased"},
       %{value: "has_biography", label: "Has Biography"},
       %{value: "has_image", label: "Has Image"}
     ])
     |> assign(:selected_status, [])
     |> assign(:nationality, "")
     |> assign(:nationalities, nationalities)
     |> assign(:show_filters, false)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Parse all parameters
    page = parse_integer(params["page"], 1, 1, nil)
    per_page = parse_integer(params["per_page"], 20, 1, 100)

    search = params["search"] || ""
    sort = params["sort"] || "movie_count_desc"

    # Parse sort into sort_by and sort_order for backward compatibility
    {sort_by, sort_order} = parse_sort(sort)

    departments = parse_list(params["departments"])
    genders = parse_list(params["genders"])
    age_min = params["age_min"] || ""
    age_max = params["age_max"] || ""
    birth_decade = params["birth_decade"] || ""
    status_filters = parse_list(params["status"])
    nationality = params["nationality"] || ""

    # Build filter params
    filter_params = %{
      "page" => to_string(page),
      "per_page" => to_string(per_page),
      "search" => search,
      "sort_by" => sort_by,
      "sort_order" => sort_order,
      "departments" => departments,
      "genders" => genders,
      "age_min" => age_min,
      "age_max" => age_max,
      "birth_decade" => birth_decade,
      "status" => status_filters,
      "nationality" => nationality
    }

    # Get filtered results
    people = People.list_people(filter_params)
    total_people = People.count_people(filter_params)
    total_pages = ceil(total_people / per_page)

    socket =
      socket
      |> assign(:page, page)
      |> assign(:per_page, per_page)
      |> assign(:people, people)
      |> assign(:total_people, total_people)
      |> assign(:total_pages, total_pages)
      |> assign(:search, search)
      |> assign(:sort, sort)
      |> assign(:selected_departments, departments)
      |> assign(:selected_genders, genders)
      |> assign(:age_min, age_min)
      |> assign(:age_max, age_max)
      |> assign(:birth_decade, birth_decade)
      |> assign(:selected_status, status_filters)
      |> assign(:nationality, nationality)
      |> assign(:page_title, page_title(filter_params))
      |> assign(:person, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    # Cancel any existing timer
    if socket.assigns.search_timer do
      Process.cancel_timer(socket.assigns.search_timer)
    end

    # Set a new debounced timer
    timer = Process.send_after(self(), {:perform_search, search}, 300)

    {:noreply, assign(socket, search: search, search_timer: timer)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    current_params = build_current_params(socket.assigns)
    new_params = Map.merge(current_params, params) |> Map.put("page", "1")

    {:noreply, push_patch(socket, to: ~p"/people?#{new_params}")}
  end

  @impl true
  def handle_event("change_sort", %{"sort" => sort}, socket) do
    current_params = build_current_params(socket.assigns)
    new_params = Map.merge(current_params, %{"sort" => sort, "page" => "1"})

    {:noreply, push_patch(socket, to: ~p"/people?#{new_params}")}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/people")}
  end

  @impl true
  def handle_event("toggle_filters", _params, socket) do
    {:noreply, assign(socket, :show_filters, !socket.assigns.show_filters)}
  end

  @impl true
  def handle_info({:perform_search, search}, socket) do
    current_params = build_current_params(socket.assigns)
    new_params = Map.merge(current_params, %{"search" => search, "page" => "1"})

    {:noreply, push_patch(socket, to: ~p"/people?#{new_params}")}
  end

  # Helper functions
  defp parse_sort(sort_string) do
    case sort_string do
      "name" -> {"name", "asc"}
      "name_desc" -> {"name", "desc"}
      "popularity" -> {"popularity", "desc"}
      "popularity_desc" -> {"popularity", "desc"}
      "birthday" -> {"birthday", "asc"}
      "birthday_desc" -> {"birthday", "desc"}
      "recently_added" -> {"recently_added", "desc"}
      "movie_count" -> {"movie_count", "desc"}
      "movie_count_desc" -> {"movie_count", "desc"}
      _ -> {"movie_count", "desc"}
    end
  end

  defp parse_integer(value, default, min, max) do
    case Integer.parse(value || to_string(default)) do
      {num, _} ->
        num = if min, do: max(num, min), else: num
        num = if max, do: min(num, max), else: num
        num

      _ ->
        default
    end
  end

  defp parse_list(nil), do: []
  defp parse_list(""), do: []

  defp parse_list(value) when is_binary(value) do
    String.split(value, ",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_list(value) when is_list(value), do: value

  defp page_title(params) do
    filters = []

    filters =
      if params["search"] && params["search"] != "",
        do: ["Search: \"#{params["search"]}\"" | filters],
        else: filters

    filters =
      if params["departments"] && params["departments"] != [],
        do: ["Departments" | filters],
        else: filters

    filters =
      if params["genders"] && params["genders"] != [], do: ["Gender" | filters], else: filters

    filters =
      if params["status"] && params["status"] != [], do: ["Status" | filters], else: filters

    if filters != [] do
      "People - " <> Enum.join(filters, ", ")
    else
      "People"
    end
  end

  # Helper function for pagination range
  def pagination_range(_current_page, total_pages) when total_pages <= 7 do
    1..total_pages |> Enum.to_list()
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

  # Helper function to build current params for pagination (used in templates)
  # Public function that accepts a map of parameters (assigns)
  def build_current_params(params) when is_map(params) do
    %{
      "search" => Map.get(params, :search, ""),
      "sort" => Map.get(params, :sort, "movie_count_desc"),
      "departments" => params |> Map.get(:selected_departments, []) |> Enum.join(","),
      "genders" => params |> Map.get(:selected_genders, []) |> Enum.join(","),
      "age_min" => Map.get(params, :age_min, ""),
      "age_max" => Map.get(params, :age_max, ""),
      "birth_decade" => Map.get(params, :birth_decade, ""),
      "status" => params |> Map.get(:selected_status, []) |> Enum.join(","),
      "nationality" => Map.get(params, :nationality, "")
    }
    |> Enum.reject(fn {_k, v} -> v == "" end)
    |> Map.new()
  end
end
