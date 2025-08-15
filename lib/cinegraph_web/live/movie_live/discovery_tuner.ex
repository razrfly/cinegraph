defmodule CinegraphWeb.MovieLive.DiscoveryTuner do
  @moduledoc """
  LiveView component for the Tunable Movie Discovery System.
  Now uses database-driven weight profiles instead of hard-coded values.
  """
  use CinegraphWeb, :live_view
  import Ecto.Query

  alias Cinegraph.Movies
  alias Cinegraph.Movies.DiscoveryScoringSimple, as: DiscoveryScoring
  alias Cinegraph.Metrics.ScoringService

  @impl true
  def mount(_params, _session, socket) do
    # Load presets from database
    presets = DiscoveryScoring.get_presets()
    
    # Get the default/balanced weights - now including people_quality
    weights = Map.get(presets, :balanced, %{
      popular_opinion: 0.2,
      critical_acclaim: 0.2,
      industry_recognition: 0.2,
      cultural_impact: 0.2,
      people_quality: 0.2
    })
    
    # Store the current profile for database lookups
    current_profile = ScoringService.get_profile("Balanced") || 
                     ScoringService.get_default_profile()

    socket =
      socket
      |> assign(:weights, weights)
      |> assign(:preset, "balanced")
      |> assign(:current_profile, current_profile)
      |> assign(:presets, presets)
      |> assign(:movies, [])
      |> assign(:page, 1)
      |> assign(:per_page, 20)
      |> assign(:min_score, 0.0)
      |> assign(:show_scores, false)
      |> assign(:show_explanation, false)
      |> load_movies()

    {:ok, socket}
  end

  @impl true
  def handle_event("update_weight", params, socket) do
    # Handle all weight updates from the form
    weights =
      Enum.reduce(params, %{}, fn
        {key, value}, acc
        when key in [
               "popular_opinion",
               "critical_acclaim",
               "industry_recognition",
               "cultural_impact",
               "people_quality"
             ] ->
          dimension = String.to_atom(key)

          parsed_value =
            case Float.parse(value) do
              {val, _} -> min(1.0, max(0.0, val / 100))
              :error -> 0.0
            end

          Map.put(acc, dimension, parsed_value)

        _, acc ->
          acc
      end)

    # Merge with existing weights to handle any missing ones
    weights = Map.merge(socket.assigns.weights, weights)

    socket =
      socket
      |> assign(:weights, weights)
      |> assign(:preset, "custom")
      |> load_movies()

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_preset", %{"preset" => preset}, socket) do
    {weights, profile} =
      case preset do
        "custom" ->
          {socket.assigns.weights, nil}

        preset_name ->
          # Try to get from database first
          profile_name = preset_name 
                        |> String.replace("_", " ")
                        |> String.split()
                        |> Enum.map(&String.capitalize/1)
                        |> Enum.join(" ")
          
          case ScoringService.get_profile(profile_name) do
            nil ->
              # Fallback to presets if not in database
              weights = socket.assigns.presets
                       |> Map.get(String.to_atom(preset_name))
              {weights, nil}
            
            profile ->
              weights = ScoringService.profile_to_discovery_weights(profile)
              {weights, profile}
          end
      end

    socket =
      socket
      |> assign(:weights, weights)
      |> assign(:preset, preset)
      |> assign(:current_profile, profile)
      |> load_movies()

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_min_score", %{"min_score" => value}, socket) do
    min_score =
      case Float.parse(value) do
        {val, _} -> min(1.0, max(0.0, val / 100))
        :error -> 0.0
      end

    socket =
      socket
      |> assign(:min_score, min_score)
      |> load_movies()

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_scores", _params, socket) do
    {:noreply, assign(socket, :show_scores, !socket.assigns.show_scores)}
  end
  
  @impl true
  def handle_event("toggle_explanation", _params, socket) do
    {:noreply, assign(socket, :show_explanation, !socket.assigns.show_explanation)}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    socket =
      socket
      |> assign(:page, socket.assigns.page + 1)
      |> load_movies(append: true)

    {:noreply, socket}
  end

  defp load_movies(socket, opts \\ []) do
    query = Movies.Movie

    # Use database profile if available, otherwise use weights
    scoring_input = 
      if socket.assigns[:current_profile] do
        socket.assigns.current_profile
      else
        socket.assigns.weights
      end

    movies =
      DiscoveryScoring.apply_scoring(
        query,
        scoring_input,
        %{min_score: socket.assigns.min_score}
      )
      |> limit(^socket.assigns.per_page)
      |> offset(^((socket.assigns.page - 1) * socket.assigns.per_page))
      |> Cinegraph.Repo.all()
      |> Cinegraph.Repo.preload([:genres])

    if opts[:append] do
      assign(socket, :movies, socket.assigns.movies ++ movies)
    else
      assign(socket, :movies, movies)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <.header>
        Tunable Movie Discovery
        <:subtitle>
          Adjust the importance of different scoring factors to discover movies that match your preferences
          <%= if @current_profile do %>
            <span class="ml-2 text-sm text-green-600">
              (Using database profile: {@current_profile.name})
            </span>
          <% end %>
        </:subtitle>
      </.header>

      <div class="tuner-controls space-y-6 bg-white p-6 rounded-lg shadow mb-8">
        <!-- Preset Selector -->
        <div>
          <label class="block text-sm font-medium text-gray-700 mb-2">
            Presets
          </label>
          <div class="flex flex-wrap gap-2">
            <button
              :for={{key, _weights} <- DiscoveryScoring.get_presets()}
              phx-click="select_preset"
              phx-value-preset={key}
              class={[
                "px-4 py-2 rounded-md text-sm font-medium transition-colors",
                if(@preset == to_string(key),
                  do: "bg-blue-600 text-white",
                  else: "bg-gray-200 text-gray-700 hover:bg-gray-300"
                )
              ]}
            >
              {humanize_preset(key)}
            </button>
            <button
              phx-click="select_preset"
              phx-value-preset="custom"
              class={[
                "px-4 py-2 rounded-md text-sm font-medium transition-colors",
                if(@preset == "custom",
                  do: "bg-blue-600 text-white",
                  else: "bg-gray-200 text-gray-700 hover:bg-gray-300"
                )
              ]}
            >
              Custom
            </button>
          </div>
        </div>
        
    <!-- Weight Sliders -->
        <form phx-change="update_weight" class="space-y-4">
          <h3 class="text-lg font-semibold text-gray-900">Scoring Weights</h3>

          <div :for={{dimension, weight} <- @weights} class="space-y-1">
            <div class="flex justify-between items-center">
              <label class="text-sm font-medium text-gray-700">
                {humanize_dimension(dimension)}
              </label>
              <span class="text-sm text-gray-600">
                {round(weight * 100)}%
              </span>
            </div>
            <input
              type="range"
              name={dimension}
              min="0"
              max="100"
              value={round(weight * 100)}
              class="w-full h-2 bg-gray-200 rounded-lg appearance-none cursor-pointer"
            />
            <p class="text-xs text-gray-500">
              {dimension_description(dimension)}
            </p>
          </div>
        </form>
        
    <!-- Minimum Score Filter -->
        <form phx-change="update_min_score" class="space-y-1">
          <div class="flex justify-between items-center">
            <label class="text-sm font-medium text-gray-700">
              Minimum Score Threshold
              <button
                type="button"
                phx-click="toggle_explanation"
                class="ml-2 text-blue-600 hover:text-blue-800"
              >
                ℹ️
              </button>
            </label>
            <span class="text-sm text-gray-600">
              {round(@min_score * 100)}%
            </span>
          </div>
          <input
            type="range"
            name="min_score"
            min="0"
            max="100"
            value={round(@min_score * 100)}
            class="w-full h-2 bg-gray-200 rounded-lg appearance-none cursor-pointer"
          />
          <%= if @show_explanation do %>
            <div class="mt-2 p-3 bg-blue-50 rounded-lg text-sm text-gray-700">
              <p class="font-semibold mb-1">What is Minimum Score Threshold?</p>
              <p>This filter excludes movies with a total discovery score below the specified percentage. The discovery score is calculated by combining:</p>
              <ul class="list-disc list-inside mt-2 space-y-1">
                <li><strong>Popular Opinion:</strong> IMDb and TMDb user ratings</li>
                <li><strong>Critical Acclaim:</strong> Metacritic and Rotten Tomatoes critic scores</li>
                <li><strong>Industry Recognition:</strong> Festival awards and Oscar nominations/wins</li>
                <li><strong>Cultural Impact:</strong> Presence in canonical film lists and popularity metrics</li>
                <li><strong>People Quality:</strong> Quality scores of directors, actors, and crew members</li>
              </ul>
              <p class="mt-2">Setting this to 50% will only show movies that score at least 0.5 out of 1.0 based on your selected weights.</p>
            </div>
          <% end %>
        </form>
        
    <!-- Toggle Score Display -->
        <div>
          <button
            phx-click="toggle_scores"
            class="px-4 py-2 bg-gray-200 text-gray-700 rounded-md hover:bg-gray-300 transition-colors"
          >
            {if @show_scores, do: "Hide", else: "Show"} Score Breakdown
          </button>
        </div>
      </div>
      
    <!-- Results Grid -->
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6">
        <%= for movie <- @movies do %>
          <.link navigate={~p"/movies/#{movie.id}"} class="group block">
            <div class="bg-white rounded-lg shadow-md hover:shadow-lg transition-shadow duration-200 overflow-hidden">
              <!-- Movie Poster -->
              <div class="aspect-[2/3] bg-gray-200 relative">
                <%= if movie.poster_path do %>
                  <img
                    src={Cinegraph.Movies.Movie.poster_url(movie, "w500")}
                    alt={movie.title}
                    class="w-full h-full object-cover"
                    loading="lazy"
                  />
                <% else %>
                  <div class="w-full h-full flex items-center justify-center">
                    <span class="text-gray-400 text-lg">No Image</span>
                  </div>
                <% end %>
                
    <!-- Rating Badge (if available) -->
                <% vote_avg = Cinegraph.Movies.Movie.vote_average(movie) %>
                <%= if vote_avg && vote_avg > 0 do %>
                  <div class="absolute top-2 left-2 bg-black bg-opacity-75 text-white text-sm px-2 py-1 rounded">
                    ⭐ {Float.round(vote_avg, 1)}
                  </div>
                <% end %>
              </div>
              
    <!-- Movie Info -->
              <div class="p-4">
                <h3 class="font-semibold text-lg text-gray-900 group-hover:text-blue-600 transition-colors line-clamp-2">
                  {movie.title}
                </h3>

                <%= if movie.release_date do %>
                  <p class="text-gray-500 text-sm mt-1">
                    {Calendar.strftime(movie.release_date, "%Y")}
                  </p>
                <% end %>
                
    <!-- Quick Stats -->
                <div class="mt-3 flex flex-wrap gap-2">
                  <%= if movie.runtime do %>
                    <span class="text-xs text-gray-500">
                      {movie.runtime} min
                    </span>
                  <% end %>

                  <%= if movie.original_language do %>
                    <span class="inline-flex items-center px-2 py-1 rounded-full text-xs font-medium bg-blue-100 text-blue-800">
                      {String.upcase(movie.original_language)}
                    </span>
                  <% end %>
                </div>
                
    <!-- Score Breakdown -->
                <%= if @show_scores and movie.score_components do %>
                  <div class="mt-4 space-y-1 text-xs text-gray-600">
                    <div class="font-semibold text-gray-700">
                      Total Score: {format_score(movie.discovery_score)}
                    </div>
                    <div
                      :for={{dimension, score} <- movie.score_components}
                      class="flex justify-between"
                    >
                      <span>{humanize_dimension(dimension)}:</span>
                      <span>{format_score(score)}</span>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </.link>
        <% end %>
      </div>
      
    <!-- Load More Button -->
      <%= if rem(length(@movies), @per_page) == 0 and length(@movies) > 0 do %>
        <div class="mt-8 text-center">
          <button
            phx-click="load_more"
            class="px-6 py-3 bg-blue-600 text-white rounded-md hover:bg-blue-700 transition-colors"
          >
            Load More Movies
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  defp humanize_preset(:balanced), do: "Balanced"
  defp humanize_preset(:crowd_pleaser), do: "Crowd Pleaser"
  defp humanize_preset(:critics_choice), do: "Critics' Choice"
  defp humanize_preset(:award_winner), do: "Award Winner"
  defp humanize_preset(:cult_classic), do: "Cult Classic"
  defp humanize_preset(preset), do: Phoenix.Naming.humanize(preset)

  defp humanize_dimension(:popular_opinion), do: "Popular Opinion"
  defp humanize_dimension(:critical_acclaim), do: "Critical Acclaim"
  defp humanize_dimension(:industry_recognition), do: "Industry Recognition"
  defp humanize_dimension(:cultural_impact), do: "Cultural Impact"
  defp humanize_dimension(:people_quality), do: "People Quality"
  defp humanize_dimension(dimension), do: Phoenix.Naming.humanize(dimension)

  defp dimension_description(:popular_opinion), do: "TMDb and IMDb user ratings"
  defp dimension_description(:critical_acclaim), do: "Metacritic and Rotten Tomatoes scores"
  defp dimension_description(:industry_recognition), do: "Festival awards and nominations"
  defp dimension_description(:cultural_impact), do: "Canonical lists and popularity metrics"
  defp dimension_description(:people_quality), do: "Quality of directors, actors, and crew"
  defp dimension_description(_), do: ""

  defp format_score(nil), do: "N/A"
  defp format_score(score) when is_float(score), do: "#{round(score * 100)}%"
  defp format_score(score), do: to_string(score)
end
