defmodule Cinegraph.Metrics.ApiTracker do
  @moduledoc """
  Tracks and monitors all external API and scraping operations.
  Provides real-time visibility into success rates, response times,
  and error patterns across all external data sources.
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Metrics.ApiLookupMetric

  require Logger

  @doc """
  Tracks an external API or scraping operation.
  
  ## Examples
  
      ApiTracker.track_lookup("tmdb", "find_by_imdb", "tt0111161", fn ->
        # Your API call here
        {:ok, movie_data}
      end)
  """
  def track_lookup(source, operation, target, fun, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    
    result = 
      try do
        fun.()
      rescue
        error -> 
          Logger.error("API operation failed: #{inspect(error)}")
          {:error, error}
      catch
        :exit, reason -> {:error, {:exit, reason}}
        kind, reason -> {:error, {kind, reason}}
      end
    
    end_time = System.monotonic_time(:millisecond)
    response_time = end_time - start_time
    
    attrs = build_metric_attrs(source, operation, target, result, response_time, opts)
    
    # Fire and forget - don't let tracking failures affect the operation
    Task.start(fn -> create_metric(attrs) end)
    
    result
  end

  @doc """
  Tracks an async operation with proper timing.
  """
  def track_async_lookup(source, operation, target, task, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    
    result = Task.await(task, Keyword.get(opts, :timeout, 30_000))
    
    end_time = System.monotonic_time(:millisecond)
    response_time = end_time - start_time
    
    attrs = build_metric_attrs(source, operation, target, result, response_time, opts)
    
    # Fire and forget
    Task.start(fn -> create_metric(attrs) end)
    
    result
  end

  defp build_metric_attrs(source, operation, target, result, response_time, opts) do
    base_attrs = %{
      source: to_string(source),
      operation: to_string(operation),
      target_identifier: to_string(target),
      success: successful?(result),
      response_time_ms: response_time,
      metadata: Keyword.get(opts, :metadata, %{})
    }
    
    base_attrs
    |> add_error_info(result)
    |> add_confidence_score(result, opts)
    |> add_fallback_level(opts)
  end

  defp successful?({:ok, _}), do: true
  defp successful?({:error, _}), do: false
  defp successful?(_), do: false

  defp add_error_info(attrs, {:error, error}) do
    {error_type, error_message} = extract_error_details(error)
    
    attrs
    |> Map.put(:error_type, error_type)
    |> Map.put(:error_message, error_message)
  end
  defp add_error_info(attrs, _), do: attrs

  defp extract_error_details(%{message: msg}), do: {"api_error", msg}
  defp extract_error_details({:not_found, msg}), do: {"not_found", to_string(msg)}
  defp extract_error_details({:timeout, _}), do: {"timeout", "Request timed out"}
  defp extract_error_details({:rate_limit, _}), do: {"rate_limit", "Rate limit exceeded"}
  defp extract_error_details(error) when is_binary(error), do: {"error", error}
  defp extract_error_details(error), do: {"unknown", inspect(error)}

  defp add_confidence_score(attrs, {:ok, %{confidence: confidence}}, _opts) do
    Map.put(attrs, :confidence_score, confidence)
  end
  defp add_confidence_score(attrs, _result, opts) do
    case Keyword.get(opts, :confidence) do
      nil -> attrs
      confidence -> Map.put(attrs, :confidence_score, confidence)
    end
  end

  defp add_fallback_level(attrs, opts) do
    case Keyword.get(opts, :fallback_level) do
      nil -> attrs
      level -> Map.put(attrs, :fallback_level, level)
    end
  end

  defp create_metric(attrs) do
    %ApiLookupMetric{}
    |> ApiLookupMetric.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, metric} -> 
        Logger.debug("Tracked API operation: #{metric.source}/#{metric.operation}")
        {:ok, metric}
      {:error, changeset} -> 
        Logger.warning("Failed to track API operation: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  @doc """
  Gets success rate for a specific source/operation combination.
  """
  def get_success_rate(source, operation \\ nil, hours \\ 24) do
    since = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)
    
    query = 
      from m in ApiLookupMetric,
        where: m.source == ^source and m.inserted_at >= ^since
    
    query = 
      if operation do
        where(query, [m], m.operation == ^operation)
      else
        query
      end
    
    metrics = Repo.all(query)
    calculate_success_rate(metrics)
  end

  @doc """
  Gets aggregated statistics for all sources.
  """
  def get_all_stats(hours \\ 24) do
    since = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)
    
    Repo.all(
      from m in ApiLookupMetric,
        where: m.inserted_at >= ^since,
        group_by: [m.source, m.operation],
        select: %{
          source: m.source,
          operation: m.operation,
          total: count(m.id),
          successful: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.success)),
          avg_response_time: avg(m.response_time_ms),
          max_response_time: max(m.response_time_ms),
          min_response_time: min(m.response_time_ms)
        }
    )
    |> Enum.map(fn stat ->
      Map.put(stat, :success_rate, calculate_rate(stat.successful, stat.total))
    end)
  end

  @doc """
  Gets error distribution for a source.
  """
  def get_error_distribution(source, hours \\ 24) do
    since = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)
    
    Repo.all(
      from m in ApiLookupMetric,
        where: m.source == ^source and 
               m.success == false and 
               m.inserted_at >= ^since,
        group_by: m.error_type,
        select: %{
          error_type: m.error_type,
          count: count(m.id)
        }
    )
  end

  @doc """
  Gets fallback strategy effectiveness for TMDb by level.
  """
  def get_tmdb_fallback_stats(hours \\ 24) do
    since = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)
    
    Repo.all(
      from m in ApiLookupMetric,
        where: m.source == "tmdb" and 
               not is_nil(m.fallback_level) and
               m.inserted_at >= ^since,
        group_by: m.fallback_level,
        select: %{
          level: m.fallback_level,
          total: count(m.id),
          successful: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.success)),
          avg_confidence: avg(m.confidence_score)
        }
    )
    |> Enum.map(fn stat ->
      Map.put(stat, :success_rate, calculate_rate(stat.successful, stat.total))
    end)
  end

  @doc """
  Gets breakdown of TMDb fallback strategies by strategy name.
  Shows how often each strategy (direct_imdb, fuzzy_title, etc.) is used.
  """
  def get_tmdb_strategy_breakdown(hours \\ 24) do
    since = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)
    
    # Get operations that contain fallback strategy info
    Repo.all(
      from m in ApiLookupMetric,
        where: m.source == "tmdb" and 
               like(m.operation, "fallback_%") and
               m.inserted_at >= ^since,
        group_by: m.operation,
        select: %{
          strategy: m.operation,
          total: count(m.id),
          successful: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.success)),
          avg_confidence: avg(m.confidence_score),
          avg_response_time: avg(m.response_time_ms)
        }
    )
    |> Enum.map(fn stat ->
      strategy_name = String.replace(stat.strategy, "fallback_", "")
      
      stat
      |> Map.put(:strategy_name, strategy_name)
      |> Map.put(:success_rate, calculate_rate(stat.successful, stat.total))
      |> Map.update(:avg_confidence, nil, fn
        nil -> nil
        %Decimal{} = decimal -> Decimal.to_float(decimal)
        number when is_number(number) -> number
      end)
      |> Map.update(:avg_response_time, nil, fn
        nil -> nil
        %Decimal{} = decimal -> Decimal.to_float(decimal)
        number when is_number(number) -> number
      end)
    end)
    |> Enum.sort_by(& &1.total, :desc)
  end

  @doc """
  Cleans up old metrics based on retention policy.
  Default: 90 days
  """
  def cleanup_old_metrics(days \\ 90) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)
    
    {deleted, _} = 
      from(m in ApiLookupMetric, where: m.inserted_at < ^cutoff)
      |> Repo.delete_all()
    
    Logger.info("Cleaned up #{deleted} old API metrics")
    deleted
  end

  # Helper functions
  
  defp calculate_success_rate([]), do: 0.0
  defp calculate_success_rate(metrics) do
    total = length(metrics)
    successful = Enum.count(metrics, & &1.success)
    calculate_rate(successful, total)
  end

  defp calculate_rate(_, 0), do: 0.0
  defp calculate_rate(successful, total) do
    Float.round(successful / total * 100, 1)
  end
end