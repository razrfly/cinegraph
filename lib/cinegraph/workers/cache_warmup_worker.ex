defmodule Cinegraph.Workers.CacheWarmupWorker do
  @moduledoc """
  Background worker for warming up prediction caches.
  Runs periodically to ensure fast response times for common queries.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger
  alias Cinegraph.Cache.PredictionsCache

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"operation" => "warmup_predictions"}}) do
    Logger.info("Starting prediction cache warmup job")

    case PredictionsCache.warm_cache() do
      :ok ->
        Logger.info("Cache warmup job completed successfully")
        :ok

      :error ->
        Logger.error("Cache warmup job failed")
        {:error, "Cache warmup failed"}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.warning("Unknown cache warmup operation: #{inspect(args)}")
    {:error, "Unknown operation"}
  end

  @doc """
  Schedule a cache warmup job to run immediately.
  """
  def schedule_warmup do
    %{operation: "warmup_predictions"}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Schedule periodic cache warmup jobs.
  This should be called once during application startup.
  """
  def schedule_periodic_warmup do
    # Schedule warmup to run every hour
    %{operation: "warmup_predictions"}
    # 1 hour
    |> new(schedule_in: 3600)
    |> Oban.insert()

    Logger.info("Scheduled periodic cache warmup (every hour)")
  end
end
