defmodule CinegraphWeb.SearchEventHandlers do
  @moduledoc """
  Shared event handler implementations for search-based LiveViews.

  This module provides a `__using__` macro that injects common event handlers
  for search, sort, pagination, and filter operations. Each LiveView using this
  module must implement a `build_path/2` callback to generate the appropriate
  URL path for navigation.

  ## Usage

      defmodule MyApp.SomeLive do
        use CinegraphWeb, :live_view
        use CinegraphWeb.SearchEventHandlers

        # Required callback - builds the navigation path
        @impl CinegraphWeb.SearchEventHandlers
        def build_path(socket, params) do
          ~p"/my-route?\#{params}"
        end
      end

  ## Provided Event Handlers

  The following `handle_event` callbacks are injected:
  - `"search"` - Handle search term changes
  - `"change_sort"` - Handle sort parameter changes
  - `"sort_criteria_changed"` - Handle sort criteria dropdown changes
  - `"toggle_sort_direction"` - Toggle between ascending/descending
  - `"page"` - Handle pagination
  - `"toggle_filters"` - Show/hide filter panel
  - `"apply_filters"` - Apply filter parameters
  - `"clear_filters"` - Clear all filters (keeps search and sort)
  - `"remove_filter"` - Remove a single filter

  ## Provided Info Handlers

  The following `handle_info` callbacks are injected:
  - `{:search_people_autocomplete, component_id, query}` - People search autocomplete
  - `{:people_selected, component_id, selected_people}` - People selection updates

  ## Required Assigns

  LiveViews using this module should have these assigns:
  - `:params` - Current URL parameters map
  - `:sort_criteria` - Current sort field
  - `:sort_direction` - Current sort direction (:asc or :desc)
  - `:show_filters` - Boolean for filter panel visibility

  ## Required Imports

  The LiveView should import these helpers:
  - `CinegraphWeb.LiveViewHelpers.build_sort_param/2`
  - `CinegraphWeb.LiveViewHelpers.clean_filter_params/1`
  """

  @doc """
  Callback to build the navigation path for the LiveView.

  This must be implemented by each LiveView using this module.

  ## Parameters
  - `socket` - The LiveView socket (for accessing assigns like slug, filter_mode, etc.)
  - `params` - Map of URL parameters to include in the path

  ## Returns
  A path string suitable for `push_patch/2`
  """
  @callback build_path(Phoenix.LiveView.Socket.t(), map()) :: String.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour CinegraphWeb.SearchEventHandlers

      # Import required helpers for the injected handlers
      import CinegraphWeb.LiveViewHelpers,
        only: [build_sort_param: 2, clean_filter_params: 1]

      # ========================================================================
      # Search Event Handler
      # ========================================================================

      @impl Phoenix.LiveView
      def handle_event("search", %{"search" => search}, socket) do
        params = build_params(socket, %{"search" => search, "page" => "1"})
        path = build_path(socket, params)
        {:noreply, push_patch(socket, to: path)}
      end

      # ========================================================================
      # Sort Event Handlers
      # ========================================================================

      @impl Phoenix.LiveView
      def handle_event("change_sort", %{"sort" => sort}, socket) do
        params = build_params(socket, %{"sort" => sort, "page" => "1"})
        path = build_path(socket, params)
        {:noreply, push_patch(socket, to: path)}
      end

      @impl Phoenix.LiveView
      def handle_event("sort_criteria_changed", %{"criteria" => criteria}, socket) do
        sort = build_sort_param(criteria, socket.assigns.sort_direction)
        params = build_params(socket, %{"sort" => sort, "page" => "1"})
        path = build_path(socket, params)

        {:noreply,
         socket
         |> assign(:sort_criteria, criteria)
         |> push_patch(to: path)}
      end

      @impl Phoenix.LiveView
      def handle_event("toggle_sort_direction", _params, socket) do
        new_direction = if socket.assigns.sort_direction == :desc, do: :asc, else: :desc
        sort = build_sort_param(socket.assigns.sort_criteria, new_direction)
        params = build_params(socket, %{"sort" => sort, "page" => "1"})
        path = build_path(socket, params)

        {:noreply,
         socket
         |> assign(:sort_direction, new_direction)
         |> push_patch(to: path)}
      end

      # ========================================================================
      # Pagination Event Handler
      # ========================================================================

      @impl Phoenix.LiveView
      def handle_event("page", %{"page" => page}, socket) do
        params = build_params(socket, %{"page" => page})
        path = build_path(socket, params)
        {:noreply, push_patch(socket, to: path)}
      end

      # ========================================================================
      # Filter Event Handlers
      # ========================================================================

      @impl Phoenix.LiveView
      def handle_event("toggle_filters", _params, socket) do
        {:noreply, assign(socket, :show_filters, !socket.assigns.show_filters)}
      end

      @impl Phoenix.LiveView
      def handle_event("apply_filters", %{"filters" => filters}, socket) do
        cleaned_filters = clean_filter_params(filters)

        params =
          socket.assigns.params
          |> Map.merge(cleaned_filters)
          |> Map.put("page", "1")
          |> clean_filter_params()

        path = build_path(socket, params)
        {:noreply, push_patch(socket, to: path)}
      end

      @impl Phoenix.LiveView
      def handle_event("clear_filters", _params, socket) do
        # Keep only search and sort, reset filters
        params =
          socket.assigns.params
          |> Map.take(["search", "sort"])
          |> Map.put("page", "1")
          |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
          |> Map.new()

        path = build_path(socket, params)
        {:noreply, push_patch(socket, to: path)}
      end

      @impl Phoenix.LiveView
      def handle_event("remove_filter", %{"filter" => filter_key}, socket) do
        params =
          socket.assigns.params
          |> Map.delete(filter_key)
          |> Map.put("page", "1")

        path = build_path(socket, params)
        {:noreply, push_patch(socket, to: path)}
      end

      # ========================================================================
      # People Autocomplete Info Handlers
      # ========================================================================

      @impl Phoenix.LiveView
      def handle_info({:search_people_autocomplete, component_id, query}, socket) do
        # Skip search for empty/whitespace queries
        results =
          if String.trim(query) == "" do
            []
          else
            Cinegraph.Movies.Search.search_people(query, 10)
          end

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

      @impl Phoenix.LiveView
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

        path = build_path(socket, params)
        {:noreply, push_patch(socket, to: path)}
      end

      # ========================================================================
      # Shared Helper - Build Params
      # ========================================================================

      @doc false
      def build_params(socket, updates) do
        socket.assigns.params
        |> Map.merge(updates)
        |> Map.delete("slug")
        |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
        |> Map.new()
      end

      # Allow the using module to override any of these handlers
      defoverridable handle_event: 3, handle_info: 2, build_params: 2
    end
  end
end
