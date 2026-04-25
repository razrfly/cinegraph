defmodule Cinegraph.Health.Drift.Ratings do
  @moduledoc """
  Ratings-source drift checks (#722). Cross-references `external_metrics`
  for OMDb/Rotten Tomatoes/Metacritic coverage.
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
  (`metascore`). The contract calls this `rt_metacritic_gap`; semantically
  it's "movies with no consensus rating from either source".

  `affected_pct` is the fraction of all movies that lack both.
  """
  def rt_metacritic_gap(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:ratings, :rt_metacritic_gap}, @cache_ttl, fn ->
      total = scalar("SELECT count(*)::bigint FROM movies")

      affected =
        scalar("""
        SELECT count(*)::bigint FROM movies m
        WHERE NOT EXISTS (
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
      WHERE NOT EXISTS (
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
                reason: "no Rotten Tomatoes or Metacritic rating"
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
