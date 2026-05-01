defmodule Mix.Tasks.Cinegraph.Prod.Collaborations do
  @moduledoc """
  Inspect and operate production collaboration graph repair via Kamal.

  ## Usage

      mix cinegraph.prod.collaborations --health [--json]
      mix cinegraph.prod.collaborations --backfill [--limit N] [--dry-run] [--json]
      mix cinegraph.prod.collaborations --repair-movie MOVIE_ID [--json]
  """
  use Mix.Task

  @shortdoc "Inspect/backfill production collaboration graph coverage"

  alias Cinegraph.ProdRpc

  @impl Mix.Task
  def run(args) do
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

    expr =
      cond do
        Keyword.get(opts, :health, false) ->
          "IO.puts(Jason.encode!(Cinegraph.Maintenance.Collaborations.stats()))"

        Keyword.get(opts, :backfill, false) ->
          limit = Keyword.get(opts, :limit, 5_000)
          dry_run? = Keyword.get(opts, :dry_run, false)

          "({:ok, result} = Cinegraph.Maintenance.Collaborations.backfill(limit: #{limit}, dry_run: #{inspect(dry_run?)}); IO.puts(Jason.encode!(result)))"

        movie_id = Keyword.get(opts, :repair_movie) ->
          "({:ok, result} = Cinegraph.Maintenance.Collaborations.repair_movie(#{movie_id}); IO.puts(Jason.encode!(result)))"

        true ->
          usage_error("choose one of --health, --backfill, or --repair-movie MOVIE_ID")
      end

    case ProdRpc.eval_json(expr) do
      {:ok, result} -> ProdRpc.print(result, opts)
      {:error, reason} -> ProdRpc.print_error(reason)
    end
  end

  defp reject_invalid_switches!([]), do: :ok

  defp reject_invalid_switches!(invalid) do
    flags = invalid |> Enum.map(fn {flag, _} -> flag end) |> Enum.join(", ")
    usage_error("unknown flag(s): #{flags}")
  end

  defp usage_error(msg) do
    Mix.shell().error("✗ #{msg}")
    Mix.shell().info("\nUsage:")
    Mix.shell().info("  mix cinegraph.prod.collaborations --health [--json]")

    Mix.shell().info(
      "  mix cinegraph.prod.collaborations --backfill [--limit N] [--dry-run] [--json]"
    )

    Mix.shell().info("  mix cinegraph.prod.collaborations --repair-movie MOVIE_ID [--json]")
    System.halt(1)
  end
end
