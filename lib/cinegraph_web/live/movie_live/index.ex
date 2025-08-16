defmodule CinegraphWeb.MovieLive.Index do
  use CinegraphWeb, :live_view

  import Ecto.Query, only: [from: 2]
  require Logger

  alias Cinegraph.Movies
  alias Cinegraph.Movies.{Genre, ProductionCountry, SpokenLanguage, MovieLists}
  alias Cinegraph.Repo
  alias Cinegraph.Metrics.PersonMetric
  alias CinegraphWeb.MovieLive.AdvancedFilters

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
     |> assign(:sort_criteria, "release_date")
     |> assign(:sort_direction, :desc)
     |> assign(:sort, "release_date_desc")
     |> assign(:filters, %{})
     |> assign(:search_term, "")
     |> assign(:show_filters, false)
     |> assign(:show_advanced_filters, false)
     |> assign_filter_options()
     |> assign_advanced_filter_options()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply,
     socket
     |> assign_pagination_params(params)
     |> assign_filter_params(params)
     |> load_paginated_movies()
     |> apply_action(socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("change_sort", %{"sort" => sort}, socket) do
    params =
      build_filter_params(socket)
      |> Map.put("sort", sort)
      |> Map.put("page", "1")

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("sort_criteria_changed", %{"criteria" => criteria}, socket) do
    # Keep current direction, just change criteria
    direction = socket.assigns.sort_direction
    sort_value = build_sort_value(criteria, direction)

    params =
      build_filter_params(socket)
      |> Map.put("sort", sort_value)
      |> Map.put("page", "1")

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("toggle_sort_direction", _params, socket) do
    # Toggle between :asc and :desc
    new_direction = if socket.assigns.sort_direction == :desc, do: :asc, else: :desc
    criteria = socket.assigns.sort_criteria
    sort_value = build_sort_value(criteria, new_direction)

    params =
      build_filter_params(socket)
      |> Map.put("sort", sort_value)
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
  def handle_event("remove_filter", %{"filter" => filter_key} = params, socket) do
    filter_type = params["filter_type"] || "basic"

    updated_filters =
      case filter_type do
        "basic" ->
          remove_basic_filter(socket.assigns.filters, filter_key)

        "advanced" ->
          remove_advanced_filter(socket.assigns.filters, filter_key)

        "people" ->
          remove_people_filter(socket.assigns.filters, filter_key)

        _ ->
          # Fallback to legacy behavior for backwards compatibility
          filter_atom =
            try do
              String.to_existing_atom(filter_key)
            rescue
              ArgumentError -> nil
            end

          case filter_atom do
            nil -> socket.assigns.filters
            atom -> Map.delete(socket.assigns.filters, atom)
          end
      end

    # Build params directly with updated filters to avoid merge conflicts
    params =
      %{
        "page" => "1",
        "per_page" => to_string(socket.assigns.per_page),
        "sort" => socket.assigns.sort,
        "search" => socket.assigns.search_term
      }
      |> Map.merge(stringify_filters(updated_filters))
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" or v == [] end)
      |> Map.new()

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("clear_all_filters", _params, socket) do
    params = %{
      "page" => "1",
      "per_page" => to_string(socket.assigns.per_page),
      "sort" => socket.assigns.sort
    }

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("search", %{"search" => search_term}, socket) do
    params =
      build_filter_params(socket)
      |> Map.put("search", search_term)
      |> Map.put("page", "1")

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("apply_filters", %{"filters" => filters}, socket) do
    params =
      build_filter_params(socket)
      |> Map.merge(filters)
      |> Map.put("page", "1")
      |> Enum.reject(fn {_k, v} -> v == "" or v == [] end)
      |> Map.new()

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    params = %{
      "page" => "1",
      "per_page" => to_string(socket.assigns.per_page),
      "sort" => socket.assigns.sort
    }

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  # Handle autocomplete search for people
  @impl true
  def handle_info({:search_people_autocomplete, component_id, query}, socket) do
    results = Cinegraph.People.search_people(query, limit: 10)

    # Enhance results with person quality metrics
    enhanced_results = enhance_people_with_metrics(results)

    # Update component with results and cache them
    send_update(CinegraphWeb.Components.PersonAutocomplete,
      id: component_id,
      search_results: enhanced_results,
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
    current_filters = socket.assigns.filters

    # Always use simple people_ids only - no role filtering
    people_search_filter = %{"people_ids" => people_ids}
    updated_filters = Map.put(current_filters, :people_search, people_search_filter)

    # Apply the updated filters
    params =
      build_filter_params(%{socket | assigns: %{socket.assigns | filters: updated_filters}})
      |> Map.put("page", "1")

    path = ~p"/movies?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  # Private functions

  defp enhance_people_with_metrics(people) do
    person_ids = Enum.map(people, & &1.id)

    # Get quality scores for these people
    metrics =
      from(pm in PersonMetric,
        where: pm.person_id in ^person_ids and pm.metric_type == "quality_score",
        select: %{person_id: pm.person_id, score: pm.score}
      )
      |> Repo.all()
      |> Map.new(fn %{person_id: id, score: score} -> {id, score} end)

    # Add quality scores to people
    Enum.map(people, fn person ->
      score = Map.get(metrics, person.id)
      Map.put(person, :quality_score, score)
    end)
  end

  defp assign_pagination_params(socket, params) do
    page = parse_int_param(params["page"], 1, min: 1)
    per_page = parse_int_param(params["per_page"], 50, min: 10, max: 100)
    sort = params["sort"] || "release_date_desc"

    # Parse sort into criteria and direction
    {criteria, direction} = parse_sort_value(sort)

    socket
    |> assign(:page, page)
    |> assign(:per_page, per_page)
    |> assign(:sort, sort)
    |> assign(:sort_criteria, criteria)
    |> assign(:sort_direction, direction)
  end

  defp assign_filter_params(socket, params) do
    # Handle both array notation and regular params for genres
    genres_param = params["genres[]"] || params["genres"]
    
    socket
    |> assign(:search_term, params["search"] || "")
    |> assign(:filters, %{
      genres: parse_list_param(genres_param),
      countries: parse_list_param(params["countries[]"] || params["countries"]),
      languages: parse_list_param(params["languages[]"] || params["languages"]),
      lists: parse_list_param(params["lists[]"] || params["lists"]),
      year: params["year"],
      year_from: params["year_from"],
      year_to: params["year_to"],
      decade: params["decade"],
      runtime_min: params["runtime_min"],
      runtime_max: params["runtime_max"],
      rating_min: params["rating_min"],
      show_unreleased: params["show_unreleased"] == "true",
      # Advanced filters
      award_status: params["award_status"],
      festival_id: params["festival_id"],
      award_category_id: params["award_category_id"],
      award_year_from: params["award_year_from"],
      award_year_to: params["award_year_to"],
      tmdb_min: params["tmdb_min"],
      tmdb_max: params["tmdb_max"],
      imdb_min: params["imdb_min"],
      imdb_max: params["imdb_max"],
      metacritic_min: params["metacritic_min"],
      metacritic_max: params["metacritic_max"],
      rt_critics_min: params["rt_critics_min"],
      rt_audience_min: params["rt_audience_min"],
      director_id: params["director_id"],
      actor_ids: parse_list_param(params["actor_ids"]),
      person_ids: parse_list_param(params["person_ids"]),
      popular_opinion_min: params["popular_opinion_min"],
      critical_acclaim_min: params["critical_acclaim_min"],
      industry_recognition_min: params["industry_recognition_min"],
      cultural_impact_min: params["cultural_impact_min"],
      people_quality_min: params["people_quality_min"],
      # New simplified filters
      people_search: parse_people_search_param(params),
      rating_preset: params["rating_preset"],
      discovery_preset: params["discovery_preset"],
      award_preset: params["award_preset"]
    })
  end

  defp assign_filter_options(socket) do
    socket
    |> assign(:available_genres, list_genres())
    |> assign(:available_countries, list_production_countries())
    |> assign(:available_languages, list_spoken_languages())
    |> assign(:available_lists, list_canonical_lists())
    |> assign(:available_decades, generate_decades())
  end

  defp assign_advanced_filter_options(socket) do
    socket
    |> assign(:festival_organizations, list_festival_organizations())
    |> assign(:director_options, [])
    |> assign(:actor_options, [])
    |> assign(:person_options, [])
    |> assign(:form, to_form(%{}))
  end

  defp load_paginated_movies(socket) do
    %{page: page, per_page: per_page, sort: sort, filters: filters, search_term: search_term} =
      socket.assigns
    
    query_filters = stringify_filters_for_query(filters)
    
    params =
      %{
        "page" => to_string(page),
        "per_page" => to_string(per_page),
        "sort" => sort,
        "search" => search_term
      }
      |> Map.merge(query_filters)

    movies = Movies.list_movies(params)
    total_movies = Movies.count_movies(params)
    total_pages = ceil(total_movies / per_page)

    socket
    |> assign(:movies, movies)
    |> assign(:total_movies, total_movies)
    |> assign(:total_pages, max(total_pages, 1))
  end

  defp build_filter_params(socket) do
    %{
      "page" => to_string(socket.assigns.page),
      "per_page" => to_string(socket.assigns.per_page),
      "sort" => socket.assigns.sort,
      "search" => socket.assigns.search_term
    }
    |> Map.merge(stringify_filters(socket.assigns.filters))
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" or v == [] end)
    |> Map.new()
  end

  # For database queries - uses simple keys like "genres"
  defp stringify_filters_for_query(filters) do
    filters
    |> Enum.flat_map(fn {k, v} ->
      case {k, v} do
        # Handle people_search specially to preserve nested structure for database
        {:people_search, value} when is_map(value) ->
          # For database queries, we need to pass the map directly
          # not as nested parameters
          [{"people_search", value}]
        
        {"people_search", value} when is_map(value) ->
          # For database queries, we need to pass the map directly
          # not as nested parameters
          [{"people_search", value}]
        
        # Handle regular parameters - just convert to string key
        {k, v} ->
          stringified = stringify_value(k, v)
          if is_nil(stringified) or stringified == "" or stringified == [] do
            []
          else
            [{to_string(k), stringified}]
          end
      end
    end)
    |> Map.new()
  end

  # For URLs - uses array notation like "genres[]"
  defp stringify_filters(filters) do
    filters
    |> Enum.flat_map(fn {k, v} ->
      case {k, v} do
        # Handle list/array parameters with proper array notation
        {key, value} when is_list(value) and value != [] ->
          # For list parameters, we need to preserve the array notation
          key_str =
            case key do
              :genres -> "genres[]"
              :countries -> "countries[]"
              :languages -> "languages[]"
              :lists -> "lists[]"
              # These stay as comma-separated
              :actor_ids -> "actor_ids"
              # These stay as comma-separated
              :person_ids -> "person_ids"
              _ when is_atom(key) -> to_string(key)
              _ -> to_string(key)
            end

          [{key_str, value}]

        # Handle people_search specially to preserve nested structure
        {:people_search, value} when is_map(value) ->
          case stringify_value(:people_search, value) do
            nil ->
              []

            %{"people_ids" => people_ids} = result ->
              # Return nested parameters
              base = [{"people_search[people_ids]", people_ids}]

              if Map.has_key?(result, "role_filter") do
                base ++ [{"people_search[role_filter]", result["role_filter"]}]
              else
                base
              end

            _ ->
              []
          end

        {"people_search", value} when is_map(value) ->
          case stringify_value("people_search", value) do
            nil ->
              []

            %{"people_ids" => people_ids} = result ->
              # Return nested parameters
              base = [{"people_search[people_ids]", people_ids}]

              if Map.has_key?(result, "role_filter") do
                base ++ [{"people_search[role_filter]", result["role_filter"]}]
              else
                base
              end

            _ ->
              []
          end

        # Handle regular parameters
        {k, v} ->
          stringified = stringify_value(k, v)

          if is_nil(stringified) or stringified == "" or stringified == [] do
            []
          else
            [{to_string(k), stringified}]
          end
      end
    end)
    |> Map.new()
  end

  # Handle special cases for new filter types
  defp stringify_value(:people_search, %{"people_ids" => people_ids, "role_filter" => role_filter}) do
    if people_ids != "" do
      # Include role_filter only if it's not the default "any" (for advanced filters)
      # For basic filters with hidden role dropdown, we exclude role_filter entirely
      if role_filter && role_filter != "any" do
        %{"people_ids" => people_ids, "role_filter" => role_filter}
      else
        %{"people_ids" => people_ids}
      end
    else
      nil
    end
  end

  defp stringify_value(_key, nil), do: nil
  defp stringify_value(_key, v) when is_list(v), do: Enum.join(v, ",")
  defp stringify_value(_key, true), do: "true"
  defp stringify_value(_key, false), do: "false"
  defp stringify_value(_key, v) when is_map(v), do: v
  defp stringify_value(_key, v), do: to_string(v)

  defp parse_list_param(nil), do: []
  defp parse_list_param(""), do: []

  defp parse_list_param(param) when is_binary(param) do
    # Handle comma-separated values
    if String.contains?(param, ",") do
      String.split(param, ",", trim: true)
    else
      # Single value - keep it as a single-item list
      # This ensures filters persist when rebuilt
      [param]
    end
  end

  defp parse_list_param(param) when is_list(param), do: param

  defp parse_people_search_param(params) do
    case {params["people_search"], params["people_search[people_ids]"],
          params["people_search[role_filter]"]} do
      # New format with nested parameters - only if we have actual people
      {nil, people_ids, role_filter} when people_ids not in [nil, ""] ->
        base_map = %{"people_ids" => people_ids || ""}
        # Only include role_filter if it's explicitly set and not "any" AND it exists in params
        # If role_filter param is missing entirely, this indicates basic filter usage
        if role_filter && role_filter != "any" do
          Map.put(base_map, "role_filter", role_filter)
        else
          base_map
        end

      # Handle case where only people_ids is provided (basic filter usage)
      {nil, people_ids, nil} when people_ids not in [nil, ""] ->
        # Basic filter usage - no role_filter at all
        %{"people_ids" => people_ids}

      # Existing format (map) - only if it has people
      {people_search, _, _} when is_map(people_search) ->
        case people_search do
          %{"people_ids" => people_ids} when people_ids not in [nil, ""] ->
            # Only preserve role_filter if it exists and is not the default "any"
            base_map = %{"people_ids" => people_ids}
            role_filter = people_search["role_filter"]

            if role_filter && role_filter != "any" do
              Map.put(base_map, "role_filter", role_filter)
            else
              base_map
            end

          _ ->
            nil
        end

      # No people search data - return nil to avoid unnecessary processing
      _ ->
        nil
    end
  end

  defp parse_int_param(param, default, opts) do
    min_val = Keyword.get(opts, :min, 1)
    max_val = Keyword.get(opts, :max, 999_999)

    case Integer.parse(param || to_string(default)) do
      {num, _} when num >= min_val and num <= max_val -> num
      _ -> default
    end
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Movies Database")
  end

  # Data loading helpers
  defp list_genres do
    Repo.all(from g in Genre, order_by: g.name)
  end

  defp list_production_countries do
    Repo.all(from c in ProductionCountry, order_by: c.name)
  end

  defp list_spoken_languages do
    Repo.all(from l in SpokenLanguage, order_by: l.english_name)
  end

  defp list_canonical_lists do
    MovieLists.get_active_source_keys()
    |> Enum.map(fn key ->
      case MovieLists.get_config(key) do
        {:ok, config} -> %{key: key, name: config.name}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp generate_decades do
    current_year = Date.utc_today().year
    start_decade = 1900

    for decade <- start_decade..current_year//10 do
      %{value: decade, label: "#{decade}s"}
    end
    |> Enum.reverse()
  end

  defp list_festival_organizations do
    from(fo in "festival_organizations",
      select: %{id: fo.id, name: fo.name, abbreviation: fo.abbreviation},
      order_by: fo.name
    )
    |> Repo.all()
  end

  # Pagination path builder
  def build_pagination_path(assigns, new_params \\ %{}) do
    current_params =
      %{
        "page" => to_string(assigns.page),
        "per_page" => to_string(assigns.per_page),
        "sort" => assigns.sort,
        "search" => assigns.search_term
      }
      |> Map.merge(stringify_filters(assigns.filters))

    params =
      current_params
      |> Map.merge(new_params)
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" or v == [] end)
      |> Map.new()

    ~p"/movies?#{params}"
  end

  # Sort helper functions

  defp parse_sort_value(sort_value) do
    case sort_value do
      # Basic sorts
      "title_desc" -> {"title", :desc}
      "title" -> {"title", :asc}
      "release_date_desc" -> {"release_date", :desc}
      "release_date" -> {"release_date", :asc}
      "runtime_desc" -> {"runtime", :desc}
      "runtime" -> {"runtime", :asc}
      "rating" -> {"rating", :desc}
      "popularity" -> {"popularity", :desc}
      # Discovery metrics
      "popular_opinion" -> {"popular_opinion", :desc}
      "popular_opinion_asc" -> {"popular_opinion", :asc}
      "critical_acclaim" -> {"critical_acclaim", :desc}
      "critical_acclaim_asc" -> {"critical_acclaim", :asc}
      "industry_recognition" -> {"industry_recognition", :desc}
      "industry_recognition_asc" -> {"industry_recognition", :asc}
      "cultural_impact" -> {"cultural_impact", :desc}
      "cultural_impact_asc" -> {"cultural_impact", :asc}
      "people_quality" -> {"people_quality", :desc}
      "people_quality_asc" -> {"people_quality", :asc}
      # Default
      _ -> {"release_date", :desc}
    end
  end

  defp build_sort_value(criteria, direction) do
    case {criteria, direction} do
      # Basic sorts
      {"title", :asc} -> "title"
      {"title", :desc} -> "title_desc"
      {"release_date", :asc} -> "release_date"
      {"release_date", :desc} -> "release_date_desc"
      {"runtime", :asc} -> "runtime"
      {"runtime", :desc} -> "runtime_desc"
      # Rating only has desc
      {"rating", _} -> "rating"
      # Popularity only has desc
      {"popularity", _} -> "popularity"
      # Discovery metrics
      {"popular_opinion", :asc} -> "popular_opinion_asc"
      {"popular_opinion", :desc} -> "popular_opinion"
      {"critical_acclaim", :asc} -> "critical_acclaim_asc"
      {"critical_acclaim", :desc} -> "critical_acclaim"
      {"industry_recognition", :asc} -> "industry_recognition_asc"
      {"industry_recognition", :desc} -> "industry_recognition"
      {"cultural_impact", :asc} -> "cultural_impact_asc"
      {"cultural_impact", :desc} -> "cultural_impact"
      {"people_quality", :asc} -> "people_quality_asc"
      {"people_quality", :desc} -> "people_quality"
      # Default
      _ -> "release_date_desc"
    end
  end

  # Helper functions for template

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

  def has_active_basic_filters(filters) do
    basic_filter_keys = [
      :genres,
      :countries,
      :languages,
      :lists,
      :year_from,
      :year_to,
      :decade,
      :runtime_min,
      :runtime_max,
      :rating_min
    ]

    Enum.any?(basic_filter_keys, fn key ->
      value = Map.get(filters, key)
      value not in [nil, "", []]
    end)
  end

  def get_active_basic_filters(filters) do
    basic_filter_keys = [
      :genres,
      :countries,
      :languages,
      :lists,
      :year_from,
      :year_to,
      :decade,
      :runtime_min,
      :runtime_max,
      :rating_min
    ]

    filters
    |> Map.take(basic_filter_keys)
    |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)
  end

  def format_basic_filter_label(key) do
    case key do
      :genres -> "Genres"
      :countries -> "Countries"
      :languages -> "Languages"
      :lists -> "Lists"
      :year_from -> "Year From"
      :year_to -> "Year To"
      :decade -> "Decade"
      :runtime_min -> "Min Runtime"
      :runtime_max -> "Max Runtime"
      :rating_min -> "Min Rating"
      _ -> Phoenix.Naming.humanize(key)
    end
  end

  def format_basic_filter_value(key, value, assigns) do
    case key do
      :genres ->
        genre_names =
          value
          |> Enum.map(fn id ->
            # Handle both string and list values
            id_int =
              case id do
                id when is_binary(id) -> String.to_integer(id)
                id when is_integer(id) -> id
                _ -> nil
              end

            if id_int do
              genre = Enum.find(assigns.available_genres, &(&1.id == id_int))
              if genre, do: genre.name, else: id
            else
              to_string(id)
            end
          end)
          |> Enum.join(", ")

        if String.length(genre_names) > 30,
          do: String.slice(genre_names, 0..27) <> "...",
          else: genre_names

      :countries ->
        country_names =
          value
          |> Enum.map(fn id ->
            # Handle both string and list values
            id_int =
              case id do
                id when is_binary(id) -> String.to_integer(id)
                id when is_integer(id) -> id
                _ -> nil
              end

            if id_int do
              country = Enum.find(assigns.available_countries, &(&1.id == id_int))
              if country, do: country.name, else: id
            else
              to_string(id)
            end
          end)
          |> Enum.join(", ")

        if String.length(country_names) > 30,
          do: String.slice(country_names, 0..27) <> "...",
          else: country_names

      :languages ->
        lang_names =
          value
          |> Enum.map(fn code ->
            lang = Enum.find(assigns.available_languages, &(&1.iso_639_1 == code))
            if lang, do: lang.english_name, else: code
          end)
          |> Enum.join(", ")

        if String.length(lang_names) > 30,
          do: String.slice(lang_names, 0..27) <> "...",
          else: lang_names

      :lists ->
        list_names =
          value
          |> Enum.map(fn key ->
            list = Enum.find(assigns.available_lists, &(&1.key == key))
            if list, do: list.name, else: key
          end)
          |> Enum.join(", ")

        if String.length(list_names) > 30,
          do: String.slice(list_names, 0..27) <> "...",
          else: list_names

      :decade ->
        "#{value}s"

      :runtime_min ->
        "#{value} min"

      :runtime_max ->
        "#{value} min"

      :rating_min ->
        "#{value}/10"

      _ ->
        to_string(value)
    end
  end

  # Helper functions for people search in basic filters
  defp get_selected_people_basic(filters) do
    case filters[:people_search] || filters["people_search"] do
      %{"people_ids" => people_ids} when people_ids != "" ->
        ids =
          people_ids
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(&Integer.parse/1)
          |> Enum.flat_map(fn
            {id, _} -> [id]
            :error -> []
          end)

        if ids == [] do
          []
        else
          try do
            # get_people_by_ids returns a list directly, not a tuple
            people = Cinegraph.People.get_people_by_ids(ids)

            if is_list(people) do
              enhance_people_with_metrics(people)
            else
              []
            end
          rescue
            error ->
              require Logger
              Logger.error("Failed to get people by IDs: #{inspect(error)}")
              []
          end
        end

      _ ->
        []
    end
  end

  defp get_search_term_basic(filters) do
    case filters[:people_search] || filters["people_search"] do
      %{"search_term" => search_term} -> search_term || ""
      _ -> ""
    end
  end

  # Unified Active Filter System

  def has_any_active_filters(filters) do
    has_active_basic_filters(filters) ||
      AdvancedFilters.has_active_advanced_filters(filters) ||
      has_active_people_search(filters)
  end

  def get_all_active_filters(filters, assigns) do
    basic_filters = get_active_basic_filters(filters)
    advanced_filters = AdvancedFilters.get_active_advanced_filters(filters)
    people_filters = get_active_people_search_filters(filters)

    []
    |> append_normalized_filters(basic_filters, :basic, assigns)
    |> append_normalized_filters(advanced_filters, :advanced, assigns)
    |> append_normalized_filters(people_filters, :people, assigns)
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

  def has_active_people_search(filters) do
    case filters[:people_search] || filters["people_search"] do
      %{"people_ids" => people_ids} -> people_ids not in [nil, ""]
      _ -> false
    end
  end

  def get_active_people_search_filters(filters) do
    case filters[:people_search] || filters["people_search"] do
      %{"people_ids" => people_ids} when people_ids not in [nil, ""] ->
        [{"people_search", people_ids}]

      _ ->
        []
    end
  end

  defp format_unified_filter_label(key, type) do
    case {type, key} do
      {:basic, key} when is_atom(key) ->
        format_basic_filter_label(key)

      {:basic, key} when is_binary(key) ->
        try do
          format_basic_filter_label(String.to_existing_atom(key))
        rescue
          ArgumentError -> Phoenix.Naming.humanize(key)
        end

      {:advanced, key} ->
        AdvancedFilters.format_filter_label(key)

      {:people, "people_search"} ->
        "Cast & Crew"

      _ ->
        Phoenix.Naming.humanize(to_string(key))
    end
  end

  defp format_unified_filter_value(key, value, type, assigns) do
    case {type, key} do
      {:basic, key} when is_atom(key) ->
        format_basic_filter_value(key, value, assigns)

      {:basic, key} when is_binary(key) ->
        try do
          atom_key = String.to_existing_atom(key)
          format_basic_filter_value(atom_key, value, assigns)
        rescue
          ArgumentError -> to_string(value)
        end

      {:advanced, key} ->
        AdvancedFilters.format_filter_value(key, value)

      {:people, "people_search"} ->
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
      |> Enum.map(&Integer.parse/1)
      |> Enum.flat_map(fn
        {id, _} -> [id]
        :error -> []
      end)

    if ids == [] do
      "No people selected"
    else
      try do
        people = Cinegraph.People.get_people_by_ids(ids)
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

  # Filter removal helpers

  defp remove_basic_filter(filters, filter_key) when is_binary(filter_key) do
    try do
      atom_key = String.to_existing_atom(filter_key)
      Map.delete(filters, atom_key)
    rescue
      ArgumentError -> filters
    end
  end

  defp remove_advanced_filter(filters, filter_key) do
    Map.delete(filters, filter_key)
  end

  defp remove_people_filter(filters, "people_search") do
    Map.delete(filters, "people_search")
  end

  defp remove_people_filter(filters, _), do: filters
end
