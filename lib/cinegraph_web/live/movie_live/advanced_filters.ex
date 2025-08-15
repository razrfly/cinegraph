defmodule CinegraphWeb.MovieLive.AdvancedFilters do
  @moduledoc """
  Advanced filtering component for movies including awards, ratings, people, and metric scores.
  """
  
  use Phoenix.Component
  
  @advanced_keys [
    "award_status", "festival_id", "award_year_from", "award_year_to",
    "tmdb_min", "tmdb_max", "imdb_min", "imdb_max",
    "metacritic_min", "metacritic_max", "rt_critics_min", "rt_audience_min",
    "director_id", "actor_ids", "person_ids",
    "popular_opinion_min", "critical_acclaim_min", 
    "industry_recognition_min", "cultural_impact_min", "people_quality_min"
  ]
  
  def advanced_filters(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Awards & Recognition Section -->
      <div class="border-t pt-4">
        <h3 class="text-sm font-semibold text-gray-900 mb-3">🏆 Awards & Recognition</h3>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
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
                  <%= org.name %> (<%= org.abbreviation %>)
                </option>
              <% end %>
            </select>
          </div>
          
          <!-- Award Year Range -->
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
      
      <!-- Ratings Section -->
      <div class="border-t pt-4">
        <h3 class="text-sm font-semibold text-gray-900 mb-3">⭐ Ratings</h3>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
          <!-- TMDb Rating -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              TMDb Rating
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
          
          <!-- IMDb Rating -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              IMDb Rating
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
          
          <!-- Metacritic Score -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Metacritic Score
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
          
          <!-- Rotten Tomatoes -->
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
      </div>
      
      <!-- People Section -->
      <div class="border-t pt-4">
        <h3 class="text-sm font-semibold text-gray-900 mb-3">👥 People</h3>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          <!-- Director Search -->
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
          
          <!-- Actor Search -->
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
          
          <!-- Any Person -->
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
      </div>
      
      <!-- Discovery Metrics Section -->
      <div class="border-t pt-4">
        <h3 class="text-sm font-semibold text-gray-900 mb-3">📊 Discovery Metrics</h3>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
          <!-- Popular Opinion -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              🎬 Popular Opinion
              <span class="text-xs text-gray-500 ml-1">(0-1)</span>
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
          
          <!-- Critical Acclaim -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              🏆 Critical Acclaim
              <span class="text-xs text-gray-500 ml-1">(0-1)</span>
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
          
          <!-- Industry Recognition -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              🌟 Industry Recognition
              <span class="text-xs text-gray-500 ml-1">(0-1)</span>
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
          
          <!-- Cultural Impact -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              📚 Cultural Impact
              <span class="text-xs text-gray-500 ml-1">(0-1)</span>
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
          
          <!-- People Quality -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              👥 People Quality
              <span class="text-xs text-gray-500 ml-1">(0-1)</span>
            </label>
            <input
              type="number"
              name="filters[people_quality_min]"
              value={@filters["people_quality_min"]}
              placeholder="Min score"
              min="0"
              max="1"
              step="0.1"
              class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
            />
          </div>
        </div>
      </div>
      
      <!-- Active Filters Display -->
      <%= if has_active_advanced_filters(@filters) do %>
        <div class="border-t pt-4">
          <h3 class="text-sm font-semibold text-gray-900 mb-2">Active Advanced Filters</h3>
          <div class="flex flex-wrap gap-2">
            <%= for {key, value} <- get_active_advanced_filters(@filters) do %>
              <span class="inline-flex items-center px-3 py-1 rounded-full text-sm bg-blue-100 text-blue-800">
                <%= format_filter_label(key) %>: <%= format_filter_value(key, value) %>
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
  
  def has_active_advanced_filters(filters) do
    Enum.any?(@advanced_keys, fn key ->
      value = Map.get(filters, key)
      value not in [nil, "", []]
    end)
  end
  
  def get_active_advanced_filters(filters) do
    filters
    |> Map.take(@advanced_keys)
    |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)
  end
  
  def format_filter_label(key) do
    case key do
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
      "people_quality_min" -> "People Quality"
      _ -> key |> String.replace("_", " ") |> String.capitalize()
    end
  end
  
  def format_filter_value(_key, value) when is_list(value) do
    Enum.join(value, ", ")
  end
  
  def format_filter_value(key, value) do
    cond do
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