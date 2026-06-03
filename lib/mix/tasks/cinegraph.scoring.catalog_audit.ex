defmodule Mix.Tasks.Cinegraph.Scoring.CatalogAudit do
  @moduledoc """
  Live Layer-0 reconciliation audit (#1036 Session 2.5).

  Reconciles the FULL `metric_definitions` catalog against the FULL `metric_values_view`
  on real data and classifies every code:

    * matched        — emitted AND catalogued (the happy path)
    * dynamic-family — emitted, uncatalogued, but a valid family member
                       (festival `{abbr}_win/_nom` ↔ festival_organizations.abbreviation,
                        canonical key ↔ movie_lists.source_key)
    * orphan         — emitted, uncatalogued, NOT a family member  ← failure
    * unreachable    — catalogued raw+available, but its source_table has no view branch ← failure
    * data-absent    — catalogued raw+available, reachable, simply has no rows yet (informational)

  Exits non-zero only on `orphan` or `unreachable` — the two states that mean the substrate
  is internally inconsistent. `data-absent` is expected (e.g. lists not yet imported in an env).

  Unlike the fixture-backed `catalog_contract_test`, this runs against whatever is actually in
  the database, so it is the check that catches a live drift. The full-view scan is heavy
  (seconds); this is an ops/CI tool, not a hot path. Runnable in prod via `bin/cinegraph eval`
  or `Cinegraph.ProdRpc`.

      mix cinegraph.scoring.catalog_audit
  """
  use Mix.Task

  alias Cinegraph.Metrics
  alias Cinegraph.Repo

  @shortdoc "Reconcile the metric catalog against the live normalized feed"

  # Source tables the view has a branch for. A catalogued raw code whose source_table is
  # not here is structurally unreachable (no UNION branch can ever emit it).
  @reachable_source_tables ~w(
    external_metrics festival_nominations canonical_sources person_metrics
    movies movie_genres movie_keywords movie_production_countries movie_videos
  )

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    emitted = query_set("SELECT DISTINCT metric_code FROM metric_values_view")
    # `active: true` is explicit: only ACTIVE definitions count as "catalogued" — an emitted
    # code backed solely by a deactivated row must be flagged, not silently matched.
    active = Metrics.list_metric_definitions(active: true)
    active_codes = active |> Enum.map(& &1.code) |> MapSet.new()

    raw_available = Metrics.list_metric_definitions(only_available: true, kind: "raw")

    families = %{
      abbrs: query_set("SELECT DISTINCT LOWER(abbreviation) FROM festival_organizations"),
      list_keys: query_set("SELECT source_key FROM movie_lists")
    }

    # Forward: emitted but uncatalogued → dynamic-family or orphan.
    uncatalogued = MapSet.difference(emitted, active_codes)
    {family, orphans} = Enum.split_with(uncatalogued, &dynamic_family?(&1, families))

    # Backward: catalogued raw+available but not emitted → unreachable or data-absent.
    not_emitted = Enum.reject(raw_available, &MapSet.member?(emitted, &1.code))

    {unreachable, data_absent} =
      Enum.split_with(not_emitted, &(&1.source_table not in @reachable_source_tables))

    matched = MapSet.intersection(emitted, active_codes)

    report(
      matched: MapSet.size(matched),
      family: Enum.sort(family),
      orphans: Enum.sort(orphans),
      unreachable: Enum.map(unreachable, &"#{&1.code} (#{&1.source_table})") |> Enum.sort(),
      data_absent: Enum.map(data_absent, & &1.code) |> Enum.sort()
    )

    if orphans == [] and unreachable == [] do
      Mix.shell().info(
        "\nAUDIT OK — every emitted code is catalogued or a known family; every catalogued raw code is reachable."
      )
    else
      Mix.raise(
        "AUDIT FAILED — #{length(orphans)} orphan(s), #{length(unreachable)} unreachable code(s). " <>
          "Catalogue/repoint the orphans or add a view branch for the unreachable codes."
      )
    end
  end

  defp report(opts) do
    Mix.shell().info("Layer-0 catalog ↔ feed reconciliation\n")
    Mix.shell().info("matched (emitted + catalogued): #{opts[:matched]}")

    Mix.shell().info(
      "dynamic-family (emitted, rule-valid): #{length(opts[:family])} #{preview(opts[:family])}"
    )

    Mix.shell().info(
      "data-absent (catalogued, reachable, no rows): #{length(opts[:data_absent])} #{preview(opts[:data_absent])}"
    )

    Mix.shell().info(
      "orphan (emitted, uncatalogued, no family): #{length(opts[:orphans])} #{inspect(opts[:orphans])}"
    )

    Mix.shell().info(
      "unreachable (catalogued, no view branch): #{length(opts[:unreachable])} #{inspect(opts[:unreachable])}"
    )
  end

  defp preview([]), do: ""
  defp preview(list) when length(list) <= 8, do: inspect(list)
  defp preview(list), do: inspect(Enum.take(list, 8) ++ ["…"])

  defp query_set(sql) do
    %{rows: rows} = Repo.query!(sql, [])
    rows |> List.flatten() |> MapSet.new()
  end

  defp dynamic_family?(code, %{abbrs: abbrs, list_keys: list_keys}) do
    MapSet.member?(list_keys, code) or
      (Regex.match?(~r/^[a-z0-9]+_(win|nom)$/, code) and
         MapSet.member?(abbrs, Regex.replace(~r/_(win|nom)$/, code, "")))
  end
end
