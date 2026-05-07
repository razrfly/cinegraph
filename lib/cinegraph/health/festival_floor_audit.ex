defmodule Cinegraph.Health.FestivalFloorAudit do
  @moduledoc """
  Per-organization breakdown of ceremonies below the
  `nominations_below_floor` threshold (#896 Phase 2.1).

  Wraps `Cinegraph.Health.Drift.Festivals.nominations_below_floor/1` —
  no new SQL. Adds organization-name resolution and grouping so the CLI
  audit (`mix cinegraph.audit.festival_floor`) and the admin UI section
  on `/admin/health` can show actionable lists like
  "AMPAS · 1929 · noms=8 / median=24 (-66.7%)".
  """

  import Ecto.Query

  alias Cinegraph.Health.Drift.Festivals
  alias Cinegraph.Repo

  @audit_limit 10_000

  @doc """
  Returns a list of organizations with their below-floor ceremonies,
  sorted by `below_floor_count` descending (worst offenders first).

      [%{
        organization: %{id: 1, name: "Academy Awards", abbreviation: "AMPAS"},
        ceremonies: [
          %{id: 42, year: 1929, nominations: 8, org_median: 24.0, delta_pct: -66.7, ...},
          ...
        ],
        median: 24.0,
        below_floor_count: 7
      }, ...]

  ## Options

    * `:org` — scope to a single organization (slug/abbreviation or numeric id),
      forwarded to `Drift.Festivals.nominations_below_floor/1`.
  """
  def audit(opts \\ []) do
    drift_opts =
      opts
      |> Keyword.take([:org])
      |> Keyword.put(:limit, @audit_limit)

    drift = Festivals.nominations_below_floor(drift_opts)
    org_ids = drift.examples |> Enum.map(& &1.organization_id) |> Enum.uniq()
    orgs_by_id = load_orgs(org_ids)

    drift.examples
    |> Enum.group_by(& &1.organization_id)
    |> Enum.map(fn {org_id, ceremonies} ->
      decorated = Enum.map(ceremonies, &decorate_ceremony/1)
      median = decorated |> List.first() |> Map.get(:org_median)

      %{
        organization: orgs_by_id[org_id] || %{id: org_id, name: "Unknown", abbreviation: nil},
        ceremonies: Enum.sort_by(decorated, & &1.year, :desc),
        median: median,
        below_floor_count: length(decorated)
      }
    end)
    |> Enum.sort_by(& &1.below_floor_count, :desc)
  end

  defp decorate_ceremony(%{nominations: n, org_median: m} = c)
       when is_number(m) and m > 0 do
    Map.put(c, :delta_pct, Float.round((n - m) / m * 100, 1))
  end

  defp decorate_ceremony(c), do: Map.put(c, :delta_pct, nil)

  defp load_orgs([]), do: %{}

  defp load_orgs(ids) do
    from(o in "festival_organizations",
      where: o.id in ^ids,
      select: %{id: o.id, name: o.name, abbreviation: o.abbreviation}
    )
    |> Repo.replica().all()
    |> Map.new(&{&1.id, &1})
  end
end
