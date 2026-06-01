defmodule Cinegraph.Database.MonitoringTest do
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Database.Monitoring

  describe "evaluate/5 thresholds (pure)" do
    test ":ok when usage is low and no long queries" do
      r = Monitoring.evaluate(50, 300, [%{datname: "x", count: 50}], [], 300)
      assert r.status == :ok
      assert r.usage_pct == 17
      assert r.warnings == []
    end

    test ":warn above 70%" do
      r = Monitoring.evaluate(220, 300, [], [], 300)
      assert r.status == :warn
      assert [msg] = r.warnings
      assert msg =~ "70%"
    end

    test ":crit above 90% (and includes both crit + warn messages)" do
      r = Monitoring.evaluate(280, 300, [], [], 300)
      assert r.status == :crit
      assert Enum.any?(r.warnings, &(&1 =~ "90% ceiling"))
    end

    test "long-running query escalates to at least :warn" do
      r = Monitoring.evaluate(50, 300, [], [%{pid: 1}, %{pid: 2}], 300)
      assert r.status == :warn
      assert Enum.any?(r.warnings, &(&1 =~ "2 query(s) active > 300s"))
    end

    test "guards against max_connections == 0" do
      assert Monitoring.evaluate(10, 0, [], [], 300).usage_pct == 0
    end
  end

  describe "snapshot/0 (live pg_stat_activity)" do
    test "returns the documented shape" do
      s = Monitoring.snapshot()
      assert is_integer(s.total_backends)
      assert is_integer(s.max_connections) and s.max_connections > 0
      assert is_integer(s.usage_pct)
      assert is_list(s.by_database)
      assert is_list(s.long_running)
      assert s.status in [:ok, :warn, :crit]
      assert is_list(s.warnings)
    end
  end
end
