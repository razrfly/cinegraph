defmodule CinegraphWeb.PredictionsLive.Index do
  use CinegraphWeb, :live_view
  alias Cinegraph.Predictions.{MoviePredictor, HistoricalValidator, CriteriaScoring}

  @impl true
  def mount(_params, _session, socket) do
    # Load initial data with error handling
    try do
      predictions_result = MoviePredictor.predict_2020s_movies(100)
      validation_result = HistoricalValidator.validate_all_decades()
      confirmed_additions = MoviePredictor.get_confirmed_2020s_additions()
      
      # Debug: Log first few predictions
      IO.puts("=== PREDICTIONS DEBUG ===")
      predictions_result.predictions
      |> Enum.take(5)
      |> Enum.each(fn pred ->
        IO.inspect(pred.prediction.likelihood_percentage, label: "#{pred.title} likelihood")
      end)
      
      {:ok,
       socket
       |> assign(:page_title, "2020s Movie Predictions")
       |> assign(:loading, false)
       |> assign(:view_mode, :predictions)
       |> assign(:predictions_result, predictions_result)
       |> assign(:validation_result, validation_result)
       |> assign(:confirmed_additions, confirmed_additions)
       |> assign(:selected_movie, nil)
       |> assign(:algorithm_weights, CriteriaScoring.get_default_weights())
       |> assign(:show_weight_tuner, false)
       |> assign(:last_updated, DateTime.utc_now())}
    rescue
      error ->
        {:ok,
         socket
         |> assign(:page_title, "2020s Movie Predictions")
         |> assign(:loading, false)
         |> assign(:error, "Failed to load predictions: #{inspect(error)}")
         |> assign(:view_mode, :predictions)
         |> assign(:predictions_result, %{predictions: [], total_candidates: 0})
         |> assign(:validation_result, %{overall_accuracy: 0, decade_results: []})
         |> assign(:confirmed_additions, [])}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    case params["movie_id"] do
      nil ->
        {:noreply, assign(socket, :selected_movie, nil)}
      movie_id ->
        movie_details = MoviePredictor.get_movie_scoring_details(String.to_integer(movie_id))
        {:noreply, assign(socket, :selected_movie, movie_details)}
    end
  end

  @impl true
  def handle_event("switch_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :view_mode, String.to_atom(mode))}
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
  def handle_event("update_weights", params, socket) do
    try do
      # Extract weights from form params with validation
      new_weights = %{
        critical_acclaim: String.to_float(params["critical_acclaim"]) / 100,
        festival_recognition: String.to_float(params["festival_recognition"]) / 100,
        cultural_impact: String.to_float(params["cultural_impact"]) / 100,
        technical_innovation: String.to_float(params["technical_innovation"]) / 100,
        auteur_recognition: String.to_float(params["auteur_recognition"]) / 100
      }
      
      # Validate weights sum to approximately 1.0
      total_weight = new_weights |> Map.values() |> Enum.sum()
      
      if abs(total_weight - 1.0) > 0.01 do
        {:noreply, 
         socket
         |> put_flash(:error, "Weights must sum to 100%. Current total: #{round(total_weight * 100)}%")}
      else
        # Start progressive loading
        send(self(), {:recalculate_predictions, new_weights})
        
        {:noreply,
         socket
         |> assign(:loading, true)
         |> assign(:algorithm_weights, new_weights)
         |> assign(:last_updated, DateTime.utc_now())
         |> clear_flash()}
      end
    rescue
      error ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid weight values: #{inspect(error)}")}
    end
  end
  
  @impl true
  def handle_info({:recalculate_predictions, weights}, socket) do
    try do
      # Perform calculations in background
      predictions_result = MoviePredictor.predict_2020s_movies(100, weights)
      validation_result = HistoricalValidator.validate_all_decades(weights)
      
      {:noreply,
       socket
       |> assign(:loading, false)
       |> assign(:predictions_result, predictions_result)
       |> assign(:validation_result, validation_result)
       |> assign(:last_updated, DateTime.utc_now())
       |> put_flash(:info, "Predictions updated successfully!")}
    rescue
      error ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> put_flash(:error, "Failed to recalculate predictions: #{inspect(error)}")}
    end
  end

  @impl true
  def handle_event("reset_weights", _params, socket) do
    default_weights = CriteriaScoring.get_default_weights()
    
    socket = assign(socket, :loading, true)
    
    predictions_result = MoviePredictor.predict_2020s_movies(100, default_weights)
    validation_result = HistoricalValidator.validate_all_decades(default_weights)
    
    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:algorithm_weights, default_weights)
     |> assign(:predictions_result, predictions_result)
     |> assign(:validation_result, validation_result)}
  end

  defp format_status(:already_added), do: {"✅ Added", "text-green-600"}
  defp format_status(:future_prediction), do: {"🔮 Future", "text-blue-600"}

  defp format_likelihood(percentage) when percentage >= 90, do: {"#{percentage}%", "text-green-600 font-bold"}
  defp format_likelihood(percentage) when percentage >= 80, do: {"#{percentage}%", "text-blue-600 font-semibold"}
  defp format_likelihood(percentage) when percentage >= 70, do: {"#{percentage}%", "text-yellow-600"}
  defp format_likelihood(percentage), do: {"#{percentage}%", "text-gray-600"}

  defp criterion_label(:critical_acclaim), do: "Critical Acclaim"
  defp criterion_label(:festival_recognition), do: "Festival Recognition"
  defp criterion_label(:cultural_impact), do: "Cultural Impact"
  defp criterion_label(:technical_innovation), do: "Technical Innovation"
  defp criterion_label(:auteur_recognition), do: "Auteur Recognition"
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