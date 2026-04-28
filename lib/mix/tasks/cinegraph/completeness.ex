defmodule Mix.Tasks.Cinegraph.Completeness do
  @moduledoc """
  Catalog completeness snapshot — coverage % and totals per domain.

  ## Usage

      mix cinegraph.completeness               # compute and print
      mix cinegraph.completeness --json
      mix cinegraph.completeness --write       # also persist to completeness_log
  """
  use Mix.Task

  alias Cinegraph.Health.Completeness

  @shortdoc "Run a catalog completeness snapshot"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: [json: :boolean, write: :boolean])
    json? = Keyword.get(opts, :json, false)
    write? = Keyword.get(opts, :write, false)

    snapshot = Completeness.run()

    if write? do
      case Completeness.persist(snapshot) do
        {:ok, log} ->
          unless json? do
            Mix.shell().info("✓ Persisted snapshot for #{Date.to_iso8601(log.captured_on)}")
          end

        {:error, changeset} ->
          Mix.shell().error("✗ Failed to persist: #{inspect(changeset.errors)}")
      end
    end

    if json? do
      snapshot
      |> serialize()
      |> Jason.encode!(pretty: true)
      |> IO.puts()
    else
      print_table(snapshot)
    end
  end

  defp serialize(snapshot) do
    snapshot
    |> Map.put(:generated_at, DateTime.to_iso8601(snapshot.generated_at))
    |> stringify()
  end

  defp stringify(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(other), do: other

  defp print_table(s) do
    Mix.shell().info("Catalog completeness — #{DateTime.to_iso8601(s.generated_at)}")
    Mix.shell().info(String.duplicate("=", 70))
    Mix.shell().info("Overall: #{s.overall_completeness_pct}%")
    Mix.shell().info("")
    Mix.shell().info("Movies (#{s.movies.total})")
    Mix.shell().info("  with OMDb:    #{s.movies.with_omdb} (#{s.movies.with_omdb_pct}%)")
    Mix.shell().info("  with imdb_id: #{s.movies.with_imdb_id} (#{s.movies.with_imdb_id_pct}%)")
    Mix.shell().info("")
    Mix.shell().info("People (#{s.people.total})")

    Mix.shell().info(
      "  with profile_path:        #{s.people.with_profile} (#{s.people.with_profile_pct}%)"
    )

    Mix.shell().info(
      "  with biography:           #{s.people.with_biography} (#{s.people.with_biography_pct}%)"
    )

    Mix.shell().info(
      "  with known_for_dept:      #{s.people.with_known_for} (#{s.people.with_known_for_pct}%)"
    )

    Mix.shell().info("")
    Mix.shell().info("Festivals")
    Mix.shell().info("  ceremonies:                #{s.festivals.ceremonies}")
    Mix.shell().info("  nominations:               #{s.festivals.nominations}")
    Mix.shell().info("  nominations w/ movie pct:  #{s.festivals.with_movie_pct}%")
  end
end
