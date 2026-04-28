defmodule Mix.Tasks.Cinegraph.Festivals.ResolvePersons do
  @moduledoc """
  Enqueues one `NominationPersonResolver` job for every festival nomination
  whose category has `tracks_person = true` but whose `person_id IS NULL`.
  Drains the backlog surfaced by `mix cinegraph.health` (#730 Phase 1a).

  ## Usage

      mix cinegraph.festivals.resolve_persons               # enqueue all
      mix cinegraph.festivals.resolve_persons --org AMPAS   # scope to one org (by abbreviation)
      mix cinegraph.festivals.resolve_persons --dry-run     # count only — no jobs enqueued
      mix cinegraph.festivals.resolve_persons --limit 100   # cap enqueue count

  Jobs run on the `:maintenance` queue (2-concurrent) — a 11k-row drain
  unwinds over hours, not minutes, by design.
  """
  use Mix.Task

  @shortdoc "Backfill festival nominations missing person_id"

  alias Cinegraph.Festivals.{
    FestivalCategory,
    FestivalCeremony,
    FestivalNomination,
    FestivalOrganization
  }

  alias Cinegraph.Repo
  alias Cinegraph.Workers.NominationPersonResolver
  import Ecto.Query

  # Postgres caps a single statement at 65 535 parameters; Oban jobs serialize
  # to ~8+ params each, so 500 keeps us well under the limit even with overhead.
  @insert_chunk_size 500

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    # Note: OptionParser converts `--dry-run` to `:dry_run` (underscore) by
    # default. Declare the key in strict with the same shape we read it.
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [org: :string, dry_run: :boolean, limit: :integer]
      )

    base =
      from n in FestivalNomination,
        join: c in FestivalCategory,
        on: n.category_id == c.id,
        join: cer in FestivalCeremony,
        on: n.ceremony_id == cer.id,
        join: org in FestivalOrganization,
        on: cer.organization_id == org.id,
        where: c.tracks_person == true and is_nil(n.person_id),
        select: n.id

    scoped =
      case Keyword.get(opts, :org) do
        nil -> base
        abbr -> from [n, c, cer, org] in base, where: org.abbreviation == ^abbr
      end

    capped =
      case Keyword.get(opts, :limit) do
        nil -> scoped
        n when is_integer(n) -> from(q in scoped, limit: ^n)
      end

    ids = Repo.all(capped)

    Mix.shell().info("Found #{length(ids)} nominations to resolve")

    if Keyword.get(opts, :dry_run, false) do
      Mix.shell().info("(dry-run — no jobs enqueued)")
    else
      {inserted, failed} = enqueue_in_chunks(ids)

      Mix.shell().info("Enqueued #{inserted} jobs on queue :maintenance")

      if failed > 0 do
        Mix.shell().error("#{failed} job(s) failed to enqueue — see logs above")
      end
    end
  end

  defp enqueue_in_chunks(ids) do
    ids
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce({0, 0}, fn chunk, {ok, err} ->
      jobs = Enum.map(chunk, &NominationPersonResolver.new(%{nomination_id: &1}))

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
