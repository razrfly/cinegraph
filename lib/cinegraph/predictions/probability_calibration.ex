defmodule Cinegraph.Predictions.ProbabilityCalibration do
  @moduledoc """
  Turn raw bus scores (0–100) into calibrated probabilities (#1036 Session 3).

  **Platt scaling** — fit `p = σ(a·s + b)` on holdout `(score, label)` pairs by logistic
  regression (plain gradient descent over 2 params; deterministic, no Nx dependency, so it
  is trivially testable). When the holdout has too few positives to fit a stable sigmoid,
  it falls back to an `identity` map (`p = score/100`) and records the reason — honesty over
  a spuriously-confident curve.

  The fitted map is stored on `prediction_models.calibration` and applied to convert a
  model's score into a stated probability.
  """

  @min_positives 8
  @iterations 500
  @learning_rate 0.5
  @scale 100.0

  @doc """
  Fit a calibration map from holdout scores (0–100) and 0/1 labels.
  Returns a JSON-able map: `%{"method" => "platt"|"identity", ...}`.
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
      {a, b} = gradient_fit(Enum.map(scores, &(&1 / @scale)), labels)

      %{
        "method" => "platt",
        "a" => a,
        "b" => b,
        "scale" => @scale,
        "n" => length(labels),
        "n_positives" => pos
      }
    end
  end

  @doc "Apply a calibration map to a raw 0–100 score → probability in [0,1]."
  def apply_calibration(%{"method" => "platt", "a" => a, "b" => b, "scale" => scale}, score) do
    sigmoid(a * (score / scale) + b)
  end

  def apply_calibration(%{"method" => "identity"}, score), do: min(max(score / @scale, 0.0), 1.0)
  def apply_calibration(_nil_or_other, score), do: min(max(score / @scale, 0.0), 1.0)

  # 2-parameter logistic regression (Platt) by batch gradient descent.
  defp gradient_fit(xs, ys) do
    n = length(xs)
    pairs = Enum.zip(xs, ys)

    Enum.reduce(1..@iterations, {0.0, 0.0}, fn _, {a, b} ->
      {ga, gb} =
        Enum.reduce(pairs, {0.0, 0.0}, fn {x, y}, {ga, gb} ->
          err = sigmoid(a * x + b) - y
          {ga + err * x, gb + err}
        end)

      {a - @learning_rate * ga / n, b - @learning_rate * gb / n}
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
