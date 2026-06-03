defmodule Cinegraph.Predictions.LinearLogRegTest do
  @moduledoc """
  The byte-stability guard (#1061 Session 1): the extracted `LinearLogReg` class must produce the
  IDENTICAL weight map to the pre-extraction path (`WeightOptimizer.fit_raw |> extract_weights`).
  Plus registry resolution and the weight-map serving round-trip. Pure — no DB (tests use the
  Nx.BinaryBackend pinned in config/test.exs, so the fit is deterministic).
  """
  use ExUnit.Case, async: true

  alias Cinegraph.Predictions.{LinearLogReg, ModelRegistry, WeightOptimizer}

  # A small, fixed, separable matrix: 3 features, members (label 1) score high on feature 0.
  @x [
    [0.9, 0.1, 0.2],
    [0.8, 0.2, 0.1],
    [0.85, 0.15, 0.25],
    [0.1, 0.8, 0.9],
    [0.2, 0.7, 0.85],
    [0.15, 0.9, 0.8]
  ]
  @y [1, 1, 1, 0, 0, 0]
  @names ["f0", "f1", "f2"]

  describe "byte-stable extraction" do
    test "fit/4 equals the legacy fit_raw |> extract_weights(:simplex)" do
      expected =
        @x
        |> WeightOptimizer.fit_raw(@y, [])
        |> WeightOptimizer.extract_weights(@names, normalize: :simplex)

      assert {:ok, got} = LinearLogReg.fit(@x, @y, @names, [])
      assert got == expected
    end

    test "fit/4 honors :weight_normalize and :alpha passthrough" do
      expected =
        @x
        |> WeightOptimizer.fit_raw(@y, alpha: 0.1)
        |> WeightOptimizer.extract_weights(@names, normalize: :signed)

      assert {:ok, got} =
               LinearLogReg.fit(@x, @y, @names, weight_normalize: :signed, alpha: 0.1)

      assert got == expected
    end

    test "simplex weights are non-negative and sum to 1.0" do
      assert {:ok, w} = LinearLogReg.fit(@x, @y, @names, [])
      assert Enum.all?(Map.values(w), &(&1 >= 0.0))
      assert_in_delta Enum.sum(Map.values(w)), 1.0, 1.0e-6
    end
  end

  describe "behaviour contract" do
    test "metadata + serving kind" do
      assert LinearLogReg.key() == "linear_logreg"
      assert LinearLogReg.serving_kind() == :weight_map
      assert is_binary(LinearLogReg.label())
    end

    test "score/3 returns the existing Bus data_point spec (no new serving code)" do
      w = %{"f0" => 0.7, "f1" => 0.3}
      assert LinearLogReg.score(w, :data_point, "some_list") == {:data_point, w, "some_list"}
    end

    test "serialize/load/explain round-trip the weight map" do
      w = %{"f0" => 0.6, "f1" => 0.4}
      assert LinearLogReg.serialize(w) == w
      assert LinearLogReg.load(LinearLogReg.serialize(w)) == w
      assert LinearLogReg.explain(w) == w
    end

    test "serialize stringifies atom keys" do
      assert LinearLogReg.serialize(%{f0: 1.0}) == %{"f0" => 1.0}
    end
  end

  describe "ModelRegistry" do
    test "defaults to LinearLogReg" do
      assert ModelRegistry.all() == [LinearLogReg]
      assert ModelRegistry.default() == LinearLogReg
      assert ModelRegistry.keys() == ["linear_logreg"]
    end

    test "fetch/1 resolves a known key and errors on unknown" do
      assert {:ok, LinearLogReg} = ModelRegistry.fetch("linear_logreg")
      assert {:error, {:unknown_model_class, "nope"}} = ModelRegistry.fetch("nope")
    end

    test "is config-driven (adding a class is a config edit, not a code edit)" do
      defmodule FakeClass do
        def key, do: "fake"
      end

      original = Application.get_env(:cinegraph, :model_classes)
      Application.put_env(:cinegraph, :model_classes, [LinearLogReg, FakeClass])

      on_exit(fn ->
        if original,
          do: Application.put_env(:cinegraph, :model_classes, original),
          else: Application.delete_env(:cinegraph, :model_classes)
      end)

      assert "fake" in ModelRegistry.keys()
      assert {:ok, FakeClass} = ModelRegistry.fetch("fake")
    end
  end
end
