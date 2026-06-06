defmodule Cinegraph.Predictions.HoldoutPairsTest do
  @moduledoc """
  `Trainer.holdout_pairs/1` (#1074) — reproduce a served model's holdout evaluation for
  calibration refit, validated by the recall-match contract.
  """
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Metrics.CatalogSeed
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Predictions.{Model, Trainer}
  alias Cinegraph.Repo

  @sk "holdout_pairs_list"

  setup do
    CatalogSeed.seed!()
    :ok
  end

  defp film!(title, date, attrs) do
    movie =
      %Movie{}
      |> Movie.changeset(
        Map.merge(
          %{
            tmdb_id: System.unique_integer([:positive]),
            title: title,
            import_status: "full",
            release_date: date
          },
          Map.new(attrs)
        )
      )
      |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("external_metrics", [
      %{
        movie_id: movie.id,
        source: "imdb",
        metric_type: "rating_average",
        value: Map.get(Map.new(attrs), :rating, 7.0),
        fetched_at: now,
        inserted_at: now,
        updated_at: now
      }
    ])

    movie
  end

  test "temporal: reproduces pairs from stored holdout_decades; recall matches the report" do
    # one member + one non-member in the holdout decade; the member rates higher, so a
    # positive-weight model ranks it #1 of K=1 → recall 1.0
    _member =
      film!("HP Member", ~D[2021-04-04], canonical_sources: %{@sk => 1}, rating: 9.0)

    _nonmember = film!("HP Nonmember", ~D[2022-05-05], canonical_sources: %{}, rating: 5.0)

    model = %Model{
      source_key: @sk,
      backtest_strategy: "temporal",
      model_class: "linear_logreg",
      feature_set: %{"granularity" => "data_point", "features" => ["imdb_rating"]},
      weights: %{"imdb_rating" => 1.0},
      integrity_report: %{
        "holdout_decades" => [2020],
        "recall_at_k" => 1.0
      }
    }

    assert {:ok, pairs, recall} = Trainer.holdout_pairs(model)
    assert recall == 1.0
    assert length(pairs) == 2
    assert Enum.sort_by(pairs, &elem(&1, 0), :desc) |> hd() |> elem(1) == 1

    # the caller's contract: recomputed recall matches the stored report
    assert_in_delta recall, model.integrity_report["recall_at_k"], 1.0e-3
  end

  test "temporal without stored holdout_decades is honestly not reproducible" do
    model = %Model{
      source_key: @sk,
      backtest_strategy: "temporal",
      feature_set: %{"granularity" => "data_point"},
      weights: %{"imdb_rating" => 1.0},
      integrity_report: %{}
    }

    assert {:error, :no_holdout_decades} = Trainer.holdout_pairs(model)
  end

  test "static without a stored seed is honestly not reproducible" do
    model = %Model{
      source_key: @sk,
      backtest_strategy: "static",
      feature_set: %{"granularity" => "data_point", "features" => ["imdb_rating"]},
      weights: %{"imdb_rating" => 1.0},
      integrity_report: %{}
    }

    assert {:error, :no_seed} = Trainer.holdout_pairs(model)
  end

  # The contract that recalibration depends on (#1074 audit): for a FIXED DB state, a static
  # evaluation must reproduce exactly from its stored seed — same split, same pairs, same recall.
  # (Over a LIVING DB the pools drift and the recall-match guard refuses; that is by design.)
  test "static: end-to-end reproduction — evaluate, build the model, holdout_pairs matches" do
    sk = "hp_static_#{System.unique_integer([:positive])}"

    # enough members for the split guard (>= 4) + a non-member pool, across two decades
    for i <- 1..6 do
      film!("HP S Member #{i}", Date.new!(2000 + i, 3, 3), %{
        canonical_sources: %{sk => 1},
        rating: 6.0 + i * 0.5
      })
    end

    for i <- 1..20 do
      film!("HP S Pool #{i}", Date.new!(2000 + rem(i, 9), 7, 7), %{
        canonical_sources: %{},
        rating: 3.0 + rem(i, 5) * 1.0
      })
    end

    assert {:ok, %{report: report, weights: weights, feature_names: names}} =
             Trainer.evaluate_strategy(sk, "static", seed: 4242)

    model = %Model{
      source_key: sk,
      backtest_strategy: "static",
      model_class: "linear_logreg",
      feature_set: %{"granularity" => "data_point", "features" => names},
      weights: weights,
      integrity_report: report
    }

    assert {:ok, pairs, recall} = Trainer.holdout_pairs(model)
    assert pairs != []
    # exact reproduction on a fixed DB state — the recall-match guard's happy path
    assert_in_delta recall, report["recall_at_k"], 1.0e-9

    # and it is stable across repeated calls (deterministic ordering + seeded shuffle)
    assert {:ok, ^pairs, ^recall} = Trainer.holdout_pairs(model)
  end
end
