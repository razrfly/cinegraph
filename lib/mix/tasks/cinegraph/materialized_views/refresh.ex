defmodule Mix.Tasks.Cinegraph.MaterializedViews.Refresh do
  @moduledoc """
  Refresh PostgreSQL materialized views in the `public` schema (#896
  Phase 4.3).

  Used standalone (e.g. after a partial `mix db.pull_production` failure
  where pgsql_tmp ran out of disk and a view's refresh errored).

  Refresh behaviour (CONCURRENTLY when a unique index exists + a server-side
  `statement_timeout`) lives in `Cinegraph.Database.MaterializedViews`, the single
  safe refresh path shared with `db.pull_production`, the scheduled sweeper, and
  `Cinegraph.Collaborations.refresh_collaboration_trends/0`.

  ## Usage

      # Refresh every materialized view in the public schema:
      mix cinegraph.materialized_views.refresh

      # Refresh just one view by name:
      mix cinegraph.materialized_views.refresh --view person_collaboration_trends
  """
  use Mix.Task

  alias Cinegraph.Database.MaterializedViews

  @shortdoc "Refresh PostgreSQL materialized views in the public schema"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: [view: :string])

    views =
      case opts[:view] do
        nil ->
          MaterializedViews.list_public()

        name ->
          if name in MaterializedViews.list_public() do
            [name]
          else
            Mix.raise("Unknown materialized view public.#{name}")
          end
      end

    Enum.each(views, fn name ->
      Mix.shell().info("Refreshing public.#{name}...")

      case MaterializedViews.refresh!(name) do
        :ok -> :ok
        {:skipped, reason} -> Mix.shell().info("  skipped (#{reason})")
      end
    end)

    Mix.shell().info("✓ Refreshed #{length(views)} view(s)")
  end
end
