defmodule CinegraphWeb.ListsManagerLive do
  @moduledoc """
  Unified admin interface for managing canonical movie lists and awards.
  Phase 5: Data visualization & insights - category breakdown, activity feed, health indicators.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Repo
  alias Cinegraph.Movies.MovieLists
  alias Cinegraph.Workers.CanonicalImportOrchestrator
  require Logger

  @refresh_interval 10_000
  @categories ["awards", "critics", "curated", "festivals", "personal", "registry"]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Cinegraph.PubSub, "import_progress")
      Phoenix.PubSub.subscribe(Cinegraph.PubSub, "canonical_progress")
    end

    socket =
      socket
      |> assign(:page_title, "Lists Manager")
      |> assign(:stats_loading, false)
      |> assign(:search_query, "")
      |> assign(:filter_category, "all")
      |> assign(:filter_status, "all")
      |> assign(:show_modal, false)
      |> assign(:editing_list, nil)
      |> assign(:categories, @categories)
      |> assign(:view_mode, "table")
      |> assign(:selected_ids, MapSet.new())
      |> assign(:select_all, false)
      # Phase 4: Sorting
      |> assign(:sort_by, "name")
      |> assign(:sort_order, "asc")
      # Phase 4: Import tracking
      |> assign(:importing_ids, MapSet.new())
      |> assign(:show_import_log, false)
      |> assign(:import_log_list, nil)
      # Phase 4: Duplicate modal
      |> assign(:show_duplicate_modal, false)
      |> assign(:duplicating_list, nil)
      # Phase 5: Insights & analytics
      |> assign(:show_category_breakdown, true)
      |> assign(:show_activity_feed, true)
      |> load_data()
      |> schedule_refresh()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket =
      socket
      |> load_data()
      |> schedule_refresh()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:canonical_progress, progress}, socket) do
    list_key = Map.get(progress, :list_key)

    case progress.status do
      :completed ->
        # Remove from importing set
        importing_ids =
          if list_key do
            case find_list_id_by_source_key(socket.assigns.all_lists, list_key) do
              nil -> socket.assigns.importing_ids
              id -> MapSet.delete(socket.assigns.importing_ids, id)
            end
          else
            socket.assigns.importing_ids
          end

        socket =
          socket
          |> put_flash(:info, "Import completed for #{list_key || "list"}")
          |> assign(:importing_ids, importing_ids)
          |> load_data()

        {:noreply, socket}

      :orchestrating ->
        {:noreply, socket}

      :error ->
        importing_ids =
          if list_key do
            case find_list_id_by_source_key(socket.assigns.all_lists, list_key) do
              nil -> socket.assigns.importing_ids
              id -> MapSet.delete(socket.assigns.importing_ids, id)
            end
          else
            socket.assigns.importing_ids
          end

        socket =
          socket
          |> put_flash(:error, "Import failed for #{list_key || "list"}")
          |> assign(:importing_ids, importing_ids)
          |> load_data()

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp find_list_id_by_source_key(lists, source_key) do
    case Enum.find(lists, fn l -> l.source_key == source_key end) do
      nil -> nil
      list -> list.id
    end
  end

  # Search and Filter Events

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    socket =
      socket
      |> assign(:search_query, query)
      |> apply_filters()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_category", %{"category" => category}, socket) do
    socket =
      socket
      |> assign(:filter_category, category)
      |> apply_filters()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    socket =
      socket
      |> assign(:filter_status, status)
      |> apply_filters()

    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    socket =
      socket
      |> assign(:search_query, "")
      |> assign(:filter_category, "all")
      |> assign(:filter_status, "all")
      |> apply_filters()

    {:noreply, socket}
  end

  # Sorting Events

  @impl true
  def handle_event("sort", %{"field" => field}, socket) do
    {new_sort_by, new_sort_order} =
      if socket.assigns.sort_by == field do
        # Toggle order if same field
        new_order = if socket.assigns.sort_order == "asc", do: "desc", else: "asc"
        {field, new_order}
      else
        # Default to ascending for new field
        {field, "asc"}
      end

    socket =
      socket
      |> assign(:sort_by, new_sort_by)
      |> assign(:sort_order, new_sort_order)
      |> apply_filters()

    {:noreply, socket}
  end

  # View Mode Events

  @impl true
  def handle_event("set_view_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :view_mode, mode)}
  end

  # Selection Events

  @impl true
  def handle_event("toggle_select", %{"id" => id}, socket) do
    id = String.to_integer(id)
    selected_ids = socket.assigns.selected_ids

    new_selected =
      if MapSet.member?(selected_ids, id) do
        MapSet.delete(selected_ids, id)
      else
        MapSet.put(selected_ids, id)
      end

    # Update select_all based on whether all visible items are selected
    visible_ids = MapSet.new(Enum.map(socket.assigns.lists, & &1.id))
    select_all = MapSet.subset?(visible_ids, new_selected) and MapSet.size(visible_ids) > 0

    socket =
      socket
      |> assign(:selected_ids, new_selected)
      |> assign(:select_all, select_all)

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_select_all", _params, socket) do
    visible_ids = MapSet.new(Enum.map(socket.assigns.lists, & &1.id))

    {new_selected, new_select_all} =
      if socket.assigns.select_all do
        # Deselect all visible items
        {MapSet.difference(socket.assigns.selected_ids, visible_ids), false}
      else
        # Select all visible items
        {MapSet.union(socket.assigns.selected_ids, visible_ids), true}
      end

    socket =
      socket
      |> assign(:selected_ids, new_selected)
      |> assign(:select_all, new_select_all)

    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    socket =
      socket
      |> assign(:selected_ids, MapSet.new())
      |> assign(:select_all, false)

    {:noreply, socket}
  end

  # Bulk Operations

  @impl true
  def handle_event("bulk_activate", _params, socket) do
    selected_ids = socket.assigns.selected_ids

    if MapSet.size(selected_ids) == 0 do
      {:noreply, put_flash(socket, :error, "No lists selected")}
    else
      results =
        Enum.map(selected_ids, fn id ->
          case MovieLists.get_movie_list(id) do
            nil -> {:error, :not_found}
            list -> MovieLists.update_movie_list(list, %{active: true})
          end
        end)

      success_count = Enum.count(results, fn res -> match?({:ok, _}, res) end)

      socket =
        socket
        |> put_flash(:info, "#{success_count} list(s) activated")
        |> assign(:selected_ids, MapSet.new())
        |> assign(:select_all, false)
        |> load_data()

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("bulk_deactivate", _params, socket) do
    selected_ids = socket.assigns.selected_ids

    if MapSet.size(selected_ids) == 0 do
      {:noreply, put_flash(socket, :error, "No lists selected")}
    else
      results =
        Enum.map(selected_ids, fn id ->
          case MovieLists.get_movie_list(id) do
            nil -> {:error, :not_found}
            list -> MovieLists.update_movie_list(list, %{active: false})
          end
        end)

      success_count = Enum.count(results, fn res -> match?({:ok, _}, res) end)

      socket =
        socket
        |> put_flash(:info, "#{success_count} list(s) deactivated")
        |> assign(:selected_ids, MapSet.new())
        |> assign(:select_all, false)
        |> load_data()

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("bulk_delete", _params, socket) do
    selected_ids = socket.assigns.selected_ids

    if MapSet.size(selected_ids) == 0 do
      {:noreply, put_flash(socket, :error, "No lists selected")}
    else
      results =
        Enum.map(selected_ids, fn id ->
          case MovieLists.get_movie_list(id) do
            nil -> {:error, :not_found}
            list -> MovieLists.delete_movie_list(list)
          end
        end)

      success_count = Enum.count(results, fn res -> match?({:ok, _}, res) end)

      socket =
        socket
        |> put_flash(:info, "#{success_count} list(s) deleted")
        |> assign(:selected_ids, MapSet.new())
        |> assign(:select_all, false)
        |> load_data()

      {:noreply, socket}
    end
  end

  # Import Events (Phase 4)

  @impl true
  def handle_event("trigger_import", %{"id" => id}, socket) do
    list = MovieLists.get_movie_list!(String.to_integer(id))

    case trigger_list_import(list) do
      {:ok, _job} ->
        socket =
          socket
          |> put_flash(:info, "Import queued for '#{list.name}'")
          |> assign(:importing_ids, MapSet.put(socket.assigns.importing_ids, list.id))

        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to queue import: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("bulk_import", _params, socket) do
    selected_ids = socket.assigns.selected_ids

    if MapSet.size(selected_ids) == 0 do
      {:noreply, put_flash(socket, :error, "No lists selected")}
    else
      results =
        Enum.map(selected_ids, fn id ->
          list = MovieLists.get_movie_list!(id)
          {id, trigger_list_import(list)}
        end)

      success_count = Enum.count(results, fn {_id, res} -> match?({:ok, _}, res) end)
      successful_ids = for {id, {:ok, _}} <- results, do: id

      socket =
        socket
        |> put_flash(:info, "#{success_count} import(s) queued")
        |> assign(
          :importing_ids,
          MapSet.union(socket.assigns.importing_ids, MapSet.new(successful_ids))
        )
        |> assign(:selected_ids, MapSet.new())
        |> assign(:select_all, false)

      {:noreply, socket}
    end
  end

  # Duplicate Events (Phase 4)

  def handle_event("show_duplicate_modal", %{"id" => id}, socket) do
    list = MovieLists.get_movie_list!(String.to_integer(id))

    socket =
      socket
      |> assign(:show_duplicate_modal, true)
      |> assign(:duplicating_list, list)

    {:noreply, socket}
  end

  def handle_event("hide_duplicate_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_duplicate_modal, false)
      |> assign(:duplicating_list, nil)

    {:noreply, socket}
  end

  def handle_event("duplicate_list", params, socket) do
    original = socket.assigns.duplicating_list

    attrs = %{
      source_url: original.source_url,
      name: params["name"],
      source_key: params["source_key"],
      category: params["category"] || original.category,
      description: params["description"] || original.description,
      source_type: original.source_type,
      tracks_awards: original.tracks_awards,
      active: false
    }

    case MovieLists.create_movie_list(attrs) do
      {:ok, list} ->
        socket =
          socket
          |> put_flash(:info, "List '#{list.name}' duplicated successfully!")
          |> assign(:show_duplicate_modal, false)
          |> assign(:duplicating_list, nil)
          |> load_data()

        {:noreply, socket}

      {:error, changeset} ->
        errors = format_changeset_errors(changeset)
        socket = put_flash(socket, :error, "Failed to duplicate list: #{errors}")
        {:noreply, socket}
    end
  end

  # Toggle Visibility Events (Phase 5)

  def handle_event("toggle_category_breakdown", _params, socket) do
    {:noreply, assign(socket, :show_category_breakdown, !socket.assigns.show_category_breakdown)}
  end

  def handle_event("toggle_activity_feed", _params, socket) do
    {:noreply, assign(socket, :show_activity_feed, !socket.assigns.show_activity_feed)}
  end

  # Quick filter by clicking stats cards (Phase 5)
  def handle_event("filter_quick", %{"filter" => filter}, socket) do
    socket =
      case filter do
        "active" ->
          socket
          |> assign(:filter_status, "active")
          |> assign(:filter_category, "all")
          |> apply_filters()

        "inactive" ->
          socket
          |> assign(:filter_status, "inactive")
          |> assign(:filter_category, "all")
          |> apply_filters()

        "failed" ->
          # Filter to show only failed imports
          socket
          |> assign(:filter_status, "all")
          |> assign(:filter_category, "all")
          |> assign(:search_query, "")
          |> filter_by_import_status("failed")

        "never_imported" ->
          socket
          |> assign(:filter_status, "all")
          |> assign(:filter_category, "all")
          |> assign(:search_query, "")
          |> filter_by_import_status("never")

        "stale" ->
          socket
          |> assign(:filter_status, "all")
          |> assign(:filter_category, "all")
          |> assign(:search_query, "")
          |> filter_stale_lists()

        "empty" ->
          socket
          |> assign(:filter_status, "all")
          |> assign(:filter_category, "all")
          |> assign(:search_query, "")
          |> filter_empty_lists()

        _ ->
          socket
      end

    {:noreply, socket}
  end

  # Filter by clicking category in breakdown (Phase 5)
  def handle_event("filter_by_category", %{"category" => category}, socket) do
    socket =
      socket
      |> assign(:filter_category, category)
      |> apply_filters()

    {:noreply, socket}
  end

  # Import Log Events (Phase 4)

  def handle_event("show_import_log", %{"id" => id}, socket) do
    id = String.to_integer(id)

    # Get the list from already-loaded data (which includes movie_count)
    # or fall back to fetching it directly
    list =
      Enum.find(socket.assigns.all_lists, fn l -> l.id == id end) ||
        get_list_with_movie_count(id)

    socket =
      socket
      |> assign(:show_import_log, true)
      |> assign(:import_log_list, list)

    {:noreply, socket}
  end

  def handle_event("hide_import_log", _params, socket) do
    socket =
      socket
      |> assign(:show_import_log, false)
      |> assign(:import_log_list, nil)

    {:noreply, socket}
  end

  # Modal Events

  def handle_event("show_add_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_modal, true)
      |> assign(:editing_list, nil)

    {:noreply, socket}
  end

  def handle_event("show_edit_modal", %{"id" => id}, socket) do
    list = MovieLists.get_movie_list!(String.to_integer(id))

    socket =
      socket
      |> assign(:show_modal, true)
      |> assign(:editing_list, list)

    {:noreply, socket}
  end

  def handle_event("hide_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_modal, false)
      |> assign(:editing_list, nil)

    {:noreply, socket}
  end

  # CRUD Events

  def handle_event("add_list", params, socket) do
    source_type = detect_source_type(params["source_url"])

    attrs = %{
      source_url: params["source_url"],
      name: params["name"],
      source_key: params["source_key"],
      category: params["category"],
      description: params["description"],
      source_type: source_type,
      tracks_awards: params["tracks_awards"] == "on",
      active: true
    }

    case MovieLists.create_movie_list(attrs) do
      {:ok, list} ->
        socket =
          socket
          |> put_flash(:info, "List '#{list.name}' added successfully!")
          |> assign(:show_modal, false)
          |> load_data()

        {:noreply, socket}

      {:error, changeset} ->
        errors = format_changeset_errors(changeset)
        socket = put_flash(socket, :error, "Failed to add list: #{errors}")
        {:noreply, socket}
    end
  end

  def handle_event("update_list", params, socket) do
    list = MovieLists.get_movie_list!(String.to_integer(params["list_id"]))
    source_type = detect_source_type(params["source_url"])

    attrs = %{
      source_url: params["source_url"],
      name: params["name"],
      category: params["category"],
      description: params["description"],
      source_type: source_type,
      tracks_awards: params["tracks_awards"] == "on"
    }

    case MovieLists.update_movie_list(list, attrs) do
      {:ok, updated_list} ->
        socket =
          socket
          |> put_flash(:info, "List '#{updated_list.name}' updated successfully!")
          |> assign(:show_modal, false)
          |> assign(:editing_list, nil)
          |> load_data()

        {:noreply, socket}

      {:error, changeset} ->
        errors = format_changeset_errors(changeset)
        socket = put_flash(socket, :error, "Failed to update list: #{errors}")
        {:noreply, socket}
    end
  end

  def handle_event("delete_list", %{"id" => id}, socket) do
    list = MovieLists.get_movie_list!(String.to_integer(id))

    case MovieLists.delete_movie_list(list) do
      {:ok, _deleted_list} ->
        socket =
          socket
          |> put_flash(:info, "List '#{list.name}' deleted successfully!")
          |> load_data()

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to delete list")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    list = MovieLists.get_movie_list!(String.to_integer(id))

    case MovieLists.update_movie_list(list, %{active: !list.active}) do
      {:ok, updated_list} ->
        status = if updated_list.active, do: "activated", else: "deactivated"

        socket =
          socket
          |> put_flash(:info, "List '#{updated_list.name}' #{status}!")
          |> load_data()

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to toggle list status")
        {:noreply, socket}
    end
  end

  # Private helpers for import triggering

  defp trigger_list_import(list) do
    %{
      "action" => "orchestrate_import",
      "list_key" => list.source_key
    }
    |> CanonicalImportOrchestrator.new()
    |> Oban.insert()
  end

  defp load_data(socket) do
    all_lists = get_lists_with_movie_counts()
    stats = calculate_aggregate_stats(all_lists)

    socket
    |> assign(:all_lists, all_lists)
    |> assign(:aggregate_stats, stats)
    |> apply_filters()
  end

  defp apply_filters(socket) do
    all_lists = socket.assigns[:all_lists] || []
    search_query = socket.assigns.search_query
    filter_category = socket.assigns.filter_category
    filter_status = socket.assigns.filter_status
    sort_by = socket.assigns.sort_by
    sort_order = socket.assigns.sort_order

    filtered_lists =
      all_lists
      |> filter_by_search(search_query)
      |> filter_by_category(filter_category)
      |> filter_by_status(filter_status)
      |> sort_lists(sort_by, sort_order)

    assign(socket, :lists, filtered_lists)
  end

  # Phase 5: Special filter functions
  defp filter_by_import_status(socket, status) do
    all_lists = socket.assigns[:all_lists] || []

    filtered =
      case status do
        "failed" ->
          Enum.filter(all_lists, fn l -> l.last_import_status == "failed" end)

        "never" ->
          Enum.filter(all_lists, fn l -> is_nil(l.last_import_at) end)

        "success" ->
          Enum.filter(all_lists, fn l -> l.last_import_status == "success" end)

        _ ->
          all_lists
      end
      |> sort_lists(socket.assigns.sort_by, socket.assigns.sort_order)

    assign(socket, :lists, filtered)
  end

  defp filter_stale_lists(socket) do
    all_lists = socket.assigns[:all_lists] || []
    now = DateTime.utc_now()
    stale_threshold_days = 30

    filtered =
      all_lists
      |> Enum.filter(fn l ->
        l.active && l.last_import_at != nil &&
          DateTime.diff(now, l.last_import_at, :day) > stale_threshold_days
      end)
      |> sort_lists(socket.assigns.sort_by, socket.assigns.sort_order)

    assign(socket, :lists, filtered)
  end

  defp filter_empty_lists(socket) do
    all_lists = socket.assigns[:all_lists] || []

    filtered =
      all_lists
      |> Enum.filter(fn l -> l.active && (l.movie_count || 0) == 0 end)
      |> sort_lists(socket.assigns.sort_by, socket.assigns.sort_order)

    assign(socket, :lists, filtered)
  end

  defp sort_lists(lists, sort_by, sort_order) do
    sorted =
      case sort_by do
        "name" ->
          Enum.sort_by(lists, fn l -> String.downcase(l.name || "") end)

        "category" ->
          Enum.sort_by(lists, fn l -> l.category || "" end)

        "movies" ->
          Enum.sort_by(lists, fn l -> l.movie_count || 0 end)

        "last_import" ->
          Enum.sort_by(lists, fn l -> l.last_import_at || ~U[1970-01-01 00:00:00Z] end)

        "status" ->
          Enum.sort_by(lists, fn l -> l.last_import_status || "" end)

        "active" ->
          Enum.sort_by(lists, fn l -> if l.active, do: 0, else: 1 end)

        _ ->
          lists
      end

    if sort_order == "desc", do: Enum.reverse(sorted), else: sorted
  end

  defp filter_by_search(lists, ""), do: lists
  defp filter_by_search(lists, nil), do: lists

  defp filter_by_search(lists, query) do
    query_down = String.downcase(query)

    Enum.filter(lists, fn list ->
      String.contains?(String.downcase(list.name || ""), query_down) ||
        String.contains?(String.downcase(list.source_key || ""), query_down) ||
        String.contains?(String.downcase(list.description || ""), query_down)
    end)
  end

  defp filter_by_category(lists, "all"), do: lists

  defp filter_by_category(lists, category) do
    Enum.filter(lists, fn list -> list.category == category end)
  end

  defp filter_by_status(lists, "all"), do: lists
  defp filter_by_status(lists, "active"), do: Enum.filter(lists, & &1.active)
  defp filter_by_status(lists, "inactive"), do: Enum.filter(lists, &(!&1.active))

  defp get_lists_with_movie_counts do
    import Ecto.Query
    alias Cinegraph.Movies.Movie

    MovieLists.list_all_movie_lists()
    |> Enum.map(fn list ->
      movie_count =
        from(m in Movie,
          where: fragment("? \\? ?", m.canonical_sources, ^list.source_key),
          select: count(m.id)
        )
        |> Repo.one()

      Map.put(list, :movie_count, movie_count || 0)
    end)
  end

  defp get_list_with_movie_count(id) do
    import Ecto.Query
    alias Cinegraph.Movies.Movie

    list = MovieLists.get_movie_list!(id)

    movie_count =
      from(m in Movie,
        where: fragment("? \\? ?", m.canonical_sources, ^list.source_key),
        select: count(m.id)
      )
      |> Repo.one()

    Map.put(list, :movie_count, movie_count || 0)
  end

  defp calculate_aggregate_stats(lists) do
    total = length(lists)
    active = Enum.count(lists, & &1.active)
    inactive = total - active
    with_awards = Enum.count(lists, & &1.tracks_awards)
    total_movies = Enum.sum(Enum.map(lists, & &1.movie_count))

    successful =
      Enum.count(lists, fn l -> l.last_import_status == "success" end)

    failed =
      Enum.count(lists, fn l -> l.last_import_status == "failed" end)

    never_imported =
      Enum.count(lists, fn l -> is_nil(l.last_import_at) end)

    # Phase 5: Category breakdown
    category_counts =
      lists
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {cat, cat_lists} ->
        %{
          name: cat,
          count: length(cat_lists),
          active: Enum.count(cat_lists, & &1.active),
          movies: Enum.sum(Enum.map(cat_lists, & &1.movie_count))
        }
      end)
      |> Enum.sort_by(& &1.count, :desc)

    # Phase 5: Recent activity (last 5 imports)
    recent_activity =
      lists
      |> Enum.filter(fn l -> l.last_import_at != nil end)
      |> Enum.sort_by(& &1.last_import_at, {:desc, DateTime})
      |> Enum.take(5)
      |> Enum.map(fn l ->
        %{
          id: l.id,
          name: l.name,
          status: l.last_import_status,
          timestamp: l.last_import_at,
          category: l.category
        }
      end)

    # Phase 5: Health indicators
    now = DateTime.utc_now()
    stale_threshold_days = 30

    stale_lists =
      Enum.count(lists, fn l ->
        l.active && l.last_import_at != nil &&
          DateTime.diff(now, l.last_import_at, :day) > stale_threshold_days
      end)

    empty_lists = Enum.count(lists, fn l -> l.active && (l.movie_count || 0) == 0 end)

    health_warnings =
      []
      |> maybe_add_warning(failed > 0, {:failed_imports, failed})
      |> maybe_add_warning(stale_lists > 0, {:stale_lists, stale_lists})
      |> maybe_add_warning(empty_lists > 0, {:empty_lists, empty_lists})
      |> maybe_add_warning(never_imported > 0, {:never_imported, never_imported})

    %{
      total_lists: total,
      active_lists: active,
      inactive_lists: inactive,
      with_awards: with_awards,
      total_movies: total_movies,
      successful_imports: successful,
      failed_imports: failed,
      never_imported: never_imported,
      # Phase 5 additions
      category_counts: category_counts,
      recent_activity: recent_activity,
      stale_lists: stale_lists,
      empty_lists: empty_lists,
      health_warnings: health_warnings
    }
  end

  defp maybe_add_warning(warnings, false, _warning), do: warnings
  defp maybe_add_warning(warnings, true, warning), do: [warning | warnings]

  defp schedule_refresh(socket) do
    if connected?(socket) do
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    socket
  end

  # Template helper functions

  def format_number(nil), do: "0"

  def format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_number(num) when is_float(num) do
    format_number(round(num))
  end

  def format_datetime(nil), do: "Never"

  def format_datetime(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, dt, :second)

    cond do
      diff_seconds < 60 -> "Just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)}h ago"
      diff_seconds < 604_800 -> "#{div(diff_seconds, 86400)}d ago"
      true -> Calendar.strftime(dt, "%Y-%m-%d")
    end
  end

  def format_datetime(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_datetime()
  end

  def format_datetime(_), do: "Unknown"

  def status_badge_class(status) do
    case status do
      "success" -> "bg-green-100 text-green-800"
      "failed" -> "bg-red-100 text-red-800"
      "partial" -> "bg-yellow-100 text-yellow-800"
      _ -> "bg-gray-100 text-gray-600"
    end
  end

  def status_icon(status) do
    case status do
      "success" -> "✓"
      "failed" -> "✗"
      "partial" -> "⚠"
      _ -> "—"
    end
  end

  def category_badge_class(category) do
    case category do
      "awards" -> "bg-amber-100 text-amber-800"
      "critics" -> "bg-purple-100 text-purple-800"
      "curated" -> "bg-blue-100 text-blue-800"
      "festivals" -> "bg-pink-100 text-pink-800"
      "personal" -> "bg-cyan-100 text-cyan-800"
      "registry" -> "bg-emerald-100 text-emerald-800"
      _ -> "bg-gray-100 text-gray-600"
    end
  end

  # Private helper functions

  defp detect_source_type(url) when is_binary(url) do
    cond do
      String.contains?(url, "imdb.com") -> "imdb"
      String.contains?(url, "themoviedb.org") -> "tmdb"
      String.contains?(url, "letterboxd.com") -> "letterboxd"
      true -> "custom"
    end
  end

  defp detect_source_type(_), do: "custom"

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end

  def filters_active?(assigns) do
    assigns.search_query != "" ||
      assigns.filter_category != "all" ||
      assigns.filter_status != "all"
  end

  def selected?(assigns, id) do
    MapSet.member?(assigns.selected_ids, id)
  end

  def selection_count(assigns) do
    MapSet.size(assigns.selected_ids)
  end

  def importing?(assigns, id) do
    MapSet.member?(assigns.importing_ids, id)
  end

  def sort_indicator(assigns, field) do
    if assigns.sort_by == field do
      if assigns.sort_order == "asc", do: "↑", else: "↓"
    else
      ""
    end
  end

  def sort_header_class(assigns, field) do
    base = "cursor-pointer hover:text-gray-900"
    if assigns.sort_by == field, do: "#{base} text-indigo-600 font-semibold", else: base
  end

  # Phase 5: Health warning helpers
  def health_warning_message({:failed_imports, count}) do
    "#{count} list(s) have failed imports"
  end

  def health_warning_message({:stale_lists, count}) do
    "#{count} active list(s) haven't been imported in 30+ days"
  end

  def health_warning_message({:empty_lists, count}) do
    "#{count} active list(s) have no movies"
  end

  def health_warning_message({:never_imported, count}) do
    "#{count} list(s) have never been imported"
  end

  def health_warning_message(_), do: "Unknown warning"

  def health_warning_action({:failed_imports, _}), do: "failed"
  def health_warning_action({:stale_lists, _}), do: "stale"
  def health_warning_action({:empty_lists, _}), do: "empty"
  def health_warning_action({:never_imported, _}), do: "never_imported"
  def health_warning_action(_), do: nil

  def health_warning_icon({:failed_imports, _}), do: "✗"
  def health_warning_icon({:stale_lists, _}), do: "⏰"
  def health_warning_icon({:empty_lists, _}), do: "∅"
  def health_warning_icon({:never_imported, _}), do: "?"
  def health_warning_icon(_), do: "!"

  def health_warning_color({:failed_imports, _}), do: "red"
  def health_warning_color({:stale_lists, _}), do: "amber"
  def health_warning_color({:empty_lists, _}), do: "orange"
  def health_warning_color({:never_imported, _}), do: "slate"
  def health_warning_color(_), do: "gray"

  # Category bar width calculation for visual breakdown
  def category_bar_width(count, max_count) when max_count > 0 do
    percentage = count / max_count * 100
    "#{Float.round(percentage, 1)}%"
  end

  def category_bar_width(_, _), do: "0%"
end
