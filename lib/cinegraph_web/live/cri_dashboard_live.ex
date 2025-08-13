defmodule CinegraphWeb.CRIDashboardLive do
  @moduledoc """
  Cultural Relevance Index (CRI) Dashboard
  
  Provides:
  - Weight profile management and testing
  - Real-time CRI score calculation
  - Backtesting against 1001 Movies list
  - Visual comparison of different profiles
  - ML optimization controls (when Scholar is integrated)
  """
  use CinegraphWeb, :live_view
  
  alias Cinegraph.Metrics.{CRI, WeightProfile, CRIScore}
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo
  import Ecto.Query
  
  @impl true
  def mount(_params, _session, socket) do
    profiles = CRI.list_weight_profiles()
    
    socket =
      socket
      |> assign(:profiles, profiles)
      |> assign(:selected_profile, hd(profiles))
      |> assign(:comparison_profile, nil)
      |> assign(:movies, [])
      |> assign(:page, 1)
      |> assign(:per_page, 20)
      |> assign(:backtest_results, nil)
      |> assign(:editing_weights, false)
      |> assign(:custom_weights, %{})
      |> assign(:show_optimization, false)
      |> load_movies()
    
    {:ok, socket}
  end
  
  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <h1 class="text-3xl font-bold mb-8">Cultural Relevance Index Dashboard</h1>
      
      <!-- Profile Selector and Controls -->
      <div class="bg-white rounded-lg shadow-md p-6 mb-6">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <!-- Primary Profile -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-2">
              Weight Profile
            </label>
            <select
              phx-change="select_profile"
              name="profile_id"
              class="w-full px-3 py-2 border border-gray-300 rounded-md"
            >
              <%= for profile <- @profiles do %>
                <option value={profile.id} selected={profile.id == @selected_profile.id}>
                  <%= profile.name %> - <%= profile.description %>
                </option>
              <% end %>
            </select>
          </div>
          
          <!-- Comparison Profile -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-2">
              Compare With (Optional)
            </label>
            <select
              phx-change="select_comparison"
              name="comparison_id"
              class="w-full px-3 py-2 border border-gray-300 rounded-md"
            >
              <option value="">No Comparison</option>
              <%= for profile <- @profiles do %>
                <option value={profile.id} selected={@comparison_profile && profile.id == @comparison_profile.id}>
                  <%= profile.name %>
                </option>
              <% end %>
            </select>
          </div>
        </div>
        
        <!-- Action Buttons -->
        <div class="mt-4 flex gap-2">
          <button
            phx-click="run_backtest"
            class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
          >
            Run Backtest vs 1001 Movies
          </button>
          <button
            phx-click="toggle_weight_editor"
            class="px-4 py-2 bg-gray-600 text-white rounded hover:bg-gray-700"
          >
            <%= if @editing_weights, do: "Hide", else: "Edit" %> Weights
          </button>
          <button
            phx-click="recalculate_scores"
            class="px-4 py-2 bg-green-600 text-white rounded hover:bg-green-700"
          >
            Recalculate All Scores
          </button>
        </div>
      </div>
      
      <!-- Weight Editor (Conditional) -->
      <%= if @editing_weights do %>
        <div class="bg-white rounded-lg shadow-md p-6 mb-6">
          <h2 class="text-xl font-semibold mb-4">Dimension Weights</h2>
          <form phx-change="update_weights">
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-5 gap-4">
              <%= for dimension <- [:timelessness, :cultural_penetration, :artistic_impact, :institutional, :public] do %>
                <div>
                  <label class="block text-sm font-medium text-gray-700 mb-1">
                    <%= humanize(dimension) %>
                  </label>
                  <input
                    type="range"
                    name={"weight[#{dimension}]"}
                    value={get_weight(@selected_profile, dimension) * 100}
                    min="0"
                    max="100"
                    class="w-full"
                  />
                  <div class="text-sm text-gray-600 text-center">
                    <%= Float.round(get_weight(@selected_profile, dimension) * 100, 1) %>%
                  </div>
                </div>
              <% end %>
            </div>
            <div class="mt-4 text-sm text-gray-600">
              Note: Weights will be normalized to sum to 1.0
            </div>
          </form>
        </div>
      <% end %>
      
      <!-- Backtest Results (Conditional) -->
      <%= if @backtest_results do %>
        <div class="bg-white rounded-lg shadow-md p-6 mb-6">
          <h2 class="text-xl font-semibold mb-4">Backtest Results vs 1001 Movies</h2>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div class="text-center">
              <div class="text-2xl font-bold text-blue-600">
                <%= Float.round(@backtest_results.overlap_percentage, 1) %>%
              </div>
              <div class="text-sm text-gray-600">Overlap</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-bold text-green-600">
                <%= Float.round(@backtest_results.precision * 100, 1) %>%
              </div>
              <div class="text-sm text-gray-600">Precision</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-bold text-orange-600">
                <%= Float.round(@backtest_results.recall * 100, 1) %>%
              </div>
              <div class="text-sm text-gray-600">Recall</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-bold text-purple-600">
                <%= Float.round(@backtest_results.f1_score * 100, 1) %>%
              </div>
              <div class="text-sm text-gray-600">F1 Score</div>
            </div>
          </div>
          
          <div class="mt-4 text-sm text-gray-600">
            <p>True Positives: <%= @backtest_results.true_positives %> movies correctly identified</p>
            <p>False Positives: <%= @backtest_results.false_positives %> movies incorrectly included</p>
            <p>False Negatives: <%= @backtest_results.false_negatives %> movies missed</p>
          </div>
        </div>
      <% end %>
      
      <!-- Movies Table -->
      <div class="bg-white rounded-lg shadow-md overflow-hidden">
        <div class="px-6 py-4 border-b">
          <h2 class="text-xl font-semibold">Top Movies by CRI Score</h2>
        </div>
        
        <div class="overflow-x-auto">
          <table class="w-full">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Movie
                </th>
                <th class="px-6 py-3 text-center text-xs font-medium text-gray-500 uppercase tracking-wider">
                  CRI Score
                </th>
                <%= if @comparison_profile do %>
                  <th class="px-6 py-3 text-center text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Comparison Score
                  </th>
                  <th class="px-6 py-3 text-center text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Difference
                  </th>
                <% end %>
                <th class="px-6 py-3 text-center text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Timelessness
                </th>
                <th class="px-6 py-3 text-center text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Cultural
                </th>
                <th class="px-6 py-3 text-center text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Artistic
                </th>
                <th class="px-6 py-3 text-center text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Institutional
                </th>
                <th class="px-6 py-3 text-center text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Public
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <%= for movie <- @movies do %>
                <tr class="hover:bg-gray-50">
                  <td class="px-6 py-4">
                    <div>
                      <div class="text-sm font-medium text-gray-900">
                        <%= movie.title %>
                      </div>
                      <div class="text-sm text-gray-500">
                        <%= movie.release_date && movie.release_date.year %>
                      </div>
                    </div>
                  </td>
                  <td class="px-6 py-4 text-center">
                    <span class="inline-flex px-2 py-1 text-xs font-semibold rounded-full bg-blue-100 text-blue-800">
                      <%= format_score(movie.cri_score) %>
                    </span>
                  </td>
                  <%= if @comparison_profile && movie.comparison_score do %>
                    <td class="px-6 py-4 text-center">
                      <span class="inline-flex px-2 py-1 text-xs font-semibold rounded-full bg-gray-100 text-gray-800">
                        <%= format_score(movie.comparison_score) %>
                      </span>
                    </td>
                    <td class="px-6 py-4 text-center">
                      <span class={"inline-flex px-2 py-1 text-xs font-semibold rounded-full #{score_diff_class(movie)}"}>
                        <%= format_diff(movie.cri_score - movie.comparison_score) %>
                      </span>
                    </td>
                  <% end %>
                  <td class="px-6 py-4 text-center text-sm text-gray-600">
                    <%= format_dimension_score(movie.timelessness_score) %>
                  </td>
                  <td class="px-6 py-4 text-center text-sm text-gray-600">
                    <%= format_dimension_score(movie.cultural_penetration_score) %>
                  </td>
                  <td class="px-6 py-4 text-center text-sm text-gray-600">
                    <%= format_dimension_score(movie.artistic_impact_score) %>
                  </td>
                  <td class="px-6 py-4 text-center text-sm text-gray-600">
                    <%= format_dimension_score(movie.institutional_score) %>
                  </td>
                  <td class="px-6 py-4 text-center text-sm text-gray-600">
                    <%= format_dimension_score(movie.public_score) %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
        
        <!-- Pagination -->
        <div class="px-6 py-4 border-t flex justify-between items-center">
          <button
            phx-click="prev_page"
            disabled={@page == 1}
            class="px-4 py-2 bg-gray-200 rounded disabled:opacity-50"
          >
            Previous
          </button>
          <span class="text-sm text-gray-600">
            Page <%= @page %>
          </span>
          <button
            phx-click="next_page"
            disabled={length(@movies) < @per_page}
            class="px-4 py-2 bg-gray-200 rounded disabled:opacity-50"
          >
            Next
          </button>
        </div>
      </div>
    </div>
    """
  end
  
  @impl true
  def handle_event("select_profile", %{"profile_id" => profile_id}, socket) do
    profile = Enum.find(socket.assigns.profiles, &(&1.id == String.to_integer(profile_id)))
    
    socket =
      socket
      |> assign(:selected_profile, profile)
      |> assign(:page, 1)
      |> load_movies()
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_event("select_comparison", %{"comparison_id" => ""}, socket) do
    socket =
      socket
      |> assign(:comparison_profile, nil)
      |> load_movies()
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_event("select_comparison", %{"comparison_id" => profile_id}, socket) do
    profile = Enum.find(socket.assigns.profiles, &(&1.id == String.to_integer(profile_id)))
    
    socket =
      socket
      |> assign(:comparison_profile, profile)
      |> load_movies()
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_event("run_backtest", _, socket) do
    profile = socket.assigns.selected_profile
    
    case CRI.backtest_profile(profile.id) do
      {:ok, results} ->
        {:noreply, assign(socket, :backtest_results, results)}
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to run backtest")}
    end
  end
  
  @impl true
  def handle_event("toggle_weight_editor", _, socket) do
    {:noreply, assign(socket, :editing_weights, !socket.assigns.editing_weights)}
  end
  
  @impl true
  def handle_event("update_weights", %{"weight" => weights}, socket) do
    # Parse and normalize weights
    parsed_weights = 
      weights
      |> Enum.map(fn {k, v} -> 
        {String.to_atom(k), String.to_float(v) / 100.0}
      end)
      |> Map.new()
    
    # Update profile (would need to implement update_weight_profile)
    profile = socket.assigns.selected_profile
    attrs = Map.merge(profile, parsed_weights)
    
    case CRI.update_weight_profile(profile.id, attrs) do
      {:ok, updated_profile} ->
        profiles = CRI.list_weight_profiles()
        
        socket =
          socket
          |> assign(:profiles, profiles)
          |> assign(:selected_profile, updated_profile)
          |> load_movies()
        
        {:noreply, socket}
      
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update weights")}
    end
  end
  
  @impl true
  def handle_event("recalculate_scores", _, socket) do
    profile = socket.assigns.selected_profile
    
    # In production, this would be done in a background job
    Task.start(fn ->
      movies = Repo.all(from m in Movie, limit: 1000)
      
      Enum.each(movies, fn movie ->
        CRI.calculate_score(movie.id, profile.id)
      end)
    end)
    
    {:noreply, put_flash(socket, :info, "Recalculating scores in background...")}
  end
  
  @impl true
  def handle_event("prev_page", _, socket) do
    socket =
      socket
      |> assign(:page, max(1, socket.assigns.page - 1))
      |> load_movies()
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_event("next_page", _, socket) do
    socket =
      socket
      |> assign(:page, socket.assigns.page + 1)
      |> load_movies()
    
    {:noreply, socket}
  end
  
  # Private functions
  
  defp load_movies(socket) do
    profile = socket.assigns.selected_profile
    comparison = socket.assigns.comparison_profile
    offset = (socket.assigns.page - 1) * socket.assigns.per_page
    
    # Get movies with CRI scores
    query = 
      from m in Movie,
        join: cs in CRIScore,
        on: cs.movie_id == m.id and cs.profile_id == ^profile.id,
        order_by: [desc: cs.total_cri_score],
        limit: ^socket.assigns.per_page,
        offset: ^offset,
        select: %{
          m | 
          cri_score: cs.total_cri_score,
          timelessness_score: cs.timelessness_score,
          cultural_penetration_score: cs.cultural_penetration_score,
          artistic_impact_score: cs.artistic_impact_score,
          institutional_score: cs.institutional_score,
          public_score: cs.public_score
        }
    
    movies = Repo.all(query)
    
    # Add comparison scores if needed
    movies = 
      if comparison do
        movie_ids = Enum.map(movies, & &1.id)
        
        comparison_scores = 
          from(cs in CRIScore,
            where: cs.movie_id in ^movie_ids and cs.profile_id == ^comparison.id,
            select: {cs.movie_id, cs.total_cri_score}
          )
          |> Repo.all()
          |> Map.new()
        
        Enum.map(movies, fn movie ->
          Map.put(movie, :comparison_score, Map.get(comparison_scores, movie.id))
        end)
      else
        movies
      end
    
    assign(socket, :movies, movies)
  end
  
  defp get_weight(profile, dimension) do
    Map.get(profile, :"#{dimension}_weight", 0.0)
  end
  
  defp humanize(atom) do
    atom
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
  
  defp format_score(nil), do: "N/A"
  defp format_score(score), do: Float.round(score, 3)
  
  defp format_dimension_score(nil), do: "-"
  defp format_dimension_score(score), do: Float.round(score, 2)
  
  defp format_diff(diff) when diff > 0, do: "+#{Float.round(diff, 3)}"
  defp format_diff(diff), do: Float.round(diff, 3)
  
  defp score_diff_class(movie) do
    diff = movie.cri_score - (movie.comparison_score || 0)
    cond do
      diff > 0.05 -> "bg-green-100 text-green-800"
      diff < -0.05 -> "bg-red-100 text-red-800"
      true -> "bg-gray-100 text-gray-800"
    end
  end
end