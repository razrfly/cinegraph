defmodule Mix.Tasks.Cinegraph.People.RefreshBiographies do
  @moduledoc """
  Enqueues `PersonTmdbRefreshWorker` jobs for every person with a credit on
  a canonical-list movie (`movies.canonical_sources != '{}'`) whose biography
  is currently null or empty. Drains the scoped backlog surfaced by
  `Cinegraph.Health.Drift.People.missing_biography/0` (#735 Phase 1.2).

  ## Usage

      mix cinegraph.people.refresh_biographies               # enqueue all
      mix cinegraph.people.refresh_biographies --dry-run     # count only
      mix cinegraph.people.refresh_biographies --limit 100   # cap enqueue count

  Jobs run on the `:tmdb` queue (rate-limited to TMDb's API budget). A
  several-thousand-person drain unwinds over hours.
  """
  use Mix.Task

  @shortdoc "Backfill biographies for canonical-list people"

  alias Cinegraph.Repo
  alias Cinegraph.Workers.PersonTmdbRefreshWorker
  import Ecto.Query

  # Postgres caps a single statement at 65,535 parameters; Oban jobs serialize
  # to ~8+ params each, so 500 keeps us well under the limit.
  @insert_chunk_size 500

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    # Note: OptionParser converts `--dry-run` to `:dry_run` (underscore) by
    # default. Declare the key in strict with the same shape we read it.
    {opts, _, _} =
      OptionParser.parse(args, strict: [dry_run: :boolean, limit: :integer])

    base =
      from p in "people",
        join: mc in "movie_credits",
        on: mc.person_id == p.id,
        join: m in "movies",
        on: m.id == mc.movie_id,
        where:
          (is_nil(p.biography) or p.biography == "") and
            fragment("? != '{}'::jsonb", m.canonical_sources) and
            not is_nil(p.tmdb_id),
        distinct: p.id,
        select: p.id

    capped =
      case Keyword.get(opts, :limit) do
        nil -> base
        n when is_integer(n) -> from(q in base, limit: ^n)
      end

    ids = Repo.all(capped)
    Mix.shell().info("Found #{length(ids)} people to refresh")

    if Keyword.get(opts, :dry_run, false) do
      Mix.shell().info("(dry-run — no jobs enqueued)")
    else
      {ok, err} = enqueue_in_chunks(ids)
      Mix.shell().info("Enqueued #{ok} jobs on queue :tmdb")

      if err > 0 do
        Mix.shell().error("#{err} job(s) failed to enqueue — see logs above")
      end
    end
  end

  defp enqueue_in_chunks(ids) do
    ids
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce({0, 0}, fn chunk, {ok, err} ->
      jobs = Enum.map(chunk, &PersonTmdbRefreshWorker.new(%{person_id: &1}))

      try do
        case Oban.insert_all(jobs) do
          results when is_list(results) ->
            {ok + length(results), err}

          other ->
            Mix.shell().error("Oban.insert_all returned unexpected value: #{inspect(other)}")
            {ok, err + length(chunk)}
        end
      rescue
        e ->
          Mix.shell().error(
            "Oban.insert_all failed for chunk of #{length(chunk)}: #{Exception.message(e)}"
          )

          {ok, err + length(chunk)}
      end
    end)
  end
end
