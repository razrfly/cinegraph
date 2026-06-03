defmodule Cinegraph.Predictions.LinearLogReg do
  @moduledoc """
  The linear logistic-regression model class (#1061 Session 1) — today's only served model,
  now expressed through the `Cinegraph.Predictions.ModelClass` behaviour.

  This is a **byte-stable** extraction: `fit/4` is a literal pass-through to the existing
  `WeightOptimizer.fit_raw/3` + `WeightOptimizer.extract_weights/3` pair (Scholar logistic
  regression, default `alpha: 1.0`, `max_iterations: 1000`, `normalize: :simplex`) that
  `Trainer.fit_weights/6` already calls — so the produced weight map is identical to the pre-#1061
  path. A regression test pins this.

  `serving_kind/0` is `:weight_map`: the fitted artifact IS the simplex weight map, and `score/3`
  returns the `{granularity, weights, source_key}` bus spec the existing `Cinegraph.Scoring.Bus`
  already consumes — so serving needs no new code.
  """
  @behaviour Cinegraph.Predictions.ModelClass

  alias Cinegraph.Predictions.WeightOptimizer

  @impl true
  def key, do: "linear_logreg"

  @impl true
  def label, do: "Linear (logistic regression)"

  @impl true
  def serving_kind, do: :weight_map

  @impl true
  def fit(x, y, feature_names, opts) do
    normalize = Keyword.get(opts, :weight_normalize, :simplex)
    fit_opts = Keyword.take(opts, [:alpha, :max_iterations])

    weights =
      x
      |> WeightOptimizer.fit_raw(y, fit_opts)
      |> WeightOptimizer.extract_weights(feature_names, normalize: normalize)

    {:ok, weights}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def score(weights, granularity, source_key), do: {granularity, stringify(weights), source_key}

  @impl true
  def serialize(weights), do: stringify(weights)

  @impl true
  def load(map) when is_map(map), do: map

  @impl true
  def explain(weights), do: weights

  defp stringify(weights), do: Map.new(weights, fn {k, v} -> {to_string(k), v} end)
end
