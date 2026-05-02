defmodule Cinegraph.Workers.CanonicalListRefreshSweeper do
  @moduledoc """
  Low-frequency sweeper that keeps IMDb-backed canonical movie lists from
  remaining blank or stale indefinitely.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3, priority: 3

  alias Cinegraph.Maintenance.RefreshCanonicalLists

  require Logger

  @doc false
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    [
      [blank_only: true],
      [stale_days: 90]
    ]
    |> Enum.map(&run_refresh/1)
    |> combine_stats()
    |> then(&{:ok, &1})
  end

  defp run_refresh(selector_opts) do
    opts =
      selector_opts ++
        [
          limit: 5,
          trigger: "scheduled_canonical_refresh"
        ]

    {:ok, stats} = RefreshCanonicalLists.run(opts)

    Logger.info(
      "CanonicalListRefreshSweeper: selector=#{inspect(selector_opts)} " <>
        "found=#{stats.found} enqueued=#{stats.enqueued} " <>
        "already=#{stats.already_queued} failed=#{stats.failed}"
    )

    stats
  end

  defp combine_stats(stats) do
    Enum.reduce(stats, empty_stats(), fn stat, acc ->
      %{
        found: acc.found + stat.found,
        enqueued: acc.enqueued + stat.enqueued,
        already_queued: acc.already_queued + stat.already_queued,
        failed: acc.failed + stat.failed,
        dry_run: false,
        lists: acc.lists ++ stat.lists
      }
    end)
  end

  defp empty_stats do
    %{found: 0, enqueued: 0, already_queued: 0, failed: 0, dry_run: false, lists: []}
  end
end
