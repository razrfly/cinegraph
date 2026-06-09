defmodule Cinegraph.Maintenance.BackfillOmdb do
  @moduledoc """
  Release-safe maintenance entry point for the OMDb null backfill. Enqueues
  one `OMDbEnrichmentWorker` job per movie that still **needs a fetch** — has
  no stored `omdb_data` blob and no recent `fetch_attempt` marker.

  #1053: the predicate is "needs fetch", NOT "has no `source='omdb'` row". A
  successful OMDb response may legitimately materialize only an `imdb`/
  `metacritic`/`rotten_tomatoes` row and no `omdb` row (e.g. a film with an
  IMDb rating but no Awards/box-office/RT). Keying on the `omdb` row re-fetched
  those movies forever and, at a raised cap, would waste quota re-downloading
  blobs we already have. Materializing metrics from existing blobs is
  `mix cinegraph.metrics.backfill_from_jsonb`'s job (no API), not this one's.

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
    * `:movie_ids` (list of ids) — restrict the backlog to this set (e.g. the prediction
      candidate universe, #1051 Stage A2). Canonical-list members still sort first.

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
    ids = eligible_ids(opts)
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

  @doc """
  The movie ids this backfill targets, in priority order (canonical-list members first,
  then by id desc). Accepts the same `:movie_ids` and `:limit` options as `run/1`. Exposed so
  a synchronous runner (e.g. the #1051 Stage A2 candidate-universe densification) can process
  exactly the same set the sweeper would enqueue.
  """
  def eligible_ids(opts \\ []) do
    base =
      "movies"
      |> needs_fetch()
      |> where([m], not is_nil(m.imdb_id) and m.imdb_id != "")
      |> order_by([m],
        desc: fragment("? != '{}'::jsonb", m.canonical_sources),
        desc: m.id
      )
      |> select([m], m.id)

    # Optional id-set scoping (#1051 Stage A2) — restrict to e.g. the candidate universe.
    scoped =
      case Keyword.get(opts, :movie_ids) do
        nil -> base
        ids when is_list(ids) -> from(q in base, where: q.id in ^ids)
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

    Repo.replica().all(capped)
  end

  @doc """
  The #1053 OMDb **needs-fetch** predicate as a composable query, so every caller agrees on
  one definition of "not yet resolved" (this is the shared source of truth for `eligible_ids/1`,
  `Cinegraph.Health.Drift.Movies.missing_omdb/1`, and `Cinegraph.Health.SurfaceArea`).

  Adds, to `queryable` (default the `"movies"` table): no stored blob (`omdb_data IS NULL`) AND
  no recent `omdb`/`fetch_attempt` marker (90-day cooldown so source-absent movies don't churn).
  It deliberately does NOT key on a `source='omdb'` row — a sparse OMDb response yields only an
  `imdb` row and no `omdb` row (see the moduledoc). Pass `:cooldown_seconds` to override the
  90-day window.
  """
  def needs_fetch(queryable \\ "movies", opts \\ []) do
    cooldown = Keyword.get(opts, :cooldown_seconds, 90 * 24 * 3600)
    cutoff = DateTime.add(DateTime.utc_now(), -cooldown, :second)

    from m in queryable,
      where:
        is_nil(m.omdb_data) and
          not fragment(
            "EXISTS (SELECT 1 FROM external_metrics em WHERE em.movie_id = ? AND em.source = 'omdb' AND em.metric_type = 'fetch_attempt' AND em.fetched_at > ?)",
            m.id,
            ^cutoff
          )
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
