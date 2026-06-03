defmodule Cinegraph.Predictions.TrainerSplitTest do
  use ExUnit.Case, async: true

  alias Cinegraph.Predictions.Trainer

  # Pure 3-way split policy (#1040). The crux invariant: the sacred holdout (latest decade) is
  # ALWAYS reserved and never lands in train or validation, so experiments can't peek at it.
  describe "split_decades/3" do
    @decades [1920, 1930, 1940, 1950, 1960, 1970, 1980, 1990, 2000, 2010, 2020]

    test "holdout is the latest decade and is excluded from train + validation" do
      counts = Map.new(@decades, &{&1, 10})
      {train, val, holdout} = Trainer.split_decades(@decades, counts, 30)

      assert holdout == [2020]
      refute 2020 in train
      refute 2020 in val
      # train + val + holdout partition the full set with no overlap
      assert Enum.sort(train ++ val ++ holdout) == @decades
      assert train -- val == train
    end

    test "validation pools backward until it reaches the minimum positive count" do
      # 10 positives per decade; min 30 → validation should be the 3 decades before 2020.
      counts = Map.new(@decades, &{&1, 10})
      {_train, val, _holdout} = Trainer.split_decades(@decades, counts, 30)
      assert val == [1990, 2000, 2010]
    end

    test "a single rich validation decade suffices when it clears the minimum" do
      counts = Map.new(@decades, &{&1, 100})
      {_train, val, _holdout} = Trainer.split_decades(@decades, counts, 30)
      assert val == [2010]
    end

    test "always leaves at least one decade for training" do
      {train, val, holdout} =
        Trainer.split_decades([1990, 2000, 2010], %{1990 => 1, 2000 => 1}, 30)

      assert holdout == [2010]
      assert train == [1990]
      assert val == [2000]
    end

    test "fewer than 3 decades is insufficient" do
      assert Trainer.split_decades([2010, 2020], %{}, 30) == {:error, :insufficient_decades}
      assert Trainer.split_decades([2020], %{}, 30) == {:error, :insufficient_decades}
    end
  end
end
