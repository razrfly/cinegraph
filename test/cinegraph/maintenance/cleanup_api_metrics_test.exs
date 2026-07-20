defmodule Cinegraph.Maintenance.CleanupApiMetricsTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Maintenance.CleanupApiMetrics
  alias Cinegraph.Metrics.ApiLookupMetric
  alias Cinegraph.Repo

  # api_lookup_metrics uses naive_datetime timestamps; insert_all lets us set an
  # explicit inserted_at (no casting) to straddle the retention cutoff.
  defp insert_metric!(attrs) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    row =
      Map.merge(
        %{
          source: "omdb",
          operation: "search_movie",
          target_identifier: "tt0000001",
          success: true,
          metadata: %{},
          inserted_at: now,
          updated_at: now
        },
        Map.new(attrs)
      )

    {1, [%{id: id}]} = Repo.insert_all(ApiLookupMetric, [row], returning: [:id])
    id
  end

  defp days_ago(days) do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(-days * 86_400, :second)
    |> NaiveDateTime.truncate(:second)
  end

  defp exists?(id), do: Repo.exists?(from m in ApiLookupMetric, where: m.id == ^id)

  # NOTE: ApiTracker writes metrics via Task.start (fire-and-forget). In the shared
  # sandbox those async writes from other tests can land in this test's connection,
  # so assertions scope to the specific rows we insert rather than absolute counts.
  describe "run/1" do
    test "deletes rows older than retention but preserves the latest import_state per key" do
      old_regular = insert_metric!(%{operation: "search_movie", inserted_at: days_ago(100)})

      old_import_state =
        insert_metric!(%{
          operation: "import_state",
          target_identifier: "last_page",
          success: true,
          inserted_at: days_ago(100)
        })

      recent = insert_metric!(%{operation: "search_movie", inserted_at: days_ago(1)})

      assert {:ok, %{retention_days: 90, dry_run: false, deleted: deleted}} =
               CleanupApiMetrics.run([])

      assert deleted >= 1
      refute exists?(old_regular)
      assert exists?(old_import_state)
      assert exists?(recent)
    end

    test "dry_run reports a count without deleting anything we inserted" do
      old_a = insert_metric!(%{operation: "search_movie", inserted_at: days_ago(100)})
      old_b = insert_metric!(%{operation: "search_movie", inserted_at: days_ago(120)})

      assert {:ok, %{retention_days: 90, dry_run: true, deleted: count}} =
               CleanupApiMetrics.run(dry_run: true)

      assert count >= 2
      assert exists?(old_a)
      assert exists?(old_b)
    end

    test "honors a custom retention_days" do
      old = insert_metric!(%{operation: "search_movie", inserted_at: days_ago(20)})
      recent = insert_metric!(%{operation: "search_movie", inserted_at: days_ago(1)})

      # 10-day retention deletes the 20-day-old row but keeps the 1-day-old one.
      assert {:ok, %{retention_days: 10, dry_run: false, deleted: deleted}} =
               CleanupApiMetrics.run(retention_days: 10)

      assert deleted >= 1
      refute exists?(old)
      assert exists?(recent)
    end

    test "raises on invalid retention_days" do
      assert_raise ArgumentError, fn -> CleanupApiMetrics.run(retention_days: 0) end
      assert_raise ArgumentError, fn -> CleanupApiMetrics.run(retention_days: -5) end
    end
  end
end
