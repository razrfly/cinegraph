defmodule Mix.Tasks.QueuePersonInference do
  @moduledoc """
  Queues person inference jobs for all non-Oscar festival ceremonies.

  This is a workaround for issue #286 where person inference isn't being
  automatically queued after festival discovery.

  Usage:
    mix queue_person_inference                # Queue for all ceremonies
    mix queue_person_inference --year 2024    # Queue for specific year
    mix queue_person_inference --festival VIFF # Queue for specific festival
  """

  use Mix.Task
  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Festivals.FestivalCeremony
  alias Cinegraph.Workers.FestivalPersonInferenceWorker
  require Logger

  @shortdoc "Queue person inference jobs for festival ceremonies"

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [year: :integer, festival: :string]
      )

    query =
      from fc in FestivalCeremony,
        join: fo in assoc(fc, :organization),
        where: fo.abbreviation != "AMPAS",
        preload: [:organization]

    query =
      case opts[:year] do
        nil -> query
        year -> where(query, [fc], fc.year == ^year)
      end

    query =
      case opts[:festival] do
        nil -> query
        festival -> where(query, [fc, fo], fo.abbreviation == ^festival)
      end

    ceremonies = Repo.all(query)

    IO.puts("Found #{length(ceremonies)} non-Oscar ceremonies to process")

    results =
      Enum.map(ceremonies, fn ceremony ->
        job_args = %{
          "ceremony_id" => ceremony.id,
          "abbr" => ceremony.organization.abbreviation,
          "year" => ceremony.year
        }

        IO.puts("Queuing inference for #{ceremony.organization.abbreviation} #{ceremony.year}...")

        case FestivalPersonInferenceWorker.new(job_args) |> Oban.insert() do
          {:ok, job} ->
            IO.puts("  ✅ Queued job ##{job.id}")
            {:ok, job}

          {:error, %{errors: [args: {"has already been taken", _}]}} ->
            IO.puts("  ⏭️  Job already exists (unique constraint)")
            :exists

          {:error, reason} ->
            IO.puts("  ❌ Failed: #{inspect(reason)}")
            {:error, reason}
        end
      end)

    success_count = Enum.count(results, fn r -> match?({:ok, _}, r) end)
    exists_count = Enum.count(results, fn r -> r == :exists end)
    error_count = Enum.count(results, fn r -> match?({:error, _}, r) end)

    IO.puts("\n=== Summary ===")
    IO.puts("✅ Successfully queued: #{success_count}")
    IO.puts("⏭️  Already existed: #{exists_count}")
    IO.puts("❌ Failed: #{error_count}")
    IO.puts("Total ceremonies: #{length(ceremonies)}")
  end
end
