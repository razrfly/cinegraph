defmodule Mix.Tasks.Cinegraph.Collaborations do
  @moduledoc """
  Inspect and operate collaboration graph repair.

  ## Usage

      mix cinegraph.collaborations --health [--json]
      mix cinegraph.collaborations --backfill [--limit N] [--dry-run] [--json]
      mix cinegraph.collaborations --repair-movie MOVIE_ID [--json]
  """
  use Mix.Task

  @shortdoc "Inspect/backfill collaboration graph coverage"

  alias Cinegraph.Maintenance.Collaborations

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          health: :boolean,
          backfill: :boolean,
          repair_movie: :integer,
          limit: :integer,
          dry_run: :boolean,
          json: :boolean
        ]
      )

    reject_invalid_switches!(invalid)

    result =
      cond do
        Keyword.get(opts, :health, false) ->
          Collaborations.stats()

        Keyword.get(opts, :backfill, false) ->
          {:ok, result} =
            Collaborations.backfill(
              limit: Keyword.get(opts, :limit, 5_000),
              dry_run: Keyword.get(opts, :dry_run, false)
            )

          result

        movie_id = Keyword.get(opts, :repair_movie) ->
          {:ok, result} = Collaborations.repair_movie(movie_id)
          result

        true ->
          usage_error("choose one of --health, --backfill, or --repair-movie MOVIE_ID")
      end

    print(result, Keyword.get(opts, :json, false))
  end

  defp print(result, true), do: IO.puts(Jason.encode!(result))
  defp print(result, false), do: IO.puts(Jason.encode!(result, pretty: true))

  defp reject_invalid_switches!([]), do: :ok

  defp reject_invalid_switches!(invalid) do
    flags = invalid |> Enum.map(fn {flag, _} -> flag end) |> Enum.join(", ")
    usage_error("unknown flag(s): #{flags}")
  end

  defp usage_error(msg) do
    Mix.shell().error("✗ #{msg}")
    Mix.shell().info("\nUsage:")
    Mix.shell().info("  mix cinegraph.collaborations --health [--json]")
    Mix.shell().info("  mix cinegraph.collaborations --backfill [--limit N] [--dry-run] [--json]")
    Mix.shell().info("  mix cinegraph.collaborations --repair-movie MOVIE_ID [--json]")
    System.halt(1)
  end
end
