defmodule Cinegraph.Predictions.PromoteDemoteTest do
  @moduledoc """
  Ledger-driven promote selection/gating and demote rollback (#1061 Session 2, PR4). Tests the
  task cores (`Promote.standings/1`, `Demote.demote/2`) directly — the run/1 wrappers are thin.
  """
  use Cinegraph.DataCase

  alias Cinegraph.Movies.MovieLists
  alias Cinegraph.Predictions.{Model, PreRegistration}
  alias Cinegraph.Repo
  alias Mix.Tasks.Predictions.{Demote, Promote}

  @list "promote_test_list"
  @other "promote_other_list"

  setup do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("movie_lists", [
      list_row(@list, now),
      list_row(@other, now)
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

  # ── promote standings (selection + activation gating) ────────────────────────────
  describe "Promote.standings/1" do
    test "overall best can be pooled, but only a serving-cleared (active-lifecycle) class is activatable" do
      ledger_row(@list, "linear_logreg", "high", 0.50)
      # pooled scores higher but is :experimental in lifecycle → not activatable.
      ledger_row(@list, "pooled_linear", "high", 0.90)

      [%{overall_best: overall, activatable: activatable}] = Promote.standings([@list])

      assert overall.model_class == "pooled_linear"
      assert overall.objective_recall == 0.90
      assert activatable.model_class == "linear_logreg"
      assert activatable.objective_recall == 0.50
    end

    test "an insufficient-grade linear run is not activatable" do
      ledger_row(@list, "linear_logreg", "insufficient", 0.40)

      [%{activatable: activatable, overall_best: overall}] = Promote.standings([@list])
      assert overall.model_class == "linear_logreg"
      assert activatable == nil
    end

    test "no recorded runs → both nil" do
      assert [%{overall_best: nil, activatable: nil}] = Promote.standings([@list])
    end
  end

  # ── demote (clear / auto next-best / --to + guards) ──────────────────────────────
  describe "Demote.demote/2" do
    test ":clear clears the active model and the trained_weights cache" do
      model = insert_model!(@list, sufficient_ir())
      {:ok, _} = MovieLists.set_active_prediction_model(@list, model.id, model.weights)

      assert {:ok, _list} = Demote.demote(@list, :clear)

      reloaded = MovieLists.get_by_source_key(@list)
      assert reloaded.active_prediction_model_id == nil
      assert reloaded.trained_weights == nil
    end

    test ":auto rolls back to the next-best OTHER sufficient model" do
      active = insert_model!(@list, sufficient_ir())
      fallback = insert_model!(@list, sufficient_ir())
      {:ok, _} = MovieLists.set_active_prediction_model(@list, active.id, active.weights)

      assert {:ok, _} = Demote.demote(@list, :auto)
      reloaded = MovieLists.get_by_source_key(@list)
      # repointed away from the current active, to the other sufficient model.
      assert reloaded.active_prediction_model_id == fallback.id
    end

    test ":auto clears when there is no other sufficient model" do
      only = insert_model!(@list, sufficient_ir())
      {:ok, _} = MovieLists.set_active_prediction_model(@list, only.id, only.weights)

      assert {:ok, _} = Demote.demote(@list, :auto)
      assert MovieLists.get_by_source_key(@list).active_prediction_model_id == nil
    end

    test "--to refuses a model that belongs to another list" do
      other_model = insert_model!(@other, sufficient_ir())
      assert {:error, {:wrong_list, _id, @other}} = Demote.demote(@list, other_model.id)
    end

    test "--to honors the insufficiency activation guard" do
      weak = insert_model!(@list, insufficient_ir())
      assert {:error, {:insufficient_reliability, _id}} = Demote.demote(@list, weak.id)
    end

    test "unknown list / missing model are reported" do
      assert {:error, {:unknown_list, "nope"}} = Demote.demote("nope", :clear)
      assert {:error, {:model_not_found, 999_999}} = Demote.demote(@list, 999_999)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────────
  defp ledger_row(sk, model_class, grade, obj) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Cinegraph.Predictions.ExperimentLedger{}
    |> Cinegraph.Predictions.ExperimentLedger.changeset(%{
      source_key: sk,
      model_class: model_class,
      backtest_strategy: "temporal",
      granularity: "data_point",
      feature_bucket: "all",
      status: "ok",
      grade: grade,
      metrics: %{
        "objective_recall_at_k" => obj,
        "recall_at_k" => obj,
        "baselines" => %{"popularity" => 0.05}
      },
      run_at: now
    })
    |> Repo.insert!()
  end

  defp sufficient_ir,
    do: %{
      "recall_at_k" => 0.8,
      "objective_recall_at_k" => 0.8,
      "n_positives" => 50,
      "n_evaluated" => 100_000,
      "baselines" => %{"popularity" => 0.0}
    }

  defp insufficient_ir,
    do: %{
      "recall_at_k" => 0.5,
      "n_positives" => 3,
      "n_evaluated" => 100,
      "baselines" => %{"popularity" => 0.0}
    }

  defp insert_model!(sk, integrity) do
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
        feature_set: %{"granularity" => "data_point", "features" => ["imdb_rating"]},
        weights: %{"imdb_rating" => 1.0},
        weights_hash: "h#{System.unique_integer([:positive])}",
        model_version: 1,
        model_class: "linear_logreg",
        integrity_report: integrity,
        calibration: %{"method" => "platt"},
        prereg_id: prereg.id
      })
      |> Repo.insert()

    model
  end
end
