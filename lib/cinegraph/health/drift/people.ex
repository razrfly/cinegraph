defmodule Cinegraph.Health.Drift.People do
  @moduledoc """
  People drift checks — the headliner domain (#722).

  Each public function returns `Cinegraph.Health.Drift.result/5`. All
  reads use `Repo.replica()`. Cached in `:health_cache` (5 min for
  cheap checks, 15 min for `pqs_stale` which is expensive).

  ## Population scoping

  `missing_biography` is scoped to people with at least one credit on a
  canonical-list movie (`movies.canonical_sources != '{}'`) — see #735
  Phase 1.2. Other checks remain scoped to the full `people` table.
  Bulk imports never populate biography for non-canonical cast/crew, so
  reporting against the full 674k-row population produced a meaningless
  100% RED. The canonical scope produces a tier-appropriate signal that
  `mix cinegraph.people.refresh_biographies` can actually drain.
  """

  import Ecto.Query
  alias Cinegraph.Health.Drift
  alias Cinegraph.Repo

  @cache_ttl :timer.minutes(5)
  @pqs_cache_ttl :timer.minutes(15)
  @example_limit 10
  @stale_days 180
  @pqs_metric_type "quality_score"

  @doc """
  Run all 7 checks in parallel. Accepts options (`:limit`) propagated to
  individual checks.
  """
  def all(opts \\ []) do
    Drift.run_all([
      fn -> missing_profile_path(opts) end,
      fn -> missing_biography(opts) end,
      fn -> missing_known_for_department(opts) end,
      fn -> stale_record(opts) end,
      fn -> zero_credits(opts) end,
      fn -> person_required_nomination_missing_person(opts) end,
      fn -> pqs_stale(opts) end
    ])
  end

  @doc "People with `profile_path IS NULL`."
  def missing_profile_path(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:people, :missing_profile_path, limit}, @cache_ttl, fn ->
      total = total_people()
      query = from(p in "people", where: is_nil(p.profile_path))
      affected = count_query(query)
      examples = examples_for(query, "profile_path IS NULL", limit)
      Drift.result(:people, :missing_profile_path, total, affected, examples)
    end)
  end

  @doc """
  People missing `biography`, scoped to people with credits on canonical-list
  movies (#735 Phase 1.2). The full `people` table is dominated by long-tail
  TMDb cast/crew rows whose biographies are never fetched by bulk imports —
  reporting 100% missing against that population is meaningless. The canonical
  scope produces an actionable signal.
  """
  def missing_biography(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:people, :missing_biography, limit}, @cache_ttl, fn ->
      total = total_canonical_people()

      affected =
        Repo.replica().one(
          from p in "people",
            join: mc in "movie_credits",
            on: mc.person_id == p.id,
            join: m in "movies",
            on: m.id == mc.movie_id,
            where:
              (is_nil(p.biography) or p.biography == "") and
                fragment("? != '{}'::jsonb", m.canonical_sources),
            select: count(p.id, :distinct)
        ) || 0

      examples =
        from(p in "people",
          join: mc in "movie_credits",
          on: mc.person_id == p.id,
          join: m in "movies",
          on: m.id == mc.movie_id,
          where:
            (is_nil(p.biography) or p.biography == "") and
              fragment("? != '{}'::jsonb", m.canonical_sources),
          distinct: p.id,
          select: %{id: p.id, name: p.name},
          order_by: [desc: p.id],
          limit: ^limit
        )
        |> Repo.replica().all()
        |> Enum.map(&Map.put(&1, :reason, "biography missing or blank (canonical-list scope)"))

      Drift.result(:people, :missing_biography, total, affected, examples)
    end)
  end

  @doc "People with `known_for_department IS NULL`."
  def missing_known_for_department(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:people, :missing_known_for_department, limit}, @cache_ttl, fn ->
      total = total_people()
      query = from(p in "people", where: is_nil(p.known_for_department))
      affected = count_query(query)
      examples = examples_for(query, "known_for_department IS NULL", limit)
      Drift.result(:people, :missing_known_for_department, total, affected, examples)
    end)
  end

  @doc "People whose row hasn't been touched in `@stale_days` days."
  def stale_record(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:people, :stale_record}, @cache_ttl, fn ->
      total = total_people()
      cutoff = DateTime.utc_now() |> DateTime.add(-@stale_days * 86_400, :second)

      affected =
        Repo.replica().one(
          from(p in "people",
            where: p.updated_at < ^cutoff,
            select: count(p.id)
          )
        ) || 0

      examples =
        from(p in "people",
          where: p.updated_at < ^cutoff,
          select: %{id: p.id, name: p.name, updated_at: p.updated_at},
          order_by: [asc: p.updated_at],
          limit: ^limit
        )
        |> Repo.replica().all()
        |> Enum.map(
          &Map.put(&1, :reason, "updated_at < #{Date.to_iso8601(DateTime.to_date(cutoff))}")
        )

      Drift.result(:people, :stale_record, total, affected, examples)
    end)
  end

  @doc "People with zero rows in `movie_credits` (likely bad imports / inference leftovers)."
  def zero_credits(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:people, :zero_credits}, @cache_ttl, fn ->
      total = total_people()

      sql_count = """
      SELECT count(*)::bigint
      FROM people p
      WHERE NOT EXISTS (SELECT 1 FROM movie_credits mc WHERE mc.person_id = p.id)
      """

      affected =
        case Ecto.Adapters.SQL.query!(Repo.replica(), sql_count, []) do
          %{rows: [[count]]} -> count
          _ -> 0
        end

      sql_examples = """
      SELECT p.id, p.name
      FROM people p
      WHERE NOT EXISTS (SELECT 1 FROM movie_credits mc WHERE mc.person_id = p.id)
      ORDER BY p.id DESC
      LIMIT $1
      """

      examples =
        case Ecto.Adapters.SQL.query!(Repo.replica(), sql_examples, [limit]) do
          %{rows: rows} ->
            Enum.map(rows, fn [id, name] ->
              %{id: id, name: name, reason: "no rows in movie_credits"}
            end)

          _ ->
            []
        end

      Drift.result(:people, :zero_credits, total, affected, examples)
    end)
  end

  @doc """
  `festival_nominations` rows where the linked category has `tracks_person = true`
  but `nomination.person_id IS NULL`. Indicates an upstream pipeline bug.
  """
  def person_required_nomination_missing_person(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:people, :person_required_nomination_missing_person}, @cache_ttl, fn ->
      total =
        Repo.replica().one(
          from(n in "festival_nominations",
            join: c in "festival_categories",
            on: n.category_id == c.id,
            where: c.tracks_person == true,
            select: count(n.id)
          )
        ) || 0

      affected =
        Repo.replica().one(
          from(n in "festival_nominations",
            join: c in "festival_categories",
            on: n.category_id == c.id,
            where: c.tracks_person == true and is_nil(n.person_id),
            select: count(n.id)
          )
        ) || 0

      examples =
        from(n in "festival_nominations",
          join: c in "festival_categories",
          on: n.category_id == c.id,
          where: c.tracks_person == true and is_nil(n.person_id),
          select: %{id: n.id, category: c.name, ceremony_id: n.ceremony_id, movie_id: n.movie_id},
          limit: ^limit
        )
        |> Repo.replica().all()
        |> Enum.map(&Map.put(&1, :reason, "person-required category, person_id IS NULL"))

      Drift.result(
        :people,
        :person_required_nomination_missing_person,
        total,
        affected,
        examples
      )
    end)
  end

  @doc """
  PQS staleness: people with credits whose latest `person_metrics.calculated_at`
  for the PQS metric is older than the most recent `movie_credits.updated_at`,
  or who have no PQS row at all.

  Restricted to people with ≥1 credit (zero-credit people are surfaced by
  `zero_credits/0` instead).
  """
  def pqs_stale(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:people, :pqs_stale}, @pqs_cache_ttl, fn ->
      total =
        scalar("""
        SELECT count(DISTINCT p.id)::bigint
        FROM people p
        WHERE EXISTS (SELECT 1 FROM movie_credits mc WHERE mc.person_id = p.id)
        """)

      sql_count = """
      WITH credit_recency AS (
        SELECT mc.person_id, MAX(mc.updated_at) AS last_credit_at
        FROM movie_credits mc
        GROUP BY mc.person_id
      ),
      pqs_recency AS (
        SELECT pm.person_id, MAX(pm.calculated_at) AS last_pqs_at
        FROM person_metrics pm
        WHERE pm.metric_type = $1
        GROUP BY pm.person_id
      )
      SELECT count(*)::bigint
      FROM credit_recency cr
      LEFT JOIN pqs_recency pr ON pr.person_id = cr.person_id
      WHERE pr.last_pqs_at IS NULL OR pr.last_pqs_at < cr.last_credit_at
      """

      affected =
        case Ecto.Adapters.SQL.query!(Repo.replica(), sql_count, [@pqs_metric_type]) do
          %{rows: [[count]]} -> count
          _ -> 0
        end

      sql_examples = """
      WITH credit_recency AS (
        SELECT mc.person_id, MAX(mc.updated_at) AS last_credit_at
        FROM movie_credits mc
        GROUP BY mc.person_id
      ),
      pqs_recency AS (
        SELECT pm.person_id, MAX(pm.calculated_at) AS last_pqs_at
        FROM person_metrics pm
        WHERE pm.metric_type = $1
        GROUP BY pm.person_id
      )
      SELECT p.id, p.name, cr.last_credit_at, pr.last_pqs_at
      FROM credit_recency cr
      JOIN people p ON p.id = cr.person_id
      LEFT JOIN pqs_recency pr ON pr.person_id = cr.person_id
      WHERE pr.last_pqs_at IS NULL OR pr.last_pqs_at < cr.last_credit_at
      ORDER BY cr.last_credit_at DESC
      LIMIT $2
      """

      examples =
        case Ecto.Adapters.SQL.query!(Repo.replica(), sql_examples, [
               @pqs_metric_type,
               limit
             ]) do
          %{rows: rows} ->
            Enum.map(rows, fn [id, name, last_credit, last_pqs] ->
              reason =
                if last_pqs == nil,
                  do: "no PQS row",
                  else: "PQS calculated_at older than last credit update"

              %{
                id: id,
                name: name,
                last_credit_at: last_credit,
                last_pqs_at: last_pqs,
                reason: reason
              }
            end)

          _ ->
            []
        end

      Drift.result(:people, :pqs_stale, total, affected, examples)
    end)
  end

  # ===== private =====

  defp total_people do
    Drift.cached({:people, :total}, @cache_ttl, fn ->
      Repo.replica().one(from(p in "people", select: count(p.id))) || 0
    end)
  end

  # Canonical-list-scoped denominator: people with at least one credit on a
  # movie that appears in any active canonical list (e.g. 1001 Movies, IMDb
  # Top 250). Used by checks whose population should not be the full 674k-row
  # `people` table — see #735 Phase 1.2.
  defp total_canonical_people do
    Drift.cached({:people, :total_canonical}, @cache_ttl, fn ->
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

  # Counts rows matched by a pre-built Ecto query (parameterized — no
  # string interpolation of predicates). Counts directly against the source
  # query's binding instead of wrapping in `subquery/1`, which would require
  # the source to declare its own `:select` (schemaless `from(p in "people"...)`
  # queries don't).
  defp count_query(query) do
    query |> select([p], count(p.id)) |> Repo.replica().one() || 0
  end

  # Selects up to `limit` examples from a pre-built Ecto query.
  defp examples_for(query, reason, limit) do
    from(p in query, select: %{id: p.id, name: p.name}, order_by: [desc: p.id], limit: ^limit)
    |> Repo.replica().all()
    |> Enum.map(&Map.put(&1, :reason, reason))
  end

  defp scalar(sql, params \\ []) do
    case Ecto.Adapters.SQL.query!(Repo.replica(), sql, params) do
      %{rows: [[value]]} -> value
      _ -> 0
    end
  end
end
