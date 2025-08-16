defmodule CinegraphWeb.Components.PersonAutocomplete do
  @moduledoc """
  Reusable autocomplete component for selecting people with multi-select support.
  Simplified version without role filtering.
  """

  use Phoenix.LiveComponent
  alias Cinegraph.People

  def mount(socket) do
    {:ok,
     socket
     |> assign(:search_term, "")
     |> assign(:search_results, [])
     |> assign(:selected_people, [])
     |> assign(:searching, false)
     |> assign(:show_results, false)
     |> assign(:search_cache, %{})
     |> assign(:last_search_time, nil)}
  end

  def update(assigns, socket) do
    # Parse selected_people if it comes as a string (from form params)
    selected_people = parse_selected_people(assigns[:selected_people] || [])
    
    # Handle cache updates when search results come back
    socket = if assigns[:cache_query] && assigns[:cache_timestamp] do
      cache_key = assigns.cache_query
      updated_cache = Map.put(socket.assigns.search_cache, cache_key, %{
        results: assigns[:search_results] || [],
        timestamp: assigns[:cache_timestamp]
      })
      
      # Limit cache size to prevent memory issues
      updated_cache = if map_size(updated_cache) > 50 do
        # Remove oldest entries
        updated_cache
        |> Enum.sort_by(fn {_k, v} -> v.timestamp end, DateTime)
        |> Enum.drop(10)
        |> Map.new()
      else
        updated_cache
      end
      
      assign(socket, :search_cache, updated_cache)
    else
      socket
    end
    
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:selected_people, selected_people)
     |> assign(:search_term, assigns[:search_term] || "")}
  end

  def handle_event("search", params, socket) do
    # Handle various parameter formats that LiveView might send
    query = params["value"] || params["search"] || params["query"] || ""
    handle_search_query(query, socket)
  end
  def handle_event("select_person", %{"person_id" => person_id}, socket) do
    person_id = String.to_integer(person_id)
    
    # Don't add if already selected
    if not Enum.any?(socket.assigns.selected_people, &(&1.id == person_id)) do
      person = Enum.find(socket.assigns.search_results, &(&1.id == person_id))
      
      if person do
        selected_people = [person | socket.assigns.selected_people]
        
        # Send update to parent
        send(self(), {:people_selected, socket.assigns.id, selected_people})
        
        {:noreply,
         socket
         |> assign(:selected_people, selected_people)
         |> assign(:search_results, [])
         |> assign(:show_results, false)}
      else
        {:noreply, socket}
      end
    else
      {:noreply,
       socket
       |> assign(:search_results, [])
       |> assign(:show_results, false)}
    end
  end

  def handle_event("remove_person", %{"person_id" => person_id}, socket) do
    person_id = String.to_integer(person_id)
    selected_people = Enum.reject(socket.assigns.selected_people, &(&1.id == person_id))
    
    # Send update to parent
    send(self(), {:people_selected, socket.assigns.id, selected_people})
    
    {:noreply, assign(socket, :selected_people, selected_people)}
  end


  def handle_event("clear_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_term, "")
     |> assign(:search_results, [])
     |> assign(:show_results, false)}
  end

  # Private helper functions
  
  defp handle_search_query(query, socket) do
    trimmed_query = String.trim(query)
    
    if String.length(trimmed_query) >= 2 do
      # Check cache first
      cached_results = Map.get(socket.assigns.search_cache, trimmed_query)
      
      cond do
        # Use cached results if available and recent (within 30 seconds)
        cached_results && cache_still_valid?(cached_results.timestamp) ->
          {:noreply,
           socket
           |> assign(:search_term, query)
           |> assign(:search_results, cached_results.results)
           |> assign(:searching, false)
           |> assign(:show_results, true)}
        
        # Otherwise, perform new search
        true ->
          send(self(), {:search_people_autocomplete, socket.assigns.id, trimmed_query})
          {:noreply, 
           socket
           |> assign(:search_term, query)
           |> assign(:searching, true)
           |> assign(:show_results, true)}
      end
    else
      {:noreply,
       socket
       |> assign(:search_term, query)
       |> assign(:search_results, [])
       |> assign(:searching, false)
       |> assign(:show_results, false)}
    end
  end
  
  defp cache_still_valid?(timestamp) do
    # Cache is valid for 30 seconds
    DateTime.diff(DateTime.utc_now(), timestamp) < 30
  end

  def render(assigns) do
    ~H"""
    <div id={@id} class="relative">
      <!-- Search Input -->
      <div class="relative">
        <div class="relative">
          <input
            type="text"
            name="search"
            phx-keyup="search"
            phx-target={@myself}
            phx-debounce="300"
            value={@search_term}
            placeholder="Start typing a person's name..."
            class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm pr-8"
            autocomplete="off"
          />
          <%= if @search_term != "" do %>
            <button
              type="button"
              phx-click="clear_search"
              phx-target={@myself}
              class="absolute inset-y-0 right-0 flex items-center pr-3 text-gray-400 hover:text-gray-600"
            >
              <svg class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          <% end %>
        </div>

        <!-- Search Results Dropdown -->
        <%= if @show_results and length(@search_results) > 0 do %>
          <div class="absolute z-50 w-full mt-1 bg-white border border-gray-300 rounded-md shadow-lg max-h-60 overflow-auto">
            <%= for person <- @search_results do %>
              <button
                type="button"
                phx-click="select_person"
                phx-value-person_id={person.id}
                phx-target={@myself}
                class="w-full text-left px-4 py-2 hover:bg-gray-100 focus:bg-gray-100 focus:outline-none"
              >
                <div class="flex items-center space-x-3">
                  <%= if person.profile_path do %>
                    <img
                      src={"https://image.tmdb.org/t/p/w92#{person.profile_path}"}
                      alt={person.name}
                      class="w-8 h-8 rounded-full object-cover"
                    />
                  <% else %>
                    <div class="w-8 h-8 rounded-full bg-gray-300 flex items-center justify-center">
                      <span class="text-xs text-gray-600 font-medium">
                        <%= String.first(person.name) %>
                      </span>
                    </div>
                  <% end %>
                  <div>
                    <div class="font-medium text-gray-900"><%= person.name %></div>
                    <%= if person.known_for_department do %>
                      <div class="text-xs text-gray-500"><%= person.known_for_department %></div>
                    <% end %>
                  </div>
                </div>
              </button>
            <% end %>
          </div>
        <% end %>

        <!-- Loading indicator -->
        <%= if @searching do %>
          <div class="absolute z-40 w-full mt-1 bg-white border border-gray-300 rounded-md shadow-lg p-4">
            <div class="flex items-center justify-center">
              <svg class="animate-spin h-5 w-5 text-blue-500" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
              </svg>
              <span class="ml-2 text-sm text-gray-600">Searching...</span>
            </div>
          </div>
        <% end %>
      </div>

      <!-- Selected People Tags -->
      <%= if length(@selected_people) > 0 do %>
        <div class="mt-3">
          <label class="block text-sm font-medium text-gray-700 mb-2">
            Selected People (<%= length(@selected_people) %>)
          </label>
          <div class="flex flex-wrap gap-2">
            <%= for person <- @selected_people do %>
              <span class="inline-flex items-center px-3 py-1 rounded-full text-sm bg-blue-100 text-blue-800">
                <span class="flex items-center space-x-2">
                  <%= if person.profile_path do %>
                    <img
                      src={"https://image.tmdb.org/t/p/w92#{person.profile_path}"}
                      alt={person.name}
                      class="w-5 h-5 rounded-full object-cover"
                    />
                  <% end %>
                  <span><%= person.name %></span>
                </span>
                <button
                  type="button"
                  phx-click="remove_person"
                  phx-value-person_id={person.id}
                  phx-target={@myself}
                  class="ml-2 inline-flex items-center justify-center w-4 h-4 text-blue-600 hover:text-blue-800"
                >
                  ×
                </button>
              </span>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Hidden input for form submission -->
      <input type="hidden" name={@field_name <> "[people_ids]"} value={Enum.map_join(@selected_people, ",", & &1.id)} />
    </div>
    """
  end

  defp parse_selected_people(selected) when is_list(selected) do
    cond do
      selected == [] ->
        []
      Enum.all?(selected, &match?(%{id: _}, &1)) ->
        # Already person structs
        selected
      Enum.all?(selected, &is_integer/1) ->
        # List of integer IDs
        People.get_people_by_ids(selected)
      Enum.all?(selected, &is_binary/1) ->
        # List of string IDs
        ids =
          selected
          |> Enum.map(&Integer.parse/1)
          |> Enum.flat_map(fn
            {id, _} -> [id]
            :error -> []
          end)
        if ids == [], do: [], else: People.get_people_by_ids(ids)
      true ->
        []
    end
  end
  
  defp parse_selected_people(selected) when is_binary(selected) do
    # Parse comma-separated IDs and fetch people
    ids =
      selected
      |> String.trim()
      |> case do
        "" -> []
        s ->
          s
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(&Integer.parse/1)
          |> Enum.flat_map(fn
            {id, _} -> [id]
            :error -> []
          end)
      end
    
    if ids == [], do: [], else: People.get_people_by_ids(ids)
  end
  
  defp parse_selected_people(_), do: []
end