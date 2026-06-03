defmodule Cinegraph.Predictions.CredibilityTest do
  use ExUnit.Case, async: true

  alias Cinegraph.Predictions.Credibility

  test "brier is 0 for perfect confident predictions and 1 for confidently wrong" do
    assert Credibility.brier([1.0, 0.0, 1.0], [1, 0, 1]) == 0.0
    assert Credibility.brier([0.0, 1.0], [1, 0]) == 1.0
  end

  test "brier penalizes uncertainty quadratically" do
    # all p=0.5 → (0.5)^2 = 0.25 regardless of labels
    assert Credibility.brier([0.5, 0.5, 0.5, 0.5], [1, 0, 1, 0]) == 0.25
  end

  test "brier_calibrated applies the calibration map before scoring" do
    pairs = [{100.0, 1}, {0.0, 0}]
    # identity calibration → p = score/100 → {1.0, 0.0} vs {1, 0} → perfect
    assert Credibility.brier_calibrated(pairs, %{"method" => "identity"}) == 0.0
  end
end
