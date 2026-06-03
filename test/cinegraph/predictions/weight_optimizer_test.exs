defmodule Cinegraph.Predictions.WeightOptimizerTest do
  @moduledoc "Unit tests for the #1051 Stage B weight-extraction strategies (pure; no DB)."
  use ExUnit.Case, async: true

  alias Cinegraph.Predictions.WeightOptimizer

  # Build a fake fitted model: coefficients are {n_features, 2}; extract_weights reads column 1
  # (the positive class), so `col1` is the per-feature positive-class coefficient list.
  defp model(col1), do: %{coefficients: Nx.tensor(Enum.map(col1, &[0.0, &1]))}

  describe "extract_weights/3 normalize strategies" do
    test ":simplex clamps negative coefficients to 0 and normalizes to sum 1.0" do
      w =
        WeightOptimizer.extract_weights(model([5.0, 0.1, -0.2]), ["dom", "weak", "neg"],
          normalize: :simplex
        )

      assert w["neg"] == 0.0
      assert_in_delta Enum.sum(Map.values(w)), 1.0, 1.0e-6
      assert w["dom"] > w["weak"]
    end

    test ":signed preserves sign and is L2-normalized" do
      w =
        WeightOptimizer.extract_weights(model([5.0, 0.1, -0.2]), ["dom", "weak", "neg"],
          normalize: :signed
        )

      assert w["neg"] < 0.0
      l2 = w |> Map.values() |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
      assert_in_delta l2, 1.0, 1.0e-6
    end

    test "default (no opts) and /2 both behave as :simplex" do
      m = model([1.0, -1.0])

      assert WeightOptimizer.extract_weights(m, ["a", "b"]) ==
               WeightOptimizer.extract_weights(m, ["a", "b"], normalize: :simplex)
    end

    # The #1051 Stage B dilution: a dominant feature loses its weight share under :simplex when many
    # weak positive features are added (the cause of `full < canon`), but :signed preserves it.
    test "a dominant feature is diluted by many weak ones under :simplex but preserved under :signed" do
      col1 = [5.0 | List.duplicate(0.1, 50)]
      names = ["dom" | Enum.map(1..50, &"w#{&1}")]

      simplex = WeightOptimizer.extract_weights(model(col1), names, normalize: :simplex)
      signed = WeightOptimizer.extract_weights(model(col1), names, normalize: :signed)

      # simplex: dom share = 5 / (5 + 50*0.1) = 0.5 (diluted)
      assert simplex["dom"] < 0.6
      # signed: dom = 5 / sqrt(25 + 50*0.01) ≈ 0.99 (preserved)
      assert signed["dom"] > 0.95
    end

    test ":simplex falls back to uniform weights when all coefficients are non-positive" do
      w = WeightOptimizer.extract_weights(model([-1.0, -2.0]), ["a", "b"], normalize: :simplex)
      assert w == %{"a" => 0.5, "b" => 0.5}
    end
  end
end
