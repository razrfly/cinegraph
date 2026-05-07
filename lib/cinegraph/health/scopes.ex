defmodule Cinegraph.Health.Scopes do
  @moduledoc """
  Shared "what counts as our curated catalog?" scope helpers.

  Health drift checks and the Coverage tile measure data quality against
  this scope, not the full bulk-ingest population, so percentages reflect
  signal we can actually act on. See #896.

  The canonical scope is movies with at least one active canonical-list
  source recorded in `movies.canonical_sources` (a JSONB map keyed by
  list slug). The bulk TMDb long-tail has `canonical_sources = '{}'` and
  is excluded.
  """

  import Ecto.Query
  alias Cinegraph.Health.Drift
  alias Cinegraph.Repo

  @cache_ttl :timer.minutes(5)

  @doc """
  Composable Ecto query for canonical movies. Schemaless to match the
  surrounding drift modules; callers compose predicates on top.
  """
  def canonical_movies do
    from m in "movies",
      where: fragment("? != '{}'::jsonb", m.canonical_sources)
  end

  @doc "Total count of canonical movies (cached 5 min)."
  def canonical_movies_count do
    Drift.cached({:scopes, :canonical_movies_count}, @cache_ttl, fn ->
      Repo.replica().one(from(m in canonical_movies(), select: count(m.id))) || 0
    end)
  end

  @doc """
  Count of distinct people with at least one credit on a canonical
  movie (cached 5 min). This is the denominator that drift checks
  scoped to the curated catalog should use.
  """
  def canonical_people_count do
    Drift.cached({:scopes, :canonical_people_count}, @cache_ttl, fn ->
      Repo.replica().one(
        from p in "people",
          join: mc in "movie_credits",
          on: mc.person_id == p.id,
          join: m in "movies",
          on: m.id == mc.movie_id,
          where: fragment("? != '{}'::jsonb", m.canonical_sources),
          select: count(p.id, :distinct)
      ) || 0
    end)
  end
end
