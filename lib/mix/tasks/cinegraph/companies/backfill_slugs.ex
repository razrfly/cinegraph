defmodule Mix.Tasks.Cinegraph.Companies.BackfillSlugs do
  @moduledoc """
  Backfills missing production-company slugs.

      mix cinegraph.companies.backfill_slugs
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
        Mix.shell().error(
          "Failed to backfill company #{company.id} (#{company.name}): #{inspect(changeset.errors)}"
        )
    end
  end
end
