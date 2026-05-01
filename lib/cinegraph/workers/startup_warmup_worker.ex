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
    warmup_jobs()
    |> Enum.reduce([], fn child, failed ->
      case schedule_child_warmup(child) do
        {:ok, _job} -> failed
        {:error, reason} -> [warmup_failure(child, reason) | failed]
        other -> [warmup_failure(child, other) | failed]
      end
    end)
    |> case do
      [] -> :ok
      failed -> {:error, {:startup_warmup_children_failed, Enum.reverse(failed)}}
    end
  end

  defp warmup_jobs do
    [
      cache_warmup:
        Cinegraph.Workers.CacheWarmupWorker.new(
          %{operation: "warmup_predictions"},
          unique: startup_child_unique_opts()
        ),
      movies_warmup:
        Cinegraph.Workers.MoviesCacheWarmer.new(%{}, unique: startup_child_unique_opts()),
      health_warmup:
        Cinegraph.Workers.HealthCacheWarmer.new(%{}, unique: startup_child_unique_opts())
    ]
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

  defp warmup_failure({name, _job}, reason), do: {name, reason}

  defp startup_child_unique_opts do
    [
      period: 300,
      fields: [:worker, :args, :queue],
      states: [:available, :scheduled, :executing, :retryable]
    ]
  end
end
