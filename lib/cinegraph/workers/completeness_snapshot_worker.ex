defmodule Cinegraph.Workers.CompletenessSnapshotWorker do
  @moduledoc """
  Daily snapshot of catalog completeness — persists one row to
  `completeness_log` per UTC day. Scheduled via Oban cron at `5 5 * * *`
  (5:05 AM UTC), after the 4 AM TMDb sync settles.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Cinegraph.Health.Completeness

  @impl Oban.Worker
  def perform(_job) do
    case Completeness.run_and_persist() do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end
end
