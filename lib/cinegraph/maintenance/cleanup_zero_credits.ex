defmodule Cinegraph.Maintenance.CleanupZeroCredits do
  @moduledoc """
  Release-safe maintenance entry point for the zero-credits cleanup
  (#745 Phase 1.5). Two-phase logic:

  1. **`enqueue_refetch/1`** — Enqueue `TMDbDetailsWorker` jobs for orphan
     people (those with no `movie_credits` rows). The worker re-fetches
     credits from TMDb; if TMDb has credits we missed, the orphan condition
     resolves naturally.
  2. **`delete_still_orphaned/1`** — Hard-delete people who *remain* orphaned
     after the refetch path. Only deletes rows whose `tmdb_id` is set (so we
     can reproduce the import if needed) and whose post-refetch state still
     shows zero credits. Wrapped in a transaction; logs each delete.

  The delete phase runs as a separate cron 24h after the enqueue phase to
  give TMDb fetches time to land.

  Reachable from:
  - `mix cinegraph.people.cleanup_zero_credits --phase enqueue` (default)
  - `mix cinegraph.people.cleanup_zero_credits --phase delete`
  - `Cinegraph.Workers.ZeroCreditsCleanupSweeper` (Sun cron, enqueue)
  - `Cinegraph.Workers.ZeroCreditsCleanupDeleteSweeper` (Mon cron, delete)
  - `bin/cinegraph eval "Cinegraph.Maintenance.CleanupZeroCredits.run([])"`

  ## Options (both phases)
    * `:limit` (positive integer)
    * `:dry_run` (boolean)

  ## Returns
  `{:ok, %{found, enqueued: integer | nil, deleted: integer | nil, failed, dry_run, phase}}`
  """

  alias Cinegraph.Movies.Person
  alias Cinegraph.Repo
  alias Cinegraph.Workers.TMDbDetailsWorker

  import Ecto.Query
  require Logger

  @insert_chunk_size 500

  @doc """
  Default entry point — runs the enqueue phase. Use `enqueue_refetch/1` or
  `delete_still_orphaned/1` directly to pick a specific phase.
  """
  def run(opts \\ []), do: enqueue_refetch(opts)

  @doc """
  Phase 1 — enqueue TMDbDetailsWorker for each orphan person with a tmdb_id.
  """
  @spec enqueue_refetch(keyword()) ::
          {:ok,
           %{
             found: non_neg_integer(),
             enqueued: non_neg_integer(),
             failed: non_neg_integer(),
             dry_run: boolean(),
             phase: :enqueue
           }}
  def enqueue_refetch(opts \\ []) when is_list(opts) do
    base =
      from p in "people",
        where:
          not fragment(
            "EXISTS (SELECT 1 FROM movie_credits mc WHERE mc.person_id = ?)",
            p.id
          ) and not is_nil(p.tmdb_id),
        order_by: [asc: p.id],
        select: p.tmdb_id

    capped =
      case Keyword.get(opts, :limit) do
        nil ->
          base

        n when is_integer(n) and n > 0 ->
          from(q in base, limit: ^n)

        other ->
          raise ArgumentError,
                ":limit must be a positive integer or nil, got: #{inspect(other)}"
      end

    tmdb_ids = Repo.replica().all(capped)
    found = length(tmdb_ids)
    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run? do
      Logger.info("CleanupZeroCredits[enqueue]: dry-run found #{found} orphans")
      {:ok, %{found: found, enqueued: 0, failed: 0, dry_run: true, phase: :enqueue}}
    else
      {enqueued, failed} = enqueue_in_chunks(tmdb_ids)

      Logger.info(
        "CleanupZeroCredits[enqueue]: enqueued #{enqueued} TMDb refetches (#{failed} failed)"
      )

      {:ok, %{found: found, enqueued: enqueued, failed: failed, dry_run: false, phase: :enqueue}}
    end
  end

  @doc """
  Phase 2 — hard-delete people who *still* have zero credits after the
  enqueue phase ran. Safety-bounded to rows with a `tmdb_id` so the
  operation is auditable and reproducible.
  """
  @spec delete_still_orphaned(keyword()) ::
          {:ok,
           %{
             found: non_neg_integer(),
             deleted: non_neg_integer(),
             failed: non_neg_integer(),
             dry_run: boolean(),
             phase: :delete
           }}
  def delete_still_orphaned(opts \\ []) when is_list(opts) do
    # Pull the orphan rows themselves (id + name + tmdb_id) for logging.
    base =
      from p in Person,
        where:
          not fragment(
            "EXISTS (SELECT 1 FROM movie_credits mc WHERE mc.person_id = ?)",
            p.id
          ) and not is_nil(p.tmdb_id),
        order_by: [asc: p.id]

    capped =
      case Keyword.get(opts, :limit) do
        nil ->
          base

        n when is_integer(n) and n > 0 ->
          from(q in base, limit: ^n)

        other ->
          raise ArgumentError,
                ":limit must be a positive integer or nil, got: #{inspect(other)}"
      end

    rows = Repo.all(capped)
    found = length(rows)
    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run? do
      Logger.info("CleanupZeroCredits[delete]: dry-run found #{found} still-orphaned rows")
      {:ok, %{found: found, deleted: 0, failed: 0, dry_run: true, phase: :delete}}
    else
      {deleted, failed} = delete_each(rows)

      Logger.info(
        "CleanupZeroCredits[delete]: deleted #{deleted} orphan people (#{failed} failed)"
      )

      {:ok, %{found: found, deleted: deleted, failed: failed, dry_run: false, phase: :delete}}
    end
  end

  defp enqueue_in_chunks(tmdb_ids) do
    tmdb_ids
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce({0, 0}, fn chunk, {ok, err} ->
      jobs = Enum.map(chunk, &TMDbDetailsWorker.new(%{"tmdb_id" => &1}))

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

  defp delete_each(rows) do
    Enum.reduce(rows, {0, 0}, fn person, {ok, err} ->
      try do
        Repo.transaction(fn ->
          # Single conditional delete: the WHERE clause re-evaluates at delete
          # time, so a credit row inserted between the candidate-set query and
          # this statement keeps the person row alive. Avoids the race where a
          # separate count() + Repo.delete! could cascade-delete credits
          # (movie_credits.person_id is on_delete: :delete_all).
          delete_query =
            from(p in Person,
              where: p.id == ^person.id,
              where:
                not fragment(
                  "EXISTS (SELECT 1 FROM movie_credits mc WHERE mc.person_id = ?)",
                  p.id
                )
            )

          case Repo.delete_all(delete_query) do
            {1, _} ->
              Logger.warning(
                "CleanupZeroCredits: deleting orphan person id=#{person.id} name=#{inspect(person.name)} tmdb_id=#{person.tmdb_id}"
              )

              :deleted

            {0, _} ->
              Logger.info(
                "CleanupZeroCredits: skipping id=#{person.id} (credits arrived after refetch)"
              )

              :skipped
          end
        end)
        |> case do
          {:ok, :deleted} -> {ok + 1, err}
          {:ok, :skipped} -> {ok, err}
          _ -> {ok, err + 1}
        end
      rescue
        e ->
          Logger.error(
            "CleanupZeroCredits: failed to delete person #{person.id}: #{Exception.message(e)}"
          )

          {ok, err + 1}
      end
    end)
  end
end
