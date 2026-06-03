defmodule Cinegraph.Predictions.SourceOfTruthTest do
  @moduledoc """
  The #1036 source-of-truth contract for Session 2:
    * trained/measured weights live in `prediction_models` (the artifact) and a derived
      `movie_lists.trained_weights` read-cache — NEVER in `metric_weight_profiles`.
    * human-authored presets live in `metric_weight_profiles` — and never leak into the
      trained-weights path.
  """
  use Cinegraph.DataCase

  alias Cinegraph.Repo
  alias Cinegraph.Predictions.{Model, PreRegistration}
  alias Cinegraph.Movies.{MovieList, MovieLists}
  alias Cinegraph.Metrics.MetricWeightProfile

  defp insert_list(source_key) do
    %MovieList{}
    |> MovieList.changeset(%{
      source_key: source_key,
      name: "SoT #{source_key}",
      source_type: "custom",
      source_url: "https://example.com/#{source_key}",
      category: "curated"
    })
    |> Repo.insert!()
  end

  defp prereg!(source_key) do
    {:ok, p} =
      PreRegistration.register(%{
        source_key: source_key,
        expected_top_features: %{},
        expected_accuracy_range: %{},
        failure_threshold: "0.10"
      })

    p
  end

  defp insert_model(source_key, weights) do
    %Model{}
    |> Model.changeset(%{
      source_key: source_key,
      feature_set: %{"granularity" => "lens", "features" => Map.keys(weights)},
      weights: weights,
      weights_hash: "hash-#{source_key}",
      model_version: 1,
      lens_config_hash: "lc-1",
      prereg_id: prereg!(source_key).id
    })
    |> Repo.insert!()
  end

  test "trained weights flow through prediction_models + the derived movie_lists cache" do
    insert_list("sot_list")
    weights = %{"mob" => 0.5, "critics" => 0.5}
    model = insert_model("sot_list", weights)

    {:ok, _} = MovieLists.set_active_prediction_model("sot_list", model.id, model.weights)

    assert MovieLists.get_trained_weights("sot_list") == weights
    assert MovieLists.get_by_source_key("sot_list").active_prediction_model_id == model.id
  end

  test "a metric_weight_profile (human preset) never affects trained weights" do
    insert_list("sot_list2")
    model = insert_model("sot_list2", %{"mob" => 0.7, "critics" => 0.3})
    {:ok, _} = MovieLists.set_active_prediction_model("sot_list2", model.id, model.weights)

    {:ok, _preset} =
      %MetricWeightProfile{}
      |> MetricWeightProfile.changeset(%{
        name: "Human Preset X",
        category_weights: %{"mob" => 0.9, "critics" => 0.1}
      })
      |> Repo.insert()

    # trained weights are still the model's — presets are a separate store
    assert MovieLists.get_trained_weights("sot_list2") == model.weights
  end

  test "WeightOptimizer is analysis-only — it no longer persists models (Rule 1)" do
    src = File.read!("lib/cinegraph/predictions/weight_optimizer.ex")
    refute src =~ "MetricWeightProfile", "WeightOptimizer must not write human presets"
    # The persist path was removed — only the integrity-enforcing Trainer may save a model.
    refute src =~ "Model.changeset", "WeightOptimizer must not insert prediction_models"
    refute src =~ "set_active_prediction_model"
  end

  test "Rule 1 is enforced at the DB level — a model cannot exist without a prereg" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Changeset-free insert so this proves the DATABASE NOT NULL rule, independent of any
    # application-level validation (prereg_id is not in the changeset's validate_required).
    assert_raise Postgrex.Error, ~r/null value in column "prereg_id"/, fn ->
      Repo.insert_all("prediction_models", [
        %{
          source_key: "sot_notnull",
          feature_set: %{"granularity" => "lens", "features" => ["mob"]},
          weights: %{"mob" => 1.0},
          weights_hash: "h-notnull",
          model_version: 1,
          prereg_id: nil,
          inserted_at: now,
          updated_at: now
        }
      ])
    end
  end
end
