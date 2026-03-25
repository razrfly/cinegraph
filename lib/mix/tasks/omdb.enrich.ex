defmodule Mix.Tasks.Omdb.Enrich do
  use Mix.Task
  @shortdoc "Queue OMDb enrichment jobs for all movies on a canonical list"

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Workers.OMDbEnrichmentWorker

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [list: :string, force: :boolean, null_only: :boolean, dry_run: :boolean]
      )

    list_key = opts[:list] || Mix.raise("--list <source_key> is required")
    force = opts[:force] || false
    null_only = opts[:null_only] || false
    dry_run = opts[:dry_run] || false

    Mix.Task.run("app.start")

    movie_ids = fetch_movie_ids(list_key, null_only)
    count = length(movie_ids)

    if dry_run do
      Mix.shell().info("DRY RUN — #{count} jobs would be queued")
      Mix.shell().info("  list=#{list_key}  force=#{force}  null_only=#{null_only}")
      if count > 0, do: Mix.shell().info("  Sample IDs: #{Enum.take(movie_ids, 5) |> inspect()}")
    else
      Mix.shell().info("Queueing #{count} OMDb jobs  (list=#{list_key} force=#{force})")
      queued = queue_jobs(movie_ids, force)
      Mix.shell().info("Done — #{queued} inserted (#{count - queued} deduplicated by Oban)")
    end
  end

  defp fetch_movie_ids(list_key, null_only) do
    query =
      from m in Movie,
        where: fragment("? \\? ?", m.canonical_sources, ^list_key),
        where: not is_nil(m.imdb_id),
        where: m.import_status == "full",
        order_by: [asc: m.id],
        select: m.id

    query = if null_only, do: where(query, [m], is_nil(m.omdb_data)), else: query
    Repo.all(query)
  end

  defp queue_jobs(movie_ids, force) do
    extra = if force, do: %{"force" => true}, else: %{}

    Enum.reduce(movie_ids, 0, fn id, count ->
      job = OMDbEnrichmentWorker.new(Map.merge(%{"movie_id" => id}, extra))

      case Oban.insert(job) do
        {:ok, _} -> count + 1
        {:error, _} -> count
      end
    end)
  end
end
