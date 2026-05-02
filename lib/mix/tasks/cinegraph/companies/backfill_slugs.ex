defmodule Mix.Tasks.Cinegraph.Companies.BackfillSlugs do
  @moduledoc """
  Backfills missing production-company slugs.

      mix cinegraph.companies.backfill_slugs

  The underlying backfill stops at the first invalid changeset so operators can
  inspect and fix the offending company. This task raises on that error so
  automation receives a non-zero exit instead of treating the partial run as a
  success.
  """
  use Mix.Task

  @shortdoc "Backfill missing production-company slugs"

  alias Cinegraph.Maintenance.Companies

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Companies.backfill_slugs() do
      {:ok, count} ->
        Mix.shell().info("Backfilled #{count} production-company slug(s)")

      {:error, company, changeset} ->
        Mix.raise(
          "Failed to backfill company #{company.id} (#{company.name}): #{inspect(changeset.errors)}"
        )
    end
  end
end
