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
    opts = [
      blank_only: true,
      limit: 5,
      trigger: "scheduled_canonical_refresh"
    ]

    case RefreshCanonicalLists.run(opts) do
      {:ok, %{found: found, enqueued: enqueued, already_queued: already, failed: failed} = stats} ->
        Logger.info(
          "CanonicalListRefreshSweeper: found=#{found} enqueued=#{enqueued} " <>
            "already=#{already} failed=#{failed}"
        )

        {:ok, stats}
    end
  end
end
