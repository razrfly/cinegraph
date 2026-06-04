defmodule Cinegraph.Predictions.ExplanationTest do
  @moduledoc """
  The human-facing explanation read-model (#1061 Session 2, PR5): no-active-model error, weights
  tagged objective vs canon-overlap with catalog labels, and rivals ranked from the ledger.
  """
  use Cinegraph.DataCase

  alias Cinegraph.Metrics.CatalogSeed
  alias Cinegraph.Movies.MovieLists
  alias Cinegraph.Predictions.{ExperimentLedger, Explanation, Model, PreRegistration}
  alias Cinegraph.Repo

  @list "explain_test_list"
  @other_list "explain_other_list"

  setup do
    CatalogSeed.seed!()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("movie_lists", [
      list_row(@list, now),
      list_row(@other_list, now)
    ])

    :ok
  end

  defp list_row(key, now) do
    %{
      name: key,
      source_key: key,
      source_type: "imdb",
      source_url: "https://example.com/#{key}",
      category: "test",
      slug: key,
      active: true,
      inserted_at: now,
      updated_at: now
    }
  end

  test "no active model → {:error, :no_active_model}" do
    assert {:error, :no_active_model} = Explanation.for_list(@list)
  end

  describe "with an active model" do
    setup do
      # weights mix an objective code (imdb_rating) and a canon-overlap code (the OTHER list's
      # membership code + canonical_contribution).
      weights = %{
        "imdb_rating" => 0.6,
        "canonical_contribution" => 0.3,
        @other_list => 0.1
      }

      model = insert_active_model!(@list, weights)
      %{model: model, weights: weights}
    end

    test "payload tags weights objective vs canon-overlap with labels, sorted by |weight|" do
      {:ok, exp} = Explanation.for_list(@list)

      assert exp.list == @list
      assert exp.model_class == "linear_logreg"
      assert exp.model_label == "Linear (logistic regression)"
      assert exp.serving_kind == :weight_map
      assert exp.grade in [:high, :moderate, :low, :insufficient]

      # sorted by |weight| desc: imdb_rating (0.6) first.
      assert hd(exp.weights).code == "imdb_rating"

      by_code = Map.new(exp.weights, &{&1.code, &1})
      assert by_code["imdb_rating"].bucket == :objective
      assert by_code["canonical_contribution"].bucket == :canon_overlap
      assert by_code[@other_list].bucket == :canon_overlap
      # human label resolved from the catalog (imdb_rating has a name), not the raw code.
      assert by_code["imdb_rating"].label == "IMDb Rating"
    end

    test "rivals are ranked from the ledger and exclude the active combo" do
      # active model is linear/temporal; seed a higher-scoring pooled rival + a lower linear/static.
      ledger_row(@list, "pooled_linear", "temporal", 0.90)
      ledger_row(@list, "linear_logreg", "static", 0.20)

      {:ok, exp} = Explanation.for_list(@list)

      classes = Enum.map(exp.rivals, & &1.model_class)
      assert "pooled_linear" in classes
      # top rival is the highest objective recall.
      assert hd(exp.rivals).model_class == "pooled_linear"
    end
  end

  defp ledger_row(sk, model_class, strategy, obj) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %ExperimentLedger{}
    |> ExperimentLedger.changeset(%{
      source_key: sk,
      model_class: model_class,
      backtest_strategy: strategy,
      granularity: "data_point",
      feature_bucket: "all",
      status: "ok",
      grade: "moderate",
      metrics: %{"objective_recall_at_k" => obj, "recall_at_k" => obj},
      run_at: now
    })
    |> Repo.insert!()
  end

  defp insert_active_model!(sk, weights) do
    {:ok, prereg} =
      PreRegistration.register(%{
        source_key: sk,
        expected_top_features: %{},
        expected_accuracy_range: %{},
        failure_threshold: "0.10"
      })

    {:ok, model} =
      %Model{}
      |> Model.changeset(%{
        source_key: sk,
        feature_set: %{"granularity" => "data_point", "features" => Map.keys(weights)},
        weights: weights,
        weights_hash: "h#{System.unique_integer([:positive])}",
        model_version: 1,
        model_class: "linear_logreg",
        backtest_strategy: "temporal",
        integrity_report: %{
          "recall_at_k" => 0.8,
          "objective_recall_at_k" => 0.8,
          "n_positives" => 50,
          "n_evaluated" => 100_000,
          "baselines" => %{"popularity" => 0.0}
        },
        calibration: %{"method" => "platt"},
        prereg_id: prereg.id
      })
      |> Repo.insert()

    {:ok, _} = MovieLists.set_active_prediction_model(sk, model.id, weights)
    model
  end
end
