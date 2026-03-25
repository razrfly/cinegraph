defmodule Mix.Tasks.Tmdb.RefreshCredits do
  use Mix.Task
  @shortdoc "Queue TMDb credit repair for movies missing director credits"

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Workers.DataRepairWorker

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [list: :string, dry_run: :boolean]
      )

    if invalid != [] do
      Mix.shell().error("Unknown options: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
      Mix.raise("Invalid options provided")
    end

    list_key = opts[:list] || Mix.raise("--list <source_key> is required")
    dry_run = opts[:dry_run] || false

    Mix.Task.run("app.start")

    count = count_missing(list_key)

    if dry_run do
      Mix.shell().info("DRY RUN — #{count} films on '#{list_key}' are missing director credits")
      Mix.shell().info("  Real run will trigger global DataRepairWorker (covers all movies)")
    else
      Mix.shell().info("#{count} films on '#{list_key}' missing director credits")

      Mix.shell().info(
        "WARNING: DataRepairWorker runs globally — it will process ALL movies, not just '#{list_key}'"
      )

      Mix.shell().info("Triggering global missing_director_credits repair...")

      case %{"repair_type" => "missing_director_credits"}
           |> DataRepairWorker.new()
           |> Oban.insert() do
        {:ok, job} ->
          Mix.shell().info("Done — DataRepairWorker queued (job id=#{job.id})")
          Mix.shell().info("  Processes all movies globally in batches of 50 (250ms/movie)")
          Mix.shell().info("  Monitor: Oban.check_queue(queue: :maintenance)")

        {:error, reason} ->
          Mix.raise("Failed to queue job: #{inspect(reason)}")
      end
    end
  end

  defp count_missing(list_key) do
    Repo.one(
      from m in Movie,
        where: fragment("? \\? ?", m.canonical_sources, ^list_key),
        where: not is_nil(m.tmdb_id),
        where:
          m.id not in subquery(
            from c in "movie_credits",
              where: c.credit_type == "crew" and c.department == "Directing",
              select: c.movie_id,
              distinct: true
          ),
        select: count(m.id)
    )
  end
end
