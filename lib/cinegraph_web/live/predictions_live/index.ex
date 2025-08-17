defmodule CinegraphWeb.PredictionsLive.Index do
  use CinegraphWeb, :live_view
  alias Cinegraph.Predictions.{MoviePredictor, HistoricalValidator}
  alias Cinegraph.Metrics.ScoringService

  @impl true
  def mount(_params, _session, socket) do
    # Load initial data with error handling
    try do
      predictions_result = MoviePredictor.predict_2020s_movies(100)
      validation_result = HistoricalValidator.validate_all_decades()
      confirmed_additions = MoviePredictor.get_confirmed_2020s_additions()
      
      # Optionally enable debug logging during development only
      if Mix.env() == :dev do
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
       |> assign(:confirmed_additions, confirmed_additions)
       |> assign(:selected_movie, nil)
       |> assign(:current_profile, ScoringService.get_default_profile())
       |> assign(:available_profiles, ScoringService.get_all_profiles())
       |> assign(:algorithm_weights, ScoringService.profile_to_discovery_weights(ScoringService.get_default_profile()))
       |> assign(:show_weight_tuner, false)
       |> assign(:last_updated, DateTime.utc_now())}
    rescue
      error ->
        default_profile = ScoringService.get_default_profile() || %Cinegraph.Metrics.MetricWeightProfile{name: "Balanced", category_weights: %{"ratings" => 0.4, "awards" => 0.2, "cultural" => 0.2, "financial" => 0.0, "people" => 0.2}}
        {:ok,
         socket
         |> assign(:page_title, "2020s Movie Predictions")
         |> assign(:loading, false)
         |> assign(:error, "Failed to load predictions. Please try again.")
         |> then(fn s -> 
           require Logger
           Logger.error("Predictions mount failed: #{Exception.format(:error, error, __STACKTRACE__)}")
           s 
         end)
         |> assign(:view_mode, :predictions)
         |> assign(:predictions_result, %{predictions: [], total_candidates: 0})
         |> assign(:validation_result, %{overall_accuracy: 0, decade_results: []})
         |> assign(:confirmed_additions, [])
         |> assign(:selected_movie, nil)
         |> assign(:current_profile, default_profile)
         |> assign(:available_profiles, [])
         |> assign(:algorithm_weights, %{popular_opinion: 0.2, critical_acclaim: 0.2, industry_recognition: 0.2, cultural_impact: 0.2, people_quality: 0.2})
         |> assign(:show_weight_tuner, false)
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
        "confirmed" -> :confirmed
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
    case ScoringService.get_profile(profile_name) do
      nil ->
        {:noreply, put_flash(socket, :error, "Profile not found")}
      profile ->
        # Use the profile for predictions
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
      new_weights = %{
        popular_opinion: String.to_float(params["popular_opinion"]) / 100,
        critical_acclaim: String.to_float(params["critical_acclaim"]) / 100,
        industry_recognition: String.to_float(params["industry_recognition"]) / 100,
        cultural_impact: String.to_float(params["cultural_impact"]) / 100,
        people_quality: String.to_float(params["people_quality"]) / 100
      }
      
      # Validate weights sum to approximately 1.0
      total_weight = new_weights |> Map.values() |> Enum.sum()
      
      if abs(total_weight - 1.0) > 0.01 do
        {:noreply, 
         socket
         |> put_flash(:error, "Weights must sum to 100%. Current total: #{round(total_weight * 100)}%")}
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
           Logger.warning("update_weights invalid input: #{Exception.format(:error, error, __STACKTRACE__)}")
           s 
         end)}
    end
  end

  def handle_event("reset_weights", _params, socket) do
    default_profile = ScoringService.get_default_profile()
    default_weights = ScoringService.profile_to_discovery_weights(default_profile)
    
    socket = assign(socket, :loading, true)
    
    predictions_result = MoviePredictor.predict_2020s_movies(100, default_weights)
    validation_result = HistoricalValidator.validate_all_decades(default_weights)
    
    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:current_profile, default_profile)
     |> assign(:algorithm_weights, default_weights)
     |> assign(:predictions_result, predictions_result)
     |> assign(:validation_result, validation_result)}
  end
  
  @impl true
  def handle_info({:recalculate_with_profile, profile}, socket) do
    try do
      # Perform calculations in background using the profile
      predictions_result = MoviePredictor.predict_2020s_movies(100, profile)
      validation_result = HistoricalValidator.validate_all_decades(profile)
      
      {:noreply,
       socket
       |> assign(:loading, false)
       |> assign(:predictions_result, predictions_result)
       |> assign(:validation_result, validation_result)
       |> assign(:last_updated, DateTime.utc_now())
       |> put_flash(:info, "Predictions updated successfully using #{profile.name} profile!")}
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

  defp format_likelihood(percentage) when percentage >= 90, do: {"#{percentage}%", "text-green-600 font-bold"}
  defp format_likelihood(percentage) when percentage >= 80, do: {"#{percentage}%", "text-blue-600 font-semibold"}
  defp format_likelihood(percentage) when percentage >= 70, do: {"#{percentage}%", "text-yellow-600"}
  defp format_likelihood(percentage), do: {"#{percentage}%", "text-gray-600"}

  defp criterion_label(:popular_opinion), do: "Popular Opinion"
  defp criterion_label(:critical_acclaim), do: "Critical Acclaim"
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
      {:ok, date} -> date.year
      _ -> 
        if is_struct(release_date, Date) do
          release_date.year
        else
          "Unknown"
        end
    end
  end
end