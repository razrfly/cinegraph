defmodule Mix.Tasks.Cinegraph.MaterializedViews.Refresh do
  @moduledoc """
  Refresh PostgreSQL materialized views in the `public` schema (#896
  Phase 4.3).

  Used standalone (e.g. after a partial `mix db.pull_production` failure
  where pgsql_tmp ran out of disk and a view's refresh errored). The
  same `pg_matviews`-driven loop runs as part of the post-import step in
  `Mix.Tasks.Db.PullProduction` — this task re-runs it without redoing
  the multi-minute import.

  ## Usage

      # Refresh every materialized view in the public schema:
      mix cinegraph.materialized_views.refresh

      # Refresh just one view by name:
      mix cinegraph.materialized_views.refresh --view person_collaboration_trends
  """
  use Mix.Task

  alias Cinegraph.Repo

  @shortdoc "Refresh PostgreSQL materialized views in the public schema"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: [view: :string])

    views =
      case opts[:view] do
        nil -> list_views()
        name -> [name]
      end

    Enum.each(views, &refresh_view!/1)

    Mix.shell().info("✓ Refreshed #{length(views)} view(s)")
  end

  defp list_views do
    %{rows: rows} =
      Repo.query!(
        "SELECT matviewname FROM pg_matviews WHERE schemaname = 'public' ORDER BY matviewname",
        []
      )

    Enum.map(rows, fn [name] -> name end)
  end

  # Refresh a single matview, using CONCURRENTLY when a unique index on the
  # view is present (#897 Phase B). CONCURRENTLY is non-blocking for readers
  # but requires a unique index. Falls back to plain REFRESH otherwise.
  defp refresh_view!(name) do
    if has_unique_index?(name) do
      Mix.shell().info("Refreshing public.#{name} (CONCURRENTLY)...")

      Repo.query!(
        ~s(REFRESH MATERIALIZED VIEW CONCURRENTLY public."#{name}"),
        [],
        timeout: :infinity
      )
    else
      Mix.shell().info("Refreshing public.#{name} (locking — no unique index)...")
      Repo.query!(~s(REFRESH MATERIALIZED VIEW public."#{name}"), [], timeout: :infinity)
    end
  end

  @doc false
  def has_unique_index?(view_name) do
    %{rows: [[exists]]} =
      Repo.query!(
        "SELECT EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = $1 AND indexdef LIKE '%UNIQUE%')",
        [view_name]
      )

    exists
  end
end
