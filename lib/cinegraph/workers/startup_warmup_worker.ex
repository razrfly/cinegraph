defmodule Cinegraph.Workers.StartupWarmupWorker do
  @moduledoc """
  Orchestrates one-shot cache warmup jobs after application boot.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3, priority: 3

  require Logger

  @doc false
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    schedule_all_warmups()
    :ok
  end

  @doc """
  Queues the one-shot startup warmup orchestrator after the boot grace period.
  """
  def schedule do
    %{}
    |> new(schedule_in: 5)
    |> Oban.insert()
    |> log_schedule_result()
  end

  defp log_schedule_result({:ok, _job} = result), do: result

  defp log_schedule_result({:error, reason} = result) do
    Logger.warning("Startup warmup job was not scheduled: #{inspect(reason)}")
    result
  end

  defp schedule_all_warmups do
    [
      cache_warmup: Cinegraph.Workers.CacheWarmupWorker.new(%{operation: "warmup_predictions"}),
      movies_warmup: Cinegraph.Workers.MoviesCacheWarmer.new(%{}),
      health_warmup: Cinegraph.Workers.HealthCacheWarmer.new(%{})
    ]
    |> Enum.each(&schedule_child_warmup/1)
  end

  defp schedule_child_warmup({name, job}) do
    case Oban.insert(job) do
      {:ok, _job} = result ->
        result

      {:error, reason} = result ->
        Logger.error("Startup warmup child job was not scheduled at #{name}: #{inspect(reason)}")
        result
    end
  end
end
