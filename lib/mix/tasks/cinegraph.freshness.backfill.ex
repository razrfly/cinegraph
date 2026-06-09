defmodule Mix.Tasks.Cinegraph.Freshness.Backfill do
  @moduledoc """
  Seed the `data_refreshes` ledger from existing signals (#1096 Phase B / #1090
  §1d) — no API calls. Idempotent: re-running inserts nothing new.

  ## Usage

      mix cinegraph.freshness.backfill                       # all sources
      mix cinegraph.freshness.backfill --only omdb,tmdb_details
      mix cinegraph.freshness.backfill --chunk 5000 --sleep 100

  Sources: `tmdb_details`, `omdb`, `watch_providers`, `tmdb_person`, `festivals`,
  `lists`. On the shared prod DB, run a source at a time and keep the sleep up.
  """
  use Mix.Task

  alias Cinegraph.Maintenance.BackfillFreshness

  @shortdoc "Seed data_refreshes from existing freshness signals (#1096 Phase B)"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          only: :string,
          chunk: :integer,
          sleep: :integer,
          min_id: :integer,
          max_id: :integer
        ]
      )

    Mix.Task.run("app.start")

    run_opts =
      []
      |> put_only(opts[:only])
      |> maybe_put(:chunk, opts[:chunk])
      |> maybe_put(:sleep_ms, opts[:sleep])
      |> maybe_put(:min_id, opts[:min_id])
      |> maybe_put(:max_id, opts[:max_id])

    {:ok, results} = BackfillFreshness.run(run_opts)

    Mix.shell().info("data_refreshes backfill complete:")

    Enum.each(results, fn {source, result} ->
      Mix.shell().info("  #{source}: #{inspect(result)}")
    end)
  end

  defp put_only(opts, nil), do: opts

  defp put_only(opts, csv) do
    only = csv |> String.split(",", trim: true) |> Enum.map(&String.to_existing_atom/1)
    Keyword.put(opts, :only, only)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
