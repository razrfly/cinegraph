defmodule Cinegraph.Predictions.SweepTest do
  # The experiment/sweep path is integration-level (needs real movies across decades). Against the
  # empty sandbox DB we assert graceful behavior; determinism + PR-AUC ranking on real data are
  # validated live by `mix predictions.experiment --sweep` (#1040 S3 gate).
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Predictions.Trainer

  test "run_experiment errors cleanly for a list with no temporal spread" do
    assert Trainer.run_experiment("nonexistent_list_xyz", granularity: :data_point) in [
             {:error, :insufficient_decades},
             {:error, :no_data_point_features}
           ]
  end

  test "run_sweep drops failed variants and returns a (here empty) ranked list, never crashing" do
    variants = [[features: :raw, sample_ratio: 5], [features: :all, sample_ratio: 5]]
    assert Trainer.run_sweep("nonexistent_list_xyz", variants, max_concurrency: 2) == []
  end
end
