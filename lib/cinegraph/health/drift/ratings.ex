defmodule Cinegraph.Health.Drift.Ratings do
  @moduledoc """
  Ratings-source drift checks (#722). Cross-references `external_metrics`
  for OMDb/Rotten Tomatoes/Metacritic coverage.

  ## Population scoping

  `rt_metacritic_gap` is scoped to canonical-list movies
  (`movies.canonical_sources != '{}'`) — see #735 Phase 1.3. Most
  non-canonical movies legitimately have no RT/MC score, so reporting
  against the full 1.14M-movie catalog was a measurement artifact, not
  real drift. Other ratings checks (`omdb_null_backlog`, `omdb_stale`)
  remain scoped to the full `movies` table since OMDb coverage is a real
  catalog-wide drift signal. The denominator difference is intentional.
  """

  alias Cinegraph.Health.Drift
  alias Cinegraph.Repo

  @cache_ttl :timer.minutes(5)
  @example_limit 10

  @doc "Run all 3 ratings checks in parallel. Accepts `:limit`."
  def all(opts \\ []) do
    Drift.run_all([
      fn -> omdb_null_backlog(opts) end,
      fn -> omdb_stale(opts) end,
      fn -> rt_metacritic_gap(opts) end
    ])
  end

  @doc """
  Movies missing OMDb. Same set as `Drift.Movies.missing_omdb` —
  surfaced here under the ratings domain. Delegates to avoid duplicate SQL.
  """
  def omdb_null_backlog(opts \\ []) do
    result = Cinegraph.Health.Drift.Movies.missing_omdb(opts)
    %{result | domain: :ratings, check: :omdb_null_backlog}
  end

  @doc """
  Movies whose latest OMDb fetch is older than `@stale_omdb_days`.
  Delegates to `Drift.Movies.stale_omdb`.
  """
  def omdb_stale(opts \\ []) do
    result = Cinegraph.Health.Drift.Movies.stale_omdb(opts)
    %{result | domain: :ratings, check: :omdb_stale}
  end

  @doc """
  Movies missing **both** Rotten Tomatoes (`tomatometer`) and Metacritic
  (`metascore`). Scoped to canonical-list movies (#735 Phase 1.3) — see
  the module's `@moduledoc` for rationale.

  `affected_pct` is the fraction of *canonical-list* movies that lack both.
  """
  def rt_metacritic_gap(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:ratings, :rt_metacritic_gap, limit}, @cache_ttl, fn ->
      total =
        scalar("""
        SELECT count(*)::bigint FROM movies
        WHERE canonical_sources != '{}'::jsonb
        """)

      affected =
        scalar("""
        SELECT count(*)::bigint FROM movies m
        WHERE m.canonical_sources != '{}'::jsonb
        AND NOT EXISTS (
          SELECT 1 FROM external_metrics em
          WHERE em.movie_id = m.id AND em.source = 'rotten_tomatoes' AND em.metric_type = 'tomatometer'
        )
        AND NOT EXISTS (
          SELECT 1 FROM external_metrics em
          WHERE em.movie_id = m.id AND em.source = 'metacritic' AND em.metric_type = 'metascore'
        )
        """)

      sql_examples = """
      SELECT m.id, m.title, m.release_date FROM movies m
      WHERE m.canonical_sources != '{}'::jsonb
      AND NOT EXISTS (
        SELECT 1 FROM external_metrics em
        WHERE em.movie_id = m.id AND em.source = 'rotten_tomatoes' AND em.metric_type = 'tomatometer'
      )
      AND NOT EXISTS (
        SELECT 1 FROM external_metrics em
        WHERE em.movie_id = m.id AND em.source = 'metacritic' AND em.metric_type = 'metascore'
      )
      ORDER BY m.id DESC LIMIT $1
      """

      examples =
        case Ecto.Adapters.SQL.query!(Repo.replica(), sql_examples, [limit]) do
          %{rows: rows} ->
            Enum.map(rows, fn [id, title, rd] ->
              %{
                id: id,
                title: title,
                release_date: rd,
                reason: "no Rotten Tomatoes or Metacritic rating (canonical-list scope)"
              }
            end)

          _ ->
            []
        end

      Drift.result(:ratings, :rt_metacritic_gap, total, affected, examples)
    end)
  end

  defp scalar(sql, params \\ []) do
    case Ecto.Adapters.SQL.query!(Repo.replica(), sql, params) do
      %{rows: [[v]]} -> v
      _ -> 0
    end
  end
end
