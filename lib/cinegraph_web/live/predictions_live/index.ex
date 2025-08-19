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
      
      # Handle the new error tuple format from get_predictions
      {predictions_result, cache_status} = case PredictionsCache.get_predictions(100, default_profile) do
        {:error, :cache_missing, job_status} ->
          {nil, %{missing: true, job_status: job_status}}
        {:error, :cache_error, _reason} ->
          {nil, %{missing: true, job_status: :error}}
        result ->
          {result, %{missing: false, job_status: :ready}}
      end
      
      # Handle validation result
      validation_result = case PredictionsCache.get_validation(default_profile) do
        {:error, _, _} -> nil
        result -> result
      end
      
      confirmed_count = if predictions_result do
        PredictionsCache.get_confirmed_additions_count(predictions_result)
      else
        0
      end

      # Load profile comparison data (cached) - allow it to fail gracefully
      profile_comparison = case PredictionsCache.get_profile_comparison() do
        {:error, _, _} -> nil
        result -> result
      end

      # Optionally enable debug logging during development only (safe in releases)
      if @dev_logging? && predictions_result do
        require Logger
        Logger.debug("=== PREDICTIONS DEBUG ===")

        predictions_result.predictions
        |> Enum.take(5)
        |> Enum.each(fn pred ->
          Logger.debug("#{pred.title} likelihood=#{pred.prediction.likelihood_percentage}")
        end)
      end

      {:ok,
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
       |> assign(:algorithm_weights, ScoringService.profile_to_discovery_weights(default_profile))
       |> assign(:show_weight_tuner, false)
       |> assign(:profile_comparison, profile_comparison)
       |> assign(:show_comparison, false)
       |> assign(:cache_status, cache_status)
       |> assign(:last_updated, get_cache_timestamp(default_profile.id))}
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
        {fallback_predictions, fallback_cache_status} =
          try do
            case PredictionsCache.get_predictions(100, default_profile) do
              {:error, :cache_missing, job_status} ->
                {nil, %{missing: true, job_status: job_status}}
              {:error, :cache_error, _reason} ->
                {nil, %{missing: true, job_status: :error}}
              result ->
                {result, %{missing: false, job_status: :ready}}
            end
          rescue
            _ -> {nil, %{missing: true, job_status: :error}}
          end

        fallback_validation =
          try do
            case PredictionsCache.get_validation(default_profile) do
              {:error, _, _} -> nil
              result -> result
            end
          rescue
            _ -> nil
          end

        fallback_confirmed_count =
          if fallback_predictions do
            try do
              PredictionsCache.get_confirmed_additions_count(fallback_predictions)
            rescue
              _ -> 0
            end
          else
            0
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
               popular_opinion: 0.25,
               industry_recognition: 0.25,
               cultural_impact: 0.25,
               people_quality: 0.25
             }
         )
         |> assign(:show_weight_tuner, false)
         |> assign(:profile_comparison, nil)
         |> assign(:show_comparison, false)
         |> assign(:cache_status, fallback_cache_status)
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
        "comparison" -> :comparison
        _ -> socket.assigns.view_mode
      end

    {:noreply, assign(socket, :view_mode, view_mode)}
  end

  @impl true
  def handle_event("select_movie", %{"movie_id" => movie_id}, socket) do
    {:noreply,
     socket
     |> push_patch(to: ~p"/predictions?movie_id=#{movie_id}")}
  end

  @impl true
  def handle_event("close_movie_detail", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_movie, nil)
     |> push_patch(to: ~p"/predictions")}
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
        people_quality: parse_param.(params["people_quality"])
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

    # Handle the new error tuple format
    {predictions_result, cache_status} = case PredictionsCache.get_predictions(100, default_profile) do
      {:error, :cache_missing, job_status} ->
        {nil, %{missing: true, job_status: job_status}}
      {:error, :cache_error, _reason} ->
        {nil, %{missing: true, job_status: :error}}
      result ->
        {result, %{missing: false, job_status: :ready}}
    end
    
    validation_result = case PredictionsCache.get_validation(default_profile) do
      {:error, _, _} -> nil
      result -> result
    end
    
    confirmed_count = if predictions_result do
      PredictionsCache.get_confirmed_additions_count(predictions_result)
    else
      0
    end

    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:current_profile, default_profile)
     |> assign(:algorithm_weights, default_weights)
     |> assign(:predictions_result, predictions_result)
     |> assign(:validation_result, validation_result)
     |> assign(:confirmed_count, confirmed_count)
     |> assign(:cache_status, cache_status)}
  end
  
  @impl true
  def handle_event("refresh_predictions", _params, socket) do
    # Queue a refresh job for the current profile
    profile = socket.assigns.current_profile
    
    case Cinegraph.Predictions.RefreshManager.refresh_decade_profile(2020, profile.id) do
      {:ok, _job} ->
        {:noreply, 
         socket
         |> put_flash(:info, "Predictions refresh started. This may take a few minutes.")
         |> assign(:cache_status, %{missing: true, job_status: :calculating})}
         
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start refresh: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:recalculate_with_profile, profile}, socket) do
    try do
      # Perform calculations in background using the profile with caching
      {predictions_result, cache_status} = case PredictionsCache.get_predictions(100, profile) do
        {:error, :cache_missing, job_status} ->
          # No cache available - need to trigger refresh
          Cinegraph.Predictions.RefreshManager.refresh_decade_profile(2020, profile.id)
          {nil, %{missing: true, job_status: job_status}}
        {:error, :cache_error, _reason} ->
          {nil, %{missing: true, job_status: :error}}
        result ->
          {result, %{missing: false, job_status: :ready}}
      end
      
      validation_result = case PredictionsCache.get_validation(profile) do
        {:error, _, _} -> nil
        result -> result
      end
      
      confirmed_count = if predictions_result do
        PredictionsCache.get_confirmed_additions_count(predictions_result)
      else
        0
      end

      if predictions_result do
        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:predictions_result, predictions_result)
         |> assign(:validation_result, validation_result)
         |> assign(:confirmed_count, confirmed_count)
         |> assign(:cache_status, cache_status)
         |> assign(:last_updated, get_cache_timestamp(profile.id))
         |> put_flash(:info, "Predictions loaded successfully using #{profile.name} profile!")}
      else
        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:predictions_result, nil)
         |> assign(:validation_result, nil)
         |> assign(:confirmed_count, 0)
         |> assign(:cache_status, cache_status)
         |> put_flash(:warning, "Predictions need to be calculated. A refresh has been queued.")}
      end
    rescue
      error ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> put_flash(:error, "Failed to load predictions. Please try again.")
         |> then(fn s ->
           require Logger
           Logger.error("Recalculate failed: #{Exception.format(:error, error, __STACKTRACE__)}")
           s
         end)}
    end
  end

  defp format_status(:already_added), do: {"✅ Added", "text-green-600"}
  defp format_status(:predicted), do: {"📊 Predicted", "text-purple-600"}
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
  
  defp get_cache_timestamp(profile_id \\ nil) do
    # Use provided profile_id or default to 1 for backward compatibility
    pid = profile_id || 1
    case Cinegraph.Predictions.PredictionCache.get_cached_predictions(2020, pid) do
      nil -> nil
      cache -> cache.calculated_at
    end
  end
end
