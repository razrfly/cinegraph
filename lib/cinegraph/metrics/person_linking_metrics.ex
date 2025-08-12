defmodule Cinegraph.Metrics.PersonLinkingMetrics do
  @moduledoc """
  Person linking metrics and analytics for Issue #236 comprehensive tracking.
  Provides insights into person linking success rates, performance, and accuracy.
  """
  
  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Metrics.ApiLookupMetric

  @doc """
  Get person linking success rates for the last N hours.
  """
  def get_person_linking_success_rate(hours_back \\ 24) do
    since = DateTime.utc_now() |> DateTime.add(-hours_back, :hour)
    
    query = from m in ApiLookupMetric,
      where: m.source == "person_linking" and m.inserted_at >= ^since,
      select: %{
        operation: m.operation,
        success: m.success,
        response_time_ms: m.response_time_ms,
        metadata: m.metadata
      }
    
    metrics = Repo.all(query)
    
    %{
      total_operations: length(metrics),
      success_rate: calculate_success_rate(metrics),
      operations_breakdown: group_by_operation(metrics),
      avg_response_time: calculate_avg_response_time(metrics),
      strategy_breakdown: get_strategy_breakdown(metrics)
    }
  end

  @doc """
  Get category-specific person linking accuracy.
  """
  def get_category_linking_accuracy(hours_back \\ 24) do
    since = DateTime.utc_now() |> DateTime.add(-hours_back, :hour)
    
    query = from m in ApiLookupMetric,
      where: m.source == "person_linking" and 
             m.operation in ["credit_based_match", "tmdb_person_search"] and 
             m.inserted_at >= ^since,
      select: %{
        success: m.success,
        metadata: m.metadata,
        response_time_ms: m.response_time_ms
      }
    
    metrics = Repo.all(query)
    
    # Group by category
    category_groups = 
      metrics
      |> Enum.group_by(fn metric -> 
        get_in(metric.metadata, ["category"]) || "unknown" 
      end)
    
    category_groups
    |> Enum.map(fn {category, category_metrics} ->
      %{
        category: category,
        total_attempts: length(category_metrics),
        success_rate: calculate_success_rate(category_metrics),
        avg_response_time: calculate_avg_response_time(category_metrics),
        avg_confidence: calculate_avg_confidence(category_metrics)
      }
    end)
    |> Enum.sort_by(& &1.success_rate, :desc)
  end

  @doc """
  Get query performance impact metrics.
  """
  def get_query_performance_impact(hours_back \\ 24) do
    since = DateTime.utc_now() |> DateTime.add(-hours_back, :hour)
    
    query = from m in ApiLookupMetric,
      where: m.source == "person_linking" and m.inserted_at >= ^since,
      select: %{
        operation: m.operation,
        response_time_ms: m.response_time_ms,
        metadata: m.metadata,
        inserted_at: m.inserted_at
      }
    
    metrics = Repo.all(query)
    
    %{
      avg_credit_query_time: get_avg_response_time_for_operation(metrics, "credit_based_match"),
      avg_tmdb_search_time: get_avg_response_time_for_operation(metrics, "tmdb_person_search"),
      performance_by_hour: get_performance_by_hour(metrics),
      department_filter_impact: analyze_department_filter_impact(metrics),
      movie_context_impact: analyze_movie_context_impact(metrics)
    }
  end

  @doc """
  Get false positive/negative rates (estimated based on confidence scores).
  """
  def get_accuracy_metrics(hours_back \\ 24) do
    since = DateTime.utc_now() |> DateTime.add(-hours_back, :hour)
    
    query = from m in ApiLookupMetric,
      where: m.source == "person_linking" and 
             m.operation in ["credit_based_match", "tmdb_person_search"] and
             m.success == true and
             m.inserted_at >= ^since,
      select: %{
        operation: m.operation,
        metadata: m.metadata
      }
    
    metrics = Repo.all(query)
    
    # Analyze confidence distributions
    confidence_scores = 
      metrics
      |> Enum.filter(fn metric -> get_in(metric.metadata, ["confidence"]) end)
      |> Enum.map(fn metric -> get_in(metric.metadata, ["confidence"]) end)
    
    %{
      high_confidence_matches: Enum.count(confidence_scores, &(&1 > 0.9)),
      medium_confidence_matches: Enum.count(confidence_scores, &(&1 >= 0.8 and &1 <= 0.9)),
      low_confidence_matches: Enum.count(confidence_scores, &(&1 < 0.8)),
      avg_confidence: (if length(confidence_scores) > 0, do: Enum.sum(confidence_scores) / length(confidence_scores), else: 0.0),
      confidence_distribution: calculate_confidence_distribution(confidence_scores)
    }
  end

  # Private helper functions

  defp calculate_success_rate([]), do: 0.0
  defp calculate_success_rate(metrics) do
    successful = Enum.count(metrics, & &1.success)
    successful / length(metrics) * 100.0
  end

  defp group_by_operation(metrics) do
    metrics
    |> Enum.group_by(& &1.operation)
    |> Enum.map(fn {operation, operation_metrics} ->
      %{
        operation: operation,
        count: length(operation_metrics),
        success_rate: calculate_success_rate(operation_metrics),
        avg_response_time: calculate_avg_response_time(operation_metrics)
      }
    end)
  end

  defp calculate_avg_response_time([]), do: 0.0
  defp calculate_avg_response_time(metrics) do
    response_times = Enum.map(metrics, & &1.response_time_ms)
    Enum.sum(response_times) / length(response_times)
  end

  defp get_strategy_breakdown(metrics) do
    metrics
    |> Enum.filter(fn metric -> get_in(metric.metadata, ["strategy"]) end)
    |> Enum.group_by(fn metric -> get_in(metric.metadata, ["strategy"]) end)
    |> Enum.map(fn {strategy, strategy_metrics} ->
      %{
        strategy: strategy,
        count: length(strategy_metrics),
        success_rate: calculate_success_rate(strategy_metrics)
      }
    end)
  end

  defp calculate_avg_confidence(metrics) do
    confidence_scores = 
      metrics
      |> Enum.filter(fn metric -> get_in(metric.metadata, ["confidence"]) end)
      |> Enum.map(fn metric -> get_in(metric.metadata, ["confidence"]) end)
    
    if length(confidence_scores) > 0 do
      Enum.sum(confidence_scores) / length(confidence_scores)
    else
      0.0
    end
  end

  defp get_avg_response_time_for_operation(metrics, operation) do
    operation_metrics = Enum.filter(metrics, &(&1.operation == operation))
    calculate_avg_response_time(operation_metrics)
  end

  defp get_performance_by_hour(metrics) do
    metrics
    |> Enum.group_by(fn metric -> 
      metric.inserted_at 
      |> DateTime.truncate(:second) 
      |> Map.put(:minute, 0) 
      |> Map.put(:second, 0)
    end)
    |> Enum.map(fn {hour, hour_metrics} ->
      %{
        hour: hour,
        operations: length(hour_metrics),
        avg_response_time: calculate_avg_response_time(hour_metrics),
        success_rate: calculate_success_rate(hour_metrics)
      }
    end)
    |> Enum.sort_by(& &1.hour, {:desc, DateTime})
  end

  defp analyze_department_filter_impact(metrics) do
    with_filter = Enum.filter(metrics, fn metric -> 
      get_in(metric.metadata, ["department_filter_applied"]) == true 
    end)
    
    without_filter = Enum.filter(metrics, fn metric -> 
      get_in(metric.metadata, ["department_filter_applied"]) == false 
    end)

    %{
      with_filter: %{
        count: length(with_filter),
        avg_response_time: calculate_avg_response_time(with_filter),
        success_rate: calculate_success_rate(with_filter)
      },
      without_filter: %{
        count: length(without_filter),
        avg_response_time: calculate_avg_response_time(without_filter),
        success_rate: calculate_success_rate(without_filter)
      }
    }
  end

  defp analyze_movie_context_impact(metrics) do
    with_context = Enum.filter(metrics, fn metric -> 
      get_in(metric.metadata, ["movie_context_boost"]) == true 
    end)
    
    without_context = Enum.filter(metrics, fn metric -> 
      get_in(metric.metadata, ["movie_context_boost"]) == false 
    end)

    %{
      with_movie_context: %{
        count: length(with_context),
        avg_response_time: calculate_avg_response_time(with_context),
        success_rate: calculate_success_rate(with_context)
      },
      without_movie_context: %{
        count: length(without_context),
        avg_response_time: calculate_avg_response_time(without_context),
        success_rate: calculate_success_rate(without_context)
      }
    }
  end

  defp calculate_confidence_distribution(confidence_scores) do
    %{
      "90-100%" => Enum.count(confidence_scores, &(&1 >= 0.9)),
      "80-90%" => Enum.count(confidence_scores, &(&1 >= 0.8 and &1 < 0.9)),
      "70-80%" => Enum.count(confidence_scores, &(&1 >= 0.7 and &1 < 0.8)),
      "60-70%" => Enum.count(confidence_scores, &(&1 >= 0.6 and &1 < 0.7)),
      "<60%" => Enum.count(confidence_scores, &(&1 < 0.6))
    }
  end
end