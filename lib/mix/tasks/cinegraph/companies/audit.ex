defmodule Mix.Tasks.Cinegraph.Companies.Audit do
  @moduledoc """
  Audits production-company routing, logo, and TMDb metadata coverage.

      mix cinegraph.companies.audit
      mix cinegraph.companies.audit --json
  """
  use Mix.Task

  @shortdoc "Audit production-company metadata coverage"

  alias Cinegraph.Maintenance.Companies

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: [json: :boolean])
    {:ok, stats} = Companies.audit()

    if opts[:json] do
      Mix.shell().info(Jason.encode!(stats))
    else
      Mix.shell().info("Production company audit")

      stats
      |> Map.drop([:top_missing_metadata_by_movie_count, :top_missing_logo_by_movie_count])
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.each(fn {key, value} ->
        Mix.shell().info("  #{key}: #{value}")
      end)

      Mix.shell().info("\nTop missing metadata by movie count:")
      print_rows(stats.top_missing_metadata_by_movie_count)

      Mix.shell().info("\nTop missing logo by movie count:")
      print_rows(stats.top_missing_logo_by_movie_count)
    end
  end

  defp print_rows([]), do: Mix.shell().info("  none")

  defp print_rows(rows) do
    Enum.each(rows, fn row ->
      Mix.shell().info(
        "  #{row.name} (id=#{row.id}, tmdb=#{row.tmdb_id}, movies=#{row.movie_count})"
      )
    end)
  end
end
