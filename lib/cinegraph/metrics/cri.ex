defmodule Cinegraph.Metrics.CRI do
  @moduledoc """
  Cultural Relevance Index (CRI) system for movie scoring and search.
  Handles normalization, scoring, and backtesting against canonical lists.
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Metrics.{MetricDefinition, Metric, WeightProfile, CRIScore}
  alias Cinegraph.Movies.Movie

  # ========== NORMALIZATION FUNCTIONS ==========

  @doc """
  Normalizes a raw metric value according to its definition.
  Returns a value between 0.0 and 1.0.
  """
  def normalize_value(metric_code, raw_value) when is_binary(metric_code) do
    case Repo.get_by(MetricDefinition, code: metric_code) do
      nil -> {:error, "Unknown metric: #{metric_code}"}
      definition -> normalize_value(definition, raw_value)
    end
  end

  def normalize_value(%MetricDefinition{} = definition, raw_value) do
    case definition.normalization_type do
      "linear" ->
        linear_normalize(raw_value, definition.raw_scale_min, definition.raw_scale_max)
      
      "logarithmic" ->
        threshold = definition.normalization_params["threshold"] || 1_000_000
        log_normalize(raw_value, threshold)
      
      "sigmoid" ->
        k = definition.normalization_params["k"] || 0.05
        midpoint = definition.normalization_params["midpoint"] || 50
        sigmoid_normalize(raw_value, k, midpoint)
      
      "boolean" ->
        boolean_normalize(raw_value, definition.normalization_params)
      
      "custom" ->
        custom_normalize(definition.code, raw_value, definition.normalization_params)
      
      _ ->
        {:error, "Unknown normalization type: #{definition.normalization_type}"}
    end
  end

  # Linear normalization for bounded scales
  defp linear_normalize(value, min, max) when is_number(value) do
    if max == min do
      0.0
    else
      normalized = (value - min) / (max - min)
      max(0.0, min(1.0, normalized))
    end
  end
  defp linear_normalize(_, _, _), do: 0.0

  # Logarithmic normalization for unbounded scales
  defp log_normalize(value, threshold) when is_number(value) and value >= 0 do
    numerator = :math.log(value + 1)
    denominator = :math.log(threshold + 1)
    
    if denominator == 0 do
      0.0
    else
      result = numerator / denominator
      max(0.0, min(1.0, result))
    end
  end
  defp log_normalize(_, _), do: 0.0

  # Sigmoid normalization for rankings (lower rank = better)
  defp sigmoid_normalize(rank, k, midpoint) when is_number(rank) do
    result = 1 / (1 + :math.exp(-k * (midpoint - rank)))
    max(0.0, min(1.0, result))
  end
  defp sigmoid_normalize(_, _, _), do: 0.0

  # Boolean normalization
  defp boolean_normalize(value, params) when is_map(params) do
    key = to_string(value)
    Map.get(params, key, if(value, do: 1.0, else: 0.0))
  end
  defp boolean_normalize(value, _params) do
    if value, do: 1.0, else: 0.0
  end

  # Custom normalization for special cases
  defp custom_normalize("oscar_nominations", count, params) do
    cond do
      count == 0 -> params["0"] || 0.0
      count == 1 -> params["1"] || 0.5
      count == 2 -> params["2"] || 0.7
      count >= 3 -> params["3+"] || 1.0
      true -> 0.0
    end
  end

  defp custom_normalize("oscar_wins", count, params) do
    cond do
      count == 0 -> params["0"] || 0.0
      count == 1 -> params["1"] || 0.6
      count == 2 -> params["2"] || 0.8
      count >= 3 -> params["3+"] || 1.0
      true -> 0.0
    end
  end

  defp custom_normalize("restoration_count", count, params) do
    cond do
      count == 0 -> params["0"] || 0.0
      count == 1 -> params["1"] || 0.5
      count == 2 -> params["2"] || 0.8
      count >= 3 -> params["3+"] || 1.0
      true -> 0.0
    end
  end

  defp custom_normalize(_code, _value, _params), do: 0.0

  # ========== SCORING FUNCTIONS ==========

  @doc """
  Calculates CRI score for a movie using a specific weight profile.
  """
  def calculate_score(movie_id, profile_name_or_id) do
    with {:ok, profile} <- get_weight_profile(profile_name_or_id),
         {:ok, metrics} <- get_movie_metrics(movie_id),
         {:ok, dimension_scores} <- calculate_dimension_scores(metrics, profile),
         {:ok, total_score} <- calculate_total_score(dimension_scores, profile) do
      
      # Save the score
      cri_score = %CRIScore{
        movie_id: movie_id,
        profile_id: profile.id,
        timelessness_score: dimension_scores.timelessness,
        cultural_penetration_score: dimension_scores.cultural_penetration,
        artistic_impact_score: dimension_scores.artistic_impact,
        institutional_score: dimension_scores.institutional,
        public_score: dimension_scores.public,
        total_cri_score: total_score,
        explain: %{
          "dimension_scores" => dimension_scores,
          "profile_used" => profile.name
        }
      }
      
      case Repo.insert(cri_score,
        on_conflict: :replace_all,
        conflict_target: [:movie_id, :profile_id]
      ) do
        {:ok, score} -> {:ok, score}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  defp get_weight_profile(name) when is_binary(name) do
    case Repo.get_by(WeightProfile, name: name, active: true) do
      nil -> {:error, "Profile not found: #{name}"}
      profile -> {:ok, profile}
    end
  end

  defp get_weight_profile(id) when is_integer(id) do
    case Repo.get(WeightProfile, id) do
      nil -> {:error, "Profile not found: #{id}"}
      profile -> {:ok, profile}
    end
  end

  defp get_movie_metrics(movie_id) do
    metrics = 
      from(m in Metric,
        where: m.movie_id == ^movie_id,
        join: md in MetricDefinition,
        on: m.metric_code == md.code,
        select: %{
          code: m.metric_code,
          normalized_value: m.normalized_value,
          cri_dimension: md.cri_dimension,
          source_reliability: md.source_reliability
        }
      )
      |> Repo.all()
    
    if metrics == [] do
      {:error, "No metrics found for movie #{movie_id}"}
    else
      {:ok, metrics}
    end
  end

  defp calculate_dimension_scores(metrics, profile) do
    # Group metrics by CRI dimension
    dimension_groups = Enum.group_by(metrics, & &1.cri_dimension)
    
    # Calculate weighted average for each dimension
    dimension_scores = 
      ~w(timelessness cultural_penetration artistic_impact institutional public)
      |> Enum.map(fn dimension ->
        dimension_metrics = Map.get(dimension_groups, dimension, [])
        
        score = if dimension_metrics == [] do
          0.0
        else
          # Get metric-level weights from profile
          weighted_sum = 
            dimension_metrics
            |> Enum.map(fn metric ->
              metric_weight = get_metric_weight(profile, metric.code)
              metric.normalized_value * metric_weight * metric.source_reliability
            end)
            |> Enum.sum()
          
          # Normalize by total weights
          total_weight = 
            dimension_metrics
            |> Enum.map(fn metric ->
              metric_weight = get_metric_weight(profile, metric.code)
              metric_weight * metric.source_reliability
            end)
            |> Enum.sum()
          
          if total_weight > 0 do
            weighted_sum / total_weight
          else
            0.0
          end
        end
        
        {String.to_atom(dimension), score}
      end)
      |> Map.new()
    
    {:ok, dimension_scores}
  end

  defp get_metric_weight(profile, metric_code) do
    profile.metric_weights[metric_code] || 1.0
  end

  defp calculate_total_score(dimension_scores, profile) do
    total = 
      dimension_scores.timelessness * profile.timelessness_weight +
      dimension_scores.cultural_penetration * profile.cultural_penetration_weight +
      dimension_scores.artistic_impact * profile.artistic_impact_weight +
      dimension_scores.institutional * profile.institutional_weight +
      dimension_scores.public * profile.public_weight
    
    {:ok, max(0.0, min(1.0, total))}
  end

  # ========== SEARCH FUNCTIONS ==========

  @doc """
  Searches movies using normalized metrics.
  
  Examples:
    # General search across category
    search(%{category: "rating", min_normalized: 0.8})
    
    # Specific metric search
    search(%{metric_code: "metacritic_score", min_raw_value: 80})
    
    # CRI dimension search
    search(%{cri_dimension: "institutional", min_normalized: 0.5})
  """
  def search(params) do
    # Build query with proper bindings
    query = 
      from(m in Movie,
        as: :movie,
        join: metric in Metric,
        on: metric.movie_id == m.id,
        as: :metric,
        join: md in MetricDefinition,
        on: metric.metric_code == md.code,
        as: :definition
      )
    
    # Apply filters
    query = 
      params
      |> Enum.reduce(query, fn
        {:category, category}, query ->
          from [movie: m, metric: metric, definition: md] in query,
            where: md.category == ^category
        
        {:cri_dimension, dimension}, query ->
          from [movie: m, metric: metric, definition: md] in query,
            where: md.cri_dimension == ^dimension
        
        {:metric_code, code}, query ->
          from [movie: m, metric: metric, definition: md] in query,
            where: metric.metric_code == ^code
        
        {:min_normalized, min_val}, query ->
          from [movie: m, metric: metric, definition: md] in query,
            where: metric.normalized_value >= ^min_val
        
        {:max_normalized, max_val}, query ->
          from [movie: m, metric: metric, definition: md] in query,
            where: metric.normalized_value <= ^max_val
        
        {:min_raw_value, min_val}, query ->
          from [movie: m, metric: metric, definition: md] in query,
            where: metric.raw_value_numeric >= ^min_val
        
        {:max_raw_value, max_val}, query ->
          from [movie: m, metric: metric, definition: md] in query,
            where: metric.raw_value_numeric <= ^max_val
        
        {:raw_value_text, text}, query ->
          from [movie: m, metric: metric, definition: md] in query,
            where: metric.raw_value_text == ^text
        
        _, query ->
          query
      end)
    
    query
    |> select([movie: m], m)
    |> distinct(true)
    |> Repo.all()
  end

  # ========== PROFILE MANAGEMENT ==========

  @doc """
  Creates a new weight profile.
  """
  def create_weight_profile(attrs) do
    %WeightProfile{}
    |> WeightProfile.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing weight profile.
  """
  def update_weight_profile(profile_id, attrs) do
    case Repo.get(WeightProfile, profile_id) do
      nil -> {:error, "Profile not found"}
      profile ->
        profile
        |> WeightProfile.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Lists all active weight profiles.
  """
  def list_weight_profiles do
    from(wp in WeightProfile,
      where: wp.active == true,
      order_by: [desc: wp.is_default, asc: wp.name]
    )
    |> Repo.all()
  end

  # ========== BACKTESTING ==========

  @doc """
  Backtests a weight profile against the 1001 Movies list.
  Returns precision, recall, and F1 score.
  """
  def backtest_profile(profile_name_or_id) do
    with {:ok, profile} <- get_weight_profile(profile_name_or_id),
         {:ok, ground_truth} <- get_1001_movies_list(),
         {:ok, predictions} <- get_top_movies_by_profile(profile, 1001) do
      
      # Calculate metrics
      true_positives = MapSet.intersection(ground_truth, predictions) |> MapSet.size()
      false_positives = MapSet.difference(predictions, ground_truth) |> MapSet.size()
      false_negatives = MapSet.difference(ground_truth, predictions) |> MapSet.size()
      
      precision = if true_positives + false_positives > 0 do
        true_positives / (true_positives + false_positives)
      else
        0.0
      end
      
      recall = if true_positives + false_negatives > 0 do
        true_positives / (true_positives + false_negatives)
      else
        0.0
      end
      
      f1_score = if precision + recall > 0 do
        2 * (precision * recall) / (precision + recall)
      else
        0.0
      end
      
      overlap_percentage = (true_positives / MapSet.size(ground_truth)) * 100
      
      # Update profile with results
      profile
      |> WeightProfile.changeset(%{
        backtest_score: overlap_percentage,
        precision_score: precision,
        recall_score: recall,
        f1_score: f1_score
      })
      |> Repo.update()
      
      {:ok, %{
        precision: precision,
        recall: recall,
        f1_score: f1_score,
        overlap_percentage: overlap_percentage,
        true_positives: true_positives,
        false_positives: false_positives,
        false_negatives: false_negatives
      }}
    end
  end

  defp get_1001_movies_list do
    # Get all movies that are in the 1001 Movies list
    movie_ids = 
      from(m in Metric,
        where: m.metric_code == "1001_movies" and m.raw_value_text == "true",
        select: m.movie_id
      )
      |> Repo.all()
      |> MapSet.new()
    
    {:ok, movie_ids}
  end

  defp get_top_movies_by_profile(profile, count) do
    # Get top N movies by CRI score for this profile
    movie_ids = 
      from(cs in CRIScore,
        where: cs.profile_id == ^profile.id,
        order_by: [desc: cs.total_cri_score],
        limit: ^count,
        select: cs.movie_id
      )
      |> Repo.all()
      |> MapSet.new()
    
    {:ok, movie_ids}
  end
end