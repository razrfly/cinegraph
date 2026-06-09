defmodule Cinegraph.Freshness.ReportTest do
  @moduledoc "#1096 Phase B — the per-source freshness rollup."
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Freshness.{DataRefresh, Policy, Report}
  alias Cinegraph.Repo

  defp insert_row!(attrs) do
    %DataRefresh{}
    |> DataRefresh.changeset(
      Map.merge(%{entity_type: "movie", source: "omdb", status: "ok"}, attrs)
    )
    |> Repo.insert!()
  end

  defp row_for(source), do: Enum.find(Report.report().sources, &(&1.source == source))

  test "every registered source appears even with zero ledger rows" do
    sources = Report.report().sources |> Enum.map(& &1.source)

    expected_sources =
      Policy.registry()
      |> Enum.flat_map(fn {_entity_type, srcs} -> Map.keys(srcs) end)
      |> Enum.uniq()

    for s <- expected_sources do
      assert s in sources, "missing source row: #{s}"
    end
  end

  test "partitions a source into fresh / stale / never / ineligible / errors" do
    now = DateTime.utc_now()
    # fresh
    insert_row!(%{entity_id: 1, fetched_at: now, stale_after: DateTime.add(now, 86_400, :second)})
    # stale
    insert_row!(%{
      entity_id: 2,
      fetched_at: ~U[2020-01-01 00:00:00Z],
      stale_after: ~U[2020-02-01 00:00:00Z]
    })

    # never fetched (pending)
    insert_row!(%{
      entity_id: 3,
      status: "pending",
      fetched_at: nil,
      stale_after: DateTime.add(now, 86_400, :second)
    })

    # ineligible
    insert_row!(%{entity_id: 4, status: "ineligible", stale_after: nil})
    # error
    insert_row!(%{entity_id: 5, status: "error", stale_after: DateTime.add(now, 3600, :second)})

    row = row_for("omdb")
    assert row.tracked == 5
    assert row.fresh == 1
    assert row.stale == 1
    assert row.never == 1
    assert row.ineligible == 1
    assert row.errors == 1
    assert row.entity_type == "movie"
  end
end
