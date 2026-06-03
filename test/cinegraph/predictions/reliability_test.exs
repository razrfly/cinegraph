defmodule Cinegraph.Predictions.ReliabilityTest do
  use ExUnit.Case, async: true

  alias Cinegraph.Predictions.Reliability, as: R

  # An otherwise-HIGH model: recall 0.8 on 50 positives (Wilson lower ≈ 0.67 ≥ 0.50 band),
  # beats a 0.0 popularity baseline, Platt-calibrated, fresh frontier, pre-registered, no
  # failing threshold. Each cap test flips exactly one input and asserts the grade drops.
  defp high_ir(overrides \\ %{}) do
    Map.merge(
      %{
        "recall_at_k" => 0.8,
        "n_positives" => 50,
        "n_evaluated" => 100_000,
        "baselines" => %{"popularity" => 0.0}
      },
      overrides
    )
  end

  defp platt, do: %{"method" => "platt", "a" => 5.0, "b" => -2.0}
  defp identity, do: %{"method" => "identity", "reason" => "insufficient positives"}

  defp fresh_frontier(overrides \\ %{}) do
    Map.merge(%{fresh?: true, cutoff_source: :edition, warnings: []}, overrides)
  end

  defp high_ctx(overrides \\ %{}) do
    Map.merge(
      %{is_stale: false, frontier: fresh_frontier(), threshold: nil, prereg?: true},
      overrides
    )
  end

  defp grade(ir \\ high_ir(), cal \\ platt(), ctx \\ high_ctx()), do: R.score(ir, cal, ctx).grade

  describe "Wilson lower bound (headline is conservative)" do
    test "headline is the lower bound, strictly below the point estimate" do
      r = R.score(high_ir(%{"recall_at_k" => 0.3636, "n_positives" => 22}), platt(), high_ctx())
      {lo, hi} = r.ci
      # point estimate is 36.36%; Wilson lower ≈ 21%
      assert lo < 36.36
      assert lo > 0.0
      assert hi > lo
      assert r.headline_pct == lo
    end

    test "recall = 0.0 gives a 0.0 lower bound, no NaN" do
      r = R.score(high_ir(%{"recall_at_k" => 0.0, "n_positives" => 15}), platt(), high_ctx())
      {lo, _hi} = r.ci
      assert lo == 0.0
    end

    test "recall = 1.0 gives 0 < lower < 100 (never overclaims certainty)" do
      r = R.score(high_ir(%{"recall_at_k" => 1.0, "n_positives" => 10}), platt(), high_ctx())
      {lo, hi} = r.ci
      assert lo > 0.0 and lo < 100.0
      assert hi <= 100.0
    end
  end

  describe "baseline sanity" do
    test "the otherwise-high fixture grades :high" do
      assert grade() == :high
      assert R.score(high_ir(), platt(), high_ctx()).reasons == []
    end
  end

  describe "grades on objective signal (honesty rule #1051)" do
    test "a circular model (high full recall, low objective) is graded on objective, not full" do
      r = R.score(high_ir(%{"objective_recall_at_k" => 0.1}), platt(), high_ctx())
      # full recall would band :high; graded on the 0.1 objective signal it drops.
      assert r.grade == :low
      assert r.full_recall == 0.8
      assert r.objective_recall == 0.1
      assert r.circularity == Float.round((0.8 - 0.1) / 0.8, 4)
      assert r.headline_pct < 20.0
      assert Enum.any?(r.reasons, &(&1 =~ "canon-overlap circularity"))
    end

    test "falls back to full recall when objective is absent (pre-#1051 models)" do
      r = R.score(high_ir(), platt(), high_ctx())
      assert r.grade == :high
      assert r.objective_recall == nil
      assert r.circularity == nil
    end

    test "objective == full → no circularity penalty, grade unchanged" do
      r = R.score(high_ir(%{"objective_recall_at_k" => 0.8}), platt(), high_ctx())
      assert r.grade == :high
      assert r.circularity == nil
      refute Enum.any?(r.reasons, &(&1 =~ "circularity"))
    end
  end

  describe "caps fire in isolation" do
    test "n_positives < 10 → :insufficient with em-dash headline" do
      r = R.score(high_ir(%{"n_positives" => 5}), platt(), high_ctx())
      assert r.grade == :insufficient
      assert r.headline_pct == "—"
      assert Enum.any?(r.reasons, &(&1 =~ "holdout positives"))
    end

    test "lift gate fail (below margin over baseline) → :insufficient" do
      r = R.score(high_ir(%{"recall_at_k" => 0.04, "n_positives" => 30}), platt(), high_ctx())
      assert r.grade == :insufficient
      assert Enum.any?(r.reasons, &(&1 =~ "margin"))
    end

    test "lift gate fail by RATIO (clears margin but barely beats a big baseline) names the ratio" do
      # recall 0.60 vs popularity 0.50: margin 0.10 ≥ 0.05 (passes) but ratio 1.2× < 1.5× (fails).
      ir =
        high_ir(%{
          "recall_at_k" => 0.60,
          "n_positives" => 50,
          "baselines" => %{"popularity" => 0.50}
        })

      r = R.score(ir, platt(), high_ctx())
      assert r.grade == :insufficient

      assert Enum.any?(r.reasons, &(&1 =~ "ratio")),
             "expected a ratio reason, got #{inspect(r.reasons)}"
    end

    test "identity calibration → cap :low" do
      r = R.score(high_ir(), identity(), high_ctx())
      assert r.grade == :low
      # band_grade records the pre-cap grade so the UI can show "capped from HIGH"
      assert r.band_grade == :high
      assert Enum.any?(r.reasons, &(&1 =~ "identity"))
    end

    test "stale frontier → cap :low" do
      r = R.score(high_ir(), platt(), high_ctx(%{frontier: fresh_frontier(%{fresh?: false})}))
      assert r.grade == :low
      assert Enum.any?(r.reasons, &(&1 =~ "stale or has no usable cutoff"))
    end

    test "no usable cutoff → cap :low" do
      ctx = high_ctx(%{frontier: fresh_frontier(%{cutoff_source: :none})})
      assert grade(high_ir(), platt(), ctx) == :low
    end

    test "edition/data disagreement warning → cap :moderate" do
      warn = "edition year 2024 disagrees with newest member year 2018 — possible stale import"
      ctx = high_ctx(%{frontier: fresh_frontier(%{warnings: [warn]})})
      r = R.score(high_ir(), platt(), ctx)
      assert r.grade == :moderate
      assert Enum.any?(r.reasons, &(&1 =~ "disagrees"))
    end

    test "stale model → cap :low" do
      assert grade(high_ir(), platt(), high_ctx(%{is_stale: true})) == :low
    end

    test "no pre-registration → cap :low" do
      r = R.score(high_ir(), platt(), high_ctx(%{prereg?: false}))
      assert r.grade == :low
      assert Enum.any?(r.reasons, &(&1 =~ "pre-registration"))
    end

    test "recall below pre-registered failure threshold → cap :low" do
      # recall 0.8 but threshold demands 0.9
      r = R.score(high_ir(), platt(), high_ctx(%{threshold: 0.9}))
      assert r.grade == :low
      assert Enum.any?(r.reasons, &(&1 =~ "failure threshold"))
    end

    test "recall clearing the threshold does NOT cap" do
      assert grade(high_ir(), platt(), high_ctx(%{threshold: 0.5})) == :high
    end
  end

  describe "cap combinator (lowest surviving level)" do
    test "moderate cap + low cap → :low" do
      warn = "edition year 2024 disagrees with newest member year 2018"
      ctx = high_ctx(%{frontier: fresh_frontier(%{warnings: [warn]})})
      # disagreement (→moderate) stacked with identity calibration (→low)
      assert grade(high_ir(), identity(), ctx) == :low
    end

    test "an :insufficient cap beats any :low/:moderate cap" do
      # n_positives < 10 (→insufficient) stacked with identity (→low)
      r = R.score(high_ir(%{"n_positives" => 4}), identity(), high_ctx())
      assert r.grade == :insufficient
    end
  end

  describe "live shapes" do
    test "1001_movies-like → :low, sufficient, ~21% headline" do
      ir = high_ir(%{"recall_at_k" => 0.3636, "n_positives" => 22})
      r = R.score(ir, platt(), high_ctx())
      assert r.grade == :low
      assert r.sufficient?
      assert is_float(r.headline_pct)
      assert r.headline_pct > 15.0 and r.headline_pct < 30.0
      # graded purely by the band — no caps fired
      assert r.reasons == []
    end

    test "cult_movies_400-like → :insufficient, em-dash headline" do
      ir = high_ir(%{"recall_at_k" => 0.0, "n_positives" => 1})
      ctx = high_ctx(%{frontier: fresh_frontier(%{fresh?: false}), prereg?: true})
      r = R.score(ir, identity(), ctx)
      assert r.grade == :insufficient
      assert r.headline_pct == "—"
      refute r.sufficient?
      assert r.calibration == "identity"
    end
  end
end
