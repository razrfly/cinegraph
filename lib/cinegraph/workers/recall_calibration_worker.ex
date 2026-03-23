defmodule Cinegraph.Workers.RecallCalibrationWorker do
  @moduledoc """
  Oban worker that runs the 1001 Movies recall calibration measurement.

  Stores results in Cachex and broadcasts completion via PubSub so the
  admin LiveView can update without blocking the web process.
  """
  use Oban.Worker,
    queue: :metrics,
    max_attempts: 1,
    unique: [period: 600, states: [:available, :scheduled, :executing]]

  require Logger

  @cache_name :predictions_cache
  @pubsub_topic "recall_calibration"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"list_slug" => list_slug, "profile_name" => profile_name, "threshold" => threshold}}) do
    Logger.info("RecallCalibrationWorker starting: #{list_slug} / #{profile_name} @ #{threshold}")

    broadcast(%{status: :running, list_slug: list_slug, profile_name: profile_name})

    case Cinegraph.Calibration.measure_recall(list_slug, profile_name, threshold: threshold) do
      {:error, reason} = err ->
        Logger.warning("RecallCalibrationWorker failed: #{inspect(reason)}")
        broadcast(%{status: :error, error: inspect(reason), list_slug: list_slug, profile_name: profile_name})
        err

      results ->
        cache_key = cache_key(list_slug, profile_name, threshold)
        Cachex.put(@cache_name, cache_key, results, ttl: :timer.hours(24))

        Logger.info(
          "RecallCalibrationWorker done: #{Float.round(results.overall_recall * 100, 1)}% recall"
        )

        broadcast(%{
          status: :complete,
          results: results,
          list_slug: list_slug,
          profile_name: profile_name,
          cache_key: cache_key
        })

        :ok
    end
  end

  @doc "Returns cached results for the given params, or nil if not cached."
  def get_cached(list_slug, profile_name, threshold) do
    case Cachex.get(@cache_name, cache_key(list_slug, profile_name, threshold)) do
      {:ok, results} -> results
      _ -> nil
    end
  end

  @doc "Enqueues a recall calibration job. Returns {:ok, job} or {:error, reason}."
  def enqueue(list_slug, profile_name, threshold) do
    %{list_slug: list_slug, profile_name: profile_name, threshold: threshold}
    |> new()
    |> Oban.insert()
  end

  @doc "The PubSub topic this worker broadcasts on."
  def pubsub_topic, do: @pubsub_topic

  defp cache_key(list_slug, profile_name, threshold) do
    "recall_#{list_slug}_#{profile_name}_#{threshold}"
  end

  defp broadcast(payload) do
    Phoenix.PubSub.broadcast(Cinegraph.PubSub, @pubsub_topic, {:recall_update, payload})
  end
end
