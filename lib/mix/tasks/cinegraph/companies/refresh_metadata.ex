defmodule Mix.Tasks.Cinegraph.Companies.RefreshMetadata do
  @moduledoc """
  Refreshes stored TMDb metadata for production companies.

      mix cinegraph.companies.refresh_metadata --missing
      mix cinegraph.companies.refresh_metadata --stale --limit 100
      mix cinegraph.companies.refresh_metadata --company A24
      mix cinegraph.companies.refresh_metadata --missing --dry-run
  """
  use Mix.Task

  @shortdoc "Refresh production-company TMDb metadata"

  alias Cinegraph.Maintenance.Companies

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          missing: :boolean,
          stale: :boolean,
          company: :string,
          limit: :integer,
          dry_run: :boolean,
          json: :boolean
        ]
      )

    if opts[:missing] && opts[:stale] do
      Mix.raise("Use either --missing or --stale, not both")
    end

    mode = if opts[:stale], do: :stale, else: :missing

    {:ok, result} =
      Companies.refresh_metadata(
        mode: mode,
        company: opts[:company],
        limit: opts[:limit] || 100,
        dry_run: opts[:dry_run] || false
      )

    if opts[:json] do
      Mix.shell().info(Jason.encode!(result))
    else
      Mix.shell().info(
        "Found #{result.found} production compan#{suffix(result.found)} to refresh"
      )

      if result.dry_run do
        Mix.shell().info("(dry-run - no TMDb requests made)")
      else
        Mix.shell().info("Refreshed #{result.refreshed}; failed #{result.failed}")
      end

      Enum.each(result.companies, fn company ->
        Mix.shell().info("  #{company.name} (id=#{company.id}, tmdb=#{company.tmdb_id})")
      end)

      Enum.each(Map.get(result, :errors, []), fn error ->
        Mix.shell().error("  ERROR #{error.name}: #{error.error}")
      end)
    end
  end

  defp suffix(1), do: "y"
  defp suffix(_), do: "ies"
end
