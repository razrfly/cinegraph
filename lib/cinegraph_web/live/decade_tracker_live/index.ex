defmodule CinegraphWeb.DecadeTrackerLive.Index do
  use CinegraphWeb, :live_view
  alias Cinegraph.Movies.DecadeAnalyzer

  @impl true
  def mount(_params, _session, socket) do
    decade_data = DecadeAnalyzer.get_decade_distribution()
    current_year = Date.utc_today().year
    predictions = DecadeAnalyzer.predict_future_additions(current_year + 1, current_year + 5)
    recent_trends = DecadeAnalyzer.get_recent_year_trends(2010)
    available_editions = DecadeAnalyzer.get_available_editions()
    
    {:ok,
     socket
     |> assign(:page_title, "1001 Movies Decade Tracker")
     |> assign(:decade_data, decade_data)
     |> assign(:predictions, predictions)
     |> assign(:recent_trends, recent_trends)
     |> assign(:view_mode, :actual)
     |> assign(:selected_decade, nil)
     |> assign(:comparison_mode, false)
     |> assign(:available_editions, available_editions)
     |> assign(:edition1, List.first(available_editions) || "2024")
     |> assign(:edition2, Enum.at(available_editions, 1) || "2022")
     |> assign(:comparison_result, nil)
     |> assign(:prediction_candidates, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    decade = params["decade"] && String.to_integer(params["decade"])
    
    socket =
      if decade do
        decade_stats = DecadeAnalyzer.get_decade_stats(decade)
        assign(socket, :selected_decade, decade_stats)
      else
        socket
      end
    
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :view_mode, String.to_atom(mode))}
  end

  @impl true
  def handle_event("select_decade", %{"decade" => decade}, socket) do
    decade_int = String.to_integer(decade)
    decade_stats = DecadeAnalyzer.get_decade_stats(decade_int)
    
    {:noreply,
     socket
     |> assign(:selected_decade, decade_stats)
     |> push_patch(to: ~p"/movies/decades?decade=#{decade_int}")}
  end

  @impl true
  def handle_event("toggle_comparison", _params, socket) do
    {:noreply, assign(socket, :comparison_mode, !socket.assigns.comparison_mode)}
  end

  @impl true
  def handle_event("compare_editions", %{"edition1" => ed1, "edition2" => ed2}, socket) do
    comparison = DecadeAnalyzer.compare_editions(ed1, ed2)
    
    {:noreply,
     socket
     |> assign(:edition1, ed1)
     |> assign(:edition2, ed2)
     |> assign(:comparison_result, comparison)}
  end

  @impl true
  def handle_event("get_prediction_candidates", %{"year" => year}, socket) do
    year_int = String.to_integer(year)
    candidates = DecadeAnalyzer.get_prediction_candidates(year_int, 15)
    
    {:noreply, assign(socket, :prediction_candidates, candidates)}
  end

  defp calculate_max_count(decade_data) do
    decade_data
    |> Enum.map(& &1.count)
    |> Enum.max(fn -> 0 end)
  end


  defp format_decade_label(decade) do
    "#{decade}s"
  end

  defp format_year(year) when is_float(year), do: trunc(year)
  defp format_year(year), do: year
end