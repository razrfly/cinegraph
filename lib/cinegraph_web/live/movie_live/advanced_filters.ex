defmodule CinegraphWeb.MovieLive.AdvancedFilters do
  @moduledoc """
  Advanced filtering component for movies with improved UX and autocomplete search.
  """

  use Phoenix.Component

  def advanced_filters(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- People Search Section -->
      <div class="border-t pt-4">
        <h3 class="text-sm font-semibold text-gray-900 mb-3">👥 People</h3>
        <%= if should_render_people_search?(@filters) do %>
          <.live_component
            module={CinegraphWeb.Components.PersonAutocomplete}
            id="people-search"
            field_name="filters[people_search]"
            selected_people={get_selected_people(@filters)}
            selected_role={get_selected_role(@filters)}
            search_term={get_search_term(@filters)}
          />
        <% else %>
          <!-- Lightweight search input that activates full component -->
          <div class="space-y-2">
            <label class="block text-sm font-medium text-gray-700">
              Search People
            </label>
            <input
              type="text"
              placeholder="Start typing a person's name..."
              phx-focus="activate_people_search"
              phx-keyup="activate_people_search"
              phx-debounce="100"
              class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
              autocomplete="off"
            />
            <p class="text-xs text-gray-500">
              Search and filter movies by cast and crew members
            </p>
          </div>
        <% end %>
      </div>

      <!-- Rating Quality Section -->
      <div class="border-t pt-4">
        <h3 class="text-sm font-semibold text-gray-900 mb-3">⭐ Rating Quality</h3>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Rating Threshold
            </label>
            <select
              name="filters[rating_preset]"
              value={@filters["rating_preset"]}
              class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
            >
              <option value="">Any Rating</option>
              <option value="highly_rated">Highly Rated (7.5+ avg)</option>
              <option value="well_reviewed">Well Reviewed (6.0+ avg)</option>
              <option value="critically_acclaimed">Critically Acclaimed (Critics' Choice)</option>
            </select>
          </div>
        </div>
      </div>

      <!-- Discovery & Awards Section -->
      <div class="border-t pt-4">
        <h3 class="text-sm font-semibold text-gray-900 mb-3">🏆 Discovery & Awards</h3>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <!-- Discovery Type -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Discovery Type
            </label>
            <select
              name="filters[discovery_preset]"
              value={@filters["discovery_preset"]}
              class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
            >
              <option value="">All Movies</option>
              <option value="award_winners">🏆 Award Winners</option>
              <option value="popular_favorites">🎬 Popular Favorites</option>
              <option value="critically_acclaimed">📰 Critically Acclaimed</option>
              <option value="hidden_gems">💎 Hidden Gems</option>
            </select>
          </div>

          <!-- Award Era -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Award Era
            </label>
            <select
              name="filters[award_preset]"
              value={@filters["award_preset"]}
              class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
            >
              <option value="">All Time</option>
              <option value="recent_awards">Recent Awards (2020s)</option>
              <option value="2010s">2010s</option>
              <option value="2000s">2000s</option>
              <option value="classic">Classic Era (pre-2000)</option>
            </select>
          </div>
        </div>
      </div>

      <!-- Traditional Awards Section (Simplified) -->
      <div class="border-t pt-4">
        <h3 class="text-sm font-semibold text-gray-900 mb-3">🎪 Traditional Awards</h3>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <!-- Award Status -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Award Status
            </label>
            <select
              name="filters[award_status]"
              value={@filters["award_status"]}
              class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
            >
              <option value="">All Movies</option>
              <option value="any_nomination">Any Nomination</option>
              <option value="won">Award Winners</option>
              <option value="nominated_only">Nominated Only</option>
              <option value="multiple_awards">Multiple Awards</option>
            </select>
          </div>
          
          <!-- Festival Selection -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Festival/Organization
            </label>
            <select
              name="filters[festival_id]"
              value={@filters["festival_id"]}
              class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
            >
              <option value="">All Festivals</option>
              <%= for org <- @festival_organizations do %>
                <option value={org.id}>
                  {org.name} ({org.abbreviation})
                </option>
              <% end %>
            </select>
          </div>
        </div>
      </div>

      <!-- Legacy Filters (Collapsible) -->
      <div class="border-t pt-4">
        <details class="group">
          <summary class="flex items-center justify-between cursor-pointer text-sm font-semibold text-gray-900 mb-3">
            <span>⚙️ Legacy Filters (Advanced Users)</span>
            <svg class="w-4 h-4 text-gray-500 group-open:rotate-180 transition-transform" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
            </svg>
          </summary>
          <div class="mt-4 space-y-4">
            <!-- Legacy People IDs -->
            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  Director ID
                </label>
                <input
                  type="number"
                  name="filters[director_id]"
                  value={@filters["director_id"]}
                  placeholder="Director ID"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                />
              </div>
              
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  Actor IDs
                </label>
                <input
                  type="text"
                  name="filters[actor_ids]"
                  value={@filters["actor_ids"]}
                  placeholder="Comma-separated IDs"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                />
              </div>
              
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  Any Cast/Crew IDs
                </label>
                <input
                  type="text"
                  name="filters[person_ids]"
                  value={@filters["person_ids"]}
                  placeholder="Comma-separated IDs"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                />
              </div>
            </div>

            <!-- Legacy Rating Ranges -->
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  TMDb Rating Range
                </label>
                <div class="flex gap-2">
                  <input
                    type="number"
                    name="filters[tmdb_min]"
                    value={@filters["tmdb_min"]}
                    placeholder="Min"
                    min="0"
                    max="10"
                    step="0.1"
                    class="w-1/2 rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                  />
                  <input
                    type="number"
                    name="filters[tmdb_max]"
                    value={@filters["tmdb_max"]}
                    placeholder="Max"
                    min="0"
                    max="10"
                    step="0.1"
                    class="w-1/2 rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                  />
                </div>
              </div>
              
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  IMDb Rating Range
                </label>
                <div class="flex gap-2">
                  <input
                    type="number"
                    name="filters[imdb_min]"
                    value={@filters["imdb_min"]}
                    placeholder="Min"
                    min="0"
                    max="10"
                    step="0.1"
                    class="w-1/2 rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                  />
                  <input
                    type="number"
                    name="filters[imdb_max]"
                    value={@filters["imdb_max"]}
                    placeholder="Max"
                    min="0"
                    max="10"
                    step="0.1"
                    class="w-1/2 rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                  />
                </div>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  Metacritic Range
                </label>
                <div class="flex gap-2">
                  <input
                    type="number"
                    name="filters[metacritic_min]"
                    value={@filters["metacritic_min"]}
                    placeholder="Min"
                    min="0"
                    max="100"
                    step="1"
                    class="w-1/2 rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                  />
                  <input
                    type="number"
                    name="filters[metacritic_max]"
                    value={@filters["metacritic_max"]}
                    placeholder="Max"
                    min="0"
                    max="100"
                    step="1"
                    class="w-1/2 rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                  />
                </div>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  Rotten Tomatoes
                </label>
                <div class="space-y-1">
                  <input
                    type="number"
                    name="filters[rt_critics_min]"
                    value={@filters["rt_critics_min"]}
                    placeholder="Critics Min %"
                    min="0"
                    max="100"
                    step="1"
                    class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                  />
                  <input
                    type="number"
                    name="filters[rt_audience_min]"
                    value={@filters["rt_audience_min"]}
                    placeholder="Audience Min %"
                    min="0"
                    max="100"
                    step="1"
                    class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                  />
                </div>
              </div>
            </div>

            <!-- Legacy Discovery Metrics -->
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  🎬 Popular Opinion <span class="text-xs text-gray-500 ml-1">(0-1)</span>
                </label>
                <input
                  type="number"
                  name="filters[popular_opinion_min]"
                  value={@filters["popular_opinion_min"]}
                  placeholder="Min score"
                  min="0"
                  max="1"
                  step="0.1"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                />
              </div>
              
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  🏆 Critical Acclaim <span class="text-xs text-gray-500 ml-1">(0-1)</span>
                </label>
                <input
                  type="number"
                  name="filters[critical_acclaim_min]"
                  value={@filters["critical_acclaim_min"]}
                  placeholder="Min score"
                  min="0"
                  max="1"
                  step="0.1"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                />
              </div>
              
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  🌟 Industry Recognition <span class="text-xs text-gray-500 ml-1">(0-1)</span>
                </label>
                <input
                  type="number"
                  name="filters[industry_recognition_min]"
                  value={@filters["industry_recognition_min"]}
                  placeholder="Min score"
                  min="0"
                  max="1"
                  step="0.1"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                />
              </div>
              
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  📚 Cultural Impact <span class="text-xs text-gray-500 ml-1">(0-1)</span>
                </label>
                <input
                  type="number"
                  name="filters[cultural_impact_min]"
                  value={@filters["cultural_impact_min"]}
                  placeholder="Min score"
                  min="0"
                  max="1"
                  step="0.1"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                />
              </div>
            </div>

            <!-- Legacy Award Year Range -->
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  Award Year Range
                </label>
                <div class="flex gap-2">
                  <input
                    type="number"
                    name="filters[award_year_from]"
                    value={@filters["award_year_from"]}
                    placeholder="From"
                    min="1920"
                    max={Date.utc_today().year}
                    class="w-1/2 rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                  />
                  <input
                    type="number"
                    name="filters[award_year_to]"
                    value={@filters["award_year_to"]}
                    placeholder="To"
                    min="1920"
                    max={Date.utc_today().year}
                    class="w-1/2 rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
                  />
                </div>
              </div>
            </div>
          </div>
        </details>
      </div>
      
      <!-- Active Filters Display -->
      <%= if has_active_advanced_filters(@filters) do %>
        <div class="border-t pt-4">
          <h3 class="text-sm font-semibold text-gray-900 mb-2">Active Advanced Filters</h3>
          <div class="flex flex-wrap gap-2">
            <%= for {key, value} <- get_active_advanced_filters(@filters) do %>
              <span class="inline-flex items-center px-3 py-1 rounded-full text-sm bg-blue-100 text-blue-800">
                {format_filter_label(key)}: {format_filter_value(key, value)}
                <button
                  type="button"
                  phx-click="remove_filter"
                  phx-value-filter={key}
                  class="ml-2 inline-flex items-center justify-center w-4 h-4 text-blue-600 hover:text-blue-800"
                >
                  ×
                </button>
              </span>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp get_selected_people(filters) do
    case filters["people_search"] do
      %{"people_ids" => people_ids} when people_ids != "" ->
        # Parse existing selected people from filters
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
          Cinegraph.People.get_people_by_ids(ids)
        end
      _ ->
        []
    end
  end

  defp get_selected_role(filters) do
    case filters["people_search"] do
      %{"role_filter" => role_filter} -> role_filter || "any"
      _ -> "any"
    end
  end

  defp get_search_term(filters) do
    case filters["people_search"] do
      %{"search_term" => search_term} -> search_term || ""
      _ -> ""
    end
  end

  defp should_render_people_search?(filters) do
    case filters["people_search"] do
      %{"people_ids" => _people_ids, "role_filter" => _role_filter} -> true
      %{"people_ids" => _people_ids} -> true  # Allow just people_ids
      %{"role_filter" => _role_filter} -> true  # Allow just role_filter
      %{"search_term" => _search_term} -> true  # Allow just search_term
      _ -> false
    end
  end

  def has_active_advanced_filters(filters) do
    # New simplified filters
    new_filter_keys = [
      "people_search",
      "rating_preset",
      "discovery_preset", 
      "award_preset"
    ]

    # Legacy filters
    legacy_keys = [
      "award_status",
      "festival_id",
      "award_year_from",
      "award_year_to",
      "tmdb_min",
      "tmdb_max",
      "imdb_min",
      "imdb_max",
      "metacritic_min",
      "metacritic_max",
      "rt_critics_min",
      "rt_audience_min",
      "director_id",
      "actor_ids",
      "person_ids",
      "popular_opinion_min",
      "critical_acclaim_min",
      "industry_recognition_min",
      "cultural_impact_min"
    ]

    # Check new simplified filters
    new_filters_active = Enum.any?(new_filter_keys, fn key ->
      case key do
        "people_search" ->
          case Map.get(filters, key) do
            %{"people_ids" => people_ids} -> people_ids not in [nil, ""]
            _ -> false
          end
        _ ->
          value = Map.get(filters, key)
          value not in [nil, "", []]
      end
    end)

    # Check legacy filters
    legacy_filters_active = Enum.any?(legacy_keys, fn key ->
      value = Map.get(filters, key)
      value not in [nil, "", []]
    end)

    new_filters_active || legacy_filters_active
  end

  def get_active_advanced_filters(filters) do
    # Combine new and legacy filters
    new_filter_keys = [
      "people_search",
      "rating_preset",
      "discovery_preset", 
      "award_preset"
    ]

    legacy_keys = [
      "award_status",
      "festival_id", 
      "award_year_from",
      "award_year_to",
      "tmdb_min",
      "tmdb_max",
      "imdb_min",
      "imdb_max",
      "metacritic_min",
      "metacritic_max",
      "rt_critics_min",
      "rt_audience_min",
      "director_id",
      "actor_ids",
      "person_ids",
      "popular_opinion_min",
      "critical_acclaim_min",
      "industry_recognition_min",
      "cultural_impact_min"
    ]

    # Get active new filters
    new_active = 
      new_filter_keys
      |> Enum.map(fn key ->
        case key do
          "people_search" ->
            case Map.get(filters, key) do
              %{"people_ids" => people_ids} when people_ids not in [nil, ""] ->
                {key, people_ids}
              _ -> nil
            end
          _ ->
            case Map.get(filters, key) do
              value when value not in [nil, "", []] -> {key, value}
              _ -> nil
            end
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Get active legacy filters  
    legacy_active = 
      filters
      |> Map.take(legacy_keys)
      |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)

    new_active ++ legacy_active
  end

  def format_filter_label(key) do
    case key do
      # New simplified filters
      "people_search" -> "People"
      "rating_preset" -> "Rating Quality"
      "discovery_preset" -> "Discovery Type"
      "award_preset" -> "Award Era"
      
      # Legacy filters
      "award_status" -> "Award Status"
      "festival_id" -> "Festival"
      "award_year_from" -> "Award Year From"
      "award_year_to" -> "Award Year To"
      "tmdb_min" -> "TMDb Min"
      "tmdb_max" -> "TMDb Max"
      "imdb_min" -> "IMDb Min"
      "imdb_max" -> "IMDb Max"
      "metacritic_min" -> "Metacritic Min"
      "metacritic_max" -> "Metacritic Max"
      "rt_critics_min" -> "RT Critics Min"
      "rt_audience_min" -> "RT Audience Min"
      "director_id" -> "Director"
      "actor_ids" -> "Actors"
      "person_ids" -> "People"
      "popular_opinion_min" -> "Popular Opinion"
      "critical_acclaim_min" -> "Critical Acclaim"
      "industry_recognition_min" -> "Industry Recognition"
      "cultural_impact_min" -> "Cultural Impact"
      _ -> key |> String.replace("_", " ") |> String.capitalize()
    end
  end

  def format_filter_value(_key, value) when is_list(value) do
    Enum.join(value, ", ")
  end

  def format_filter_value(key, value) do
    cond do
      # New simplified filter values
      key == "rating_preset" ->
        case value do
          "highly_rated" -> "Highly Rated (7.5+)"
          "well_reviewed" -> "Well Reviewed (6.0+)"
          "critically_acclaimed" -> "Critically Acclaimed"
          _ -> value
        end

      key == "discovery_preset" ->
        case value do
          "award_winners" -> "🏆 Award Winners"
          "popular_favorites" -> "🎬 Popular Favorites"
          "critically_acclaimed" -> "📰 Critically Acclaimed"
          "hidden_gems" -> "💎 Hidden Gems"
          _ -> value
        end

      key == "award_preset" ->
        case value do
          "recent_awards" -> "Recent Awards (2020s)"
          "2010s" -> "2010s"
          "2000s" -> "2000s"
          "classic" -> "Classic Era (pre-2000)"
          _ -> value
        end

      key == "people_search" ->
        # Handle comma-separated person IDs
        if String.contains?(value, ",") do
          ids = 
            value
            |> String.split(",")
            |> Enum.take(3)
            |> Enum.map(&String.trim/1)
            |> Enum.map(&Integer.parse/1)
            |> Enum.flat_map(fn
              {id, _} -> [id]
              :error -> []
            end)
          
          people_names = 
            if ids == [] do
              []
            else
              Cinegraph.People.get_people_by_ids(ids)
              |> Enum.map(& &1.name)
            end
          
          case length(people_names) do
            0 -> "Unknown People"
            1 -> Enum.at(people_names, 0)
            2 -> Enum.join(people_names, ", ")
            _ -> "#{Enum.at(people_names, 0)}, #{Enum.at(people_names, 1)} +#{length(people_names) - 2} more"
          end
        else
          case Integer.parse(value) do
            {id, _} ->
              case Cinegraph.People.get_person(id) do
                nil -> "Unknown Person"
                person -> person.name
              end
            :error ->
              "Invalid ID"
          end
        end

      # Legacy filter values
      key in ["award_status"] ->
        case value do
          "any_nomination" -> "Any Nomination"
          "won" -> "Winners"
          "nominated_only" -> "Nominated Only"
          "multiple_awards" -> "Multiple Awards"
          _ -> value
        end

      key =~ ~r/_min$|_max$/ and is_binary(value) ->
        value

      true ->
        to_string(value)
    end
  end
end
