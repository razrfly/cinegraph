defmodule Cinegraph.Workers.CanonicalListRefreshSweeper do
  @moduledoc """
  Low-frequency sweeper that keeps IMDb-backed canonical movie lists from
  remaining blank or stale indefinitely.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3, priority: 3

  alias Cinegraph.Maintenance.RefreshCanonicalLists

  require Logger

  @doc """
  Queues refreshes for blank IMDb lists first, then stale lists that were not
  already selected by the blank-list pass.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    blank_stats = run_refresh(blank_only: true)
    stale_stats = run_refresh([stale_days: 90], exclude_source_keys: blank_stats.lists)

    [blank_stats, stale_stats]
    |> combine_stats()
    |> then(&{:ok, &1})
  end

  defp run_refresh(selector_opts, extra_opts \\ []) do
    opts =
      selector_opts
      |> Keyword.merge(
        limit: 5,
        trigger: "scheduled_canonical_refresh"
      )
      |> Keyword.merge(extra_opts)

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
