defmodule CinegraphWeb.PredictionsLive.Index do
  use CinegraphWeb, :live_view
  alias Cinegraph.Predictions.MoviePredictor
  alias Cinegraph.Metrics.ScoringService
  alias Cinegraph.Cache.PredictionsCache

  # Compile-time flag for debug logging (safe in releases)
  @dev_logging? Application.compile_env(:cinegraph, :dev_logging?, false)

  @impl true
  def mount(_params, _session, socket) do
    # Load initial data with error handling and caching
    try do
      default_profile = PredictionsCache.get_default_profile()

      # Get cached data - these return nil if not cached (no auto-calculation!)
      predictions_result = PredictionsCache.get_predictions(100, default_profile)
      validation_result = PredictionsCache.get_validation(default_profile)
      profile_comparison = PredictionsCache.get_profile_comparison()
      cache_status = PredictionsCache.get_cache_status(default_profile)

      # Handle nil results gracefully
      predictions_result =
        predictions_result || %{predictions: [], total_candidates: 0, algorithm_info: %{}}

      validation_result = validation_result || %{overall_accuracy: 0, decade_results: []}

      confirmed_count =
        if predictions_result.predictions == [] do
          0
        else
          PredictionsCache.get_confirmed_additions_count(predictions_result)
        end

      # Check if cache is empty or needs refresh based on enhanced status
      cache_empty = predictions_result.predictions == []
      cache_needs_refresh = Map.get(cache_status, :needs_refresh, true)

      # Optionally enable debug logging during development only (safe in releases)
      if @dev_logging? do
        require Logger
        Logger.debug("=== PREDICTIONS DEBUG ===")

        predictions_result.predictions
        |> Enum.take(5)
        |> Enum.each(fn pred ->
          Logger.debug("#{pred.title} likelihood=#{pred.prediction.likelihood_percentage}")
        end)
      end

      socket_assigns =
        socket
        |> assign(:page_title, "2020s Movie Predictions")
        |> assign(:loading, false)
        |> assign(:view_mode, :predictions)
        |> assign(:predictions_result, predictions_result)
        |> assign(:validation_result, validation_result)
        |> assign(:confirmed_count, confirmed_count)
        |> assign(:selected_movie, nil)
        |> assign(:current_profile, default_profile)
        |> assign(:available_profiles, ScoringService.get_all_profiles())
        |> assign(
          :algorithm_weights,
          ScoringService.profile_to_discovery_weights(default_profile)
        )
        |> assign(:show_weight_tuner, false)
        |> assign(:profile_comparison, profile_comparison)
        |> assign(:show_comparison, false)
        |> assign(:last_updated, DateTime.utc_now())
        |> assign(:cache_empty, cache_empty)
        |> assign(:cache_needs_refresh, cache_needs_refresh)
        |> assign(:cache_status, cache_status)

      # Add flash message if cache is empty or needs refresh
      socket_assigns =
        cond do
          cache_empty ->
            put_flash(
              socket_assigns,
              :info,
              "Cache is empty. Click 'Refresh Cache' to calculate predictions in the background."
            )

          cache_needs_refresh ->
            put_flash(
              socket_assigns,
              :warning,
              "Cache data is incomplete or invalid. Click 'Refresh Cache' to recalculate predictions."
            )

          true ->
            socket_assigns
        end

      {:ok, socket_assigns}
    rescue
      error ->
        require Logger

        Logger.error(
          "Predictions mount failed: #{Exception.format(:error, error, __STACKTRACE__)}"
        )

        # Try to use fallback data instead of empty results
        default_profile =
          PredictionsCache.get_default_profile() ||
            %Cinegraph.Metrics.MetricWeightProfile{
              name: "Balanced",
              category_weights: %{
                "ratings" => 0.4,
                "awards" => 0.2,
                "cultural" => 0.2,
                "financial" => 0.0,
                "people" => 0.2
              }
            }

        # Try to get cached results if available
        fallback_predictions =
          try do
            PredictionsCache.get_predictions(100, default_profile)
          rescue
            _ -> %{predictions: [], total_candidates: 0, algorithm_info: %{}}
          end

        fallback_validation =
          try do
            PredictionsCache.get_validation(default_profile)
          rescue
            _ -> %{overall_accuracy: 0, decade_results: []}
          end

        fallback_confirmed_count =
          try do
            PredictionsCache.get_confirmed_additions_count(fallback_predictions)
          rescue
            _ -> 0
          end

        {:ok,
         socket
         |> assign(:page_title, "2020s Movie Predictions")
         |> assign(:loading, false)
         |> assign(:error, "Some data may be loading in the background. Refresh if needed.")
         |> assign(:view_mode, :predictions)
         |> assign(:predictions_result, fallback_predictions)
         |> assign(:validation_result, fallback_validation)
         |> assign(:confirmed_count, fallback_confirmed_count)
         |> assign(:selected_movie, nil)
         |> assign(:current_profile, default_profile)
         |> assign(:available_profiles, ScoringService.get_all_profiles() || [])
         |> assign(
           :algorithm_weights,
           ScoringService.profile_to_discovery_weights(default_profile) ||
             %{
               popular_opinion: 0.20,
               industry_recognition: 0.20,
               cultural_impact: 0.20,
               people_quality: 0.20,
               financial_success: 0.20
             }
         )
         |> assign(:show_weight_tuner, false)
         |> assign(:profile_comparison, nil)
         |> assign(:show_comparison, false)
         |> assign(:last_updated, DateTime.utc_now())}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    case params["movie_id"] do
      nil ->
        {:noreply, assign(socket, :selected_movie, nil)}

      movie_id ->
        case Integer.parse(movie_id) do
          {id, ""} ->
            movie_details = MoviePredictor.get_movie_scoring_details(id)
            {:noreply, assign(socket, :selected_movie, movie_details)}

          _ ->
            {:noreply, assign(socket, :selected_movie, nil)}
        end
    end
  end

  @impl true
  def handle_event("switch_view", %{"mode" => mode}, socket) do
    view_mode =
      case mode do
        "predictions" -> :predictions
        "validation" -> :validation
        "cache_status" -> :cache_status
        "comparison" -> :comparison
        _ -> socket.assigns.view_mode
      end

    {:noreply, assign(socket, :view_mode, view_mode)}
  end

  @impl true
  def handle_event("select_movie", %{"movie_id" => movie_id}, socket) do
    {:noreply,
     socket
     |> push_patch(to: ~p"/admin/predictions?movie_id=#{movie_id}")}
  end

  @impl true
  def handle_event("close_movie_detail", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_movie, nil)
     |> push_patch(to: ~p"/admin/predictions")}
  end

  @impl true
  def handle_event("toggle_weight_tuner", _params, socket) do
    {:noreply, assign(socket, :show_weight_tuner, !socket.assigns.show_weight_tuner)}
  end

  @impl true
  def handle_event("select_profile", %{"profile" => profile_name}, socket) do
    case PredictionsCache.get_cached_profile(profile_name) do
      nil ->
        {:noreply, put_flash(socket, :error, "Profile not found")}

      profile ->
        # Use the profile for predictions with caching
        send(self(), {:recalculate_with_profile, profile})

        {:noreply,
         socket
         |> assign(:loading, true)
         |> assign(:current_profile, profile)
         |> assign(:algorithm_weights, ScoringService.profile_to_discovery_weights(profile))
         |> clear_flash()}
    end
  end

  def handle_event("update_weights", params, socket) do
    try do
      # Extract weights from form params with validation
      # Define helper function inline for parsing weight parameters
      parse_param = fn value ->
        cond do
          is_nil(value) ->
            0.0

          is_binary(value) ->
            case Integer.parse(value) do
              {int_val, ""} ->
                int_val / 100.0

              _ ->
                case Float.parse(value) do
                  {float_val, ""} -> float_val / 100.0
                  _ -> 0.0
                end
            end

          is_number(value) ->
            value / 100.0

          true ->
            0.0
        end
      end

      new_weights = %{
        popular_opinion: parse_param.(params["popular_opinion"]),
        industry_recognition: parse_param.(params["industry_recognition"]),
        cultural_impact: parse_param.(params["cultural_impact"]),
        people_quality: parse_param.(params["people_quality"]),
        financial_success: parse_param.(params["financial_success"])
      }

      # Validate weights sum to approximately 1.0
      total_weight = new_weights |> Map.values() |> Enum.sum()

      if abs(total_weight - 1.0) > 0.01 do
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Weights must sum to 100%. Current total: #{round(total_weight * 100)}%"
         )}
      else
        # Create a custom profile from the weights
        profile_map = ScoringService.discovery_weights_to_profile(new_weights)

        custom_profile = %Cinegraph.Metrics.MetricWeightProfile{
          name: "Custom",
          description: "Custom weights from UI",
          category_weights: profile_map.category_weights,
          weights: Map.get(profile_map, :weights, %{}),
          active: true
        }

        # Start progressive loading
        send(self(), {:recalculate_with_profile, custom_profile})

        {:noreply,
         socket
         |> assign(:loading, true)
         |> assign(:current_profile, custom_profile)
         |> assign(:algorithm_weights, new_weights)
         |> assign(:last_updated, DateTime.utc_now())
         |> clear_flash()}
      end
    rescue
      error ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid weight values. Please check your inputs.")
         |> then(fn s ->
           require Logger

           Logger.warning(
             "update_weights invalid input: #{Exception.format(:error, error, __STACKTRACE__)}"
           )

           s
         end)}
    end
  end

  def handle_event("reset_weights", _params, socket) do
    default_profile = PredictionsCache.get_default_profile()
    default_weights = ScoringService.profile_to_discovery_weights(default_profile)

    socket = assign(socket, :loading, true)

    predictions_result = PredictionsCache.get_predictions(100, default_profile)
    validation_result = PredictionsCache.get_validation(default_profile)

    # Handle nil results
    predictions_result =
      predictions_result || %{predictions: [], total_candidates: 0, algorithm_info: %{}}

    validation_result = validation_result || %{overall_accuracy: 0, decade_results: []}

    confirmed_count =
      if predictions_result.predictions == [] do
        0
      else
        PredictionsCache.get_confirmed_additions_count(predictions_result)
      end

    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:current_profile, default_profile)
     |> assign(:algorithm_weights, default_weights)
     |> assign(:predictions_result, predictions_result)
     |> assign(:validation_result, validation_result)
     |> assign(:confirmed_count, confirmed_count)
     |> assign(:cache_empty, predictions_result.predictions == [])}
  end

  @impl true
  def handle_event("refresh_cache", _params, socket) do
    # Queue background job to refresh cache
    case Cinegraph.Workers.PredictionsOrchestrator.orchestrate_default_profile() do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Cache refresh started! This will take a few minutes to complete in the background."
         )
         |> assign(:cache_refreshing, true)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to start cache refresh: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("clear_cache", _params, socket) do
    # Clear the prediction cache table
    case PredictionsCache.clear_cache() do
      {:ok, count} ->
        # Update socket assigns to reflect empty cache
        {:noreply,
         socket
         |> assign(:cache_empty, true)
         |> assign(:cache_status, %{
           cached: false,
           has_predictions: false,
           has_validation: false,
           last_calculated: nil
         })
         |> assign(:predictions_result, %{
           predictions: [],
           total_candidates: 0,
           algorithm_info: %{}
         })
         |> assign(:validation_result, %{overall_accuracy: 0, decade_results: []})
         |> assign(:confirmed_count, 0)
         |> put_flash(:info, "Cache cleared successfully! #{count} entries removed.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to clear cache: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:recalculate_with_profile, profile}, socket) do
    try do
      # Get cached data ONLY - no calculations!
      predictions_result = PredictionsCache.get_predictions(100, profile)
      validation_result = PredictionsCache.get_validation(profile)
      cache_status = PredictionsCache.get_cache_status(profile)

      # Handle nil results
      predictions_result =
        predictions_result || %{predictions: [], total_candidates: 0, algorithm_info: %{}}

      validation_result = validation_result || %{overall_accuracy: 0, decade_results: []}

      confirmed_count =
        if predictions_result.predictions == [] do
          0
        else
          PredictionsCache.get_confirmed_additions_count(predictions_result)
        end

      cache_empty = predictions_result.predictions == []

      flash_message =
        if cache_empty do
          "No cached data for #{profile.name} profile. Click 'Refresh Cache' to calculate."
        else
          "Loaded cached predictions for #{profile.name} profile!"
        end

      {:noreply,
       socket
       |> assign(:loading, false)
       |> assign(:predictions_result, predictions_result)
       |> assign(:validation_result, validation_result)
       |> assign(:confirmed_count, confirmed_count)
       |> assign(:cache_empty, cache_empty)
       |> assign(:cache_status, cache_status)
       |> assign(:last_updated, DateTime.utc_now())
       |> put_flash(:info, flash_message)}
    rescue
      error ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> put_flash(:error, "Failed to recalculate predictions. Please try again.")
         |> then(fn s ->
           require Logger
           Logger.error("Recalculate failed: #{Exception.format(:error, error, __STACKTRACE__)}")
           s
         end)}
    end
  end

  defp format_status(:already_added), do: {"✅ Added", "text-green-600"}
  defp format_status(:future_prediction), do: {"🔮 Future", "text-blue-600"}

  defp format_likelihood(percentage) when percentage >= 90,
    do: {"#{percentage}%", "text-green-600 font-bold"}

  defp format_likelihood(percentage) when percentage >= 80,
    do: {"#{percentage}%", "text-blue-600 font-semibold"}

  defp format_likelihood(percentage) when percentage >= 70,
    do: {"#{percentage}%", "text-yellow-600"}

  defp format_likelihood(percentage), do: {"#{percentage}%", "text-gray-600"}

  defp criterion_label(:popular_opinion), do: "Popular Opinion"
  defp criterion_label(:industry_recognition), do: "Industry Recognition"
  defp criterion_label(:cultural_impact), do: "Cultural Impact"
  defp criterion_label(:people_quality), do: "People Quality"
  defp criterion_label(:financial_success), do: "Financial Success"
  defp criterion_label(other), do: to_string(other)

  defp accuracy_color(percentage) when percentage >= 90, do: "text-green-600"
  defp accuracy_color(percentage) when percentage >= 80, do: "text-blue-600"
  defp accuracy_color(percentage) when percentage >= 70, do: "text-yellow-600"
  defp accuracy_color(_), do: "text-red-600"

  defp extract_year(release_date) when is_nil(release_date), do: "Unknown"

  defp extract_year(release_date) do
    case Date.from_iso8601(to_string(release_date)) do
      {:ok, date} ->
        date.year

      _ ->
        if is_struct(release_date, Date) do
          release_date.year
        else
          "Unknown"
        end
    end
  end
end
