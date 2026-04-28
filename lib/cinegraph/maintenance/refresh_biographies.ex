defmodule Cinegraph.Maintenance.RefreshBiographies do
  @moduledoc """
  Release-safe maintenance entry point for the canonical-list-people
  biography backfill. Enqueues `PersonTmdbRefreshWorker` for every person
  with a credit on a canonical-list movie (`movies.canonical_sources != '{}'`)
  whose biography is null or empty.

  Reachable from:
  - `mix cinegraph.people.refresh_biographies` (dev)
  - `Cinegraph.Workers.BiographyRefreshSweeper` (Oban Cron, prod)
  - `bin/cinegraph eval "Cinegraph.Maintenance.RefreshBiographies.run([])"` (one-shot prod)

  See #735 Phase 1.2 and #739 Phase A.

  ## Options

    * `:limit` (positive integer) — cap the number of jobs enqueued.
    * `:dry_run` (boolean) — count only; do not enqueue.

  ## Returns

  `{:ok, %{found: integer, enqueued: integer, failed: integer, dry_run: boolean}}`
  """

  alias Cinegraph.Repo
  alias Cinegraph.Workers.PersonTmdbRefreshWorker

  import Ecto.Query
  require Logger

  @insert_chunk_size 500

  @doc "Run the backfill. See module docs for options."
  @spec run(keyword()) ::
          {:ok, %{found: non_neg_integer(), enqueued: non_neg_integer(), failed: non_neg_integer(), dry_run: boolean()}}
  def run(opts \\ []) when is_list(opts) do
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
        n when is_integer(n) and n > 0 -> from(q in base, limit: ^n)
        n when is_integer(n) and n <= 0 -> raise ArgumentError, ":limit must be a positive integer, got: #{n}"
      end

    ids = Repo.replica().all(capped)
    found = length(ids)
    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run? do
      Logger.info("RefreshBiographies: dry-run found #{found} people to refresh")
      {:ok, %{found: found, enqueued: 0, failed: 0, dry_run: true}}
    else
      {enqueued, failed} = enqueue_in_chunks(ids)
      Logger.info("RefreshBiographies: enqueued #{enqueued} jobs on :tmdb (#{failed} failed)")
      {:ok, %{found: found, enqueued: enqueued, failed: failed, dry_run: false}}
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
