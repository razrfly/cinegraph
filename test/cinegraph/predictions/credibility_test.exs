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

  describe "log_loss/2" do
    test "0 for confident-correct, high for confident-wrong" do
      assert Credibility.log_loss([1.0, 0.0], [1, 0]) == 0.0
      assert Credibility.log_loss([0.0, 1.0], [1, 0]) > 30.0
    end

    test "ln 2 for p=0.5 regardless of labels" do
      assert_in_delta Credibility.log_loss([0.5, 0.5], [1, 0]), :math.log(2), 1.0e-4
    end

    test "nil for empty input" do
      assert Credibility.log_loss([], []) == nil
    end
  end

  describe "pr_auc/2 (average precision)" do
    test "perfect ranking (all positives above negatives) → 1.0" do
      scores = [0.9, 0.8, 0.2, 0.1]
      labels = [1, 1, 0, 0]
      assert Credibility.pr_auc(scores, labels) == 1.0
    end

    test "worst ranking (all negatives above positives) → low" do
      scores = [0.9, 0.8, 0.2, 0.1]
      labels = [0, 0, 1, 1]
      # first positive at rank 3 → precision 1/3; second at rank 4 → 2/4; AP = (1/3+1/2)/2
      assert_in_delta Credibility.pr_auc(scores, labels), (1 / 3 + 1 / 2) / 2, 1.0e-4
    end

    test "nil when there are no positives" do
      assert Credibility.pr_auc([0.5, 0.4], [0, 0]) == nil
    end
  end
end
