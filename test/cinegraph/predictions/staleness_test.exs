defmodule Cinegraph.Predictions.StalenessTest do
  @moduledoc "Lens-evolution staleness propagation (#1036): lens change flips :lens models, not :data_point."
  use Cinegraph.DataCase

  alias Cinegraph.Metrics.{CatalogSeed, MetricDefinition}
  alias Cinegraph.Predictions
  alias Cinegraph.Predictions.{Model, PreRegistration}
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.LensConfig

  setup do
    CatalogSeed.seed!()
    :ok
  end

  defp model!(granularity, lens_config_hash) do
    {:ok, prereg} =
      PreRegistration.register(%{
        source_key: "1001_movies",
        expected_top_features: %{},
        expected_accuracy_range: %{},
        failure_threshold: "0.10"
      })

    %Model{}
    |> Model.changeset(%{
      source_key: "1001_movies",
      feature_set: %{"granularity" => granularity, "features" => ["mob"]},
      weights: %{"mob" => 1.0},
      weights_hash: "h-#{granularity}-#{System.unique_integer([:positive])}",
      model_version: 1,
      lens_config_hash: lens_config_hash,
      prereg_id: prereg.id
    })
    |> Repo.insert!()
  end

  test "a lens change flips :lens models stale and leaves :data_point models untouched" do
    current = LensConfig.lens_config_hash()
    lens_model = model!("lens", current)
    dp_model = model!("data_point", nil)

    # Mutate a lens member → the active lens_config_hash changes.
    Repo.get_by!(MetricDefinition, code: "imdb_rating")
    |> Ecto.Changeset.change(weight_within_lens: 0.5)
    |> Repo.update!()

    refute LensConfig.lens_config_hash() == current

    assert Predictions.mark_stale_lens_models() == 1

    assert Repo.get!(Model, lens_model.id).is_stale == true
    assert Repo.get!(Model, dp_model.id).is_stale == false
  end

  test "is idempotent and a no-op when nothing changed" do
    current = LensConfig.lens_config_hash()
    fresh = model!("lens", current)

    assert Predictions.mark_stale_lens_models() == 0
    assert Repo.get!(Model, fresh.id).is_stale == false
  end

  test "stale_models/1 lists flipped models for a list" do
    model!("lens", "an-old-hash")
    assert Predictions.mark_stale_lens_models() == 1
    assert [%Model{}] = Predictions.stale_models("1001_movies")
    assert Predictions.stale_models("other_list") == []
  end
end
