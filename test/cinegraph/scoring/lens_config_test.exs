defmodule Cinegraph.Scoring.LensConfigTest do
  use Cinegraph.DataCase

  alias Cinegraph.Metrics.{CatalogSeed, MetricDefinition}
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.LensConfig

  setup do
    CatalogSeed.seed!()
    :ok
  end

  describe "lens_config_hash/0" do
    test "is stable across calls for an unchanged catalog" do
      assert LensConfig.lens_config_hash() == LensConfig.lens_config_hash()
    end

    test "changes when a lens member's weight_within_lens changes (staleness signal)" do
      before = LensConfig.lens_config_hash()

      Repo.get_by!(MetricDefinition, code: "imdb_rating")
      |> Ecto.Changeset.change(weight_within_lens: 0.5)
      |> Repo.update!()

      refute LensConfig.lens_config_hash() == before
    end

    test "changes when a member is removed from a lens (deactivated)" do
      before = LensConfig.lens_config_hash()

      Repo.get_by!(MetricDefinition, code: "tmdb_rating")
      |> Ecto.Changeset.change(active: false)
      |> Repo.update!()

      refute LensConfig.lens_config_hash() == before
    end
  end

  describe "weights_hash/4" do
    @feature_set %{"granularity" => "lens", "features" => ["mob", "critics"]}

    test "is invariant under weights-map key ordering" do
      a = LensConfig.weights_hash(@feature_set, %{"mob" => 0.6, "critics" => 0.4}, 1, "lc")
      b = LensConfig.weights_hash(@feature_set, %{"critics" => 0.4, "mob" => 0.6}, 1, "lc")
      assert a == b
    end

    test "differs when the feature set differs even if numbers match" do
      lens = LensConfig.weights_hash(@feature_set, %{"mob" => 1.0}, 1, "lc")

      dp =
        LensConfig.weights_hash(
          %{"granularity" => "data_point", "features" => ["imdb_rating"]},
          %{"mob" => 1.0},
          1,
          nil
        )

      refute lens == dp
    end

    test "differs when model_version or lens_config_hash differ" do
      base = LensConfig.weights_hash(@feature_set, %{"mob" => 1.0}, 1, "lc1")
      refute base == LensConfig.weights_hash(@feature_set, %{"mob" => 1.0}, 2, "lc1")
      refute base == LensConfig.weights_hash(@feature_set, %{"mob" => 1.0}, 1, "lc2")
    end

    # #1061 Session 1: model_class is an optional 5th arg.
    test "nil model_class reproduces the legacy 4-arg hash byte-for-byte" do
      assert LensConfig.weights_hash(@feature_set, %{"mob" => 1.0}, 1, "lc") ==
               LensConfig.weights_hash(@feature_set, %{"mob" => 1.0}, 1, "lc", nil)
    end

    test "differs by model_class so a linear and an opaque model can't collide" do
      base = LensConfig.weights_hash(@feature_set, %{"mob" => 1.0}, 1, "lc", "linear_logreg")

      refute base ==
               LensConfig.weights_hash(@feature_set, %{"mob" => 1.0}, 1, "lc", "gbm_xgboost")

      # …and naming the class differs from the legacy unnamed hash.
      refute base == LensConfig.weights_hash(@feature_set, %{"mob" => 1.0}, 1, "lc", nil)
    end
  end
end
