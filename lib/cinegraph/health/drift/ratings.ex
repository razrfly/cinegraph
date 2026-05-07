defmodule Cinegraph.Health.Drift.Ratings do
  @moduledoc """
  Ratings-source drift checks (#722). Cross-references `external_metrics`
  for OMDb/Rotten Tomatoes/Metacritic coverage.

  ## Population scoping

  All checks in this module are canonical-scoped (`movies.canonical_sources
  != '{}'`). Bulk-TMDb long-tail movies legitimately lack RT/MC/OMDb
  coverage and reporting against them was a measurement artifact rather
  than real drift.

    * `rt_metacritic_gap` — inline canonical scope (#735 Phase 1.3),
      now via `Cinegraph.Health.Scopes.canonical_movies/0`.
    * `omdb_null_backlog`, `omdb_stale` — delegate to
      `Cinegraph.Health.Drift.Movies` and inherit its canonical scope
      (#896 Phase 1.2).
  """

  import Ecto.Query
  alias Cinegraph.Health.{Drift, Scopes}
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
      canonical_base = Scopes.canonical_movies()

      missing_both_base =
        from(m in canonical_base,
          where:
            fragment(
              "NOT EXISTS (SELECT 1 FROM external_metrics em WHERE em.movie_id = ? AND em.source = 'rotten_tomatoes' AND em.metric_type = 'tomatometer')",
              m.id
            ) and
              fragment(
                "NOT EXISTS (SELECT 1 FROM external_metrics em WHERE em.movie_id = ? AND em.source = 'metacritic' AND em.metric_type = 'metascore')",
                m.id
              )
        )

      total = Repo.replica().one(from(m in canonical_base, select: count(m.id))) || 0
      affected = Repo.replica().one(from(m in missing_both_base, select: count(m.id))) || 0

      examples =
        from(m in missing_both_base,
          select: %{id: m.id, title: m.title, release_date: m.release_date},
          order_by: [desc: m.id],
          limit: ^limit
        )
        |> Repo.replica().all()
        |> Enum.map(
          &Map.put(
            &1,
            :reason,
            "no Rotten Tomatoes or Metacritic rating (canonical-list scope)"
          )
        )

      Drift.result(:ratings, :rt_metacritic_gap, total, affected, examples)
    end)
  end
end
