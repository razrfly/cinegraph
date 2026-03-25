defmodule CinegraphWeb.ScoreCalibrationLive do
  @moduledoc """
  Admin page for score calibration system.

  Provides tools to:
  - Compare Cinegraph scores against reference datasets (IMDb Top 250, AFI 100, etc.)
  - Adjust category weights with live score preview
  - Configure normalization methods and missing data strategies
  - Track calibration history and version control
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Calibration
  alias Cinegraph.Calibration.ScoringConfiguration
  alias Cinegraph.Metrics.ScoringService
  alias Cinegraph.Workers.RecallCalibrationWorker

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Cinegraph.PubSub, RecallCalibrationWorker.pubsub_topic())
    end

    default_profile = "Cinegraph Editorial"
    default_threshold = 0.25

    cached_recall =
      RecallCalibrationWorker.get_cached(
        "1001-movies",
        default_profile,
        default_threshold
      )

    socket =
      socket
      |> assign(:page_title, "Score Calibration")
      |> assign(:active_tab, :overview)
      |> assign(:reference_lists, Calibration.list_reference_lists())
      |> assign(:selected_list_id, nil)
      |> assign(:correlation_data, nil)
      |> assign(:mismatches, [])
      |> assign(:active_config, Calibration.get_active_configuration())
      |> assign(:all_configs, Calibration.list_scoring_configurations())
      |> assign(:draft_weights, nil)
      |> assign(:simulation_results, nil)
      |> assign(:show_create_modal, false)
      |> assign(:new_config_name, "")
      |> assign(:loading, false)
      |> assign(:recall_results, cached_recall)
      |> assign(:recall_running, false)
      |> assign(:recall_profile, default_profile)
      |> assign(:recall_threshold, default_threshold)
      |> assign(:all_profiles, ScoringService.get_all_profiles())

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = Map.get(params, "tab", "overview") |> String.to_existing_atom()
    {:noreply, assign(socket, :active_tab, tab)}
  rescue
    ArgumentError -> {:noreply, assign(socket, :active_tab, :overview)}
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/score-calibration?tab=#{tab}")}
  end

  @impl true
  def handle_event("select_list", %{"list_id" => list_id}, socket) do
    list_id = String.to_integer(list_id)

    socket =
      socket
      |> assign(:selected_list_id, list_id)
      |> assign(:loading, true)

    # Load correlation data asynchronously
    send(self(), {:load_correlation, list_id})

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_weight", %{"category" => category, "value" => value}, socket) do
    value =
      case Float.parse(value) do
        {float_val, _} -> float_val / 100.0
        :error -> 0.0
      end

    current_weights =
      socket.assigns.draft_weights ||
        socket.assigns.active_config.category_weights

    new_weights = Map.put(current_weights, category, value)

    # Normalize to sum to 1.0
    total = new_weights |> Map.values() |> Enum.sum()

    normalized_weights =
      if total > 0 do
        new_weights
        |> Enum.map(fn {k, v} -> {k, Float.round(v / total, 3)} end)
        |> Map.new()
      else
        new_weights
      end

    {:noreply, assign(socket, :draft_weights, normalized_weights)}
  end

  @impl true
  def handle_event("simulate_weights", _params, socket) do
    active = socket.assigns.active_config || %ScoringConfiguration{}
    weights = socket.assigns.draft_weights || Map.get(active, :category_weights) || %{}

    # Create a temporary config for simulation
    temp_config = %ScoringConfiguration{
      category_weights: weights,
      missing_data_strategies: Map.get(active, :missing_data_strategies) || %{},
      normalization_method: Map.get(active, :normalization_method) || "none",
      normalization_settings: Map.get(active, :normalization_settings) || %{}
    }

    opts =
      if socket.assigns.selected_list_id do
        [reference_list_id: socket.assigns.selected_list_id, limit: 25]
      else
        [limit: 25]
      end

    results = Calibration.simulate_configuration(temp_config, opts)

    {:noreply, assign(socket, :simulation_results, results)}
  end

  @impl true
  def handle_event("reset_weights", _params, socket) do
    {:noreply, assign(socket, :draft_weights, nil)}
  end

  @impl true
  def handle_event("show_create_modal", _params, socket) do
    {:noreply, assign(socket, :show_create_modal, true)}
  end

  @impl true
  def handle_event("hide_create_modal", _params, socket) do
    {:noreply, assign(socket, :show_create_modal, false)}
  end

  @impl true
  def handle_event("update_config_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :new_config_name, name)}
  end

  @impl true
  def handle_event("create_configuration", _params, socket) do
    weights = socket.assigns.draft_weights || socket.assigns.active_config.category_weights
    name = socket.assigns.new_config_name

    if String.trim(name) == "" do
      {:noreply, put_flash(socket, :error, "Configuration name is required")}
    else
      attrs = %{
        name: name,
        description: "Created from calibration admin",
        category_weights: weights,
        missing_data_strategies: socket.assigns.active_config.missing_data_strategies || %{},
        normalization_method: socket.assigns.active_config.normalization_method || "none",
        normalization_settings: socket.assigns.active_config.normalization_settings || %{},
        is_draft: true
      }

      case Calibration.create_scoring_configuration(attrs) do
        {:ok, config} ->
          socket =
            socket
            |> assign(:all_configs, Calibration.list_scoring_configurations())
            |> assign(:show_create_modal, false)
            |> assign(:new_config_name, "")
            |> put_flash(:info, "Created configuration v#{config.version}: #{config.name}")

          {:noreply, socket}

        {:error, changeset} ->
          errors =
            changeset.errors
            |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
            |> Enum.join(", ")

          {:noreply, put_flash(socket, :error, "Failed to create: #{errors}")}
      end
    end
  end

  @impl true
  def handle_event("activate_config", %{"id" => id}, socket) do
    case Calibration.get_scoring_configuration(String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Configuration not found")}

      config ->
        case Calibration.activate_configuration(config) do
          {:ok, activated} ->
            socket =
              socket
              |> assign(:active_config, activated)
              |> assign(:all_configs, Calibration.list_scoring_configurations())
              |> assign(:draft_weights, nil)
              |> put_flash(:info, "Activated configuration v#{activated.version}")

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to activate configuration")}
        end
    end
  end

  @impl true
  def handle_event("trigger_import", %{"slug" => slug}, socket) do
    case Cinegraph.Workers.ReferenceListImporter.new(%{list_slug: slug}) |> Oban.insert() do
      {:ok, _job} ->
        {:noreply, put_flash(socket, :info, "Import started for #{slug}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to start import")}
    end
  end

  @impl true
  def handle_event("run_calibration", _params, socket) do
    profile = socket.assigns.recall_profile
    threshold = socket.assigns.recall_threshold

    case RecallCalibrationWorker.enqueue("1001-movies", profile, threshold) do
      {:ok, _job} ->
        {:noreply, assign(socket, recall_running: true, recall_results: nil)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to queue calibration: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("select_recall_profile", %{"profile" => name}, socket) do
    {:noreply, assign(socket, recall_profile: name, recall_results: nil)}
  end

  @impl true
  def handle_event("update_recall_threshold", %{"threshold" => t}, socket) do
    case Float.parse(t) do
      {threshold, _} ->
        {:noreply, assign(socket, recall_threshold: threshold, recall_results: nil)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:recall_update, %{status: :complete, results: results}}, socket) do
    {:noreply, assign(socket, recall_results: results, recall_running: false)}
  end

  @impl true
  def handle_info({:recall_update, %{status: :error, error: reason}}, socket) do
    {:noreply,
     socket
     |> assign(recall_running: false, recall_results: {:error, reason})
     |> put_flash(:error, "Calibration failed: #{reason}")}
  end

  @impl true
  def handle_info({:recall_update, %{status: :running}}, socket) do
    {:noreply, assign(socket, recall_running: true)}
  end

  @impl true
  def handle_info({:load_correlation, list_id}, socket) do
    correlation_data =
      case Calibration.calculate_correlation(list_id) do
        {:ok, data} -> data
        {:error, _} -> nil
      end

    mismatches = Calibration.get_top_mismatches(list_id, limit: 15)

    socket =
      socket
      |> assign(:correlation_data, correlation_data)
      |> assign(:mismatches, mismatches)
      |> assign(:loading, false)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div>
        <header class="mb-8">
          <h1 class="text-3xl font-bold text-gray-900">Score Calibration</h1>
          <p class="text-gray-500 mt-1">
            Tune the Cinegraph scoring algorithm using reference datasets
          </p>
        </header>
        
    <!-- Tab Navigation -->
        <nav class="flex space-x-1 mb-8 border-b border-gray-200">
          <button
            phx-click="select_tab"
            phx-value-tab="overview"
            class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px #{if @active_tab == :overview, do: "border-blue-600 text-blue-600", else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"}"}
          >
            Overview
          </button>
          <button
            phx-click="select_tab"
            phx-value-tab="weights"
            class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px #{if @active_tab == :weights, do: "border-blue-600 text-blue-600", else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"}"}
          >
            Weight Adjustment
          </button>
          <button
            phx-click="select_tab"
            phx-value-tab="history"
            class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px #{if @active_tab == :history, do: "border-blue-600 text-blue-600", else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"}"}
          >
            Configuration History
          </button>
          <button
            phx-click="select_tab"
            phx-value-tab="recall"
            class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px #{if @active_tab == :recall, do: "border-blue-600 text-blue-600", else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"}"}
          >
            Recall Benchmark
          </button>
        </nav>
        
    <!-- Tab Content -->
        <div class="space-y-6">
          <%= case @active_tab do %>
            <% :overview -> %>
              <.overview_tab
                reference_lists={@reference_lists}
                selected_list_id={@selected_list_id}
                correlation_data={@correlation_data}
                mismatches={@mismatches}
                loading={@loading}
                active_config={@active_config}
              />
            <% :weights -> %>
              <.weights_tab
                active_config={@active_config}
                draft_weights={@draft_weights}
                simulation_results={@simulation_results}
                reference_lists={@reference_lists}
                selected_list_id={@selected_list_id}
              />
            <% :history -> %>
              <.history_tab
                all_configs={@all_configs}
                active_config={@active_config}
                show_create_modal={@show_create_modal}
                new_config_name={@new_config_name}
                draft_weights={@draft_weights}
              />
            <% :recall -> %>
              <.recall_tab
                recall_results={@recall_results}
                recall_running={@recall_running}
                recall_profile={@recall_profile}
                recall_threshold={@recall_threshold}
                all_profiles={@all_profiles}
              />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Overview Tab Component
  defp overview_tab(assigns) do
    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
      <!-- Reference List Selector -->
      <div class="bg-white shadow rounded-lg p-6">
        <h2 class="text-xl font-semibold text-gray-900 mb-4">Reference Datasets</h2>

        <div class="space-y-3">
          <%= for list <- @reference_lists do %>
            <button
              phx-click="select_list"
              phx-value-list_id={list.id}
              class={"w-full text-left p-3 rounded-lg border transition-colors #{if @selected_list_id == list.id, do: "border-blue-500 bg-blue-50", else: "border-gray-200 hover:border-gray-300"}"}
            >
              <div class="font-medium text-gray-900">{list.name}</div>
              <div class="text-sm text-gray-500">
                {list.total_items || 0} movies
                <%= if list.last_synced_at do %>
                  · Synced {format_relative_time(list.last_synced_at)}
                <% end %>
              </div>
            </button>
          <% end %>

          <%= if Enum.empty?(@reference_lists) do %>
            <p class="text-gray-500 text-center py-4">No reference lists available</p>
          <% end %>
        </div>

        <div class="mt-4 pt-4 border-t border-gray-200">
          <p class="text-sm text-gray-500 mb-2">Import reference data:</p>
          <div class="flex flex-wrap gap-2">
            <button
              phx-click="trigger_import"
              phx-value-slug="imdb-top-250"
              class="px-3 py-1 bg-gray-100 hover:bg-gray-200 text-gray-700 rounded text-sm"
            >
              IMDb Top 250
            </button>
            <button
              phx-click="trigger_import"
              phx-value-slug="afi-100"
              class="px-3 py-1 bg-gray-100 hover:bg-gray-200 text-gray-700 rounded text-sm"
            >
              AFI 100
            </button>
            <button
              phx-click="trigger_import"
              phx-value-slug="sight-and-sound-2022"
              class="px-3 py-1 bg-gray-100 hover:bg-gray-200 text-gray-700 rounded text-sm"
            >
              Sight & Sound
            </button>
          </div>
        </div>
      </div>
      
    <!-- Correlation Metrics -->
      <div class="lg:col-span-2 bg-white shadow rounded-lg p-6">
        <h2 class="text-xl font-semibold text-gray-900 mb-4">Correlation Analysis</h2>

        <%= if @loading do %>
          <div class="flex items-center justify-center py-12">
            <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-500"></div>
          </div>
        <% else %>
          <%= if @correlation_data do %>
            <.correlation_panel data={@correlation_data} />
          <% else %>
            <div class="text-center py-12 text-gray-500">
              <p>Select a reference dataset to view correlation analysis</p>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>

    <!-- Current Config Summary -->
    <%= if @active_config do %>
      <div class="bg-white shadow rounded-lg p-6">
        <h2 class="text-xl font-semibold text-gray-900 mb-4">
          Active Configuration: v{@active_config.version} - {@active_config.name}
        </h2>
        <div class="grid grid-cols-5 gap-4">
          <%= for {category, weight} <- @active_config.category_weights do %>
            <div class="bg-gray-50 border border-gray-200 rounded-lg p-4 text-center">
              <div class="text-2xl font-bold text-blue-600">
                {Float.round(weight * 100, 1)}%
              </div>
              <div class="text-sm text-gray-500 mt-1">
                {format_category_name(category)}
              </div>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>

    <!-- Top Mismatches -->
    <%= if @mismatches != [] do %>
      <div class="bg-white shadow rounded-lg p-6">
        <h2 class="text-xl font-semibold text-gray-900 mb-4">Top Score Mismatches</h2>
        <p class="text-sm text-gray-500 mb-4">
          Movies where Cinegraph score differs significantly from external rating
        </p>
        <div class="overflow-x-auto">
          <table class="w-full">
            <thead class="text-left text-gray-500 text-sm">
              <tr>
                <th class="pb-3">Rank</th>
                <th class="pb-3">Movie</th>
                <th class="pb-3 text-right">External</th>
                <th class="pb-3 text-right">Cinegraph</th>
                <th class="pb-3 text-right">Diff</th>
              </tr>
            </thead>
            <tbody class="text-sm">
              <%= for mismatch <- @mismatches do %>
                <tr class="border-t border-gray-200">
                  <td class="py-2 text-gray-500">#{mismatch.rank}</td>
                  <td class="py-2 text-gray-900">
                    {mismatch.title}
                    <span class="text-gray-500">
                      ({if mismatch.release_date, do: mismatch.release_date.year, else: "?"})
                    </span>
                  </td>
                  <td class="py-2 text-right text-green-600">
                    {Float.round(mismatch.external_score || 0, 1)}
                  </td>
                  <td class="py-2 text-right text-blue-600">
                    {Float.round(mismatch.cinegraph_score || 0, 1)}
                  </td>
                  <td class={"py-2 text-right font-medium #{if mismatch.difference > 0, do: "text-red-600", else: "text-yellow-600"}"}>
                    {if mismatch.difference > 0, do: "+", else: ""}{Float.round(
                      mismatch.difference || 0,
                      2
                    )}
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    <% end %>
    """
  end

  # Correlation Panel Component
  defp correlation_panel(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Key Metrics -->
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div class="bg-gray-50 border border-gray-200 rounded-lg p-4">
          <div class="text-sm text-gray-500">Pearson Correlation</div>
          <div class={"text-2xl font-bold #{correlation_color(@data.pearson_correlation)}"}>
            {format_correlation(@data.pearson_correlation)}
          </div>
          <div class="text-xs text-gray-500 mt-1">
            Target: > 0.75
          </div>
        </div>

        <div class="bg-gray-50 border border-gray-200 rounded-lg p-4">
          <div class="text-sm text-gray-500">Spearman Correlation</div>
          <div class={"text-2xl font-bold #{correlation_color(@data.spearman_correlation)}"}>
            {format_correlation(@data.spearman_correlation)}
          </div>
          <div class="text-xs text-gray-500 mt-1">
            Rank-based
          </div>
        </div>

        <div class="bg-gray-50 border border-gray-200 rounded-lg p-4">
          <div class="text-sm text-gray-500">Mean Absolute Error</div>
          <div class="text-2xl font-bold text-gray-900">
            {format_number(@data.mean_absolute_error)}
          </div>
          <div class="text-xs text-gray-500 mt-1">
            Lower is better
          </div>
        </div>

        <div class="bg-gray-50 border border-gray-200 rounded-lg p-4">
          <div class="text-sm text-gray-500">Match Rate</div>
          <div class="text-2xl font-bold text-gray-900">
            {Float.round((@data.match_rate || 0) * 100, 1)}%
          </div>
          <div class="text-xs text-gray-500 mt-1">
            {@data.matched_count}/{@data.total_count} matched
          </div>
        </div>
      </div>
      
    <!-- Score Comparison -->
      <div class="grid grid-cols-2 gap-4">
        <div class="bg-gray-50 border border-gray-200 rounded-lg p-4">
          <div class="text-sm text-gray-500">Mean Cinegraph Score</div>
          <div class="text-xl font-bold text-blue-600">
            {format_number(@data.mean_cinegraph_score)}
          </div>
        </div>
        <div class="bg-gray-50 border border-gray-200 rounded-lg p-4">
          <div class="text-sm text-gray-500">Mean External Score</div>
          <div class="text-xl font-bold text-green-600">
            {format_number(@data.mean_external_score)}
          </div>
        </div>
      </div>
      
    <!-- Score Distribution -->
      <div>
        <h3 class="text-lg font-medium text-gray-900 mb-3">Score Distribution</h3>
        <div class="flex items-end space-x-2 h-32">
          <%= for {bucket, count} <- @data.score_distribution do %>
            <div class="flex-1 flex flex-col items-center">
              <div
                class="w-full bg-blue-500/60 rounded-t"
                style={"height: #{distribution_height(count, @data.score_distribution)}px"}
              >
              </div>
              <div class="text-xs text-gray-500 mt-1">{bucket}</div>
              <div class="text-xs text-gray-400">{count}</div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Weights Tab Component
  defp weights_tab(assigns) do
    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
      <!-- Weight Sliders -->
      <div class="bg-white shadow rounded-lg p-6">
        <div class="flex justify-between items-center mb-6">
          <h2 class="text-xl font-semibold text-gray-900">Category Weights</h2>
          <%= if @draft_weights do %>
            <button phx-click="reset_weights" class="text-sm text-gray-500 hover:text-gray-700">
              Reset to Active
            </button>
          <% end %>
        </div>

        <div class="space-y-6">
          <%= for {category, _weight} <- @active_config.category_weights do %>
            <% current_weight = get_weight(@draft_weights, @active_config.category_weights, category) %>
            <div>
              <div class="flex justify-between mb-2">
                <label class="text-sm font-medium text-gray-700">
                  {format_category_name(category)}
                </label>
                <span class="text-sm text-blue-600">
                  {Float.round(current_weight * 100, 1)}%
                </span>
              </div>
              <input
                type="range"
                min="0"
                max="100"
                value={round(current_weight * 100)}
                phx-change="update_weight"
                phx-value-category={category}
                name="value"
                class="w-full h-2 bg-gray-200 rounded-lg appearance-none cursor-pointer"
              />
            </div>
          <% end %>
        </div>

        <div class="mt-6 pt-6 border-t border-gray-200 flex space-x-4">
          <button
            phx-click="simulate_weights"
            class="flex-1 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg font-medium"
          >
            Simulate Changes
          </button>
          <button
            phx-click="show_create_modal"
            class={"flex-1 px-4 py-2 rounded-lg font-medium #{if @draft_weights, do: "bg-green-600 hover:bg-green-700 text-white", else: "bg-gray-100 text-gray-400 cursor-not-allowed"}"}
            disabled={!@draft_weights}
          >
            Save as New Version
          </button>
        </div>
      </div>
      
    <!-- Simulation Results -->
      <div class="bg-white shadow rounded-lg p-6">
        <h2 class="text-xl font-semibold text-gray-900 mb-4">Simulation Preview</h2>

        <%= if @simulation_results do %>
          <div class="overflow-y-auto max-h-[500px]">
            <table class="w-full text-sm">
              <thead class="text-left text-gray-500 sticky top-0 bg-white">
                <tr>
                  <th class="pb-3">Movie</th>
                  <th class="pb-3 text-right">Current</th>
                  <th class="pb-3 text-right">New</th>
                  <th class="pb-3 text-right">Change</th>
                </tr>
              </thead>
              <tbody>
                <%= for result <- @simulation_results do %>
                  <tr class="border-t border-gray-200">
                    <td class="py-2 truncate max-w-[200px] text-gray-900">{result.title}</td>
                    <td class="py-2 text-right text-gray-500">
                      {Float.round(result.current_score, 1)}
                    </td>
                    <td class="py-2 text-right text-blue-600">
                      {Float.round(result.new_score, 1)}
                    </td>
                    <td class={"py-2 text-right font-medium #{diff_color(result.difference)}"}>
                      {diff_prefix(result.difference)}{Float.round(result.difference, 2)}
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <% avg_change =
            Enum.sum(Enum.map(@simulation_results, & &1.difference)) /
              max(length(@simulation_results), 1) %>
          <div class="mt-4 pt-4 border-t border-gray-200 text-sm text-gray-500">
            Average change:
            <span class={"font-medium #{if avg_change > 0, do: "text-green-600", else: "text-red-600"}"}>
              {if avg_change > 0, do: "+", else: ""}{Float.round(avg_change, 2)}
            </span>
          </div>
        <% else %>
          <div class="text-center py-12 text-gray-500">
            <p>Adjust weights and click "Simulate Changes" to preview impact</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # History Tab Component
  defp history_tab(assigns) do
    ~H"""
    <div class="bg-white shadow rounded-lg p-6">
      <div class="flex justify-between items-center mb-6">
        <h2 class="text-xl font-semibold text-gray-900">Configuration History</h2>
        <button
          phx-click="show_create_modal"
          class="bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium"
        >
          Create New Version
        </button>
      </div>

      <div class="space-y-4">
        <%= for config <- @all_configs do %>
          <div class={"p-4 rounded-lg border #{if config.is_active, do: "border-green-500 bg-green-50", else: "border-gray-200"}"}>
            <div class="flex justify-between items-start">
              <div>
                <div class="flex items-center space-x-3">
                  <span class="font-semibold text-gray-900">v{config.version}</span>
                  <span class="text-gray-700">{config.name}</span>
                  <%= if config.is_active do %>
                    <span class="px-2 py-0.5 bg-green-600 text-white text-xs rounded-full">
                      Active
                    </span>
                  <% end %>
                  <%= if config.is_draft do %>
                    <span class="px-2 py-0.5 bg-yellow-500 text-white text-xs rounded-full">
                      Draft
                    </span>
                  <% end %>
                </div>
                <%= if config.description do %>
                  <p class="text-sm text-gray-500 mt-1">{config.description}</p>
                <% end %>
                <div class="text-xs text-gray-400 mt-2">
                  Created {format_datetime(config.inserted_at)}
                  <%= if config.deployed_at do %>
                    · Deployed {format_datetime(config.deployed_at)}
                  <% end %>
                </div>
              </div>

              <div class="flex items-center space-x-2">
                <%= unless config.is_active do %>
                  <button
                    phx-click="activate_config"
                    phx-value-id={config.id}
                    class="px-3 py-1 bg-green-600 hover:bg-green-700 text-white rounded text-sm"
                  >
                    Activate
                  </button>
                <% end %>
              </div>
            </div>
            
    <!-- Weight Summary -->
            <div class="mt-4 flex flex-wrap gap-3">
              <%= for {category, weight} <- config.category_weights do %>
                <div class="text-xs bg-gray-100 border border-gray-200 px-2 py-1 rounded">
                  <span class="text-gray-500">{format_category_abbrev(category)}:</span>
                  <span class="text-gray-900 font-medium">{Float.round(weight * 100, 0)}%</span>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if Enum.empty?(@all_configs) do %>
          <p class="text-center text-gray-500 py-8">No configurations yet</p>
        <% end %>
      </div>
    </div>

    <!-- Create Modal -->
    <%= if @show_create_modal do %>
      <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
        <div class="bg-white rounded-lg shadow-xl p-6 w-full max-w-md">
          <h3 class="text-xl font-semibold text-gray-900 mb-4">Create New Configuration</h3>

          <div class="mb-4">
            <label class="block text-sm font-medium text-gray-700 mb-2">Configuration Name</label>
            <input
              type="text"
              value={@new_config_name}
              phx-change="update_config_name"
              name="name"
              placeholder="e.g., Balanced v2, Reduced Financial Penalty"
              class="w-full px-3 py-2 border border-gray-300 rounded-lg text-gray-900 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>

          <%= if @draft_weights do %>
            <div class="mb-4 p-3 bg-gray-50 border border-gray-200 rounded-lg">
              <p class="text-sm text-gray-500 mb-2">New weights:</p>
              <div class="flex flex-wrap gap-2">
                <%= for {category, weight} <- @draft_weights do %>
                  <span class="text-xs bg-blue-100 text-blue-700 px-2 py-1 rounded">
                    {format_category_abbrev(category)}: {Float.round(weight * 100, 0)}%
                  </span>
                <% end %>
              </div>
            </div>
          <% else %>
            <p class="text-sm text-gray-500 mb-4">
              Will use current active configuration weights
            </p>
          <% end %>

          <div class="flex space-x-3">
            <button
              phx-click="hide_create_modal"
              class="flex-1 px-4 py-2 bg-gray-100 hover:bg-gray-200 text-gray-700 rounded-lg"
            >
              Cancel
            </button>
            <button
              phx-click="create_configuration"
              class="flex-1 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg font-medium"
            >
              Create
            </button>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  # Recall Tab Component
  defp recall_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Controls -->
      <div class="bg-white shadow rounded-lg p-6">
        <h2 class="text-xl font-semibold text-gray-900 mb-4">1001 Movies Recall Benchmark</h2>
        <p class="text-sm text-gray-500 mb-6">
          Measures what percentage of the <em>1001 Movies You Must See Before You Die</em>
          list appears in the algorithm's top-ranked results per decade.
          Target: ≥ 75% overall recall.
        </p>

        <div class="flex flex-wrap gap-4 items-end">
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">Scoring Profile</label>
            <select
              phx-change="select_recall_profile"
              name="profile"
              class="border border-gray-300 rounded-lg px-3 py-2 text-gray-900 bg-white focus:ring-blue-500 focus:border-blue-500"
            >
              <%= for profile <- @all_profiles do %>
                <option value={profile.name} selected={profile.name == @recall_profile}>
                  {profile.name}
                </option>
              <% end %>
            </select>
          </div>

          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">Threshold</label>
            <select
              phx-change="update_recall_threshold"
              name="threshold"
              class="border border-gray-300 rounded-lg px-3 py-2 text-gray-900 bg-white focus:ring-blue-500 focus:border-blue-500"
            >
              <%= for {label, value} <- [{"Top 10%", 0.10}, {"Top 15%", 0.15}, {"Top 20%", 0.20}, {"Top 25%", 0.25}, {"Top 33%", 0.33}] do %>
                <option value={value} selected={value == @recall_threshold}>{label}</option>
              <% end %>
            </select>
          </div>

          <button
            phx-click="run_calibration"
            disabled={@recall_running}
            class={"px-6 py-2 rounded-lg font-medium #{if @recall_running, do: "bg-gray-100 text-gray-400 cursor-not-allowed", else: "bg-blue-600 hover:bg-blue-700 text-white"}"}
          >
            <%= if @recall_running do %>
              Running…
            <% else %>
              Run Calibration
            <% end %>
          </button>
        </div>
      </div>
      
    <!-- Loading state -->
      <%= if @recall_running do %>
        <div class="bg-white shadow rounded-lg p-12 text-center">
          <div class="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-500 mx-auto mb-4">
          </div>
          <p class="text-gray-500">Running calibration — this may take 2–3 minutes…</p>
        </div>
      <% end %>
      
    <!-- Results -->
      <%= if is_map(@recall_results) and not @recall_running do %>
        <!-- Overall Recall -->
        <% recall_pct = Float.round((@recall_results.overall_recall || 0) * 100, 1) %>
        <div class="bg-white shadow rounded-lg p-6">
          <div class="flex items-end gap-6 mb-4">
            <div>
              <div class={"text-6xl font-bold #{recall_color(@recall_results.overall_recall)}"}>
                {recall_pct}%
              </div>
              <div class="text-gray-500 mt-1">Overall Recall</div>
            </div>
            <div class="text-gray-500 text-sm pb-1">
              {@recall_results.total_found} of {@recall_results.total_reference} reference films surfaced
            </div>
          </div>

          <div class="w-full bg-gray-200 rounded-full h-4">
            <div
              class={"h-4 rounded-full #{recall_bar_color(@recall_results.overall_recall)}"}
              style={"width: #{min(100, recall_pct)}%"}
            >
            </div>
          </div>
          <div class="flex justify-between text-xs text-gray-500 mt-1">
            <span>0%</span>
            <span class="text-yellow-600">60%</span>
            <span class="text-green-600">75% target</span>
            <span>100%</span>
          </div>
        </div>
        
    <!-- Per-Decade Bars -->
        <div class="bg-white shadow rounded-lg p-6">
          <h3 class="text-lg font-semibold text-gray-900 mb-4">Recall by Decade</h3>
          <div class="space-y-3">
            <%= for {_decade, r} <- Enum.sort(@recall_results.by_decade, fn {a, _}, {b, _} -> a <= b end) do %>
              <% pct = Float.round(r.recall * 100, 1) %>
              <div class="flex items-center gap-3">
                <div class="w-16 text-sm text-gray-500 text-right">{r.decade_label}</div>
                <div class="flex-1 bg-gray-200 rounded-full h-5 relative">
                  <div
                    class={"h-5 rounded-full #{decade_bar_color(r.recall)}"}
                    style={"width: #{min(100, pct)}%"}
                  >
                  </div>
                </div>
                <div class="w-32 text-sm">
                  <span class={decade_text_color(r.recall)}>{pct}%</span>
                  <span class="text-gray-400 ml-1">({r.found}/{r.total})</span>
                </div>
              </div>
            <% end %>
          </div>
        </div>
        
    <!-- Lens Correlations -->
        <%= if @recall_results.lens_correlations != [] do %>
          <div class="bg-white shadow rounded-lg p-6">
            <h3 class="text-lg font-semibold text-gray-900 mb-4">Lens Scores (Reference Films)</h3>
            <p class="text-sm text-gray-500 mb-4">
              Mean score per lens across all matched reference films. Higher = this lens naturally elevates reference films.
            </p>
            <div class="space-y-3">
              <%= for corr <- @recall_results.lens_correlations do %>
                <div class="flex items-center gap-3">
                  <div class="w-40 text-sm text-gray-700">{corr.label}</div>
                  <div class="flex-1 bg-gray-200 rounded-full h-4">
                    <div
                      class="h-4 rounded-full bg-purple-500"
                      style={"width: #{min(100, corr.mean_score * 100)}%"}
                    >
                    </div>
                  </div>
                  <div class="w-16 text-sm text-right text-purple-600">
                    {Float.round(corr.mean_score * 100, 1)}%
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
        
    <!-- Systematic Gaps -->
        <%= if @recall_results.systematic_gaps != [] do %>
          <div class="bg-white shadow rounded-lg p-6">
            <h3 class="text-lg font-semibold text-gray-900 mb-4">Systematic Gaps</h3>
            <ul class="space-y-2">
              <%= for gap <- @recall_results.systematic_gaps do %>
                <li class="flex items-start gap-3 text-sm">
                  <span class="px-2 py-0.5 bg-gray-100 border border-gray-200 rounded text-xs text-gray-500 shrink-0 mt-0.5">
                    {gap.category}
                  </span>
                  <span class="text-gray-700">{gap.description}</span>
                </li>
              <% end %>
            </ul>
          </div>
        <% end %>
      <% end %>
      
    <!-- Error state -->
      <%= if match?({:error, _}, @recall_results) and not @recall_running do %>
        <% {:error, reason} = @recall_results %>
        <div class="bg-white shadow rounded-lg p-6 text-center">
          <p class="text-red-600">
            Calibration failed: {inspect(reason)}. Check that the 1001-movies reference list is imported and matched.
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  # Helper functions
  defp format_category_name(category) do
    category
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp format_category_abbrev(category) do
    case category do
      "mob" -> "Mob"
      "critics" -> "Crit"
      "festival_recognition" -> "Fest"
      "time_machine" -> "Time"
      "auteurs" -> "Aut"
      "box_office" -> "Box"
      _ -> String.slice(category, 0..2)
    end
  end

  defp get_weight(nil, active_weights, category), do: Map.get(active_weights, category, 0.2)

  defp get_weight(draft_weights, _active_weights, category),
    do: Map.get(draft_weights, category, 0.2)

  defp format_correlation(nil), do: "N/A"
  defp format_correlation(value), do: Float.round(value, 3)

  defp diff_color(value) when value > 0, do: "text-green-600"
  defp diff_color(value) when value < 0, do: "text-red-600"
  defp diff_color(_), do: "text-gray-500"

  defp diff_prefix(value) when value > 0, do: "+"
  defp diff_prefix(_), do: ""

  defp format_number(nil), do: "N/A"
  defp format_number(value) when is_float(value), do: Float.round(value, 2)
  defp format_number(value), do: value

  defp correlation_color(nil), do: "text-gray-400"
  defp correlation_color(value) when value >= 0.75, do: "text-green-600"
  defp correlation_color(value) when value >= 0.5, do: "text-yellow-600"
  defp correlation_color(_), do: "text-red-600"

  defp distribution_height(count, distribution) do
    max_count = distribution |> Map.values() |> Enum.max(fn -> 1 end)
    if max_count > 0, do: round(count / max_count * 100), else: 0
  end

  defp format_relative_time(nil), do: "never"

  defp format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  defp recall_color(recall) when recall >= 0.75, do: "text-green-600"
  defp recall_color(recall) when recall >= 0.60, do: "text-yellow-600"
  defp recall_color(_), do: "text-red-600"

  defp recall_bar_color(recall) when recall >= 0.75, do: "bg-green-500"
  defp recall_bar_color(recall) when recall >= 0.60, do: "bg-yellow-500"
  defp recall_bar_color(_), do: "bg-red-500"

  defp decade_bar_color(recall) when recall >= 0.75, do: "bg-green-500"
  defp decade_bar_color(recall) when recall >= 0.60, do: "bg-yellow-500"
  defp decade_bar_color(_), do: "bg-red-500"

  defp decade_text_color(recall) when recall >= 0.75, do: "text-green-600"
  defp decade_text_color(recall) when recall >= 0.60, do: "text-yellow-600"
  defp decade_text_color(_), do: "text-red-600"
end
