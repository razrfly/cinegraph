defmodule Cinegraph.Maintenance.RebuildCollaborationTrends do
  @moduledoc """
  Rebuilds the `person_collaboration_trends` materialized view with a cheap,
  correct definition and swaps it in with zero downtime.

  ## Background (GitHub #1018 / #1019)

  The original definition (migration `20250730130132`) had two problems:

    1. `new_collaborators` was computed with a correlated `NOT IN` subquery
       (O(n²)). In production a full `REFRESH` ran ~19.5 hours while holding an
       `ACCESS EXCLUSIVE` lock, piling up readers and saturating the shared
       Postgres connection pool.
    2. `avg_rating` and `total_revenue` were aggregated over a row set that had
       been multiplied by a `movie_genres` join (one row per genre) AND by the
       per-collaboration fan-out (one row per co-star on the same movie). On dev
       data this inflated `avg_rating` for ~15% of person-years and
       `total_revenue` for ~10%.

  A later "simple" migration (`20250730130500`) tried to replace the definition
  but used `CREATE MATERIALIZED VIEW IF NOT EXISTS` — a silent no-op on any DB
  that already ran migration 1, so production still runs the broken query.

  `view_sql/0` fixes both: `new_collaborators` is `MIN(year)` per
  `(person, collaborator)` (no correlated subquery), and rating/revenue/genre
  aggregates run over a set deduplicated to one row per `(person, year, movie)`.

  ## Why this is not a migration for existing/large databases

  Building the view inside a synchronous Ecto migration would exceed Kamal's
  `deploy_timeout` (see `config/deploy.yml`). So production (and any large DB) is
  rebuilt out-of-band via this module, in a maintenance window:

      bin/cinegraph eval "Cinegraph.Maintenance.RebuildCollaborationTrends.run()"

  Fresh/small databases (CI, test, new clones) get the new definition from the
  guarded migration `…_redefine_person_collaboration_trends`, which only rebuilds
  inline when the dataset is small.

  ## Options

    * `:dry_run` — build `person_collaboration_trends_new`, run `validate/0`, then
      drop it WITHOUT swapping. Use to time the build and confirm the gate before
      committing to the swap.
  """

  alias Cinegraph.Database.Utils, as: DatabaseUtils
  alias Cinegraph.Repo

  require Logger

  @view "person_collaboration_trends"
  @new_view "person_collaboration_trends_new"
  @old_view "person_collaboration_trends_old"

  # Generous client-side timeout for the one-off build/swap. Bounded (not
  # `:infinity`) on purpose — server-side `statement_timeout` enforcement for the
  # recurring refresh path is Session 2.
  @build_timeout :timer.minutes(30)
  @swap_timeout :timer.minutes(5)

  @doc """
  Canonical cheap-correct SELECT for `person_collaboration_trends`.

  Single source of truth for the view definition. The matching migration embeds a
  frozen copy of this SQL — keep them in sync if the definition changes.

  Column order/types are preserved exactly so the positional decode in
  `Cinegraph.Collaborations.get_person_collaboration_trends/1` and the unique
  index `(person_id, year)` keep working.

  Correctness notes:

    * `collab_pairs` is the base set (both perspectives), WITHOUT the genre join.
    * `person_year_movies` deduplicates to one row per `(person, year, movie)`, so
      a movie's rating/revenue is counted once regardless of genres or co-stars.
    * genres are aggregated separately and joined back by `(person_id, year)`.
    * `new_collaborators` = collaborators whose first year with the person is this
      year (`MIN(year)` per pair) — no correlated subquery.
  """
  def view_sql do
    """
    WITH collab_pairs AS (
      #{collab_pairs_select()}
    ),
    person_year_movies AS (
      SELECT person_id, year, movie_id,
             MAX(movie_rating)  AS movie_rating,
             MAX(movie_revenue) AS movie_revenue
      FROM collab_pairs
      GROUP BY person_id, year, movie_id
    ),
    movie_stats AS (
      SELECT person_id, year,
             COUNT(*)                        AS total_collaborations,
             AVG(movie_rating)::NUMERIC(3,1) AS avg_rating,
             SUM(movie_revenue)              AS total_revenue
      FROM person_year_movies
      GROUP BY person_id, year
    ),
    collaborator_stats AS (
      SELECT person_id, year,
             COUNT(DISTINCT collaborator_id) AS unique_collaborators
      FROM collab_pairs
      GROUP BY person_id, year
    ),
    genre_stats AS (
      SELECT pym.person_id, pym.year,
             array_agg(DISTINCT mg.genre_id ORDER BY mg.genre_id)
               FILTER (WHERE mg.genre_id IS NOT NULL) AS genre_ids
      FROM person_year_movies pym
      JOIN movie_genres mg ON mg.movie_id = pym.movie_id
      GROUP BY pym.person_id, pym.year
    ),
    first_seen AS (
      SELECT person_id, collaborator_id, MIN(year) AS first_year
      FROM collab_pairs
      GROUP BY person_id, collaborator_id
    ),
    new_collab_counts AS (
      SELECT person_id, first_year AS year, COUNT(*) AS new_collaborators
      FROM first_seen
      GROUP BY person_id, first_year
    )
    SELECT cs.person_id,
           cs.year,
           cs.unique_collaborators,
           COALESCE(ncc.new_collaborators, 0) AS new_collaborators,
           ms.total_collaborations,
           ms.avg_rating,
           ms.total_revenue,
           COALESCE(gs.genre_ids, ARRAY[]::integer[]) AS genre_ids
    FROM collaborator_stats cs
    JOIN movie_stats ms ON ms.person_id = cs.person_id AND ms.year = cs.year
    LEFT JOIN genre_stats gs ON gs.person_id = cs.person_id AND gs.year = cs.year
    LEFT JOIN new_collab_counts ncc ON ncc.person_id = cs.person_id AND ncc.year = cs.year
    """
  end

  # Base collaboration rows, both perspectives, one row per (collaboration_detail,
  # perspective). No genre join — kept separate so callers (the view and the
  # validation recompute) share one definition of the source set.
  defp collab_pairs_select do
    """
    SELECT cd.year, c.person_a_id AS person_id, c.person_b_id AS collaborator_id,
           cd.movie_id, cd.movie_rating, cd.movie_revenue
    FROM collaborations c
    JOIN collaboration_details cd ON c.id = cd.collaboration_id
    WHERE cd.year IS NOT NULL
    UNION ALL
    SELECT cd.year, c.person_b_id AS person_id, c.person_a_id AS collaborator_id,
           cd.movie_id, cd.movie_rating, cd.movie_revenue
    FROM collaborations c
    JOIN collaboration_details cd ON c.id = cd.collaboration_id
    WHERE cd.year IS NOT NULL
    """
  end

  @doc """
  Build the new view, validate it, and (unless `:dry_run`) swap it in atomically.

  Returns `{:ok, report}` or `{:error, reason}`. The report includes the
  validation metrics, `:build_ms`, `:dry_run`, and `:swapped`.
  """
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    try do
      # Clean up any leftover _new from a previously aborted run.
      drop_new!()

      Logger.info("RebuildCollaborationTrends: building #{@new_view}…")
      {build_us, :ok} = :timer.tc(fn -> build_new!() end)
      build_ms = div(build_us, 1000)
      Logger.info("RebuildCollaborationTrends: built #{@new_view} in #{build_ms} ms")

      case validate() do
        {:ok, report} ->
          report = Map.put(report, :build_ms, build_ms)

          if dry_run? do
            drop_new!()
            Logger.info("RebuildCollaborationTrends: dry run OK, dropped #{@new_view} (no swap)")
            {:ok, Map.merge(report, %{dry_run: true, swapped: false})}
          else
            swap!()

            unless DatabaseUtils.has_unique_index?(@view) do
              raise "post-swap: #{@view} has no usable unique index — CONCURRENTLY refresh would be unavailable"
            end

            Logger.info("RebuildCollaborationTrends: swapped #{@new_view} into #{@view}")
            {:ok, Map.merge(report, %{dry_run: false, swapped: true})}
          end

        {:error, reason} = err ->
          Logger.error(
            "RebuildCollaborationTrends: validation failed, leaving #{@view} untouched: #{inspect(reason)}"
          )

          drop_new!()
          err
      end
    rescue
      error ->
        Logger.error("RebuildCollaborationTrends: aborted: #{inspect(error)}")
        # Best-effort cleanup; never mask the original error.
        try do
          drop_new!()
        rescue
          _ -> :ok
        end

        {:error, error}
    end
  end

  @doc """
  Validate the freshly-built `person_collaboration_trends_new` before any swap.

  Per #1019, this does NOT re-run the old O(n²) definition. It enforces
  correctness invariants and re-derives the aggregates from source with the
  intended (deduplicated) logic:

    * structural — identical column set/order/types vs the live view
    * row count — exactly one row per `(person, year)` present in source
    * per-row — `0 <= new_collaborators <= unique_collaborators`, both `>= 1`,
      `avg_rating` in `[0,10]`, `total_revenue >= 0`
    * `new_collaborators` — for every person, `SUM(new_collaborators)` over years
      equals their lifetime distinct collaborator count
    * aggregates — `total_collaborations`, `avg_rating`, `total_revenue` match a
      reference recomputed over distinct `(person, year, movie)` rows (proves the
      materialized result matches the spec, including the dedup fix)

  The live view's contents are not required (it may be unpopulated); `old_row_count`
  is reported when available but never gates the result.
  """
  def validate do
    with :ok <- check_columns_match(),
         {:ok, counts} <- check_row_count(),
         :ok <- check_per_row_invariants(),
         :ok <- check_sum_invariant(),
         :ok <- check_aggregate_correctness() do
      {:ok, counts}
    end
  end

  ## --- build / swap ---

  defp build_new! do
    # Every build/index DDL gets the same generous, bounded client timeout — index
    # creation on a freshly-built view can also be multi-minute at prod scale.
    Repo.query!("CREATE MATERIALIZED VIEW #{@new_view} AS #{view_sql()}", [],
      timeout: @build_timeout
    )

    Repo.query!(
      "CREATE UNIQUE INDEX #{@new_view}_unique_idx ON #{@new_view} (person_id, year)",
      [],
      timeout: @build_timeout
    )

    Repo.query!("CREATE INDEX #{@new_view}_person_idx ON #{@new_view} (person_id)", [],
      timeout: @build_timeout
    )

    Repo.query!("CREATE INDEX #{@new_view}_year_idx ON #{@new_view} (year)", [],
      timeout: @build_timeout
    )

    :ok
  end

  defp drop_new! do
    Repo.query!("DROP MATERIALIZED VIEW IF EXISTS #{@new_view}", [])
    :ok
  end

  # Atomic rename-swap. Postgrex uses the extended protocol, so each statement is
  # issued separately inside a single transaction (no multi-statement strings).
  defp swap! do
    {:ok, _} =
      Repo.transaction(
        fn -> Enum.each(swap_statements(), &Repo.query!(&1, [])) end,
        timeout: @swap_timeout
      )

    # Old view is now detached; drop it outside the swap transaction.
    Repo.query!("DROP MATERIALIZED VIEW #{@old_view}", [])
    :ok
  end

  defp swap_statements do
    [
      "ALTER MATERIALIZED VIEW #{@view} RENAME TO #{@old_view}",
      "ALTER INDEX person_collaboration_trends_unique_idx RENAME TO #{@old_view}_unique_idx",
      "ALTER INDEX person_collaboration_trends_person_idx RENAME TO #{@old_view}_person_idx",
      "ALTER INDEX person_collaboration_trends_year_idx RENAME TO #{@old_view}_year_idx",
      "ALTER MATERIALIZED VIEW #{@new_view} RENAME TO #{@view}",
      "ALTER INDEX #{@new_view}_unique_idx RENAME TO person_collaboration_trends_unique_idx",
      "ALTER INDEX #{@new_view}_person_idx RENAME TO person_collaboration_trends_person_idx",
      "ALTER INDEX #{@new_view}_year_idx RENAME TO person_collaboration_trends_year_idx"
    ]
  end

  ## --- validation ---

  defp check_columns_match do
    if columns(@view) == columns(@new_view) do
      :ok
    else
      {:error, {:column_mismatch, old: columns(@view), new: columns(@new_view)}}
    end
  end

  defp columns(relation) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1
        ORDER BY ordinal_position
        """,
        [relation]
      )

    rows
  end

  # Exactly one row per (person, year) present in source.
  defp check_row_count do
    new_count = count(@new_view)
    expected = expected_row_count()
    # Compare the actual (person_id, year) key set, not just totals — otherwise one
    # missing key plus one extra wrong key would cancel out and still pass.
    key_mismatches = row_key_mismatches()
    # Live view may be unpopulated; report its count only when available.
    old_count = if populated?(@view), do: count(@view), else: :unpopulated

    if new_count == expected and key_mismatches == 0 do
      {:ok, %{old_row_count: old_count, new_row_count: new_count, expected_row_count: expected}}
    else
      {:error,
       {:row_count_mismatch, expected: expected, new: new_count, key_mismatches: key_mismatches}}
    end
  end

  # Number of (person_id, year) keys present in exactly one of {source, _new}.
  defp row_key_mismatches do
    %{rows: [[n]]} =
      Repo.query!(
        """
        WITH cp AS (#{collab_pairs_select()}),
        expected AS (SELECT DISTINCT person_id, year FROM cp),
        actual AS (SELECT person_id, year FROM #{@new_view})
        SELECT count(*) FROM (
          (SELECT person_id, year FROM expected
           EXCEPT
           SELECT person_id, year FROM actual)
          UNION ALL
          (SELECT person_id, year FROM actual
           EXCEPT
           SELECT person_id, year FROM expected)
        ) mismatches
        """,
        [],
        timeout: @build_timeout
      )

    n
  end

  defp expected_row_count do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM (SELECT DISTINCT person_id, year FROM (#{collab_pairs_select()}) cp) g",
        [],
        timeout: @build_timeout
      )

    n
  end

  defp count(relation) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{relation}", [])
    n
  end

  defp populated?(relation) do
    case Repo.query!(
           "SELECT ispopulated FROM pg_matviews WHERE schemaname = 'public' AND matviewname = $1",
           [relation]
         ) do
      %{rows: [[populated]]} -> populated
      _ -> false
    end
  end

  defp check_per_row_invariants do
    %{rows: [[bad]]} =
      Repo.query!(
        """
        SELECT count(*) FROM #{@new_view}
        WHERE new_collaborators < 0
           OR new_collaborators > unique_collaborators
           OR unique_collaborators < 1
           OR total_collaborations < 1
           OR (avg_rating IS NOT NULL AND (avg_rating < 0 OR avg_rating > 10))
           OR (total_revenue IS NOT NULL AND total_revenue < 0)
        """,
        []
      )

    if bad == 0, do: :ok, else: {:error, {:per_row_invariant_violations, bad}}
  end

  # For every person, SUM(new_collaborators) across years must equal their lifetime
  # distinct collaborator count from source.
  defp check_sum_invariant do
    %{rows: [[mismatches]]} =
      Repo.query!(
        """
        WITH cp AS (#{collab_pairs_select()}),
        lifetime AS (
          SELECT person_id, COUNT(DISTINCT collaborator_id) AS n
          FROM cp GROUP BY person_id
        ),
        from_view AS (
          SELECT person_id, SUM(new_collaborators) AS n
          FROM #{@new_view} GROUP BY person_id
        )
        SELECT count(*)
        FROM lifetime l
        FULL OUTER JOIN from_view v USING (person_id)
        WHERE COALESCE(l.n, 0) <> COALESCE(v.n, 0)
        """,
        [],
        timeout: @build_timeout
      )

    if mismatches == 0, do: :ok, else: {:error, {:sum_invariant_mismatches, mismatches}}
  end

  # total_collaborations / avg_rating / total_revenue must match a reference
  # recomputed over distinct (person, year, movie) rows — i.e. with the dedup fix.
  defp check_aggregate_correctness do
    %{rows: [[mismatches]]} =
      Repo.query!(
        """
        WITH cp AS (#{collab_pairs_select()}),
        pym AS (
          SELECT person_id, year, movie_id,
                 MAX(movie_rating)  AS movie_rating,
                 MAX(movie_revenue) AS movie_revenue
          FROM cp GROUP BY person_id, year, movie_id
        ),
        ref AS (
          SELECT person_id, year,
                 COUNT(*)                        AS total_collaborations,
                 AVG(movie_rating)::NUMERIC(3,1) AS avg_rating,
                 SUM(movie_revenue)              AS total_revenue
          FROM pym GROUP BY person_id, year
        )
        SELECT count(*)
        FROM #{@new_view} v
        JOIN ref r ON r.person_id = v.person_id AND r.year = v.year
        WHERE v.total_collaborations <> r.total_collaborations
           OR v.avg_rating    IS DISTINCT FROM r.avg_rating
           OR v.total_revenue IS DISTINCT FROM r.total_revenue
        """,
        [],
        timeout: @build_timeout
      )

    if mismatches == 0, do: :ok, else: {:error, {:aggregate_mismatches, mismatches}}
  end
end
