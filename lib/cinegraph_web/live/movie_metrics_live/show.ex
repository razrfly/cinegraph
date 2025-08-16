defmodule CinegraphWeb.MovieMetricsLive.Show do
  @moduledoc """
  LiveView for displaying detailed metrics for a specific movie.
  Shows all metric values, scores, and breakdown by category.
  """

  use CinegraphWeb, :live_view

  alias Cinegraph.Movies
  alias Cinegraph.Metrics.{MetricDefinition, MetricWeightProfile}
  alias Cinegraph.Repo
  import Ecto.Query

  @impl true
  def mount(%{"id_or_slug" => id_or_slug}, _session, socket) do
    try do
      movie = load_movie_by_id_or_slug(id_or_slug)

      {:ok,
       socket
       |> assign(:page_title, "Metrics - #{movie.title}")
       |> assign(:movie, movie)
       |> assign(:loading, true)
       |> load_movie_metrics(movie)}
    rescue
      Ecto.NoResultsError ->
        {:ok,
         socket
         |> put_flash(:error, "Movie not found")
         |> redirect(to: ~p"/movies")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_profile", %{"profile" => profile_name}, socket) do
    profile = Enum.find(socket.assigns.weight_profiles, &(&1.name == profile_name))

    {:noreply,
     socket
     |> assign(:selected_profile, profile)
     |> calculate_movie_score(socket.assigns.movie, profile)}
  end

  # Private functions

  defp load_movie_metrics(socket, movie) do
    # Load all metric data for this movie
    metric_values = get_movie_metric_values(movie.id)
    weight_profiles = get_weight_profiles()
    metric_definitions = get_metric_definitions()

    # Calculate scores for all profiles
    profile_scores = calculate_all_profile_scores(movie, weight_profiles)

    socket
    |> assign(:metric_values, metric_values)
    |> assign(:weight_profiles, weight_profiles)
    |> assign(:metric_definitions, metric_definitions)
    |> assign(:profile_scores, profile_scores)
    |> assign(:selected_profile, List.first(weight_profiles))
    |> assign(:loading, false)
  end

  defp get_movie_metric_values(movie_id) do
    # Query metric_values_view for this specific movie
    query = """
    SELECT 
      metric_code,
      raw_value_text,
      raw_value_numeric,
      normalized_value,
      source_table,
      source_key
    FROM metric_values_view
    WHERE movie_id = $1
    ORDER BY metric_code
    """

    case Repo.query(query, [movie_id]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [code, raw_text, raw_numeric, normalized, source_table, source_key] ->
          %{
            metric_code: code,
            raw_value_text: raw_text,
            raw_value_numeric: raw_numeric,
            normalized_value: normalized,
            source_table: source_table,
            source_key: source_key
          }
        end)

      _ ->
        []
    end
  end

  defp get_weight_profiles do
    Repo.all(
      from wp in MetricWeightProfile,
        where: wp.active == true,
        order_by: [desc: wp.is_default, asc: wp.name]
    )
  end

  defp get_metric_definitions do
    Repo.all(
      from md in MetricDefinition,
        where: md.active == true,
        order_by: [asc: md.category, asc: md.name]
    )
    |> Enum.group_by(& &1.category)
  end

  defp calculate_all_profile_scores(movie, profiles) do
    alias Cinegraph.Metrics.ScoringService

    # Use the ScoringService to calculate scores for each profile
    Enum.map(profiles, fn profile ->
      query = from(m in Cinegraph.Movies.Movie, where: m.id == ^movie.id)

      try do
        scored_query = ScoringService.apply_scoring(query, profile, %{min_score: 0.0})

        result =
          scored_query
          |> select([m], %{
            discovery_score: m.discovery_score,
            components: m.score_components
          })
          |> Repo.one()

        %{
          profile: profile,
          total_score: result[:discovery_score] || 0.0,
          components: result[:components] || %{}
        }
      rescue
        _ ->
          %{
            profile: profile,
            total_score: 0.0,
            components: %{},
            error: "Score calculation failed"
          }
      end
    end)
  end

  defp calculate_movie_score(socket, movie, profile) do
    # Recalculate score for the selected profile
    scores = calculate_all_profile_scores(movie, [profile])
    selected_score = List.first(scores)

    assign(socket, :selected_score, selected_score)
  end

  # Helper functions for the template

  def format_score(score) when is_number(score) do
    "#{Float.round(score * 100, 1)}%"
  end

  def format_score(_), do: "N/A"

  def format_raw_value(%{raw_value_numeric: num}) when is_number(num) do
    if Float.round(num, 0) == num do
      "#{round(num)}"
    else
      "#{Float.round(num, 2)}"
    end
  end

  def format_raw_value(%{raw_value_text: text}) when is_binary(text), do: text
  def format_raw_value(_), do: "N/A"

  def category_color("ratings"), do: "blue"
  def category_color("awards"), do: "yellow"
  def category_color("cultural"), do: "purple"
  def category_color("financial"), do: "green"
  def category_color(_), do: "gray"

  def get_metric_by_code(metric_values, code) do
    Enum.find(metric_values, &(&1.metric_code == code))
  end

  defp load_movie_by_id_or_slug(id_or_slug) do
    if is_numeric_id?(id_or_slug) do
      Movies.get_movie!(id_or_slug)
    else
      Movies.get_movie_by_slug!(id_or_slug)
    end
  end

  defp is_numeric_id?(str) do
    case Integer.parse(str) do
      {_num, ""} -> true
      _ -> false
    end
  end
end
