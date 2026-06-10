defmodule Cinegraph.Maintenance.MarkImdbIdAbsent do
  @moduledoc """
  Marks movies whose IMDb ID does not exist at the source as **source-absent**
  in the freshness ledger (#1109), so `imdb_id` reads as terminal instead of a
  permanent backlog.

  `imdb_id` is read straight from the TMDb `/movie` top-level field
  (`Movie.from_tmdb/1`) — there is no separate lookup. So a movie whose TMDb
  details were fetched but whose `imdb_id` is still null/empty means the source
  simply has none: that is terminal (source-absent), not work to do.

  Eligible = `imdb_id` null/empty **and** a `tmdb_details` ledger attempt exists
  (`ok|empty|ineligible` — we fetched details, so we saw the field) **and** no
  `imdb_id` ledger row yet (idempotent: re-runs skip already-marked movies).

  Writes `:empty` rows in bulk via `Repo.insert_all` — mirroring `Freshness.touch/5`'s
  fields + conflict behavior, with the Policy `:empty` TTL — fast enough for the
  one-shot 300–510k catch-up (row-by-row `touch` was too DB-chatty at that scale).

  Movies that are null but were *never* fully detail-fetched (no `tmdb_details`
  ledger row — e.g. discovery-only stubs whose payload never carried `imdb_id`)
  are **deliberately excluded**: they are genuine backlog, not source-absent. They
  remain `needs_fetch` until a full `/movie` fetch runs. NOTE (#1109): the existing
  `RepairImdbIds → TMDbDetailsWorker` path can't complete those stubs — the worker
  skips movies that already exist (`tmdb_details_worker.ex` `process_tmdb_movie/3`).
  Completing stubs is a separate pre-existing gap (follow-up under #760/#1108), not
  this module's job.

  Reachable from:
  - `Cinegraph.Workers.MarkImdbIdAbsentSweeper` (Oban Cron, weekly, belt-and-suspenders)
  - `bin/cinegraph eval "Cinegraph.Maintenance.MarkImdbIdAbsent.run([])"` (one-shot prod)

  ## Options
    * `:limit` (positive integer) — cap the number of movies marked.
    * `:dry_run` (boolean) — count only; write nothing.

  ## Returns
  `{:ok, %{found: integer, marked: integer, failed: integer, dry_run: boolean}}`
  """

  alias Cinegraph.Freshness.{DataRefresh, Policy}
  alias Cinegraph.Repo

  import Ecto.Query
  require Logger

  # Sub-batch under Postgres' 65,535 bind-param cap (~12 fields/row → ≤ ~5,400 rows).
  @insert_chunk_size 4_000
  # One-time catch-up of the checked-but-null set (~300–510k); no API, so high.
  @default_limit 1_000_000

  @spec run(keyword()) ::
          {:ok,
           %{
             found: non_neg_integer(),
             marked: non_neg_integer(),
             failed: non_neg_integer(),
             dry_run: boolean()
           }}
  def run(opts \\ []) when is_list(opts) do
    limit =
      case Keyword.get(opts, :limit, @default_limit) do
        n when is_integer(n) and n > 0 -> n
        other -> raise ArgumentError, ":limit must be a positive integer, got: #{inspect(other)}"
      end

    base =
      from m in "movies",
        where:
          (is_nil(m.imdb_id) or m.imdb_id == "") and
            fragment(
              "EXISTS (SELECT 1 FROM data_refreshes dr WHERE dr.entity_type = 'movie' AND dr.entity_id = ? AND dr.source = 'tmdb_details' AND dr.status IN ('ok','empty','ineligible'))",
              m.id
            ) and
            fragment(
              "NOT EXISTS (SELECT 1 FROM data_refreshes dr WHERE dr.entity_type = 'movie' AND dr.entity_id = ? AND dr.source = 'imdb_id')",
              m.id
            ),
        order_by: [asc: m.id],
        limit: ^limit,
        select: {m.id, m.release_date}

    rows = Repo.replica().all(base)
    found = length(rows)
    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run? do
      Logger.info("MarkImdbIdAbsent: dry-run found #{found} movies to mark source-absent")
      {:ok, %{found: found, marked: 0, failed: 0, dry_run: true}}
    else
      {marked, failed} = mark_in_chunks(rows)
      Logger.info("MarkImdbIdAbsent: marked #{marked} imdb_id source-absent (#{failed} failed)")
      {:ok, %{found: found, marked: marked, failed: failed, dry_run: false}}
    end
  end

  defp mark_in_chunks(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce({0, 0}, fn chunk, {ok, err} ->
      entries = Enum.map(chunk, &entry(&1, now))

      try do
        # Mirror Freshness.touch/5 (#1109): status "empty", fetched_at nil, Policy :empty
        # TTL, attempt_count 0, and the same on_conflict/conflict_target so a concurrent
        # touch never duplicates. insert_all does NO casting — values are DB-ready.
        {count, _} =
          Repo.insert_all(DataRefresh, entries,
            on_conflict: {:replace_all_except, [:id, :inserted_at]},
            conflict_target: [:entity_type, :entity_id, :source]
          )

        {ok + count, err}
      rescue
        e ->
          Logger.error(
            "MarkImdbIdAbsent: insert_all failed for chunk of #{length(chunk)}: #{Exception.message(e)}"
          )

          {ok, err + length(chunk)}
      end
    end)
  end

  defp entry({movie_id, release_date}, now) do
    %{
      entity_type: "movie",
      entity_id: movie_id,
      source: "imdb_id",
      status: "empty",
      fetched_at: nil,
      stale_after: Policy.stale_after("movie", "imdb_id", release_date, now, status: :empty),
      attempt_count: 0,
      last_attempt_at: now,
      error_reason: nil,
      metadata: %{},
      inserted_at: now,
      updated_at: now
    }
  end
end
