defmodule Cinegraph.Predictions.ModelBundleTest do
  @moduledoc """
  Dev→prod model promotion (#1043) — export/import round-trip, the two correctness gates,
  idempotency, prereg content-dedup, and the honest activation-guard outcome.
  """
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Metrics.CatalogSeed
  alias Cinegraph.Movies.{MovieList, MovieLists}
  alias Cinegraph.Predictions.{Model, ModelBundle, PreRegistration}
  alias Cinegraph.Repo

  setup do
    CatalogSeed.seed!()
    :ok
  end

  defp list!(sk) do
    %MovieList{}
    |> MovieList.changeset(%{
      source_key: sk,
      name: "Bundle List #{sk}",
      source_type: "imdb",
      source_url: "https://example.com/l",
      slug: "bundle-#{sk}",
      active: true
    })
    |> Repo.insert!()
  end

  defp served_model!(sk, attrs \\ %{}) do
    list = list!(sk)

    {:ok, prereg} =
      PreRegistration.register(%{
        source_key: sk,
        expected_top_features: %{"imdb_rating" => "up"},
        expected_accuracy_range: %{"min" => 0.1},
        failure_threshold: "0.10"
      })

    model =
      %Model{}
      |> Model.changeset(
        Map.merge(
          %{
            source_key: sk,
            feature_set: %{"granularity" => "data_point", "features" => ["imdb_rating"]},
            weights: %{"imdb_rating" => 0.6, "metacritic_metascore" => 0.4},
            weights_hash: "bundle_h_#{System.unique_integer([:positive])}",
            model_version: 1,
            backtest_strategy: "static",
            calibration: %{"method" => "platt", "a" => 12.0, "b" => -8.0, "scale" => 100.0},
            holdout_spent_at: ~U[2026-06-01 12:00:00Z],
            integrity_report: %{
              "recall_at_k" => 0.5,
              "n_positives" => 20,
              "n_evaluated" => 100,
              "baselines" => %{"popularity" => 0.0}
            },
            prereg_id: prereg.id
          },
          attrs
        )
      )
      |> Repo.insert!()

    {:ok, _} = MovieLists.set_active_prediction_model(sk, model.id, model.weights)
    {list, model}
  end

  test "export → import round-trip is idempotent and preserves the measurement verbatim" do
    sk = "bundle_rt_#{System.unique_integer([:positive])}"
    {_list, model} = served_model!(sk)

    {:ok, bundle} = ModelBundle.export(sk)
    assert bundle["format_version"] == 1
    assert bundle["model"]["weights_hash"] == model.weights_hash

    # JSON round-trip exactly as prod would receive it
    bundle = bundle |> ModelBundle.encode_deterministic() |> Jason.decode!()

    # wipe the rows + pointer to simulate a fresh prod
    {:ok, _} = MovieLists.set_active_prediction_model(sk, nil, nil)
    Repo.delete!(model)

    assert {:ok, result} = ModelBundle.import(bundle)
    assert result.status == "imported"
    assert result.activated == true

    imported = Repo.get!(Model, result.model_id)
    # Gate 2: the measurement traveled verbatim
    assert imported.integrity_report == model.integrity_report
    assert imported.holdout_spent_at == model.holdout_spent_at
    assert imported.calibration == model.calibration
    assert imported.weights == model.weights

    # pointer + read-cache flipped through the guarded path
    list = MovieLists.get_by_source_key(sk)
    assert list.active_prediction_model_id == imported.id
    assert list.trained_weights == model.weights

    # re-import: proven no-op
    assert {:ok, again} = ModelBundle.import(bundle)
    assert again.status == "already_present"
    assert again.model_id == imported.id
    assert Repo.aggregate(Model, :count) >= 1
  end

  test "Gate 1: data_point bundle with a code missing from the catalog is refused, code named" do
    sk = "bundle_gate1_#{System.unique_integer([:positive])}"
    {_list, _model} = served_model!(sk, %{weights: %{"no_such_code_xyz" => 1.0}})

    {:ok, bundle} = ModelBundle.export(sk)

    assert {:error, {:substrate_mismatch, {:missing_or_unavailable_codes, ["no_such_code_xyz"]}}} =
             ModelBundle.import(bundle)
  end

  test "Gate 1: lens bundle with a mismatched lens_config_hash is refused" do
    sk = "bundle_lens_#{System.unique_integer([:positive])}"

    {_list, _model} =
      served_model!(sk, %{feature_set: %{"granularity" => "lens"}, weights: %{"mob" => 1.0}})

    {:ok, bundle} = ModelBundle.export(sk)
    tampered = put_in(bundle["substrate_fingerprint"]["lens_config_hash"], "not-the-real-hash")

    assert {:error, {:substrate_mismatch, {:lens_config_hash, _}}} = ModelBundle.import(tampered)
  end

  test "prereg content-dedup: re-import after model deletion reuses the existing prereg row" do
    sk = "bundle_prereg_#{System.unique_integer([:positive])}"
    {_list, model} = served_model!(sk)
    {:ok, bundle} = ModelBundle.export(sk)
    bundle = bundle |> ModelBundle.encode_deterministic() |> Jason.decode!()

    before = Repo.aggregate(PreRegistration, :count)
    {:ok, _} = MovieLists.set_active_prediction_model(sk, nil, nil)
    Repo.delete!(model)

    assert {:ok, _} = ModelBundle.import(bundle)
    assert Repo.aggregate(PreRegistration, :count) == before
  end

  test "activation guard: an :insufficient bundle imports rows but honestly reports activated: false" do
    sk = "bundle_insuf_#{System.unique_integer([:positive])}"

    {_list, model} =
      served_model_unactivated!(sk, %{
        integrity_report: %{
          # zero evidence → Reliability grades :insufficient → guard refuses activation
          "recall_at_k" => 0.0,
          "n_positives" => 0,
          "n_evaluated" => 0,
          "baselines" => %{"popularity" => 0.0}
        }
      })

    bundle = build_bundle(sk, model)

    assert {:ok, result} = ModelBundle.import(bundle)
    assert result.status == "already_present"
    assert result.activated == false

    assert MovieLists.get_by_source_key(sk).active_prediction_model_id == nil
  end

  test "write!/encode_deterministic: identical bytes across runs" do
    sk = "bundle_det_#{System.unique_integer([:positive])}"
    {_list, _model} = served_model!(sk)
    {:ok, bundle} = ModelBundle.export(sk)

    assert ModelBundle.encode_deterministic(bundle) == ModelBundle.encode_deterministic(bundle)
  end

  test "unknown format_version is refused" do
    assert {:error, {:unknown_format_version, 99}} =
             ModelBundle.import(%{"format_version" => 99})
  end

  # ── helpers for the guard test (model exists but was never activated) ───────────────
  defp served_model_unactivated!(sk, attrs) do
    _list = list!(sk)

    {:ok, prereg} =
      PreRegistration.register(%{
        source_key: sk,
        expected_top_features: %{},
        expected_accuracy_range: %{},
        failure_threshold: "0.10"
      })

    model =
      %Model{}
      |> Model.changeset(
        Map.merge(
          %{
            source_key: sk,
            feature_set: %{"granularity" => "data_point", "features" => ["imdb_rating"]},
            weights: %{"imdb_rating" => 1.0},
            weights_hash: "bundle_h_#{System.unique_integer([:positive])}",
            model_version: 1,
            backtest_strategy: "static",
            prereg_id: prereg.id
          },
          attrs
        )
      )
      |> Repo.insert!()

    {nil, model}
  end

  defp build_bundle(sk, model) do
    model = Repo.preload(model, :pre_registration)

    %{
      "format_version" => 1,
      "source_key" => sk,
      "substrate_fingerprint" => %{
        "lens_config_hash" => Cinegraph.Scoring.LensConfig.lens_config_hash()
      },
      "pre_registration" => %{
        "source_key" => sk,
        "expected_top_features" => model.pre_registration.expected_top_features,
        "expected_accuracy_range" => model.pre_registration.expected_accuracy_range,
        "failure_threshold" => model.pre_registration.failure_threshold,
        "notes" => model.pre_registration.notes
      },
      "model" => %{
        "source_key" => sk,
        "feature_set" => model.feature_set,
        "weights" => model.weights,
        "weights_hash" => model.weights_hash,
        "model_version" => model.model_version,
        "backtest_strategy" => model.backtest_strategy,
        "model_class" => model.model_class,
        "metrics" => model.metrics,
        "calibration" => model.calibration,
        "integrity_report" => model.integrity_report,
        "holdout_spent_at" => model.holdout_spent_at,
        "lens_config_hash" => model.lens_config_hash,
        "serialized_model" => model.serialized_model,
        "run_id" => model.run_id
      },
      "active" => true
    }
    |> ModelBundle.encode_deterministic()
    |> Jason.decode!()
  end
end
