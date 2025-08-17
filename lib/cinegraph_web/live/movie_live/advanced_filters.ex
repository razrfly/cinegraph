defmodule CinegraphWeb.MovieLive.AdvancedFilters do
  @moduledoc """
  Advanced filtering component for movies with improved UX and autocomplete search.
  """

  use Phoenix.Component
  require Logger

  def advanced_filters(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Date & Time Filters (moved from basic) -->
      <div class="border-t pt-4">
        <h3 class="text-sm font-semibold text-gray-900 mb-3">📅 Date & Duration</h3>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          <!-- Year Range -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Year Range
            </label>
            <div class="flex gap-2">
              <input
                type="number"
                name="filters[year_from]"
                value={@filters["year_from"]}
                placeholder="From"
                min="1900"
                max={Date.utc_today().year}
                class="w-1/2 rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
              />
              <input
                type="number"
                name="filters[year_to]"
                value={@filters["year_to"]}
                placeholder="To"
                min="1900"
                max={Date.utc_today().year}
                class="w-1/2 rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
              />
            </div>
          </div>
          
    <!-- Runtime Range -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Runtime (minutes)
            </label>
            <div class="flex gap-2">
              <input
                type="number"
                name="filters[runtime_min]"
                value={@filters["runtime_min"]}
                placeholder="Min"
                min="0"
                max="500"
                class="w-1/2 rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
              />
              <input
                type="number"
                name="filters[runtime_max]"
                value={@filters["runtime_max"]}
                placeholder="Max"
                min="0"
                max="500"
                class="w-1/2 rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
              />
            </div>
          </div>
        </div>
      </div>
      
    <!-- Production Details (moved from basic) -->
      <div class="border-t pt-4">
        <h3 class="text-sm font-semibold text-gray-900 mb-3">🌍 Production Details</h3>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <!-- Country Filter -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Production Countries
            </label>
            <select
              name="filters[country_id]"
              class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
            >
              <option value="" selected={@filters["country_id"] in [nil, ""]}>All Countries</option>
              <option value="US" selected={@filters["country_id"] == "US"}>United States</option>
              <option value="GB" selected={@filters["country_id"] == "GB"}>United Kingdom</option>
              <option value="FR" selected={@filters["country_id"] == "FR"}>France</option>
              <option value="DE" selected={@filters["country_id"] == "DE"}>Germany</option>
              <option value="JP" selected={@filters["country_id"] == "JP"}>Japan</option>
              <option value="KR" selected={@filters["country_id"] == "KR"}>South Korea</option>
              <option value="IN" selected={@filters["country_id"] == "IN"}>India</option>
              <option value="CN" selected={@filters["country_id"] == "CN"}>China</option>
              <!-- Add more countries as needed -->
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
              class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
            >
              <option value="" selected={@filters["discovery_preset"] in [nil, ""]}>
                All Movies
              </option>
              <option value="award_winners" selected={@filters["discovery_preset"] == "award_winners"}>
                🏆 Award Winners
              </option>
              <option
                value="popular_favorites"
                selected={@filters["discovery_preset"] == "popular_favorites"}
              >
                🎬 Popular Favorites
              </option>
              <option
                value="critically_acclaimed"
                selected={@filters["discovery_preset"] == "critically_acclaimed"}
              >
                📰 Critically Acclaimed
              </option>
              <option value="hidden_gems" selected={@filters["discovery_preset"] == "hidden_gems"}>
                💎 Hidden Gems
              </option>
            </select>
          </div>
          
    <!-- Award Era -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Award Era
            </label>
            <select
              name="filters[award_preset]"
              class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
            >
              <option value="" selected={@filters["award_preset"] in [nil, ""]}>All Time</option>
              <option value="recent_awards" selected={@filters["award_preset"] == "recent_awards"}>
                Recent Awards (2020s)
              </option>
              <option value="2010s" selected={@filters["award_preset"] == "2010s"}>2010s</option>
              <option value="2000s" selected={@filters["award_preset"] == "2000s"}>2000s</option>
              <option value="classic" selected={@filters["award_preset"] == "classic"}>
                Classic Era (pre-2000)
              </option>
            </select>
          </div>
        </div>
      </div>
      
    <!-- Traditional Awards Section (Simplified) -->
      <div class="border-t pt-4">
        <h3 class="text-sm font-semibold text-gray-900 mb-3">🎪 Award Filters</h3>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <!-- Award Status -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">
              Award Status
            </label>
            <select
              name="filters[award_status]"
              class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
            >
              <option value="" selected={@filters["award_status"] in [nil, ""]}>All Movies</option>
              <option value="any_nomination" selected={@filters["award_status"] == "any_nomination"}>
                Any Nomination
              </option>
              <option value="won" selected={@filters["award_status"] == "won"}>Award Winners</option>
              <option value="nominated_only" selected={@filters["award_status"] == "nominated_only"}>
                Nominated Only
              </option>
              <option value="multiple_awards" selected={@filters["award_status"] == "multiple_awards"}>
                Multiple Awards
              </option>
            </select>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # People search helper functions removed - moved to index.ex for basic filters

  def has_active_advanced_filters(filters) do
    # New simplified filters (removed people_search since it's now in basic filters)
    new_filter_keys = [
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
    new_filters_active =
      Enum.any?(new_filter_keys, fn key ->
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
    legacy_filters_active =
      Enum.any?(legacy_keys, fn key ->
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
        case Map.get(filters, key) do
          value when value not in [nil, "", []] -> {key, value}
          _ -> nil
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
