defmodule Cinegraph.Health.Queues do
  @moduledoc """
  Per-queue Oban state for health dashboards and CLI.

  Single read path for `mix cinegraph.queues` and the `/admin/health`
  dashboard (#723). Both must call `snapshot/1` — never query `oban_jobs`
  directly.
  """

  alias Cinegraph.Health.ObanReader

  @states_to_track ~w(available executing scheduled retryable discarded cancelled)
  @cache_name :health_cache
  @cache_ttl :timer.minutes(1)

  @doc """
  Snapshot of every configured Oban queue.

  ## Options

    * `:bypass_cache` — when `true`, skip the cache and recompute. Used by mix tasks.

  ## Shape

      %{
        generated_at: ~U[...],
        queues: [
          %{
            name: :tmdb,
            available: 12, executing: 4, scheduled: 0,
            retryable: 0, discarded: 0, cancelled: 0,
            failures_last_hour: 0,
            longest_running_seconds: 12
          },
          ...
        ],
        total_failures_last_hour: 0
      }
  """
  def snapshot(opts \\ []) do
    if Keyword.get(opts, :bypass_cache, false) do
      compute_snapshot()
    else
      case Cachex.fetch(@cache_name, :queues_snapshot, fn ->
             {:commit, compute_snapshot(), ttl: @cache_ttl}
           end) do
        {:ok, snapshot} -> snapshot
        {:commit, snapshot} -> snapshot
        # Fallback: cache unavailable — compute directly
        _ -> compute_snapshot()
      end
    end
  end

  defp compute_snapshot do
    queues = ObanReader.configured_queues()
    counts = ObanReader.counts_by_queue_and_state(queues, @states_to_track)
    one_hour_ago = DateTime.utc_now() |> DateTime.add(-3600, :second)

    queue_rows =
      Enum.map(queues, fn queue ->
        queue_counts = Map.get(counts, queue, %{})

        %{
          name: queue,
          available: Map.get(queue_counts, "available", 0),
          executing: Map.get(queue_counts, "executing", 0),
          scheduled: Map.get(queue_counts, "scheduled", 0),
          retryable: Map.get(queue_counts, "retryable", 0),
          discarded: Map.get(queue_counts, "discarded", 0),
          cancelled: Map.get(queue_counts, "cancelled", 0),
          failures_last_hour: ObanReader.count_failed_since(one_hour_ago, queue),
          longest_running_seconds: ObanReader.longest_running_seconds(queue)
        }
      end)

    total_failures =
      queue_rows
      |> Enum.map(& &1.failures_last_hour)
      |> Enum.sum()

    %{
      generated_at: DateTime.utc_now(),
      queues: queue_rows,
      total_failures_last_hour: total_failures
    }
  end
end
