defmodule Mix.Tasks.Cinegraph.People.CleanupZeroCredits do
  @moduledoc """
  Two-phase cleanup of orphan `people` rows with no `movie_credits`
  (#745 Phase 1.5).

  ## Usage

      # Phase 1 (default): enqueue TMDb refetch for each orphan
      mix cinegraph.people.cleanup_zero_credits
      mix cinegraph.people.cleanup_zero_credits --dry-run
      mix cinegraph.people.cleanup_zero_credits --limit 50

      # Phase 2 (run AFTER refetch jobs complete, ideally 24h later):
      # hard-delete rows that remained orphaned
      mix cinegraph.people.cleanup_zero_credits --phase delete
      mix cinegraph.people.cleanup_zero_credits --phase delete --dry-run

  In production both phases run autonomously via:
  - `ZeroCreditsCleanupSweeper` — Sunday 04:00 UTC (enqueue)
  - `ZeroCreditsCleanupDeleteSweeper` — Monday 04:00 UTC (delete)
  """
  use Mix.Task

  @shortdoc "Two-phase cleanup of orphan people rows"

  alias Cinegraph.Maintenance.CleanupZeroCredits

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args, strict: [phase: :string, dry_run: :boolean, limit: :integer])

    phase = Keyword.get(opts, :phase, "enqueue")
    runtime_opts = Keyword.take(opts, [:dry_run, :limit])

    case phase do
      "enqueue" ->
        {:ok, %{found: found, enqueued: enqueued, failed: failed, dry_run: dry_run?}} =
          CleanupZeroCredits.enqueue_refetch(runtime_opts)

        Mix.shell().info("Found #{found} orphans to refetch")

        cond do
          dry_run? -> Mix.shell().info("(dry-run — no jobs enqueued)")
          true -> Mix.shell().info("Enqueued #{enqueued} TMDb refetches")
        end

        if failed > 0, do: Mix.shell().error("#{failed} failed to enqueue")

      "delete" ->
        {:ok, %{found: found, deleted: deleted, failed: failed, dry_run: dry_run?}} =
          CleanupZeroCredits.delete_still_orphaned(runtime_opts)

        Mix.shell().info("Found #{found} still-orphaned rows")

        cond do
          dry_run? -> Mix.shell().info("(dry-run — no rows deleted)")
          true -> Mix.shell().info("Deleted #{deleted} orphan people")
        end

        if failed > 0, do: Mix.shell().error("#{failed} failed to delete")

      other ->
        Mix.raise(~s|--phase must be "enqueue" or "delete", got: #{inspect(other)}|)
    end
  end
end
