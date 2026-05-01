defmodule Cinegraph.Workers.StartupWarmupWorker do
  @moduledoc """
  Orchestrates one-shot cache warmup jobs after application boot.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3, priority: 3

  require Logger

  @doc false
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    with {:ok, _job} <- Cinegraph.Workers.CacheWarmupWorker.schedule_warmup(),
         {:ok, _job} <- Cinegraph.Workers.MoviesCacheWarmer.schedule(),
         {:ok, _job} <- schedule_health_warmup() do
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Startup warmup child job was not scheduled: #{inspect(reason)}")
        error
    end
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

  defp schedule_health_warmup do
    Cinegraph.Workers.HealthCacheWarmer.new(%{})
    |> Oban.insert()
  end
end
