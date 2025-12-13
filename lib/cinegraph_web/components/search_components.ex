defmodule CinegraphWeb.SearchComponents do
  @moduledoc """
  Reusable components for search, filtering, and pagination across LiveViews.

  These components are used by MovieLive.Index, ListLive.Show, AwardsLive.Show,
  and other search-based views to eliminate template duplication.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: CinegraphWeb.Endpoint,
    router: CinegraphWeb.Router,
    statics: CinegraphWeb.static_paths()

  alias Cinegraph.Movies.Movie

  # ============================================================================
  # Search Bar
  # ============================================================================

  @doc """
  Renders a search bar with debounced input.

  ## Examples

      <.search_bar
        search_term={@search_term}
        placeholder="Search movies..."
        show_clear={true}
      />

  ## Attributes

  - `search_term` - Current search term value
  - `placeholder` - Placeholder text for the input (default: "Search...")
  - `show_clear` - Whether to show clear button when search has value (default: true)
  - `debounce` - Debounce delay in ms (default: 300)
  """
  attr :search_term, :string, default: ""
  attr :placeholder, :string, default: "Search..."
  attr :show_clear, :boolean, default: true
  attr :debounce, :integer, default: 300

  def search_bar(assigns) do
    ~H"""
    <div class="w-full lg:w-96">
      <form phx-submit="search" class="relative">
        <input
          type="text"
          name="search"
          value={@search_term}
          placeholder={@placeholder}
          class="w-full pl-10 pr-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
          phx-change="search"
          phx-debounce={@debounce}
        />
        <svg
          class="absolute left-3 top-2.5 w-5 h-5 text-gray-400"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
          />
        </svg>
        <%= if @show_clear && @search_term != "" do %>
          <button
            type="button"
            phx-click="search"
            phx-value-search=""
            class="absolute right-3 top-2.5 text-gray-400 hover:text-gray-600"
            aria-label="Clear search"
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
        <% end %>
      </form>
    </div>
    """
  end

  # ============================================================================
  # Filter Toggle Button
  # ============================================================================

  @doc """
  Renders a filter toggle button with active indicator.

  ## Examples

      <.filter_toggle show_filters={@show_filters} has_active_filters={has_active_filters(@filters)} />

  ## Attributes

  - `show_filters` - Whether filters panel is currently shown
  - `has_active_filters` - Whether any filters are currently active
  - `label_show` - Label when filters are hidden (default: "Show Filters")
  - `label_hide` - Label when filters are shown (default: "Hide Filters")
  """
  attr :show_filters, :boolean, required: true
  attr :has_active_filters, :boolean, default: false
  attr :label_show, :string, default: "Show Filters"
  attr :label_hide, :string, default: "Hide Filters"

  def filter_toggle(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_filters"
      class="inline-flex items-center px-4 py-2 border border-gray-300 rounded-md shadow-sm text-sm font-medium text-gray-700 bg-white hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500"
    >
      <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M3 4a1 1 0 011-1h16a1 1 0 011 1v2.586a1 1 0 01-.293.707l-6.414 6.414a1 1 0 00-.293.707V17l-4 4v-6.586a1 1 0 00-.293-.707L3.293 7.293A1 1 0 013 6.586V4z"
        />
      </svg>
      <%= if @show_filters do %>
        {@label_hide}
      <% else %>
        {@label_show}
      <% end %>
      <%= if @has_active_filters do %>
        <span class="ml-2 inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-blue-100 text-blue-800">
          Active
        </span>
      <% end %>
    </button>
    """
  end

  # ============================================================================
  # Active Filters Display
  # ============================================================================

  @doc """
  Renders active filter pills with remove buttons.

  ## Examples

      <.active_filters_display
        filters={get_active_filters(@filters, assigns)}
        on_clear="clear_filters"
        on_remove="remove_filter"
      />

  ## Attributes

  - `filters` - List of active filter maps with :key, :label, :display_value
  - `on_clear` - Event name for clearing all filters (default: "clear_filters")
  - `on_remove` - Event name for removing single filter (default: "remove_filter")
  """
  attr :filters, :list, required: true
  attr :on_clear, :string, default: "clear_filters"
  attr :on_remove, :string, default: "remove_filter"

  def active_filters_display(assigns) do
    ~H"""
    <div class="mt-4 bg-white p-3 rounded-lg shadow-sm border border-gray-200">
      <div class="flex items-center justify-between mb-2">
        <span class="text-sm font-medium text-gray-700">Active Filters:</span>
        <button type="button" phx-click={@on_clear} class="text-sm text-red-600 hover:text-red-800">
          Clear All
        </button>
      </div>
      <div class="flex flex-wrap gap-2">
        <%= for filter <- @filters do %>
          <span class="inline-flex items-center px-3 py-1 rounded-full text-sm bg-blue-100 text-blue-800">
            {filter.label}: {filter.display_value}
            <button
              type="button"
              phx-click={@on_remove}
              phx-value-filter={filter.key}
              class="ml-2 inline-flex items-center justify-center w-4 h-4 text-blue-600 hover:text-blue-800"
              title="Remove this filter"
              aria-label={"Remove #{filter.label} filter"}
            >
              ×
            </button>
          </span>
        <% end %>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Movie Card
  # ============================================================================

  @doc """
  Renders a movie card for grid display.

  ## Examples

      <.movie_card movie={movie} />
      <.movie_card movie={movie} show_scores={true} />

  ## Attributes

  - `movie` - The movie struct to display
  - `show_scores` - Whether to show discovery scores (default: false)
  """
  attr :movie, :map, required: true
  attr :show_scores, :boolean, default: false

  def movie_card(assigns) do
    ~H"""
    <.link navigate={~p"/movies/#{@movie.slug || @movie.id}"} class="group block">
      <div class="bg-white rounded-lg shadow-md hover:shadow-lg transition-shadow duration-200 overflow-hidden">
        <!-- Movie Poster -->
        <div class="aspect-[2/3] bg-gray-200 relative">
          <%= if @movie.poster_path do %>
            <img
              src={Movie.poster_url(@movie, "w500")}
              alt={@movie.title}
              class="w-full h-full object-cover"
              loading="lazy"
            />
          <% else %>
            <div class="w-full h-full flex items-center justify-center">
              <span class="text-gray-400 text-lg">No Image</span>
            </div>
          <% end %>
        </div>
        <!-- Movie Info -->
        <div class="p-4">
          <h3 class="font-semibold text-lg text-gray-900 group-hover:text-blue-600 transition-colors line-clamp-2">
            {@movie.title}
          </h3>

          <%= if @movie.release_date do %>
            <p class="text-gray-500 text-sm mt-1">
              {Calendar.strftime(@movie.release_date, "%Y")}
            </p>
          <% end %>
        </div>
      </div>
    </.link>
    """
  end

  # ============================================================================
  # Movie Grid
  # ============================================================================

  @doc """
  Renders a grid of movie cards.

  ## Examples

      <.movie_grid movies={@movies} />
      <.movie_grid movies={@movies} show_scores={true} />

  ## Attributes

  - `movies` - List of movie structs to display
  - `show_scores` - Whether to show discovery scores (default: false)
  """
  attr :movies, :list, required: true
  attr :show_scores, :boolean, default: false

  def movie_grid(assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6">
      <%= for movie <- @movies do %>
        <.movie_card movie={movie} show_scores={@show_scores} />
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Empty State
  # ============================================================================

  @doc """
  Renders an empty state message when no results are found.

  ## Examples

      <.empty_state />
      <.empty_state title="No films found" message="Try adjusting your search criteria." />

  ## Attributes

  - `title` - Title text (default: "No movies found")
  - `message` - Message text (default: "Try adjusting your filters or search criteria.")
  - `icon` - Icon type: :movies, :awards, :search (default: :movies)
  """
  attr :title, :string, default: "No movies found"
  attr :message, :string, default: "Try adjusting your filters or search criteria."
  attr :icon, :atom, default: :movies

  def empty_state(assigns) do
    ~H"""
    <div class="text-center py-12">
      <div class="mx-auto h-12 w-12 text-gray-400">
        <%= case @icon do %>
          <% :awards -> %>
            <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M5 3v4M3 5h4M6 17v4m-2-2h4m5-16l2.286 6.857L21 12l-5.714 2.143L13 21l-2.286-6.857L5 12l5.714-2.143L13 3z"
              />
            </svg>
          <% :search -> %>
            <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
              />
            </svg>
          <% _ -> %>
            <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M7 4V2a1 1 0 011-1h8a1 1 0 011 1v2h4a1 1 0 011 1v1a1 1 0 01-1 1H3a1 1 0 01-1-1V5a1 1 0 011-1h4zm0 0v14a2 2 0 002 2h6a2 2 0 002-2V4H7z"
              />
            </svg>
        <% end %>
      </div>
      <h3 class="mt-2 text-sm font-medium text-gray-900">{@title}</h3>
      <p class="mt-1 text-sm text-gray-500">{@message}</p>
    </div>
    """
  end

  # ============================================================================
  # Pagination
  # ============================================================================

  @doc """
  Renders pagination controls for search results.

  ## Examples

      <.pagination
        page={@page}
        total_pages={@total_pages}
        build_path={fn page -> ~p"/lists/\#{@list_info.slug}?\#{build_pagination_params(assigns, page)}" end}
      />

  ## Attributes

  - `page` - Current page number
  - `total_pages` - Total number of pages
  - `build_path` - Function that takes a page number and returns the path
  """
  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :build_path, :any, required: true

  def pagination(assigns) do
    assigns = assign(assigns, :page_range, pagination_range(assigns.page, assigns.total_pages))

    ~H"""
    <%= if @total_pages > 1 do %>
      <div class="mt-8 flex items-center justify-between">
        <!-- Mobile pagination -->
        <div class="flex flex-1 justify-between sm:hidden">
          <%= if @page > 1 do %>
            <.link
              patch={@build_path.(@page - 1)}
              class="relative inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50"
            >
              Previous
            </.link>
          <% else %>
            <span class="relative inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md text-gray-400 bg-gray-100 cursor-not-allowed">
              Previous
            </span>
          <% end %>

          <%= if @page < @total_pages do %>
            <.link
              patch={@build_path.(@page + 1)}
              class="ml-3 relative inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50"
            >
              Next
            </.link>
          <% else %>
            <span class="ml-3 relative inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md text-gray-400 bg-gray-100 cursor-not-allowed">
              Next
            </span>
          <% end %>
        </div>
        <!-- Desktop pagination -->
        <div class="hidden sm:flex-1 sm:flex sm:items-center sm:justify-between">
          <div>
            <p class="text-sm text-gray-700">
              Page <span class="font-medium">{@page}</span>
              of <span class="font-medium">{@total_pages}</span>
            </p>
          </div>

          <div>
            <nav
              class="relative z-0 inline-flex rounded-md shadow-sm -space-x-px"
              aria-label="Pagination"
            >
              <!-- Previous button -->
              <%= if @page > 1 do %>
                <.link
                  patch={@build_path.(@page - 1)}
                  class="relative inline-flex items-center px-2 py-2 rounded-l-md border border-gray-300 bg-white text-sm font-medium text-gray-500 hover:bg-gray-50"
                >
                  <span class="sr-only">Previous</span>
                  <svg class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
                    <path
                      fill-rule="evenodd"
                      d="M12.707 5.293a1 1 0 010 1.414L9.414 10l3.293 3.293a1 1 0 01-1.414 1.414l-4-4a1 1 0 010-1.414l4-4a1 1 0 011.414 0z"
                      clip-rule="evenodd"
                    />
                  </svg>
                </.link>
              <% else %>
                <span class="relative inline-flex items-center px-2 py-2 rounded-l-md border border-gray-300 bg-gray-100 text-sm font-medium text-gray-400 cursor-not-allowed">
                  <span class="sr-only">Previous</span>
                  <svg class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
                    <path
                      fill-rule="evenodd"
                      d="M12.707 5.293a1 1 0 010 1.414L9.414 10l3.293 3.293a1 1 0 01-1.414 1.414l-4-4a1 1 0 010-1.414l4-4a1 1 0 011.414 0z"
                      clip-rule="evenodd"
                    />
                  </svg>
                </span>
              <% end %>
              <!-- Page numbers -->
              <%= for page_num <- @page_range do %>
                <%= if page_num == "..." do %>
                  <span class="relative inline-flex items-center px-4 py-2 border border-gray-300 bg-white text-sm font-medium text-gray-700">
                    ...
                  </span>
                <% else %>
                  <.link
                    patch={@build_path.(page_num)}
                    class={[
                      "relative inline-flex items-center px-4 py-2 border text-sm font-medium",
                      if(page_num == @page,
                        do: "z-10 bg-blue-50 border-blue-500 text-blue-600",
                        else: "bg-white border-gray-300 text-gray-500 hover:bg-gray-50"
                      )
                    ]}
                  >
                    {page_num}
                  </.link>
                <% end %>
              <% end %>
              <!-- Next button -->
              <%= if @page < @total_pages do %>
                <.link
                  patch={@build_path.(@page + 1)}
                  class="relative inline-flex items-center px-2 py-2 rounded-r-md border border-gray-300 bg-white text-sm font-medium text-gray-500 hover:bg-gray-50"
                >
                  <span class="sr-only">Next</span>
                  <svg class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
                    <path
                      fill-rule="evenodd"
                      d="M7.293 14.707a1 1 0 010-1.414L10.586 10 7.293 6.707a1 1 0 011.414-1.414l4 4a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0z"
                      clip-rule="evenodd"
                    />
                  </svg>
                </.link>
              <% else %>
                <span class="relative inline-flex items-center px-2 py-2 rounded-r-md border border-gray-300 bg-gray-100 text-sm font-medium text-gray-400 cursor-not-allowed">
                  <span class="sr-only">Next</span>
                  <svg class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
                    <path
                      fill-rule="evenodd"
                      d="M7.293 14.707a1 1 0 010-1.414L10.586 10 7.293 6.707a1 1 0 011.414-1.414l4 4a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0z"
                      clip-rule="evenodd"
                    />
                  </svg>
                </span>
              <% end %>
            </nav>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  # ============================================================================
  # Results Count
  # ============================================================================

  @doc """
  Renders a results count message.

  ## Examples

      <.results_count page={@page} per_page={@per_page} total={@total_movies} />

  ## Attributes

  - `page` - Current page number
  - `per_page` - Items per page
  - `total` - Total number of items
  - `item_name` - Name of items (default: "films")
  """
  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :total, :integer, required: true
  attr :item_name, :string, default: "films"

  def results_count(assigns) do
    ~H"""
    <p class="text-gray-500 mt-2">
      <%= if @total > 0 do %>
        Showing {(@page - 1) * @per_page + 1} - {min(@page * @per_page, @total)} of {@total} {@item_name}
      <% else %>
        No {@item_name} found
      <% end %>
    </p>
    """
  end

  # ============================================================================
  # Back Navigation Link
  # ============================================================================

  @doc """
  Renders a back navigation link.

  ## Examples

      <.back_link navigate={~p"/lists"} label="Back to Lists" />

  ## Attributes

  - `navigate` - Path to navigate to
  - `label` - Link text
  """
  attr :navigate, :string, required: true
  attr :label, :string, required: true

  def back_link(assigns) do
    ~H"""
    <div class="mb-6">
      <.link navigate={@navigate} class="inline-flex items-center text-blue-600 hover:text-blue-800">
        <svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
        </svg>
        {@label}
      </.link>
    </div>
    """
  end

  # ============================================================================
  # Private Helper Functions
  # ============================================================================

  defp pagination_range(_current_page, total_pages) when total_pages <= 7 do
    1..total_pages |> Enum.to_list()
  end

  defp pagination_range(current_page, total_pages) do
    cond do
      current_page <= 3 ->
        [1, 2, 3, 4, "...", total_pages]

      current_page >= total_pages - 2 ->
        [1, "...", total_pages - 3, total_pages - 2, total_pages - 1, total_pages]

      true ->
        [1, "...", current_page - 1, current_page, current_page + 1, "...", total_pages]
    end
  end
end
