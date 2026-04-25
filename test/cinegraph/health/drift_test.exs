defmodule Cinegraph.Health.DriftTest do
  # Pure helpers — no DB.
  use ExUnit.Case, async: true

  alias Cinegraph.Health.Drift

  describe "result/6" do
    test "fills in defaults and computes pct" do
      r = Drift.result(:people, :missing_x, 1000, 250)
      assert r.domain == :people
      assert r.check == :missing_x
      assert r.status == :unknown
      assert r.total_population == 1000
      assert r.affected_count == 250
      assert r.affected_pct == 25.0
      assert r.examples == []
      assert r.blocked_reason == nil
      assert %DateTime{} = r.generated_at
    end

    test "0 total → 0.0 pct (no division-by-zero)" do
      r = Drift.result(:people, :x, 0, 0)
      assert r.affected_pct == 0.0
    end

    test "rounds pct to 2 decimal places" do
      r = Drift.result(:movies, :x, 7, 1)
      assert r.affected_pct == 14.29
    end

    test "captures blocked_reason and examples" do
      r = Drift.result(:people, :x, 100, 5, [%{id: 1}], "no replica")
      assert r.blocked_reason == "no replica"
      assert r.examples == [%{id: 1}]
    end
  end

  describe "run_all/2" do
    test "runs functions in parallel and returns results in input order" do
      f1 = fn -> Drift.result(:people, :a, 100, 10) end
      f2 = fn -> Drift.result(:people, :b, 200, 20) end
      f3 = fn -> Drift.result(:people, :c, 300, 30) end

      results = Drift.run_all([f1, f2, f3])
      assert length(results) == 3
      assert Enum.map(results, & &1.check) == [:a, :b, :c]
    end

    test "crashed task yields a result-shaped error with blocked_reason" do
      f1 = fn -> Drift.result(:people, :a, 100, 10) end
      f2 = fn -> raise "boom" end

      results = Drift.run_all([f1, f2], timeout: 5_000)
      assert length(results) == 2

      [_ok, err] = results
      assert err.blocked_reason =~ "task raised"
      assert err.blocked_reason =~ "boom"
    end
  end

  describe "pct/2" do
    test "0 / 0 → 0.0" do
      assert Drift.pct(0, 0) == 0.0
    end

    test "rounds to 2 decimal places" do
      assert Drift.pct(1, 3) == 33.33
      assert Drift.pct(2, 3) == 66.67
    end
  end
end
