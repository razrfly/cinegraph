defmodule Cinegraph.FreshnessTest do
  @moduledoc "#1096 Phase B — touch / stale? / due over the data_refreshes ledger."
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Freshness
  alias Cinegraph.Freshness.{DataRefresh, Policy}
  alias Cinegraph.Repo

  defp get_row(et, id, src),
    do: Repo.get_by(DataRefresh, entity_type: et, entity_id: id, source: src)

  defp insert_row!(attrs) do
    %DataRefresh{}
    |> DataRefresh.changeset(
      Map.merge(%{entity_type: "movie", source: "omdb", status: "ok"}, attrs)
    )
    |> Repo.insert!()
  end

  describe "touch/5" do
    test ":ok stamps fetched_at, resets attempts, sets a future stale_after" do
      {:ok, row} = Freshness.touch("movie", 1, "omdb", :ok, base_date: ~D[2020-01-01])

      assert row.status == "ok"
      assert row.attempt_count == 0
      assert row.fetched_at
      assert DateTime.compare(row.stale_after, DateTime.utc_now()) == :gt
    end

    test "is an idempotent upsert on (entity_type, entity_id, source)" do
      {:ok, _} = Freshness.touch("movie", 2, "omdb", :ok)
      {:ok, _} = Freshness.touch("movie", 2, "omdb", :empty)

      assert Repo.aggregate(
               from(r in DataRefresh, where: r.entity_id == 2 and r.source == "omdb"),
               :count
             ) == 1

      assert get_row("movie", 2, "omdb").status == "empty"
    end

    test ":error bumps attempt_count and backs off" do
      {:ok, r1} = Freshness.touch("movie", 3, "omdb", :error, error_reason: "boom")
      assert r1.status == "error"
      assert r1.attempt_count == 1
      assert r1.error_reason == "boom"
      # ~1h backoff on the first attempt
      assert_in_delta DateTime.diff(r1.stale_after, DateTime.utc_now(), :second), 3600, 60

      {:ok, r2} = Freshness.touch("movie", 3, "omdb", :error)
      assert r2.attempt_count == 2
    end

    test ":error escalates to ineligible after max attempts (never due)" do
      row =
        Enum.reduce(1..Policy.max_error_attempts(), nil, fn _, _ ->
          {:ok, r} = Freshness.touch("movie", 4, "omdb", :error)
          r
        end)

      assert row.status == "ineligible"
      assert is_nil(row.stale_after)
    end

    test ":ineligible nulls stale_after and preserves prior fetched_at" do
      {:ok, _} = Freshness.touch("movie", 5, "omdb", :ok, base_date: ~D[2020-01-01])
      {:ok, row} = Freshness.touch("movie", 5, "omdb", :ineligible)

      assert row.status == "ineligible"
      assert is_nil(row.stale_after)
      assert row.fetched_at, "last successful fetch_at is preserved"
    end
  end

  describe "stale?/3" do
    test "true when no row exists" do
      assert Freshness.stale?("movie", 999, "omdb")
    end

    test "false for a fresh (future stale_after) row" do
      insert_row!(%{
        entity_id: 10,
        fetched_at: ~U[2026-06-09 00:00:00Z],
        stale_after: DateTime.add(DateTime.utc_now(), 86_400, :second)
      })

      refute Freshness.stale?("movie", 10, "omdb")
    end

    test "true for a past-due row, false for an ineligible row" do
      insert_row!(%{
        entity_id: 11,
        fetched_at: ~U[2020-01-01 00:00:00Z],
        stale_after: ~U[2020-02-01 00:00:00Z]
      })

      assert Freshness.stale?("movie", 11, "omdb")

      insert_row!(%{entity_id: 12, status: "ineligible", stale_after: nil})
      refute Freshness.stale?("movie", 12, "omdb")
    end
  end

  describe "due/2" do
    test "returns past-due ids oldest-first, excluding future + ineligible" do
      now = DateTime.utc_now()
      insert_row!(%{entity_id: 20, stale_after: DateTime.add(now, -3600, :second)})
      insert_row!(%{entity_id: 21, stale_after: DateTime.add(now, -7200, :second)})
      insert_row!(%{entity_id: 22, stale_after: DateTime.add(now, 3600, :second)})
      insert_row!(%{entity_id: 23, status: "ineligible", stale_after: nil})

      assert Freshness.due("omdb", 10) == [21, 20]
    end

    test "respects the limit" do
      now = DateTime.utc_now()

      for id <- 30..34,
          do: insert_row!(%{entity_id: id, stale_after: DateTime.add(now, -id, :second)})

      assert length(Freshness.due("omdb", 3)) == 3
    end
  end
end
