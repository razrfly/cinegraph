defmodule Cinegraph.Predictions.PromoteDemoteTest do
  @moduledoc """
  Ledger-driven promote selection/gating and demote rollback (#1061 Session 2, PR4). Tests the
  task cores (`Promote.standings/1`, `Demote.demote/2`) directly — the run/1 wrappers are thin.
  """
  use Cinegraph.DataCase

  alias Cinegraph.Movies.{Movie, MovieLists}
  alias Cinegraph.Predictions.{Model, PreRegistration, Trainer}
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

    # @list is WELL-POWERED (≥10 members in its latest decade) so `temporal_underpowered?/1` is false
    # for it — keeps the §6.1/grade tests on the temporal path. §6.4 uses a separate sparse list.
    plant_members(@list, 2000, 12)
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

  # ── §6.1/§6.2: canon_overlap is excluded from serving ─────────────────────────────
  describe "serving-bucket filter (#1068 §6.1/§6.2)" do
    test "canon_overlap is NOT activatable even at higher grade/recall; `all`/objective wins" do
      ledger_row(@list, "linear_logreg", "high", 0.90, "canon_overlap")
      ledger_row(@list, "linear_logreg", "moderate", 0.40, "all")

      [%{overall_best: overall, activatable: activatable}] = Promote.standings([@list])

      # overall_best still REPORTS canon (transparency)…
      assert overall.feature_bucket == "canon_overlap"
      assert overall.objective_recall == 0.90
      # …but only the non-circular bucket is activatable.
      assert activatable.feature_bucket == "all"
      assert activatable.objective_recall == 0.40
    end

    test "objective_only is activatable" do
      ledger_row(@list, "linear_logreg", "moderate", 0.30, "objective_only")
      [%{activatable: activatable}] = Promote.standings([@list])
      assert activatable.feature_bucket == "objective_only"
    end

    test "only canon_overlap recorded → activatable nil" do
      ledger_row(@list, "linear_logreg", "high", 0.90, "canon_overlap")
      [%{overall_best: overall, activatable: activatable}] = Promote.standings([@list])
      assert overall.feature_bucket == "canon_overlap"
      assert activatable == nil
    end
  end

  # ── §6.4: prefer static when temporal is underpowered ─────────────────────────────
  describe "power-aware strategy preference (#1068 §6.4)" do
    test "underpowered temporal → prefer the static run (even at lower grade)" do
      sparse = make_list("promote_sparse_list")
      plant_members(sparse, 2020, 3)
      assert Trainer.temporal_underpowered?(sparse)

      ledger_row(sparse, "linear_logreg", "high", 0.80, "all", "temporal")
      ledger_row(sparse, "linear_logreg", "moderate", 0.50, "all", "static")

      [%{activatable: activatable}] = Promote.standings([sparse])
      assert activatable.strategy == "static"
      assert activatable.objective_recall == 0.50
    end

    test "well-powered temporal → keep the temporal run" do
      refute Trainer.temporal_underpowered?(@list)

      ledger_row(@list, "linear_logreg", "high", 0.80, "all", "temporal")
      ledger_row(@list, "linear_logreg", "moderate", 0.50, "all", "static")

      [%{activatable: activatable}] = Promote.standings([@list])
      assert activatable.strategy == "temporal"
      assert activatable.objective_recall == 0.80
    end

    test "underpowered temporal + no servable static → activatable nil (disclose)" do
      sparse = make_list("promote_sparse_nostatic")
      plant_members(sparse, 2020, 2)
      ledger_row(sparse, "linear_logreg", "high", 0.80, "all", "temporal")

      [%{activatable: activatable}] = Promote.standings([sparse])
      assert activatable == nil
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
  defp ledger_row(sk, model_class, grade, obj, feature_bucket \\ "all", strategy \\ "temporal") do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Cinegraph.Predictions.ExperimentLedger{}
    |> Cinegraph.Predictions.ExperimentLedger.changeset(%{
      source_key: sk,
      model_class: model_class,
      backtest_strategy: strategy,
      granularity: "data_point",
      feature_bucket: feature_bucket,
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

  # Insert a movie_lists row and return its source_key (for §6.4 lists with controlled power).
  defp make_list(source_key) do
    Repo.insert_all("movie_lists", [
      list_row(source_key, DateTime.utc_now() |> DateTime.truncate(:second))
    ])

    source_key
  end

  # Plant `n` member movies in `decade` for `source_key` so `temporal_underpowered?/1` (which counts
  # members in the latest decade) is deterministic.
  defp plant_members(source_key, decade, n) do
    for i <- 1..n do
      %Movie{}
      |> Movie.changeset(%{
        tmdb_id: System.unique_integer([:positive]),
        title: "#{source_key} #{decade} #{i}",
        release_date: Date.new!(decade + rem(i, 9), 6, 1),
        import_status: "full",
        canonical_sources: %{source_key => true}
      })
      |> Repo.insert!()
    end
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
