defmodule Cinegraph.Predictions.ProbabilityCalibrationTest do
  use ExUnit.Case, async: true

  alias Cinegraph.Predictions.ProbabilityCalibration, as: PC

  test "platt fit is monotonic and separates high/low scores" do
    # Scores 0..100; label 1 mostly for high scores.
    pairs =
      for s <- 0..99 do
        y = if rem(s, 100) >= 60, do: 1, else: 0
        {s * 1.0, y}
      end

    {scores, labels} = Enum.unzip(pairs)
    calib = PC.fit(scores, labels)

    assert calib["method"] == "platt"
    low = PC.apply_calibration(calib, 10.0)
    high = PC.apply_calibration(calib, 90.0)
    assert high > low
    assert low >= 0.0 and high <= 1.0
  end

  test "falls back to identity when positives are too few" do
    scores = Enum.map(0..40, &(&1 * 1.0))
    labels = List.duplicate(0, 39) ++ [1, 1]

    calib = PC.fit(scores, labels)
    assert calib["method"] == "identity"
    assert calib["reason"] =~ "insufficient class balance"
    assert_in_delta PC.apply_calibration(calib, 50.0), 0.5, 1.0e-9
  end

  test "falls back to identity when one class is missing (no negatives)" do
    scores = Enum.map(0..40, &(&1 * 1.0))
    labels = List.duplicate(1, 41)

    calib = PC.fit(scores, labels)
    assert calib["method"] == "identity"
    assert calib["reason"] =~ "insufficient class balance"
  end
end
