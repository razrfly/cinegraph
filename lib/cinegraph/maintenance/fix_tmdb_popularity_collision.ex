defmodule Cinegraph.Maintenance.FixTmdbPopularityCollision do
  @moduledoc """
  Repairs the `tmdb`/`popularity_score` metric collision (#1036).

  Two writers historically wrote the same `external_metrics (movie, source='tmdb',
  metric_type='popularity_score')` key under a unique index (last-writer-wins):
  TMDb's real popularity (from `tmdb_data`) and a TMDb *list-appearance count*. The
  list-count writer ran last, so ~81% of popularity rows hold counts, not popularity —
  and the `time_machine` lens reads them as popularity.

  This module restores correctness from data already on hand (NO API calls):
    * the list-count (a row whose `metadata->>'type' = 'list_appearances'`) is moved to
      its own `tmdb`/`list_appearances` key, and
    * the real popularity is re-extracted from `tmdb_data["popularity"]` back into
      `tmdb`/`popularity_score` (metadata `algorithm_version: "v3"`).
  When `tmdb_data` has no popularity, the wrong list-count row is moved to
  `list_appearances` and the `popularity_score` row is deleted (absent > wrong).

  Idempotent: a movie whose `popularity_score` already equals `tmdb_data` popularity
  (and isn't a list-count) is not targeted, so re-runs / the sweeper are no-ops.

  Reachable from:
    * `mix cinegraph.movies.fix_tmdb_popularity_collision` (dev)
    * `bin/cinegraph eval "Cinegraph.Maintenance.FixTmdbPopularityCollision.run([])"` (prod)

  ## Options
    * `:dry_run` (boolean) — count only.
    * `:batch_size` (positive integer) — default 500.
    * `:limit` (positive integer) — cap rows processed (for slice testing).

  ## Returns
  `{:ok, %{found:, processed:, failed:, dry_run:}}`
  """

  alias Cinegraph.Repo

  import Ecto.Query
  require Logger

  @default_batch_size 500
  @tol 1.0e-6

  @spec run(keyword()) ::
          {:ok,
           %{
             found: non_neg_integer(),
             processed: non_neg_integer(),
             failed: non_neg_integer(),
             dry_run: boolean()
           }}
  def run(opts \\ []) when is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    limit = Keyword.get(opts, :limit)

    ids = target_ids(limit)
    found = length(ids)
    Logger.info("FixTmdbPopularityCollision: found=#{found} movies to repair")

    if dry_run? do
      {:ok, %{found: found, processed: 0, failed: 0, dry_run: true}}
    else
      {processed, failed} = process_in_batches(ids, batch_size)
      Logger.info("FixTmdbPopularityCollision: processed=#{processed} failed=#{failed}")
      {:ok, %{found: found, processed: processed, failed: failed, dry_run: false}}
    end
  end

  defp target_ids(limit) do
    q =
      from m in "movies",
        where:
          fragment(
            """
            EXISTS (
              SELECT 1 FROM external_metrics em
              WHERE em.movie_id = ? AND em.source = 'tmdb' AND em.metric_type = 'popularity_score'
                AND (
                  (em.metadata->>'type') = 'list_appearances'
                  OR em.value IS NULL
                  OR ?->>'popularity' IS NULL
                  OR abs(em.value - (?->>'popularity')::float) > ?
                )
            )
            """,
            m.id,
            m.tmdb_data,
            m.tmdb_data,
            ^@tol
          ),
        order_by: [desc: fragment("? != '{}'::jsonb", m.canonical_sources), desc: m.id],
        select: m.id

    q = if limit, do: limit(q, ^limit), else: q
    Repo.replica().all(q)
  end

  # Three idempotent bulk statements per id-chunk:
  #   (1) preserve any misfiled list-count under its own list_appearances key,
  #   (2) overwrite popularity_score with the real tmdb_data popularity (v3),
  #   (3) delete leftover list-count popularity_score rows that have no real popularity.
  defp process_in_batches(ids, batch_size) do
    ids
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce({0, 0}, fn chunk, {ok, err} ->
      try do
        {:ok, _} = Repo.query(sql_preserve_list_appearances(), [chunk])
        {:ok, _} = Repo.query(sql_restore_popularity(), [chunk])
        {:ok, _} = Repo.query(sql_delete_orphan_listcounts(), [chunk])
        {ok + length(chunk), err}
      rescue
        e ->
          Logger.error("FixTmdbPopularityCollision: chunk failed #{inspect(e)}")
          {ok, err + length(chunk)}
      end
    end)
  end

  defp sql_preserve_list_appearances do
    """
    INSERT INTO external_metrics
      (movie_id, source, metric_type, value, text_value, metadata, fetched_at, inserted_at, updated_at)
    SELECT em.movie_id, 'tmdb', 'list_appearances', em.value, em.text_value, em.metadata,
           em.fetched_at, NOW(), NOW()
    FROM external_metrics em
    WHERE em.source = 'tmdb' AND em.metric_type = 'popularity_score'
      AND (em.metadata->>'type') = 'list_appearances'
      AND em.movie_id = ANY($1)
    ON CONFLICT (movie_id, source, metric_type) DO NOTHING
    """
  end

  defp sql_restore_popularity do
    """
    UPDATE external_metrics em
    SET value = (m.tmdb_data->>'popularity')::float,
        metadata = jsonb_build_object('algorithm_version', 'v3'),
        updated_at = NOW()
    FROM movies m
    WHERE em.movie_id = m.id
      AND em.source = 'tmdb' AND em.metric_type = 'popularity_score'
      AND m.tmdb_data->>'popularity' IS NOT NULL
      AND em.movie_id = ANY($1)
      AND ((em.metadata->>'type') = 'list_appearances'
           OR em.value IS DISTINCT FROM (m.tmdb_data->>'popularity')::float)
    """
  end

  defp sql_delete_orphan_listcounts do
    """
    DELETE FROM external_metrics em
    USING movies m
    WHERE em.movie_id = m.id
      AND em.source = 'tmdb' AND em.metric_type = 'popularity_score'
      AND (em.metadata->>'type') = 'list_appearances'
      AND m.tmdb_data->>'popularity' IS NULL
      AND em.movie_id = ANY($1)
    """
  end
end
