defmodule Mix.Tasks.Cinegraph.Festivals.Sync do
  @moduledoc """
  Discover-and-import sweep for active festivals (#745 Phase 2). Runs the
  same code path as `Cinegraph.Workers.FestivalSyncSweeper`.

  ## Usage

      mix cinegraph.festivals.sync               # discover + import all
      mix cinegraph.festivals.sync --dry-run     # count only
  """
  use Mix.Task

  @shortdoc "Discover + import new festival ceremonies"

  alias Cinegraph.Maintenance.SyncFestivals

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, extra, invalid} = OptionParser.parse(args, strict: [dry_run: :boolean])

    cond do
      invalid != [] -> Mix.raise("Invalid option(s): #{inspect(invalid)}")
      extra != [] -> Mix.raise("Unexpected positional argument(s): #{inspect(extra)}")
      true -> :ok
    end

    {:ok, stats} = SyncFestivals.run(opts)

    Mix.shell().info(
      "events=#{stats.events} " <>
        "discoveries=#{stats.discoveries_enqueued} (already=#{stats.discoveries_already_queued}) " <>
        "imports=#{stats.imports_enqueued} (already=#{stats.imports_already_queued}) " <>
        "failed=#{stats.failed}" <> if(stats.dry_run, do: " (dry-run)", else: "")
    )
  end
end
