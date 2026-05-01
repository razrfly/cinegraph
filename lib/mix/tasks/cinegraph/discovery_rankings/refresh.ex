defmodule Mix.Tasks.Cinegraph.DiscoveryRankings.Refresh do
  @moduledoc """
  Refresh the default movie discovery rankings materialized view.

  ## Usage

      mix cinegraph.discovery_rankings.refresh
      mix cinegraph.discovery_rankings.refresh --no-concurrent

  Normal refreshes use `REFRESH MATERIALIZED VIEW CONCURRENTLY`. Use
  `--no-concurrent` only for first-population recovery or local maintenance.
  """

  use Mix.Task

  alias Cinegraph.Movies.DiscoveryRankings

  @shortdoc "Refresh movie_discovery_rankings_mv"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [concurrent: :boolean],
        aliases: [c: :concurrent]
      )

    result =
      DiscoveryRankings.refresh(concurrently: Keyword.get(opts, :concurrent, true))

    Mix.shell().info(
      "Refreshed #{result.view} (#{result.mode}) in #{result.duration_ms}ms; rows=#{result.row_count}"
    )
  end
end
