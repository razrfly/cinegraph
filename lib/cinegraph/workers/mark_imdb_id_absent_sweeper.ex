defmodule Cinegraph.Workers.MarkImdbIdAbsentSweeper do
  @moduledoc """
  Weekly belt-and-suspenders sweep (#1109): marks `imdb_id` source-absent for
  checked-but-null movies that slipped through the inline touch on the fetch
  paths (#1106 refresh / import). The wire-forward touch is the real steady
  state; this just catches drift.

  Wraps `Cinegraph.Maintenance.MarkImdbIdAbsent.run/1`. No API hits (it only
  writes ledger rows), so the per-run cap is generous.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Maintenance.MarkImdbIdAbsent

  require Logger

  @per_run_limit 50_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case MarkImdbIdAbsent.run(limit: @per_run_limit) do
      {:ok, %{found: found, marked: marked, failed: failed} = stats} ->
        Logger.info(
          "MarkImdbIdAbsentSweeper: found=#{found} marked=#{marked} failed=#{failed} (cap=#{@per_run_limit})"
        )

        {:ok, stats}
    end
  end
end
