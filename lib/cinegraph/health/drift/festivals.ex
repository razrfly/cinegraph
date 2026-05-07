defmodule Cinegraph.Health.Drift.Festivals do
  @moduledoc """
  Festivals drift checks (#722).
  """

  alias Cinegraph.Health.Drift
  alias Cinegraph.Repo

  @cache_ttl :timer.minutes(5)
  @example_limit 10
  @floor_factor 0.5

  @doc """
  Run all 4 festivals checks in parallel. Accepts `:limit` (examples cap)
  and `:org` (organization slug filter — currently passed through but
  scoping logic per check is best-effort).
  """
  def all(opts \\ []) do
    Drift.run_all([
      fn -> nominations_below_floor(opts) end,
      fn -> missing_categories(opts) end,
      fn -> nominations_missing_movie(opts) end,
      fn -> person_required_missing_person(opts) end
    ])
  end

  @doc """
  Ceremonies whose nomination count is below `@floor_factor` × median for
  their organization (i.e., looks anomalously empty). Optionally scoped
  to a single organization via `:org` (slug or numeric id).
  """
  def nominations_below_floor(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)
    org_filter = build_org_filter(opts)

    Drift.cached({:festivals, :nominations_below_floor, org_filter, limit}, @cache_ttl, fn ->
      {org_clause, org_params} = sql_org_clause(org_filter, "c")

      sql = """
      WITH per_ceremony AS (
        SELECT c.id, c.organization_id, c.year, count(n.id) AS noms
        FROM festival_ceremonies c
        LEFT JOIN festival_nominations n ON n.ceremony_id = c.id
        #{org_clause}
        GROUP BY c.id, c.organization_id, c.year
      ),
      org_median AS (
        SELECT organization_id,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY noms) AS med
        FROM per_ceremony
        GROUP BY organization_id
      )
      SELECT pc.id, pc.organization_id, pc.year, pc.noms, om.med
      FROM per_ceremony pc
      JOIN org_median om ON om.organization_id = pc.organization_id
      WHERE pc.noms < (om.med * $#{length(org_params) + 1})
        AND om.med > 0
      ORDER BY pc.year DESC, pc.organization_id
      """

      rows =
        case Ecto.Adapters.SQL.query!(Repo.replica(), sql, org_params ++ [@floor_factor]) do
          %{rows: rows} -> rows
          _ -> []
        end

      total =
        case org_filter do
          nil ->
            scalar("SELECT count(*)::bigint FROM festival_ceremonies")

          org_id ->
            scalar(
              "SELECT count(*)::bigint FROM festival_ceremonies WHERE organization_id = $1",
              [org_id]
            )
        end

      affected = length(rows)

      examples =
        rows
        |> Enum.take(limit)
        |> Enum.map(fn [id, org_id, year, noms, med] ->
          %{
            id: id,
            organization_id: org_id,
            year: year,
            nominations: noms,
            org_median: med && med_to_float(med),
            reason: "noms #{noms} < #{@floor_factor} × org median (#{med && med_to_string(med)})"
          }
        end)

      Drift.result(:festivals, :nominations_below_floor, total, affected, examples)
    end)
  end

  @doc "Ceremonies that don't have any categories defined for their organization."
  def missing_categories(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:festivals, :missing_categories}, @cache_ttl, fn ->
      sql = """
      SELECT c.id, c.organization_id, c.year
      FROM festival_ceremonies c
      WHERE NOT EXISTS (
        SELECT 1 FROM festival_categories cat
        WHERE cat.organization_id = c.organization_id
      )
      ORDER BY c.year DESC
      LIMIT $1
      """

      examples =
        case Ecto.Adapters.SQL.query!(Repo.replica(), sql, [limit]) do
          %{rows: rows} ->
            Enum.map(rows, fn [id, org_id, year] ->
              %{
                id: id,
                organization_id: org_id,
                year: year,
                reason: "no festival_categories rows for organization"
              }
            end)

          _ ->
            []
        end

      affected =
        scalar("""
        SELECT count(*)::bigint
        FROM festival_ceremonies c
        WHERE NOT EXISTS (
          SELECT 1 FROM festival_categories cat
          WHERE cat.organization_id = c.organization_id
        )
        """)

      total = scalar("SELECT count(*)::bigint FROM festival_ceremonies")

      Drift.result(:festivals, :missing_categories, total, affected, examples)
    end)
  end

  @doc """
  CORRUPTION CHECK: `festival_nominations` rows with `movie_id IS NULL`.
  Schema constraint forbids this — should always be zero. Any non-zero is
  a sign of constraint bypass.
  """
  def nominations_missing_movie(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:festivals, :nominations_missing_movie}, @cache_ttl, fn ->
      total = scalar("SELECT count(*)::bigint FROM festival_nominations")

      affected =
        scalar("SELECT count(*)::bigint FROM festival_nominations WHERE movie_id IS NULL")

      examples =
        case Ecto.Adapters.SQL.query!(
               Repo.replica(),
               "SELECT id, ceremony_id, category_id, person_id FROM festival_nominations WHERE movie_id IS NULL LIMIT $1",
               [limit]
             ) do
          %{rows: rows} ->
            Enum.map(rows, fn [id, ceremony_id, category_id, person_id] ->
              %{
                id: id,
                ceremony_id: ceremony_id,
                category_id: category_id,
                person_id: person_id,
                reason: "movie_id IS NULL (corruption — constraint forbids this)"
              }
            end)

          _ ->
            []
        end

      Drift.result(:festivals, :nominations_missing_movie, total, affected, examples)
    end)
  end

  @doc """
  Same data as `Drift.People.person_required_nomination_missing_person/0` —
  surfaces it under the festivals domain too. Delegates to the People module
  so we don't duplicate SQL.
  """
  def person_required_missing_person(opts \\ []) do
    result = Cinegraph.Health.Drift.People.person_required_nomination_missing_person(opts)
    %{result | domain: :festivals, check: :person_required_missing_person}
  end

  defp scalar(sql, params \\ []) do
    case Ecto.Adapters.SQL.query!(Repo.replica(), sql, params) do
      %{rows: [[v]]} -> v
      _ -> 0
    end
  end

  # Resolve `:org` opt to a numeric organization_id. Accepts an integer or
  # a slug string (looked up against `festival_organizations.abbreviation`).
  defp build_org_filter(opts) do
    case Keyword.get(opts, :org) do
      nil ->
        nil

      id when is_integer(id) ->
        id

      slug when is_binary(slug) ->
        sql = "SELECT id FROM festival_organizations WHERE abbreviation = $1 LIMIT 1"

        case Ecto.Adapters.SQL.query!(Repo.replica(), sql, [slug]) do
          %{rows: [[id]]} -> id
          _ -> nil
        end
    end
  end

  defp sql_org_clause(nil, _alias_), do: {"", []}

  defp sql_org_clause(org_id, alias_),
    do: {"WHERE #{alias_}.organization_id = $1", [org_id]}

  # `percentile_cont` returns Decimal when its input is numeric/decimal, but
  # float when its input is a bigint (our case — count(id)). Tolerate both.
  defp med_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp med_to_float(n) when is_number(n), do: n / 1

  defp med_to_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp med_to_string(n) when is_number(n), do: to_string(n)
end
