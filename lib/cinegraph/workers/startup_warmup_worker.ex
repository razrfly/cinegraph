defmodule Cinegraph.Workers.StartupWarmupWorker do
  @moduledoc """
  Orchestrates one-shot cache warmup jobs after application boot.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3, priority: 3

  alias Cinegraph.Repo
  alias Ecto.Multi

  require Logger

  @doc false
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case schedule_all_warmups() do
      {:ok, _jobs} ->
        :ok

      {:error, step, reason, _changes} ->
        Logger.error("Startup warmup child job was not scheduled at #{step}: #{inspect(reason)}")
        {:error, reason}
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

  defp schedule_all_warmups do
    Multi.new()
    |> Oban.insert(
      :cache_warmup,
      Cinegraph.Workers.CacheWarmupWorker.new(%{operation: "warmup_predictions"})
    )
    |> Oban.insert(:movies_warmup, Cinegraph.Workers.MoviesCacheWarmer.new(%{}))
    |> Oban.insert(:health_warmup, Cinegraph.Workers.HealthCacheWarmer.new(%{}))
    |> Repo.transaction()
  end
end
