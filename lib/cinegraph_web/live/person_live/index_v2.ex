defmodule CinegraphWeb.PersonLive.IndexV2 do
  @moduledoc """
  V2 people discovery page.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.People
  @page_size 24
  @department_presets [
    {"all", "All"},
    {"acting", "Acting"},
    {"directing", "Directing"},
    {"writing", "Writing"},
    {"crew", "Crew"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    departments = People.get_departments()

    {:ok,
     socket
     |> assign(:page_title, "People")
     |> assign(:active_nav, "People")
     |> assign(:people, [])
     |> assign(:total_people, 0)
     |> assign(:total_pages, 1)
     |> assign(:page, 1)
     |> assign(:per_page, @page_size)
     |> assign(:params, %{})
     |> assign(:search, "")
     |> assign(:sort, "relevance_desc")
     |> assign(:include_adult, false)
     |> assign(:department_preset, "all")
     |> assign(:department_presets, @department_presets)
     |> assign(:departments, departments)
     |> assign(:birth_decades, People.get_birth_decades())
     |> assign(:nationalities, People.get_nationalities())
     |> assign(:show_drawer, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_integer(params["page"], 1, 1, nil)
    per_page = parse_integer(params["per_page"], @page_size, 1, 100)
    search = params["search"] || ""
    sort = params["sort"] || "relevance_desc"
    include_adult = truthy?(params["include_adult"])
    department_preset = normalize_department_preset(params["department_preset"])
    {sort_by, sort_order} = parse_sort(sort)

    filter_params =
      params
      |> Map.merge(%{
        "page" => to_string(page),
        "per_page" => to_string(per_page),
        "search" => search,
        "sort_by" => sort_by,
        "sort_order" => sort_order,
        "include_adult" => include_adult,
        "departments" =>
          departments_for_params(params, department_preset, socket.assigns.departments),
        "genders" => parse_list(params["genders"]),
        "status" => parse_list(params["status"]),
        "age_min" => params["age_min"] || "",
        "age_max" => params["age_max"] || "",
        "birth_decade" => params["birth_decade"] || "",
        "nationality" => params["nationality"] || ""
      })

    people = People.list_people_for_index(filter_params)
    total_people = People.count_people(filter_params)
    total_pages = total_pages(total_people, per_page)

    {:noreply,
     socket
     |> assign(:people, people)
     |> assign(:total_people, total_people)
     |> assign(:total_pages, total_pages)
     |> assign(:page, page)
     |> assign(:per_page, per_page)
     |> assign(:params, normalize_params(params, department_preset))
     |> assign(:search, search)
     |> assign(:sort, sort)
     |> assign(:include_adult, include_adult)
     |> assign(:department_preset, department_preset)
     |> assign(:page_title, page_title(search))}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query =
      socket.assigns.params
      |> Map.merge(clean_form_params(params))
      |> Map.put("page", "1")
      |> compact_params()

    {:noreply, push_patch(socket, to: ~p"/people?#{query}")}
  end

  @impl true
  def handle_event("page", %{"page" => page}, socket) do
    query =
      socket.assigns.params
      |> Map.put("page", page)
      |> compact_params()

    {:noreply, push_patch(socket, to: ~p"/people?#{query}")}
  end

  @impl true
  def handle_event("remove_filter", %{"key" => key}, socket) do
    query =
      socket.assigns.params
      |> Map.delete(key)
      |> maybe_reset_department_preset(key)
      |> Map.put("page", "1")
      |> compact_params()

    {:noreply, push_patch(socket, to: ~p"/people?#{query}")}
  end

  @impl true
  def handle_event("toggle_drawer", _params, socket),
    do: {:noreply, assign(socket, :show_drawer, !socket.assigns.show_drawer)}

  @impl true
  def handle_event("hide_drawer", _params, socket),
    do: {:noreply, assign(socket, :show_drawer, false)}

  defp total_pages(0, _per_page), do: 1
  defp total_pages(total, per_page), do: ceil(total / per_page)

  defp normalize_params(params, department_preset) do
    params
    |> Map.put_new("sort", "relevance_desc")
    |> maybe_put_department_preset(department_preset)
    |> compact_params()
  end

  defp maybe_put_department_preset(params, "all"), do: Map.delete(params, "department_preset")

  defp maybe_put_department_preset(params, preset),
    do: Map.put(params, "department_preset", preset)

  defp clean_form_params(params) do
    params
    |> Map.drop(["_target"])
    |> normalize_list_field("genders")
    |> normalize_list_field("status")
    |> normalize_list_field("departments")
  end

  defp normalize_list_field(params, key) do
    case Map.get(params, key) do
      nil -> params
      list when is_list(list) -> Map.put(params, key, Enum.reject(list, &(&1 == "")))
      value -> Map.put(params, key, value)
    end
  end

  defp compact_params(params) do
    params
    |> Enum.reject(fn
      {_key, value} when value in [nil, "", [], "all"] -> true
      {"sort", "relevance_desc"} -> true
      {"include_adult", value} when value in [false, "false", "0", 0, "off"] -> true
      {"page", "1"} -> true
      {"per_page", value} -> value in [nil, "", to_string(@page_size)]
      {_key, _value} -> false
    end)
    |> Map.new()
  end

  defp maybe_reset_department_preset(params, "department_preset"),
    do: Map.delete(params, "departments")

  defp maybe_reset_department_preset(params, "departments"),
    do: Map.delete(params, "department_preset")

  defp maybe_reset_department_preset(params, _key), do: params

  def department_preset_path(params, preset) do
    query =
      params
      |> Map.put("department_preset", preset)
      |> Map.delete("departments")
      |> Map.put("page", "1")
      |> compact_params()

    if query == %{} do
      ~p"/people"
    else
      ~p"/people?#{query}"
    end
  end

  defp departments_for_params(_params, "acting", _departments), do: ["Acting"]
  defp departments_for_params(_params, "directing", _departments), do: ["Directing"]
  defp departments_for_params(_params, "writing", _departments), do: ["Writing"]

  defp departments_for_params(_params, "crew", departments) do
    Enum.reject(departments, &(&1 in ["Acting", "Directing", "Writing"]))
  end

  defp departments_for_params(params, _preset, _departments),
    do: parse_list(params["departments"])

  defp normalize_department_preset(preset) when preset in ~w(all acting directing writing crew),
    do: preset

  defp normalize_department_preset(_preset), do: "all"

  defp parse_sort(sort_string) do
    case sort_string do
      "relevance_desc" -> {"relevance", "desc"}
      "relevance" -> {"relevance", "desc"}
      "name" -> {"name", "asc"}
      "name_desc" -> {"name", "desc"}
      "popularity_desc" -> {"popularity", "desc"}
      "popularity" -> {"popularity", "desc"}
      "birthday" -> {"birthday", "asc"}
      "birthday_desc" -> {"birthday", "desc"}
      "recently_added" -> {"recently_added", "desc"}
      "movie_count" -> {"movie_count", "desc"}
      "movie_count_desc" -> {"movie_count", "desc"}
      _ -> {"relevance", "desc"}
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_), do: false

  defp parse_integer(value, default, min, max) do
    case Integer.parse(value || to_string(default)) do
      {num, _} ->
        num = if min, do: max(num, min), else: num
        if max, do: min(num, max), else: num

      _ ->
        default
    end
  end

  defp parse_list(nil), do: []
  defp parse_list(""), do: []

  defp parse_list(value) when is_list(value),
    do: value |> List.flatten() |> Enum.reject(&(&1 == ""))

  defp parse_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp page_title(""), do: "People"
  defp page_title(search), do: "People - Search: #{search}"

  def profile_url(%{profile_path: nil}), do: nil
  def profile_url(%{profile_path: path}), do: "https://image.tmdb.org/t/p/w342#{path}"

  def person_path(%{slug: slug}) when is_binary(slug) and slug != "", do: ~p"/people/#{slug}"
  def person_path(%{id: id}), do: ~p"/people/#{id}"

  def short_place(nil), do: nil
  def short_place(""), do: nil

  def short_place(place) do
    place
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(-2)
    |> Enum.join(", ")
  end

  def active_filters(assigns) do
    keys = [
      {"search", "Search"},
      {"departments", "Department"},
      {"genders", "Gender"},
      {"status", "Status"},
      {"age_min", "Min age"},
      {"age_max", "Max age"},
      {"birth_decade", "Birth decade"},
      {"nationality", "Birthplace"},
      {"include_adult", "Adult people"}
    ]

    preset_filters =
      if assigns.department_preset != "all" do
        [{"department_preset", "Department", String.capitalize(assigns.department_preset)}]
      else
        []
      end

    param_filters =
      for {key, label} <- keys,
          value = Map.get(assigns.params, key),
          value not in [nil, "", []] do
        {key, label, filter_value(value)}
      end

    preset_filters ++ param_filters
  end

  defp filter_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp filter_value(true), do: "Included"
  defp filter_value("true"), do: "Included"
  defp filter_value(value), do: to_string(value)

  def selected_values(params, key) do
    case Map.get(params, key) do
      nil -> []
      value when is_list(value) -> value
      value when is_binary(value) -> String.split(value, ",", trim: true)
    end
  end

  def format_count(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_count(number), do: number |> to_string()

  def format_score(nil), do: nil

  def format_score(score) when is_float(score),
    do: score |> Float.round(1) |> :erlang.float_to_binary(decimals: 1)

  def format_score(score) when is_integer(score), do: "#{score}.0"
end
