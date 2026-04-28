defmodule Cinegraph.Maintenance.ResolvePersons do
  @moduledoc """
  Release-safe maintenance entry point for the festival person-resolver
  backfill. Enqueues one `NominationPersonResolver` job per nomination
  whose category has `tracks_person = true` but whose `person_id IS NULL`.

  Reachable from:
  - `mix cinegraph.festivals.resolve_persons` (dev)
  - `Cinegraph.Workers.FestivalPersonResolverSweeper` (Oban Cron, prod)
  - `bin/cinegraph eval "Cinegraph.Maintenance.ResolvePersons.run([])"` (one-shot prod)

  See #735 Phase 3.1 and #739 Phase A.

  ## Options

    * `:org` (binary) — scope to a single organization by abbreviation
      (e.g. `"AMPAS"`).
    * `:limit` (positive integer) — cap the number of jobs enqueued.
    * `:dry_run` (boolean) — count only; do not enqueue.

  ## Returns

  `{:ok, %{found: integer, enqueued: integer, failed: integer, dry_run: boolean}}`
  """

  alias Cinegraph.Festivals.{
    FestivalCategory,
    FestivalCeremony,
    FestivalNomination,
    FestivalOrganization
  }

  alias Cinegraph.Repo
  alias Cinegraph.Workers.NominationPersonResolver

  import Ecto.Query
  require Logger

  # Postgres caps a single statement at 65 535 parameters; Oban jobs serialize
  # to ~8+ params each, so 500 keeps us well under the limit even with overhead.
  @insert_chunk_size 500

  @doc "Run the backfill. See module docs for options."
  @spec run(keyword()) ::
          {:ok,
           %{
             found: non_neg_integer(),
             enqueued: non_neg_integer(),
             failed: non_neg_integer(),
             dry_run: boolean()
           }}
  def run(opts \\ []) when is_list(opts) do
    base =
      from n in FestivalNomination,
        join: c in FestivalCategory,
        on: n.category_id == c.id,
        join: cer in FestivalCeremony,
        on: n.ceremony_id == cer.id,
        join: org in FestivalOrganization,
        on: cer.organization_id == org.id,
        where: c.tracks_person == true and is_nil(n.person_id),
        order_by: [asc: n.id],
        select: n.id

    scoped =
      case Keyword.get(opts, :org) do
        nil ->
          base

        abbr when is_binary(abbr) ->
          from [n, c, cer, org] in base, where: org.abbreviation == ^abbr

        other ->
          raise ArgumentError, ":org must be nil or a binary, got: #{inspect(other)}"
      end

    capped =
      case Keyword.get(opts, :limit) do
        nil ->
          scoped

        n when is_integer(n) and n > 0 ->
          from(q in scoped, limit: ^n)

        other ->
          raise ArgumentError,
                ":limit must be a positive integer or nil, got: #{inspect(other)}"
      end

    ids = Repo.replica().all(capped)
    found = length(ids)
    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run? do
      Logger.info("ResolvePersons: dry-run found #{found} nominations to resolve")
      {:ok, %{found: found, enqueued: 0, failed: 0, dry_run: true}}
    else
      {enqueued, failed} = enqueue_in_chunks(ids)
      Logger.info("ResolvePersons: enqueued #{enqueued} jobs on :maintenance (#{failed} failed)")
      {:ok, %{found: found, enqueued: enqueued, failed: failed, dry_run: false}}
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
            Logger.error("Oban.insert_all returned unexpected value: #{inspect(other)}")
            {ok, err + length(chunk)}
        end
      rescue
        e ->
          Logger.error(
            "Oban.insert_all failed for chunk of #{length(chunk)}: #{Exception.message(e)}"
          )

          {ok, err + length(chunk)}
      end
    end)
  end
end
