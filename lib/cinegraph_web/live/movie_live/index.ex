defmodule CinegraphWeb.MovieLive.Index do
  use CinegraphWeb, :live_view

  require Logger

  alias Cinegraph.Movies.Search
  alias CinegraphWeb.MovieLive.AdvancedFilters

  import CinegraphWeb.LiveViewHelpers,
    only: [
      extract_sort_criteria: 1,
      extract_sort_direction: 1,
      build_sort_param: 2,
      assign_pagination: 2,
      parse_array_param: 1,
      clean_filter_params: 1
    ]

  import CinegraphWeb.FilterHelpers,
    only: [
      filter_value_present?: 1
    ]

  @impl true
  def mount(_params, _session, socket) do
    # Get filter options from the Search module
    filter_options = Search.get_filter_options()

    {:ok,
     socket
     |> assign(:movies, [])
     |> assign(:meta, %{})
     |> assign(:params, %{})
     |> assign(:filters, %{})
     |> assign(:search_term, "")
     |> assign(:sort_criteria, "release_date")
     |> assign(:sort_direction, :desc)
     |> assign(:show_filters, false)
     |> assign(:show_advanced_filters, false)
     # Map filter options to expected template names
     |> assign(:available_genres, filter_options.genres)
     |> assign(:available_countries, filter_options.countries)
     |> assign(:available_languages, filter_options.languages)
     |> assign(:available_lists, filter_options.lists)
     |> assign(:available_decades, filter_options.decades)
     |> assign(:festival_organizations, filter_options.festivals)
     |> assign(:director_options, [])
     |> assign(:actor_options, [])
     |> assign(:person_options, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Ensure filter options are always available
    socket = ensure_filter_options(socket)

    case Search.search_movies(params) do
      {:ok, {movies, meta}} ->
        {:noreply,
         socket
         |> assign(:movies, movies)
         |> assign(:meta, meta)
         |> assign(:params, params)
         |> assign(:filters, normalize_filters_for_template(params))
         |> assign(:search_term, params["search"] || "")
         |> assign(:sort_criteria, extract_sort_criteria(params["sort"] || "release_date_desc"))
         |> assign(:sort_direction, extract_sort_direction(params["sort"] || "release_date_desc"))
         |> assign_pagination(meta)
         |> apply_action(socket.assigns.live_action, params)}

      {:error, _changeset} ->
        # If params are invalid, try with empty params to show default results
        case Search.search_movies(%{}) do
          {:ok, {movies, meta}} ->
            {:noreply,
             socket
             |> assign(:movies, movies)
             |> assign(:meta, meta)
             |> assign(:params, %{})
             |> assign(:filters, %{})
             |> assign(:search_term, "")
             |> assign(:sort_criteria, "release_date")
             |> assign(:sort_direction, :desc)
             |> assign_pagination(meta)
             |> put_flash(:error, "Invalid search parameters, showing all movies")
             |> apply_action(socket.assigns.live_action, params)}

          {:error, _} ->
            # Fallback to empty state
            {:noreply,
             socket
             |> assign(:movies, [])
             |> assign(:meta, %{})
             |> assign(:params, %{})
             |> assign(:filters, %{})
             |> assign(:search_term, "")
             |> assign(:sort_criteria, "release_date")
             |> assign(:sort_direction, :desc)
             |> assign(:total_movies, 0)
             |> assign(:total_pages, 1)
             |> assign(:current_page, 1)
             |> put_flash(:error, "Unable to load movies")
             |> apply_action(socket.assigns.live_action, params)}
        end
    end
  end

  @impl true
  def handle_event("change_sort", %{"sort" => sort}, socket) do
    params =
      socket.assigns.params
      |> Map.put("sort", sort)
      |> Map.put("page", "1")

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("sort_criteria_changed", %{"criteria" => criteria}, socket) do
    current_criteria = socket.assigns.sort_criteria

    # When changing to a different criteria, default to descending
    # This is more intuitive for most metrics (highest first)
    direction =
      if criteria != current_criteria do
        :desc
      else
        socket.assigns.sort_direction
      end

    sort = build_sort_param(criteria, direction)

    params =
      socket.assigns.params
      |> Map.put("sort", sort)
      |> Map.put("page", "1")

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("toggle_sort_direction", _params, socket) do
    new_direction = if socket.assigns.sort_direction == :desc, do: :asc, else: :desc
    sort = build_sort_param(socket.assigns.sort_criteria, new_direction)

    params =
      socket.assigns.params
      |> Map.put("sort", sort)
      |> Map.put("page", "1")

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("toggle_filters", _params, socket) do
    {:noreply, assign(socket, :show_filters, !socket.assigns.show_filters)}
  end

  @impl true
  def handle_event("toggle_advanced_filters", _params, socket) do
    {:noreply, assign(socket, :show_advanced_filters, !socket.assigns.show_advanced_filters)}
  end

  @impl true
  def handle_event("search", %{"search" => search_term}, socket) do
    params =
      socket.assigns.params
      |> Map.put("search", search_term)
      |> Map.put("page", "1")

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("apply_filters", %{"filters" => filters}, socket) do
    cleaned_filters = clean_filter_params(filters)

    params =
      socket.assigns.params
      |> Map.merge(cleaned_filters)
      |> Map.put("page", "1")
      |> clean_filter_params()

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("clear_all_filters", _params, socket) do
    params = %{"page" => "1"}
    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    params = %{"page" => "1"}
    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("remove_filter", %{"filter" => filter_key, "filter-type" => _type}, socket) do
    # Remove the specific filter from params
    params =
      socket.assigns.params
      |> Map.delete(filter_key)
      |> Map.put("page", "1")

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  # Ensure filter options are always present in socket assigns
  defp ensure_filter_options(socket) do
    # Check if filter options are already loaded
    if Map.has_key?(socket.assigns, :available_genres) do
      socket
    else
      # Reload filter options if missing
      filter_options = Search.get_filter_options()

      socket
      |> assign(:available_genres, filter_options.genres)
      |> assign(:available_countries, filter_options.countries)
      |> assign(:available_languages, filter_options.languages)
      |> assign(:available_lists, filter_options.lists)
      |> assign(:available_decades, filter_options.decades)
      |> assign(:festival_organizations, filter_options.festivals)
      |> assign(:director_options, [])
      |> assign(:actor_options, [])
      |> assign(:person_options, [])
    end
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
      socket.assigns.params
      |> Map.put("people_ids", people_ids)
      |> Map.put("page", "1")

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  # Private functions

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Movies Database")
  end

  # Convert URL params to the format the template expects
  defp normalize_filters_for_template(params) do
    %{
      genres: parse_array_param(params["genres"]),
      countries: parse_array_param(params["countries"]),
      languages: parse_array_param(params["languages"]),
      lists: parse_array_param(params["lists"]),
      festivals: parse_array_param(params["festivals"]),
      year_from: params["year_from"],
      year_to: params["year_to"],
      decade: params["decade"],
      runtime_min: params["runtime_min"],
      runtime_max: params["runtime_max"],
      rating_min: params["rating_min"],
      show_unreleased: params["show_unreleased"],
      # Basic filters (moved from advanced)
      rating_preset: params["rating_preset"],
      # Advanced filters
      award_status: params["award_status"],
      award_category_id: params["award_category_id"],
      award_year_from: params["award_year_from"],
      award_year_to: params["award_year_to"],
      discovery_preset: params["discovery_preset"],
      award_preset: params["award_preset"],
      # People search handled specially
      people_search: parse_people_search(params)
    }
  end

  defp parse_people_search(params) do
    cond do
      params["people_ids"] not in [nil, ""] ->
        %{"people_ids" => params["people_ids"]}

      params["people_search[people_ids]"] not in [nil, ""] ->
        %{"people_ids" => params["people_search[people_ids]"]}

      true ->
        nil
    end
  end

  # Helper functions for building URLs and pagination
  def build_pagination_path(params_or_assigns, new_params \\ %{}) do
    # Extract only the URL params from assigns if full assigns are passed
    params =
      case params_or_assigns do
        %{params: url_params} when is_map(url_params) -> url_params
        %{} = map -> extract_url_params(map)
        _ -> %{}
      end

    params
    |> Map.merge(new_params)
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" or v == [] end)
    |> Map.new()
    |> then(&~p"/movies?#{&1}")
  end

  # Extract only URL-safe parameters from assigns
  defp extract_url_params(assigns) do
    url_param_keys = [
      "search",
      "sort",
      "page",
      "per_page",
      "genres",
      "countries",
      "languages",
      "lists",
      "festivals",
      "year",
      "year_from",
      "year_to",
      "decade",
      "show_unreleased",
      "runtime_min",
      "runtime_max",
      "rating_min",
      "award_status",
      "festival_id",
      "award_category_id",
      "award_year_from",
      "award_year_to",
      "rating_preset",
      "discovery_preset",
      "award_preset",
      "people_ids",
      "people_role"
    ]

    case Map.get(assigns, :params) do
      params when is_map(params) ->
        Map.take(params, url_param_keys)

      _ ->
        Map.take(assigns, url_param_keys)
    end
  end

  # Helper functions for display
  defp to_percentage(nil), do: 0
  defp to_percentage(%Decimal{} = decimal), do: Float.round(Decimal.to_float(decimal) * 100, 0)
  defp to_percentage(float) when is_float(float), do: Float.round(float * 100, 0)
  defp to_percentage(int) when is_integer(int), do: int

  defp has_meaningful_score?(nil), do: false
  defp has_meaningful_score?(%Decimal{} = decimal), do: Decimal.gt?(decimal, Decimal.new("0.01"))
  defp has_meaningful_score?(float) when is_float(float), do: float > 0.01
  defp has_meaningful_score?(int) when is_integer(int), do: int > 0.01

  defp award_worthy_score?(nil), do: false
  defp award_worthy_score?(%Decimal{} = decimal), do: Decimal.gt?(decimal, Decimal.new("0.1"))
  defp award_worthy_score?(float) when is_float(float), do: float > 0.1
  defp award_worthy_score?(int) when is_integer(int), do: int > 0.1

  def has_active_basic_filters(params) when is_map(params) do
    basic_filter_keys = [
      "genres",
      "languages",
      "lists",
      "festivals",
      "decade",
      "show_unreleased",
      "rating_preset",
      "people_ids"
    ]

    Enum.any?(basic_filter_keys, fn key ->
      value = Map.get(params, key)
      filter_value_present?(value)
    end)
  end

  def get_active_basic_filters(params) when is_map(params) do
    basic_filter_keys = [
      "genres",
      "languages",
      "lists",
      "festivals",
      "decade",
      "show_unreleased",
      "rating_preset",
      "people_ids"
    ]

    params
    |> Map.take(basic_filter_keys)
    |> Enum.reject(fn {_k, v} -> not filter_value_present?(v) end)
  end

  def format_basic_filter_label(key) when is_binary(key) do
    case key do
      "genres" -> "Genres"
      "languages" -> "Languages"
      "lists" -> "Lists"
      "festivals" -> "Festivals"
      "decade" -> "Decade"
      "show_unreleased" -> "Unreleased Films"
      "rating_preset" -> "Rating Quality"
      "people_ids" -> "Cast & Crew"
      # Advanced filters that might still appear
      "countries" -> "Countries"
      "year_from" -> "Year From"
      "year_to" -> "Year To"
      "runtime_min" -> "Min Runtime"
      "runtime_max" -> "Max Runtime"
      "rating_min" -> "Min Rating"
      _ -> Phoenix.Naming.humanize(key)
    end
  end

  def format_basic_filter_value(key, value, assigns) do
    case key do
      "genres" ->
        genres_list = Map.get(assigns, :available_genres, Map.get(assigns, :genres, []))

        genre_names =
          value
          |> List.wrap()
          |> Enum.reject(&(&1 == "" || &1 == nil))
          |> Enum.map(fn id ->
            id_int = if is_binary(id), do: String.to_integer(id), else: id
            genre = Enum.find(genres_list, &(&1.id == id_int))
            if genre, do: genre.name, else: to_string(id)
          end)
          |> Enum.join(", ")

        if String.length(genre_names) > 30,
          do: String.slice(genre_names, 0..27) <> "...",
          else: genre_names

      "countries" ->
        countries_list = Map.get(assigns, :available_countries, Map.get(assigns, :countries, []))

        country_names =
          value
          |> List.wrap()
          |> Enum.reject(&(&1 == "" || &1 == nil))
          |> Enum.map(fn id ->
            id_int = if is_binary(id), do: String.to_integer(id), else: id
            country = Enum.find(countries_list, &(&1.id == id_int))
            if country, do: country.name, else: to_string(id)
          end)
          |> Enum.join(", ")

        if String.length(country_names) > 30,
          do: String.slice(country_names, 0..27) <> "...",
          else: country_names

      "languages" ->
        languages_list = Map.get(assigns, :available_languages, Map.get(assigns, :languages, []))

        lang_names =
          value
          |> List.wrap()
          |> Enum.map(fn code ->
            lang = Enum.find(languages_list, &(&1.iso_639_1 == code))
            if lang, do: lang.english_name, else: code
          end)
          |> Enum.join(", ")

        if String.length(lang_names) > 30,
          do: String.slice(lang_names, 0..27) <> "...",
          else: lang_names

      "lists" ->
        lists_list = Map.get(assigns, :available_lists, Map.get(assigns, :lists, []))

        list_names =
          value
          |> List.wrap()
          |> Enum.map(fn key ->
            list = Enum.find(lists_list, &(&1.key == key))
            if list, do: list.name, else: key
          end)
          |> Enum.join(", ")

        if String.length(list_names) > 30,
          do: String.slice(list_names, 0..27) <> "...",
          else: list_names

      "festivals" ->
        festivals_list = Map.get(assigns, :festival_organizations, [])

        festival_names =
          value
          |> List.wrap()
          |> Enum.reject(&(&1 == "" || &1 == nil))
          |> Enum.map(fn id ->
            id_int = if is_binary(id), do: String.to_integer(id), else: id
            festival = Enum.find(festivals_list, &(&1.id == id_int))
            if festival, do: festival.name, else: to_string(id)
          end)
          |> Enum.join(", ")

        if String.length(festival_names) > 30,
          do: String.slice(festival_names, 0..27) <> "...",
          else: festival_names

      "decade" ->
        "#{value}s"

      "runtime_min" ->
        "#{value} min"

      "runtime_max" ->
        "#{value} min"

      "rating_min" ->
        "#{value}/10"

      "show_unreleased" ->
        if value == "true", do: "Yes", else: "No"

      "rating_preset" ->
        case value do
          "highly_rated" -> "Highly Rated (7.5+)"
          "well_reviewed" -> "Well Reviewed (6.0+)"
          "critically_acclaimed" -> "Critically Acclaimed"
          _ -> to_string(value)
        end

      "people_ids" ->
        format_people_search_value(value)

      _ ->
        to_string(value)
    end
  end

  # Simplified filter system for legacy template compatibility
  def has_any_active_filters(filters_or_params) when is_map(filters_or_params) do
    # Check if this is the normalized filters map (has atom keys) or params (has string keys)
    if Map.has_key?(filters_or_params, :genres) or Map.has_key?(filters_or_params, :countries) do
      # It's the normalized filters map from the template
      check_normalized_filters(filters_or_params)
    else
      # It's the params map
      has_active_basic_filters(filters_or_params) ||
        AdvancedFilters.has_active_advanced_filters(filters_or_params) ||
        Map.get(filters_or_params, "people_ids") not in [nil, ""]
    end
  end

  defp check_normalized_filters(filters) do
    # Check basic filters
    basic_active =
      Enum.any?(
        [:genres, :languages, :lists, :festivals, :decade, :show_unreleased, :rating_preset],
        fn key ->
          value = Map.get(filters, key)
          filter_value_present?(value)
        end
      )

    # Check advanced filters
    advanced_active =
      Enum.any?(
        [
          :countries,
          :year_from,
          :year_to,
          :runtime_min,
          :runtime_max,
          :award_status,
          :festival_id,
          :award_category_id,
          :award_year_from,
          :award_year_to,
          :discovery_preset,
          :award_preset
        ],
        fn key ->
          value = Map.get(filters, key)
          filter_value_present?(value)
        end
      )

    # Check people search
    people_active =
      case Map.get(filters, :people_search) do
        %{"people_ids" => ids} -> filter_value_present?(ids)
        _ -> false
      end

    basic_active || advanced_active || people_active
  end

  def get_all_active_filters(filters_or_params, assigns) do
    # Convert normalized filters back to params format if needed
    params =
      if Map.has_key?(filters_or_params, :genres) or Map.has_key?(filters_or_params, :countries) do
        # It's the normalized filters, convert back to params format
        filters_to_params(filters_or_params)
      else
        filters_or_params
      end

    basic_filters = get_active_basic_filters(params)
    advanced_filters = AdvancedFilters.get_active_advanced_filters(params)

    # Note: people_ids is now handled in advanced_filters, no need for separate people_filters

    []
    |> append_normalized_filters(basic_filters, :basic, assigns)
    |> append_normalized_filters(advanced_filters, :advanced, assigns)
  end

  defp filters_to_params(filters) do
    params = %{}

    # Convert array filters (including festivals)
    params =
      Enum.reduce([:genres, :countries, :languages, :lists, :festivals], params, fn key, acc ->
        case Map.get(filters, key) do
          nil -> acc
          [] -> acc
          value -> Map.put(acc, Atom.to_string(key), value)
        end
      end)

    # Convert single value filters
    params =
      Enum.reduce(
        [
          :year_from,
          :year_to,
          :decade,
          :runtime_min,
          :runtime_max,
          :rating_min,
          :show_unreleased,
          :award_status,
          :festival_id,
          :award_category_id,
          :award_year_from,
          :award_year_to,
          :rating_preset,
          :discovery_preset,
          :award_preset
        ],
        params,
        fn key, acc ->
          case Map.get(filters, key) do
            nil -> acc
            "" -> acc
            value -> Map.put(acc, Atom.to_string(key), value)
          end
        end
      )

    # Convert people search
    case Map.get(filters, :people_search) do
      %{"people_ids" => ids} when ids not in [nil, ""] ->
        Map.put(params, "people_ids", ids)

      _ ->
        params
    end
  end

  defp append_normalized_filters(acc, filters, type, assigns) do
    normalized =
      Enum.map(filters, fn {key, value} ->
        %{
          key: to_string(key),
          type: to_string(type),
          label: format_unified_filter_label(key, type),
          display_value: format_unified_filter_value(key, value, type, assigns),
          removable: true
        }
      end)

    acc ++ normalized
  end

  defp format_unified_filter_label(key, type) do
    case {type, key} do
      {:basic, key} ->
        format_basic_filter_label(key)

      {:advanced, key} ->
        AdvancedFilters.format_filter_label(key)

      {:people, "people_ids"} ->
        "Cast & Crew"

      _ ->
        Phoenix.Naming.humanize(to_string(key))
    end
  end

  defp format_unified_filter_value(key, value, type, assigns) do
    case {type, key} do
      {:basic, key} ->
        format_basic_filter_value(key, value, assigns)

      {:advanced, key} ->
        AdvancedFilters.format_filter_value(key, value)

      {:people, "people_ids"} ->
        format_people_search_value(value)

      _ ->
        to_string(value)
    end
  end

  defp format_people_search_value(people_ids) when is_binary(people_ids) do
    ids =
      people_ids
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(&String.to_integer/1)

    if ids == [] do
      "No people selected"
    else
      try do
        people = Search.get_people_by_ids(ids)
        names = Enum.map(people, & &1.name)

        case length(names) do
          0 -> "No people found"
          1 -> hd(names)
          2 -> Enum.join(names, " & ")
          count when count <= 3 -> Enum.join(names, ", ")
          count -> "#{hd(names)} & #{count - 1} others"
        end
      rescue
        _ -> "#{length(ids)} people selected"
      end
    end
  end
end
