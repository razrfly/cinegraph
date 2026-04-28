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

  alias Cinegraph.Repo
  alias Cinegraph.Workers.NominationPersonResolver
  import Ecto.Query

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [org: :string, "dry-run": :boolean, limit: :integer]
      )

    base =
      from(n in "festival_nominations",
        join: c in "festival_categories",
        on: n.category_id == c.id,
        join: cer in "festival_ceremonies",
        on: n.ceremony_id == cer.id,
        join: org in "festival_organizations",
        on: cer.organization_id == org.id,
        where: c.tracks_person == true and is_nil(n.person_id),
        select: n.id
      )

    scoped =
      case Keyword.get(opts, :org) do
        nil -> base
        abbr -> from([n, c, cer, org] in base, where: org.abbreviation == ^abbr)
      end

    capped =
      case Keyword.get(opts, :limit) do
        nil -> scoped
        n when is_integer(n) -> from(q in scoped, limit: ^n)
      end

    ids = Repo.all(capped)

    Mix.shell().info("Found #{length(ids)} nominations to resolve")

    if Keyword.get(opts, :"dry-run", false) do
      Mix.shell().info("(dry-run — no jobs enqueued)")
    else
      ids
      |> Enum.map(&NominationPersonResolver.new(%{nomination_id: &1}))
      |> Oban.insert_all()

      Mix.shell().info("Enqueued #{length(ids)} jobs on queue :maintenance")
    end
  end
end
