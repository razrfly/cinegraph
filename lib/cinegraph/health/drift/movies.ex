defmodule Cinegraph.Health.Drift.Movies do
  @moduledoc """
  Movies drift checks (#722).

  Each public function returns `Cinegraph.Health.Drift.result/5`.
  """

  import Ecto.Query

  alias Cinegraph.Health.{Drift, Scopes}
  alias Cinegraph.Repo
  alias Cinegraph.Services.TMDb.GapAnalysis

  @cache_ttl :timer.minutes(35)
  @example_limit 10
  @stale_omdb_days 180

  @doc """
  Run all 4 movies drift checks. Accepts options that get propagated to
  individual checks (`:limit`, `:year`).
  """
  def all(opts \\ []) do
    Drift.run_all([
      fn -> year_gap(opts) end,
      fn -> missing_omdb(opts) end,
      fn -> stale_omdb(opts) end,
      fn -> missing_imdb_id(opts) end
    ])
  end

  @doc """
  Per-year count vs TMDb total. By default reports the global gap from
  `Cinegraph.Services.TMDb.GapAnalysis.get_export_stats/1` (cheap — uses
  cached export). With `:year` opt, drills into our count for that
  specific year.

  ## Options

    * `:year` — focus on a specific release year. Drift returns our count
      for that year; TMDb side is reported as `blocked_reason` since the
      daily export does not include per-year data.
    * `:limit` — examples cap (default 10).
  """
  def year_gap(opts \\ []) do
    case Keyword.get(opts, :year) do
      nil -> global_year_gap(opts)
      year when is_integer(year) -> per_year_drilldown(year, opts)
    end
  end

  defp global_year_gap(_opts) do
    Drift.cached({:movies, :year_gap}, @cache_ttl, fn ->
      # Strictly cache-only — never initiate a TMDb download from the
      # health/read path (the dashboard polls every 30s).
      case GapAnalysis.get_cached_export_stats() do
        {:ok, %{export_total: tmdb_total, our_total: our_total, missing_count: missing}} ->
          examples = [
            %{
              id: nil,
              tmdb_total: tmdb_total,
              our_total: our_total,
              missing: missing,
              reason: "TMDb has #{tmdb_total} movies; we have #{our_total}; gap = #{missing}"
            }
          ]

          Drift.result(:movies, :year_gap, tmdb_total, missing, examples)

        {:error, :file_not_found} ->
          Drift.result(
            :movies,
            :year_gap,
            0,
            0,
            [],
            "no cached TMDb export — run `mix tmdb_export refresh` to populate it"
          )

        {:error, reason} ->
          Drift.result(:movies, :year_gap, 0, 0, [], "TMDb gap check failed: #{inspect(reason)}")
      end
    end)
  end

  defp per_year_drilldown(year, opts) do
    limit = Keyword.get(opts, :limit, @example_limit)
    {start_d, end_d} = year_bounds(year)

    our_count =
      scalar(
        "SELECT count(*)::bigint FROM movies WHERE release_date >= $1 AND release_date < $2",
        [start_d, end_d]
      )

    examples =
      examples_query(
        """
        SELECT id, title, release_date FROM movies
        WHERE release_date >= $1 AND release_date < $2
        ORDER BY release_date DESC LIMIT $3
        """,
        [start_d, end_d, limit],
        fn [id, title, rd] ->
          %{id: id, title: title, release_date: rd, reason: "movie released in #{year}"}
        end
      )

    Drift.result(
      :movies,
      :year_gap,
      our_count,
      0,
      examples,
      "per-year TMDb gap not available — daily export doesn't include release year"
    )
  end

  defp year_bounds(year) do
    {Date.new!(year, 1, 1), Date.new!(year + 1, 1, 1)}
  end

  @doc """
  Canonical-list movies that still **need an OMDb fetch** — the #1053 terminal-state
  predicate: no stored `omdb_data` blob AND no recent `fetch_attempt` marker (90-day
  cooldown). Scoped to canonical movies — bulk TMDb long-tail entries we don't intend
  to enrich are excluded.

  **#1090 fix:** this previously keyed on the absence of any `source='omdb'`
  external_metrics row, which **overcounted** ~156k blob-present movies: a sparse OMDb
  response yields an `imdb` row and no `omdb` row, so those looked "missing" despite
  having the blob. The predicate now matches `BackfillOmdb.needs_fetch/2` exactly, so
  drift, `mix cinegraph.surface_area`, and #1053 all agree on one definition of "done."

  Note: `Cinegraph.Health.Completeness.movies_completeness/0` measures OMDb differently —
  it counts movies where `omdb_data IS NOT NULL` (data present). A movie
  attempted-and-failed counts as "not missing" here but as "missing" there. Both are
  intentional: drift = "do we still need to try?", completeness = "do we have the data?".
  """
  def missing_omdb(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:movies, :missing_omdb, limit}, @cache_ttl, fn ->
      total = Scopes.canonical_movies_count()

      # Shared OMDb needs-fetch predicate (no blob ∧ no recent fetch_attempt) on the canonical
      # scope, PLUS the OMDb-eligibility filter (a usable imdb_id — OMDb has no other lookup).
      # Without the imdb_id filter, canonical movies with no IMDb ID would double-count here AND
      # under `missing_imdb_id`; they belong only to the latter. Matches `BackfillOmdb.eligible_ids/1`.
      missing_base =
        Scopes.canonical_movies()
        |> Cinegraph.Maintenance.BackfillOmdb.needs_fetch()
        |> where([m], not is_nil(m.imdb_id) and m.imdb_id != "")

      affected = Repo.replica().one(from(m in missing_base, select: count(m.id))) || 0

      examples =
        from(m in missing_base,
          select: %{id: m.id, title: m.title, release_date: m.release_date},
          order_by: [desc: m.id],
          limit: ^limit
        )
        |> Repo.replica().all()
        |> Enum.map(
          &Map.put(
            &1,
            :reason,
            "canonical + has imdb_id, no OMDb blob and no recent fetch attempt"
          )
        )

      Drift.result(:movies, :missing_omdb, total, affected, examples)
    end)
  end

  @doc "Movies whose latest OMDb fetch is older than `@stale_omdb_days` days."
  def stale_omdb(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:movies, :stale_omdb, limit}, @cache_ttl, fn ->
      cutoff = DateTime.utc_now() |> DateTime.add(-@stale_omdb_days * 86_400, :second)

      total =
        scalar(
          "SELECT count(DISTINCT movie_id)::bigint FROM external_metrics WHERE source = 'omdb'"
        )

      sql_count = """
      SELECT count(*)::bigint FROM (
        SELECT movie_id, MAX(fetched_at) AS last
        FROM external_metrics
        WHERE source = 'omdb'
        GROUP BY movie_id
        HAVING MAX(fetched_at) < $1
      ) sub
      """

      affected =
        case Ecto.Adapters.SQL.query!(Repo.replica(), sql_count, [cutoff]) do
          %{rows: [[c]]} -> c
          _ -> 0
        end

      sql_examples = """
      SELECT m.id, m.title, MAX(em.fetched_at) AS last_fetched
      FROM external_metrics em
      JOIN movies m ON m.id = em.movie_id
      WHERE em.source = 'omdb'
      GROUP BY m.id, m.title
      HAVING MAX(em.fetched_at) < $1
      ORDER BY MAX(em.fetched_at) ASC
      LIMIT $2
      """

      examples =
        examples_query(sql_examples, [cutoff, limit], fn [id, title, last] ->
          %{
            id: id,
            title: title,
            last_fetched: last,
            reason: "OMDb fetched > #{@stale_omdb_days}d ago"
          }
        end)

      Drift.result(:movies, :stale_omdb, total, affected, examples)
    end)
  end

  @doc """
  Canonical-list movies with `imdb_id IS NULL` (#896 Phase 1.3) —
  blocks OMDb lookup. Scoped to canonical movies because the bulk TMDb
  long-tail legitimately lacks IMDb cross-references and isn't a drift
  signal we can act on.
  """
  def missing_imdb_id(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:movies, :missing_imdb_id, limit}, @cache_ttl, fn ->
      total = Scopes.canonical_movies_count()

      missing_base =
        from(m in Scopes.canonical_movies(),
          where: is_nil(m.imdb_id) or m.imdb_id == ""
        )

      affected = Repo.replica().one(from(m in missing_base, select: count(m.id))) || 0

      examples =
        from(m in missing_base,
          select: %{id: m.id, title: m.title, release_date: m.release_date},
          order_by: [desc: m.id],
          limit: ^limit
        )
        |> Repo.replica().all()
        |> Enum.map(&Map.put(&1, :reason, "imdb_id IS NULL (canonical-list scope)"))

      Drift.result(:movies, :missing_imdb_id, total, affected, examples)
    end)
  end

  defp scalar(sql, params \\ []) do
    case Ecto.Adapters.SQL.query!(Repo.replica(), sql, params) do
      %{rows: [[v]]} -> v
      _ -> 0
    end
  end

  defp examples_query(sql, params, mapper) do
    case Ecto.Adapters.SQL.query!(Repo.replica(), sql, params) do
      %{rows: rows} -> Enum.map(rows, mapper)
      _ -> []
    end
  end
end
