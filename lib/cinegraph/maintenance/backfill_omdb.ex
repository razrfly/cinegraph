defmodule Cinegraph.Maintenance.BackfillOmdb do
  @moduledoc """
  Release-safe maintenance entry point for the OMDb null backfill. Enqueues
  one `OMDbEnrichmentWorker` job per movie that has no `external_metrics` row
  with `source = 'omdb'`.

  Reachable from:
  - `mix cinegraph.movies.backfill_omdb` (dev)
  - `Cinegraph.Workers.OmdbBackfillSweeper` (Oban Cron, prod)
  - `bin/cinegraph eval "Cinegraph.Maintenance.BackfillOmdb.run([])"` (one-shot)

  Only movies with a non-blank `imdb_id` are eligible — OMDb requires an
  IMDb ID and has no alternative identifier. Movies without one are skipped
  to avoid burning the daily cap on permanently-ineligible entries.

  Canonical-list movies are prioritised first, then by id desc — so daily
  runs always advance the highest-value subset.

  See #745 Phase 1.1.

  ## Options
    * `:limit` (positive integer) — cap the number of jobs enqueued.
    * `:dry_run` (boolean) — count only; do not enqueue.

  ## Returns
  `{:ok, %{found: integer, enqueued: integer, failed: integer, dry_run: boolean}}`
  """

  alias Cinegraph.Repo
  alias Cinegraph.Workers.OMDbEnrichmentWorker

  import Ecto.Query
  require Logger

  @spec run(keyword()) ::
          {:ok,
           %{
             found: non_neg_integer(),
             enqueued: non_neg_integer(),
             failed: non_neg_integer(),
             dry_run: boolean()
           }}
  def run(opts \\ []) when is_list(opts) do
    # Order: canonical-list movies first, then by id desc. (Movies have no
    # `popularity` column; popularity lives in the `tmdb_data` JSONB blob and
    # isn't worth a JSONB cast for ordering when canonical-membership already
    # encodes priority.)
    #
    # Only imdb_id-bearing movies are selected. OMDb requires an IMDb ID; movies
    # without one return :invalid_imdb_id immediately and never produce an
    # external_metrics row, so they would re-enter this backlog on every sweep.
    base =
      from m in "movies",
        where:
          not fragment(
            "EXISTS (SELECT 1 FROM external_metrics em WHERE em.movie_id = ? AND em.source = 'omdb')",
            m.id
          ) and
            not is_nil(m.imdb_id) and m.imdb_id != "",
        order_by: [
          desc: fragment("? != '{}'::jsonb", m.canonical_sources),
          desc: m.id
        ],
        select: m.id

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

    ids = Repo.replica().all(capped)
    found = length(ids)
    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run? do
      Logger.info("BackfillOmdb: dry-run found #{found} movies to enrich")
      {:ok, %{found: found, enqueued: 0, failed: 0, dry_run: true}}
    else
      {enqueued, failed} = enqueue_each(ids)
      Logger.info("BackfillOmdb: enqueued #{enqueued} jobs on :omdb (#{failed} failed)")
      {:ok, %{found: found, enqueued: enqueued, failed: failed, dry_run: false}}
    end
  end

  # Per-job inserts so the worker's :unique config is honoured —
  # Oban.insert_all bypasses uniqueness on the default BasicEngine.
  defp enqueue_each(ids) do
    Enum.reduce(ids, {0, 0}, fn id, {ok, err} ->
      job = OMDbEnrichmentWorker.new(%{"movie_id" => id})

      try do
        case Oban.insert(job) do
          {:ok, _} ->
            {ok + 1, err}

          {:error, reason} ->
            Logger.error(
              "BackfillOmdb: failed to insert OMDb job for movie_id=#{id} error=#{inspect(reason)}"
            )

            {ok, err + 1}
        end
      rescue
        e ->
          Logger.error(
            "BackfillOmdb: exception inserting OMDb job for movie_id=#{id}: #{Exception.message(e)}"
          )

          {ok, err + 1}
      end
    end)
  end
end
