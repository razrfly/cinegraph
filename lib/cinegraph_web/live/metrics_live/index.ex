defmodule CinegraphWeb.MetricsLive.Index do
  use CinegraphWeb, :live_view

  alias Cinegraph.Repo
  alias Cinegraph.Metrics.{MetricDefinition, MetricWeightProfile}
  alias Cinegraph.Movies.Movie
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Metrics Dashboard")
     |> assign(:loading, true)
     |> load_metrics_data()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:selected_profile, nil)
    |> assign(:selected_category, nil)
  end

  defp apply_action(socket, :profile, %{"name" => profile_name}) do
    profile = Enum.find(socket.assigns.weight_profiles, &(&1.name == profile_name))

    socket
    |> assign(:selected_profile, profile)
    |> load_profile_examples(profile)
  end

  @impl true
  def handle_event("select_profile", %{"profile" => profile_name}, socket) do
    profile = Enum.find(socket.assigns.weight_profiles, &(&1.name == profile_name))

    {:noreply,
     socket
     |> assign(:selected_profile, profile)
     |> load_profile_examples(profile)}
  end

  @impl true
  def handle_event("filter_category", %{"category" => category}, socket) do
    category = if category == "all", do: nil, else: category

    {:noreply, assign(socket, :selected_category, category)}
  end

  # Private functions

  defp load_metrics_data(socket) do
    # Load all the data we need
    metric_definitions = load_metric_definitions()
    weight_profiles = load_weight_profiles()
    coverage_stats = calculate_coverage_stats()
    category_stats = calculate_category_stats()
    value_distributions = calculate_value_distributions()
    total_movies = Repo.one(from m in Movie, select: count(m.id))
    profiles_sum_warning = check_profile_sums(weight_profiles)

    socket
    |> assign(:metric_definitions, metric_definitions)
    |> assign(:weight_profiles, weight_profiles)
    |> assign(:coverage_stats, coverage_stats)
    |> assign(:category_stats, category_stats)
    |> assign(:value_distributions, value_distributions)
    |> assign(:total_movies, total_movies)
    |> assign(:profiles_sum_warning, profiles_sum_warning)
    |> assign(:loading, false)
  end

  defp load_metric_definitions do
    Repo.all(
      from md in MetricDefinition,
        where: md.active == true,
        order_by: [asc: md.category, asc: md.subcategory, asc: md.name]
    )
  end

  defp load_weight_profiles do
    Repo.all(
      from wp in MetricWeightProfile,
        where: wp.active == true,
        order_by: [desc: wp.is_default, asc: wp.name]
    )
  end

  defp calculate_coverage_stats do
    # Get coverage from metric_values_view
    query = """
    SELECT 
      metric_code,
      COUNT(DISTINCT movie_id) as movie_count,
      COUNT(*) as total_values,
      AVG(CASE WHEN raw_value_numeric IS NOT NULL THEN raw_value_numeric END) as avg_value,
      MIN(CASE WHEN raw_value_numeric IS NOT NULL THEN raw_value_numeric END) as min_value,
      MAX(CASE WHEN raw_value_numeric IS NOT NULL THEN raw_value_numeric END) as max_value
    FROM metric_values_view
    GROUP BY metric_code
    """

    case Repo.query(query) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [code, movie_count, total_values, avg_value, min_value, max_value] ->
          {code,
           %{
             movie_count: movie_count,
             total_values: total_values,
             avg_value: avg_value && Float.round(avg_value, 2),
             min_value: min_value,
             max_value: max_value
           }}
        end)

      _ ->
        %{}
    end
  end

  defp calculate_category_stats do
    # Stats by category
    ratings_query = """
    SELECT 
      COUNT(DISTINCT em.movie_id) as movies_with_ratings
    FROM external_metrics em
    WHERE em.metric_type IN ('rating_average', 'metascore', 'tomatometer', 'audience_score')
    """

    awards_query = """
    SELECT 
      COUNT(DISTINCT fn.movie_id) as movies_with_awards
    FROM festival_nominations fn
    """

    cultural_query = """
    SELECT 
      COUNT(DISTINCT m.id) as movies_with_cultural
    FROM movies m
    WHERE m.canonical_sources IS NOT NULL 
      AND m.canonical_sources != '{}'::jsonb
    """

    financial_query = """
    SELECT 
      COUNT(DISTINCT m.id) as movies_with_financial
    FROM movies m
    WHERE (m.tmdb_data->>'budget' IS NOT NULL AND (m.tmdb_data->>'budget')::bigint > 0)
       OR (m.tmdb_data->>'revenue' IS NOT NULL AND (m.tmdb_data->>'revenue')::bigint > 0)
    """

    people_query = """
    SELECT 
      COUNT(DISTINCT mc.movie_id) as movies_with_people_scores
    FROM movie_credits mc
    JOIN person_metrics pm ON mc.person_id = pm.person_id
    WHERE pm.metric_type IN ('quality_score', 'director_quality', 'actor_quality', 'writer_quality', 'producer_quality')
    """

    %{
      ratings: get_single_count(ratings_query),
      awards: get_single_count(awards_query),
      cultural: get_single_count(cultural_query),
      financial: get_single_count(financial_query),
      people: get_single_count(people_query)
    }
  end

  defp get_single_count(query) do
    case Repo.query(query) do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end

  defp calculate_value_distributions do
    # Get distributions for key metrics

    # IMDb rating distribution
    imdb_dist = get_rating_distribution("imdb", "rating_average")

    # Oscar nominations distribution
    oscar_dist = get_oscar_distribution()

    # TMDb popularity distribution  
    popularity_dist = get_popularity_distribution()

    %{
      imdb_rating: imdb_dist,
      oscar_nominations: oscar_dist,
      tmdb_popularity: popularity_dist
    }
  end

  defp get_rating_distribution(source, metric_type) do
    query = """
    SELECT 
      CASE 
        WHEN value < 2 THEN '0-2'
        WHEN value < 4 THEN '2-4'
        WHEN value < 6 THEN '4-6'
        WHEN value < 8 THEN '6-8'
        ELSE '8-10'
      END as bucket,
      COUNT(*) as count
    FROM external_metrics
    WHERE source = $1 AND metric_type = $2
    GROUP BY bucket
    ORDER BY bucket
    """

    case Repo.query(query, [source, metric_type]) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [bucket, count] -> {bucket, count} end)

      _ ->
        %{}
    end
  end

  defp get_oscar_distribution do
    query = """
    SELECT 
      CASE 
        WHEN nom_count = 0 THEN '0'
        WHEN nom_count <= 3 THEN '1-3'
        WHEN nom_count <= 7 THEN '4-7'
        ELSE '8+'
      END as bucket,
      COUNT(*) as movie_count
    FROM (
      SELECT 
        m.id,
        COUNT(fn.id) as nom_count
      FROM movies m
      LEFT JOIN festival_nominations fn ON fn.movie_id = m.id
      LEFT JOIN festival_ceremonies fc ON fn.ceremony_id = fc.id
      LEFT JOIN festival_organizations fo ON fc.organization_id = fo.id
      WHERE fo.abbreviation = 'AMPAS' OR fo.abbreviation IS NULL
      GROUP BY m.id
    ) as nom_counts
    GROUP BY bucket
    ORDER BY bucket
    """

    case Repo.query(query) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [bucket, count] -> {bucket, count} end)

      _ ->
        %{}
    end
  end

  defp check_profile_sums(profiles) do
    profiles
    |> Enum.map(fn profile ->
      weights = profile.category_weights || %{}
      sum = Map.values(weights) |> Enum.sum()

      if abs(sum - 1.0) > 0.01 do
        {profile.name, sum}
      else
        nil
      end
    end)
    |> Enum.filter(& &1)
  end

  defp get_popularity_distribution do
    query = """
    SELECT 
      CASE 
        WHEN value < 10 THEN '0-10'
        WHEN value < 50 THEN '10-50'
        WHEN value < 100 THEN '50-100'
        WHEN value < 500 THEN '100-500'
        ELSE '500+'
      END as bucket,
      COUNT(*) as count
    FROM external_metrics
    WHERE source = 'tmdb' AND metric_type = 'popularity_score'
    GROUP BY bucket
    ORDER BY bucket
    """

    case Repo.query(query) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [bucket, count] -> {bucket, count} end)

      _ ->
        %{}
    end
  end

  defp load_profile_examples(socket, nil), do: socket

  defp load_profile_examples(socket, profile) do
    # Load top 5 movies for this profile
    alias Cinegraph.Metrics.ScoringService

    query = from(m in Movie)
    scored_query = ScoringService.apply_scoring(query, profile, %{min_score: 0.0})

    top_movies =
      scored_query
      |> limit(5)
      |> select([m], %{
        id: m.id,
        title: m.title,
        year: fragment("EXTRACT(YEAR FROM ?)", m.release_date),
        score: m.discovery_score,
        components: m.score_components
      })
      |> Repo.all()

    assign(socket, :profile_examples, top_movies)
  end

  # Helper functions for the template

  def format_percentage(count, total) when total > 0 do
    percentage = Float.round(count / total * 100, 1)
    "#{percentage}%"
  end

  def format_percentage(_, _), do: "0%"

  def format_coverage(count, total) when total > 0 do
    percentage = Float.round(count / total * 100, 1)
    "#{percentage}% (#{format_number(count)}/#{format_number(total)})"
  end

  def format_coverage(_, _), do: "0% (0/0)"

  def format_number(n) when n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  def format_number(n) when n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}K"
  end

  def format_number(n), do: "#{n}"

  def category_color("ratings"), do: "blue"
  def category_color("awards"), do: "yellow"
  def category_color("cultural"), do: "purple"
  def category_color("financial"), do: "green"
  def category_color("people"), do: "orange"
  def category_color(_), do: "gray"

  def get_metric_coverage(metric_code, coverage_stats, total_movies) do
    case Map.get(coverage_stats, metric_code) do
      nil -> {0, 0.0}
      %{movie_count: count} -> {count, Float.round(count / total_movies * 100, 1)}
      _ -> {0, 0.0}
    end
  end

  def get_profile_weight(profile, category) do
    weights = profile.category_weights || %{}
    # Default to 20% for 5 categories instead of 25% for 4
    weight = Map.get(weights, category, 0.20)
    round(weight * 100)
  end

  def get_profile_weight_actual(profile, category) do
    # Get the actual weight for displaying what's really in the database
    weights = profile.category_weights || %{}
    # Don't default - show actual DB value (0 if not set)
    weight = Map.get(weights, category, 0.0)
    Float.round(weight * 100, 1)
  end

  def get_metric_weight(profile, metric_code) do
    weights = profile.weights || %{}
    Map.get(weights, metric_code, 1.0)
  end

  def distribution_bar_width(count, total) when total > 0 do
    "#{Float.round(count / total * 100, 0)}%"
  end

  def distribution_bar_width(_, _), do: "0%"
end
