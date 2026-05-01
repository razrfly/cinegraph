defmodule Cinegraph.Workers.StartupWarmupWorker do
  @moduledoc """
  Orchestrates one-shot cache warmup jobs after application boot.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3, priority: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Cinegraph.Workers.CacheWarmupWorker.schedule_warmup()

    Cinegraph.Workers.MoviesCacheWarmer.schedule()

    Cinegraph.Workers.HealthCacheWarmer.new(%{})
    |> Oban.insert()

    :ok
  end

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
end
