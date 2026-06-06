defmodule Cinegraph.Predictions.ProbabilityCalibration do
  @moduledoc """
  Turn raw bus scores (0–100) into calibrated probabilities (#1036 Session 3, refit #1074).

  **Two-stage balanced Platt scaling** — fit `p = σ(a·s + b)` on holdout `(score, label)` pairs
  by plain deterministic gradient descent (no Nx dependency, trivially testable):

    * **Stage A (slope)** — class-*balanced* weighted logistic fit with Platt's smoothed targets
      (`t₊ = (n₊+1)/(n₊+2)`, `t₋ = 1/(n₋+2)`). At the full evaluation pool's ~0.1% positive rate,
      an unweighted fit lets the negative mass dominate the loss — that's how every served model
      ended up with a *negative* slope (#1074). Balancing makes `a` reflect the score→label
      relationship, not the imbalance.
    * **Stage B (intercept)** — with `a` fixed, refit `b` alone on the *unweighted* pairs, so the
      stated probabilities respect the TRUE base rate. (A balanced fit alone would inflate a
      0.4%-likely film to ~45% — a new fake number.)

  When the holdout has too few positives to fit a stable sigmoid, it falls back to an `identity`
  map (`p = score/100`) and records the reason — honesty over a spuriously-confident curve.
  Genuinely anti-correlated data still yields `a < 0`; `informative?/1` then keeps per-film %
  hidden, which is correct behavior, not a failure.

  The fitted map is stored on `prediction_models.calibration` and applied to convert a
  model's score into a stated probability.
  """

  @min_positives 8
  @iterations 2000
  @learning_rate 0.5
  @grad_epsilon 1.0e-6
  @scale 100.0
  @fit_version 2

  @doc """
  Fit a calibration map from holdout scores (0–100) and 0/1 labels.
  Returns a JSON-able map: `%{"method" => "platt"|"identity", ...}` (`"fit_version" => 2` since
  the #1074 balanced refit).
  """
  def fit(scores, labels) when length(scores) == length(labels) do
    pos = Enum.count(labels, &(&1 == 1))
    neg = length(labels) - pos

    if pos < @min_positives or neg < @min_positives or length(labels) < 2 * @min_positives do
      %{
        "method" => "identity",
        "reason" =>
          "insufficient class balance (pos #{pos}, neg #{neg}; need ≥#{@min_positives} each); using score/100",
        "n" => length(labels),
        "n_positives" => pos
      }
    else
      xs = Enum.map(scores, &(&1 / @scale))
      a = balanced_slope(xs, labels, pos, neg)
      b = intercept_fit(xs, labels, a)

      %{
        "method" => "platt",
        "a" => a,
        "b" => b,
        "scale" => @scale,
        "n" => length(labels),
        "n_positives" => pos,
        "fit_version" => @fit_version
      }
    end
  end

  @doc """
  Can this calibration honestly back a *per-film* percentage? Only a Platt fit with a **positive
  slope** qualifies: identity is a fake `score/100`, and a flat/negative-slope Platt (it happens —
  1001_movies served one) maps higher scores to equal-or-*lower* probabilities, so a % badge next
  to a rank would be anti-correlated with it. Display gates must use this, not just
  `method != "identity"`.
  """
  def informative?(%{"method" => "platt", "a" => a}) when is_number(a), do: a > 0.0
  def informative?(_nil_or_other), do: false

  @doc "Apply a calibration map to a raw 0–100 score → probability in [0,1]."
  def apply_calibration(%{"method" => "platt", "a" => a, "b" => b, "scale" => scale}, score) do
    sigmoid(a * (score / scale) + b)
  end

  def apply_calibration(%{"method" => "identity"}, score), do: min(max(score / @scale, 0.0), 1.0)
  def apply_calibration(_nil_or_other, score), do: min(max(score / @scale, 0.0), 1.0)

  # ── Stage A: slope from a class-balanced fit with Platt's smoothed targets ──────────
  # Each example carries weight n/(2·n_class) (mean weight 1, classes contribute equally) and a
  # smoothed target instead of the hard 0/1 (Platt 1999) — the standard guards against the
  # imbalance-dominated and overconfident fits that produced #1074's negative slopes.
  defp balanced_slope(xs, ys, pos, neg) do
    n = pos + neg
    w_pos = n / (2.0 * pos)
    w_neg = n / (2.0 * neg)
    t_pos = (pos + 1.0) / (pos + 2.0)
    t_neg = 1.0 / (neg + 2.0)

    triples =
      Enum.zip(xs, ys)
      |> Enum.map(fn
        {x, 1} -> {x, t_pos, w_pos}
        {x, _} -> {x, t_neg, w_neg}
      end)

    {a, _b} =
      descend({0.0, 0.0}, fn {a, b} ->
        {ga, gb} =
          Enum.reduce(triples, {0.0, 0.0}, fn {x, t, w}, {ga, gb} ->
            err = w * (sigmoid(a * x + b) - t)
            {ga + err * x, gb + err}
          end)

        # mean gradients (weights have mean 1, so /n is the weighted average)
        {ga / n, gb / n}
      end)

    a
  end

  # ── Stage B: intercept refit on the UNWEIGHTED pairs (slope fixed) ───────────────────
  # Restores the true base-rate prior so the displayed probability isn't inflated to the
  # balanced fit's implicit 50/50 world.
  defp intercept_fit(xs, ys, a) do
    pairs = Enum.zip(xs, ys)
    n = length(pairs)

    {_a, b} =
      descend({a, 0.0}, fn {_a, b} ->
        gb =
          Enum.reduce(pairs, 0.0, fn {x, y}, acc -> acc + (sigmoid(a * x + b) - y) end)

        # slope is frozen: zero gradient for `a`
        {0.0, gb / n}
      end)

    b
  end

  # Deterministic batch gradient descent (mean gradients) with early stop on gradient norm.
  defp descend({a0, b0}, grad_fn) do
    Enum.reduce_while(1..@iterations, {a0, b0}, fn _, {a, b} ->
      {ga, gb} = grad_fn.({a, b})

      if abs(ga) < @grad_epsilon and abs(gb) < @grad_epsilon do
        {:halt, {a, b}}
      else
        {:cont, {a - @learning_rate * ga, b - @learning_rate * gb}}
      end
    end)
  end

  defp sigmoid(z) when z >= 0 do
    e = :math.exp(-z)
    1.0 / (1.0 + e)
  end

  defp sigmoid(z) do
    e = :math.exp(z)
    e / (1.0 + e)
  end
end
