defmodule Cinegraph.Maintenance.BackfillOmdb do
  @moduledoc """
  Release-safe maintenance entry point for the OMDb null backfill. Enqueues
  one `OMDbEnrichmentWorker` job per movie that has no `external_metrics` row
  with `source = 'omdb'`.

  Reachable from:
  - `mix cinegraph.movies.backfill_omdb` (dev)
  - `Cinegraph.Workers.OmdbBackfillSweeper` (Oban Cron, prod)
  - `bin/cinegraph eval "Cinegraph.Maintenance.BackfillOmdb.run([])"` (one-shot)

  Canonical-list movies are prioritised first, then by `popularity` desc,
  then by id desc — so daily runs always advance the highest-value subset.

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

  @insert_chunk_size 500

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
    base =
      from m in "movies",
        where:
          not fragment(
            "EXISTS (SELECT 1 FROM external_metrics em WHERE em.movie_id = ? AND em.source = 'omdb')",
            m.id
          ),
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
      {enqueued, failed} = enqueue_in_chunks(ids)
      Logger.info("BackfillOmdb: enqueued #{enqueued} jobs on :omdb (#{failed} failed)")
      {:ok, %{found: found, enqueued: enqueued, failed: failed, dry_run: false}}
    end
  end

  defp enqueue_in_chunks(ids) do
    ids
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce({0, 0}, fn chunk, {ok, err} ->
      jobs = Enum.map(chunk, &OMDbEnrichmentWorker.new(%{"movie_id" => &1}))

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
