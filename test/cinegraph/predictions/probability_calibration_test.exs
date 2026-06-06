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

  describe "two-stage balanced fit (#1074 — the negative-slope regression)" do
    # The shape that broke every served model: ~1% positives, concentrated at high scores. The
    # old unweighted fit let the negative mass set the slope (negative); the balanced fit must
    # recover the true direction.
    defp imbalanced_correlated do
      neg = for i <- 0..1979, do: {rem(i * 37, 90) * 1.0, 0}
      pos = for i <- 0..19, do: {60.0 + rem(i * 7, 35) * 1.0, 1}
      Enum.unzip(neg ++ pos)
    end

    test "recovers a positive slope at ~1% positive rate (the #1074 failure shape)" do
      {scores, labels} = imbalanced_correlated()
      calib = PC.fit(scores, labels)

      assert calib["method"] == "platt"
      assert calib["fit_version"] == 2
      assert calib["a"] > 0.0
      assert PC.informative?(calib)
    end

    test "stated probabilities respect the TRUE base rate (intercept stage)" do
      {scores, labels} = imbalanced_correlated()
      calib = PC.fit(scores, labels)

      mean_prob =
        scores |> Enum.map(&PC.apply_calibration(calib, &1)) |> then(&(Enum.sum(&1) / length(&1)))

      base_rate = Enum.count(labels, &(&1 == 1)) / length(labels)
      # balanced-only fitting would put this near 0.5 — the intercept refit must pull it back
      assert_in_delta mean_prob, base_rate, base_rate * 0.5
    end

    test "Brier does not regress vs the identity baseline" do
      {scores, labels} = imbalanced_correlated()
      calib = PC.fit(scores, labels)
      pairs = Enum.zip(scores, labels)

      brier = fn c ->
        probs = Enum.map(scores, &PC.apply_calibration(c, &1))

        Enum.zip(probs, labels)
        |> Enum.reduce(0.0, fn {p, y}, acc -> acc + :math.pow(p - y, 2) end)
        |> Kernel./(length(pairs))
      end

      assert brier.(calib) <= brier.(%{"method" => "identity"})
    end

    test "genuinely anti-correlated data still fits a negative slope — and stays gated" do
      neg = for i <- 0..1979, do: {10.0 + rem(i * 37, 90) * 1.0, 0}
      pos = for i <- 0..19, do: {rem(i * 7, 30) * 1.0, 1}
      {scores, labels} = Enum.unzip(neg ++ pos)

      calib = PC.fit(scores, labels)
      assert calib["a"] < 0.0
      refute PC.informative?(calib)
    end

    test "deterministic: same pairs → identical map" do
      {scores, labels} = imbalanced_correlated()
      assert PC.fit(scores, labels) == PC.fit(scores, labels)
    end
  end

  describe "informative?/1 (the per-film % display gate)" do
    test "true only for a Platt fit with positive slope" do
      assert PC.informative?(%{"method" => "platt", "a" => 2.5, "b" => -6.0})
    end

    test "false for flat or inverted Platt — % would anti-correlate with rank" do
      refute PC.informative?(%{"method" => "platt", "a" => 0.0, "b" => -6.0})
      refute PC.informative?(%{"method" => "platt", "a" => -1.2, "b" => -6.0})
    end

    test "false for identity, nil, and junk" do
      refute PC.informative?(%{"method" => "identity", "reason" => "whatever"})
      refute PC.informative?(nil)
      refute PC.informative?(%{})
    end
  end
end
